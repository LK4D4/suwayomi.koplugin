-- Boundary: one-chapter device-local downloader.
--
-- Responsibility: download pages or direct archives, validate page data, write
-- ordered CBZ files, clean partial files, and report progress.
-- Owned state: none.
-- Dependencies: lfs, KOReader archiver, API facade, and path helpers.
-- External data: page URLs, archive bytes, filesystem paths, and API responses
-- are validated before final CBZ rename.

local lfs = require("lfs")
local Archiver = require("ffi/archiver")
local SuwayomiAPI = require("suwayomi/api")
local ProgressFile = require("suwayomi/downloads/progress_file")
local SuwayomiPaths = require("suwayomi/paths")

local Downloader = {}
local DOWNLOAD_RETRY_DELAYS_SECONDS = { 0.5, 1 }

local function sleep(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.sleep then
        socket.sleep(seconds)
    end
end

local function isTransientDownloadError(error_message)
    error_message = tostring(error_message or ""):lower()
    return error_message:match("timed out") ~= nil
        or error_message:match("timeout") ~= nil
        or error_message:match("could not reach") ~= nil
        or error_message:match("could not download chapter page") ~= nil
        or error_message:match("too many requests") ~= nil
        or error_message:match("rate limit") ~= nil
        or error_message:match("server error") ~= nil
        or error_message:match("bad gateway") ~= nil
        or error_message:match("service unavailable") ~= nil
        or error_message:match("gateway timeout") ~= nil
end

local function isRetryableResult(result)
    if type(result) == "table" and result.retryable ~= nil then
        return result.retryable == true
    end
    return isTransientDownloadError(result and result.error)
end

local function callWithTransientRetry(callback)
    local result
    for attempt = 1, #DOWNLOAD_RETRY_DELAYS_SECONDS + 1 do
        result = callback() or {}
        if result.ok == true then
            return result
        end
        if attempt > #DOWNLOAD_RETRY_DELAYS_SECONDS or not isRetryableResult(result) then
            return result
        end
        sleep(DOWNLOAD_RETRY_DELAYS_SECONDS[attempt])
    end
    return result
end

function Downloader:sanitizePathSegment(name)
    return SuwayomiPaths.sanitizePathSegment(name)
end

function Downloader:getTargetPath(download_directory, manga, chapter)
    return SuwayomiPaths.getTargetPath(download_directory, manga, chapter)
end

function Downloader:getPartialPath(chapter_path)
    return tostring(chapter_path or "") .. ".part"
end

function Downloader:getDirectPartialPath(chapter_path)
    return tostring(chapter_path or "") .. ".direct.part"
end

function Downloader:chapterExists(chapter_path)
    return lfs.attributes(chapter_path, "mode") == "file"
end

function Downloader:ensureDirectory(path)
    if lfs.attributes(path, "mode") == "directory" then
        return true
    end

    local parent = tostring(path or ""):match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path and lfs.attributes(parent, "mode") ~= "directory" then
        local parent_ok, parent_error = self:ensureDirectory(parent)
        if not parent_ok then
            return false, parent_error
        end
    end

    if lfs.mkdir(path) then
        return true
    end

    return false, "Could not create manga folder."
end

function Downloader:cleanupPartialFile(path)
    if path and path ~= "" then
        local removed = os.remove(path)
        if removed then
            return true
        end
        if not lfs.attributes then
            return true
        end
        if lfs.attributes(path, "mode") ~= "file" then
            return true
        end
        return false, "Could not remove partial chapter archive."
    end
    return true
end

function Downloader:failAndCleanup(message, chapter_path, writer)
    if writer then
        local closed, close_error = self:closeArchiveWriter(writer)
        if not closed and close_error and close_error ~= "" then
            message = tostring(message or "") .. " " .. tostring(close_error)
        end
    end
    local cleanup_ok, cleanup_error = self:cleanupPartialFile(chapter_path)
    local result = {
        ok = false,
        error = message,
    }
    if not cleanup_ok then
        result.cleanup_error = cleanup_error
    end
    return result
end

function Downloader:closeArchiveWriter(writer)
    if not writer then
        return true
    end

    local ok, closed, close_error = pcall(function()
        return writer:close()
    end)
    if not ok then
        return false, "Could not close chapter archive. " .. tostring(closed)
    end
    if closed == false or close_error ~= nil then
        return false, "Could not close chapter archive. " .. tostring(close_error or writer.err or "unknown error")
    end
    return true
end

function Downloader:isArchiveContentType(content_type)
    content_type = tostring(content_type or ""):lower()
    return content_type:match("comicbook") ~= nil
        or content_type:match("cbz") ~= nil
        or content_type:match("zip") ~= nil
end

function Downloader:isZipHeader(header_bytes)
    header_bytes = tostring(header_bytes or "")
    return header_bytes:sub(1, 4) == "PK\003\004"
        or header_bytes:sub(1, 4) == "PK\005\006"
        or header_bytes:sub(1, 4) == "PK\007\008"
end

local function readUInt16LE(bytes, index)
    local first = bytes:byte(index)
    local second = bytes:byte(index + 1)
    if not first or not second then
        return nil
    end
    return first + (second * 256)
end

local function readUInt32LE(bytes, index)
    local low = readUInt16LE(bytes, index)
    local high = readUInt16LE(bytes, index + 2)
    if not low or not high then
        return nil
    end
    return low + (high * 65536)
end

local function hasFlag(value, flag)
    return value and value % (flag * 2) >= flag
end

local function parseCentralDirectoryEntry(bytes, index, limit)
    if index + 45 > limit or bytes:sub(index, index + 3) ~= "PK\001\002" then
        return nil
    end

    local name_length = readUInt16LE(bytes, index + 28)
    local extra_length = readUInt16LE(bytes, index + 30)
    local comment_length = readUInt16LE(bytes, index + 32)
    local compressed_size = readUInt32LE(bytes, index + 20)
    local local_header_offset = readUInt32LE(bytes, index + 42)
    local flags = readUInt16LE(bytes, index + 8)
    if not name_length
        or name_length == 0
        or not extra_length
        or not comment_length
        or not compressed_size
        or not local_header_offset
        or not flags
    then
        return nil
    end

    local length = 46 + name_length + extra_length + comment_length
    if index + length - 1 > limit then
        return nil
    end

    return {
        length = length,
        name_length = name_length,
        compressed_size = compressed_size,
        local_header_offset = local_header_offset,
        flags = flags,
    }
end

local function readArchiveBytes(archive_result, archive_path, offset, length)
    local head_bytes = tostring(archive_result.head_bytes or archive_result.header_bytes or "")
    if offset >= 0 and offset + length <= #head_bytes then
        return head_bytes:sub(offset + 1, offset + length)
    end

    local tail_bytes = tostring(archive_result.tail_bytes or "")
    local tail_offset = (archive_result.bytes or 0) - #tail_bytes
    if offset >= tail_offset and offset + length <= tail_offset + #tail_bytes then
        local start_index = offset - tail_offset + 1
        return tail_bytes:sub(start_index, start_index + length - 1)
    end

    if not archive_path or archive_path == "" then
        return nil
    end
    local handle = io.open(archive_path, "rb")
    if not handle then
        return nil
    end
    local seek_ok = handle:seek("set", offset)
    local bytes
    if seek_ok then
        bytes = handle:read(length)
    end
    handle:close()
    if type(bytes) ~= "string" or #bytes ~= length then
        return nil
    end
    return bytes
end

local function parseLocalHeader(archive_result, archive_path, offset)
    local header = readArchiveBytes(archive_result, archive_path, offset, 30)
    if not header or header:sub(1, 4) ~= "PK\003\004" then
        return nil
    end

    local flags = readUInt16LE(header, 7)
    local compressed_size = readUInt32LE(header, 19)
    local name_length = readUInt16LE(header, 27)
    local extra_length = readUInt16LE(header, 29)
    if not flags or not compressed_size or not name_length or not extra_length or name_length == 0 then
        return nil
    end

    return {
        flags = flags,
        compressed_size = compressed_size,
        name_length = name_length,
        header_length = 30 + name_length + extra_length,
    }
end

local function isAllowedDescriptorGap(uses_data_descriptor, gap)
    if uses_data_descriptor then
        return gap == 12 or gap == 16
    end
    return gap == 0
end

function Downloader:isZipArchiveResult(archive_result, archive_path)
    if not archive_result or (archive_result.bytes or 0) < 22 then
        return false
    end
    local header_signature = tostring(archive_result.header_bytes or ""):sub(1, 4)
    if not self:isZipHeader(header_signature) then
        return false
    end

    local tail_bytes = tostring(archive_result.tail_bytes or "")
    local eocd_start
    for index = math.max(#tail_bytes - 21, 1), 1, -1 do
        if tail_bytes:sub(index, index + 3) == "PK\005\006" then
            eocd_start = index
            break
        end
    end
    if not eocd_start or #tail_bytes - eocd_start + 1 < 22 then
        return false
    end

    local comment_length = readUInt16LE(tail_bytes, eocd_start + 20)
    if not comment_length or eocd_start + 21 + comment_length ~= #tail_bytes then
        return false
    end

    local entry_count = readUInt16LE(tail_bytes, eocd_start + 10)
    local central_dir_size = readUInt32LE(tail_bytes, eocd_start + 12)
    local central_dir_offset = readUInt32LE(tail_bytes, eocd_start + 16)
    if not entry_count or not central_dir_size or not central_dir_offset then
        return false
    end

    local eocd_offset = archive_result.bytes - (#tail_bytes - eocd_start + 1)
    if eocd_offset < 0 or central_dir_offset + central_dir_size ~= eocd_offset then
        return false
    end
    if entry_count == 0 and central_dir_size == 0 then
        return false
    end
    if header_signature ~= "PK\003\004" or entry_count == 0 or central_dir_size == 0 or central_dir_offset <= 0 then
        return false
    end

    if central_dir_size < 46 then
        return false
    end
    local central_dir_bytes = readArchiveBytes(archive_result, archive_path, central_dir_offset, central_dir_size)
    if not central_dir_bytes then
        return false
    end

    local central_dir_end = central_dir_size
    local central_index = 1
    local entries = {}
    for _ = 1, entry_count do
        local entry = parseCentralDirectoryEntry(central_dir_bytes, central_index, central_dir_end)
        if not entry then
            return false
        end
        local local_header = parseLocalHeader(archive_result, archive_path, entry.local_header_offset)
        if not local_header then
            return false
        end
        local uses_data_descriptor = hasFlag(local_header.flags, 8)
        if uses_data_descriptor ~= hasFlag(entry.flags, 8)
            or entry.local_header_offset >= central_dir_offset
            or local_header.name_length ~= entry.name_length
            or entry.local_header_offset + local_header.header_length + entry.compressed_size > central_dir_offset
        then
            return false
        end
        if not uses_data_descriptor and local_header.compressed_size ~= entry.compressed_size then
            return false
        end
        table.insert(entries, {
            local_header_offset = entry.local_header_offset,
            payload_end = entry.local_header_offset + local_header.header_length + entry.compressed_size,
            uses_data_descriptor = uses_data_descriptor,
        })
        central_index = central_index + entry.length
    end
    if central_index ~= central_dir_end + 1 or #entries == 0 then
        return false
    end
    table.sort(entries, function(left, right)
        return left.local_header_offset < right.local_header_offset
    end)

    local previous_payload_end = 0
    local previous_uses_data_descriptor = false
    for _, entry in ipairs(entries) do
        local gap = entry.local_header_offset - previous_payload_end
        if not isAllowedDescriptorGap(previous_uses_data_descriptor, gap) then
            return false
        end
        previous_payload_end = entry.payload_end
        previous_uses_data_descriptor = entry.uses_data_descriptor
    end
    if not isAllowedDescriptorGap(previous_uses_data_descriptor, central_dir_offset - previous_payload_end) then
        return false
    end

    return true
end

function Downloader:finalizePartialArchive(partial_path, chapter_path)
    local renamed, rename_error = os.rename(partial_path, chapter_path)
    if renamed then
        return {
            ok = true,
            path = chapter_path,
        }
    end

    if self:chapterExists(chapter_path) then
        self:cleanupPartialFile(partial_path)
        return {
            ok = true,
            skipped = true,
            path = chapter_path,
        }
    end

    self:cleanupPartialFile(partial_path)
    local error_message = "Could not finalize chapter archive."
    if rename_error and tostring(rename_error) ~= "" then
        error_message = error_message .. " " .. tostring(rename_error)
    end
    return {
        ok = false,
        error = error_message,
        path = chapter_path,
    }
end

function Downloader:downloadDirectChapterArchive(credentials, download_directory, manga, chapter)
    if not SuwayomiAPI.downloadChapterArchive or not chapter or chapter.id == nil then
        return nil
    end

    if not download_directory or download_directory == "" then
        return { ok = false, error = "Set up a download directory first." }
    end

    local manga_dir, chapter_path = self:getTargetPath(download_directory, manga, chapter)
    if self:chapterExists(chapter_path) then
        return { ok = true, skipped = true, path = chapter_path }
    end

    local directory_ok, directory_error = self:ensureDirectory(manga_dir)
    if not directory_ok then
        return { ok = false, error = directory_error }
    end

    local partial_path = self.getDirectPartialPath and self:getDirectPartialPath(chapter_path) or self:getPartialPath(chapter_path)
    self:cleanupPartialFile(partial_path)

    local archive_result = callWithTransientRetry(function()
        return SuwayomiAPI.downloadChapterArchive(credentials, chapter.id, partial_path)
    end)
    if not archive_result.ok then
        self:cleanupPartialFile(partial_path)
        return nil
    end
    if (archive_result.bytes or 0) <= 0
        or not self:isArchiveContentType(archive_result.content_type)
        or not self:isZipArchiveResult(archive_result, partial_path)
    then
        self:cleanupPartialFile(partial_path)
        return nil
    end

    return self:finalizePartialArchive(partial_path, chapter_path)
end

function Downloader:writeProgress(progress_path, state, current, total, path, error_message)
    if not progress_path or progress_path == "" then
        return
    end

    local tmp_path = tostring(progress_path) .. ".tmp"
    local handle = io.open(tmp_path, "w")
    if not handle then
        return
    end

    handle:write("state=", ProgressFile.lineSafe(state), "\n")
    handle:write("current=", ProgressFile.lineSafe(current or 0), "\n")
    handle:write("total=", ProgressFile.lineSafe(total or 0), "\n")
    handle:write("path=", ProgressFile.lineSafe(path), "\n")
    if error_message then
        handle:write("error=", ProgressFile.lineSafe(error_message), "\n")
    end
    handle:close()
    if not os.rename(tmp_path, progress_path) then
        os.remove(tmp_path)
    end
end

function Downloader:startChapterDownload(credentials, download_directory, manga, chapter)
    if not download_directory or download_directory == "" then
        return { ok = false, error = "Set up a download directory first." }
    end

    local manga_dir, chapter_path = self:getTargetPath(download_directory, manga, chapter)
    if self:chapterExists(chapter_path) then
        return { ok = true, skipped = true, path = chapter_path }
    end
    local partial_path = self:getPartialPath(chapter_path)

    local page_result = callWithTransientRetry(function()
        return SuwayomiAPI.fetchChapterPages(credentials, chapter.id)
    end)
    if not page_result.ok then
        return { ok = false, error = page_result.error }
    end
    if #page_result.pages == 0 then
        return { ok = false, error = "Suwayomi server did not return chapter pages." }
    end

    local directory_ok, directory_error = self:ensureDirectory(manga_dir)
    if not directory_ok then
        return { ok = false, error = directory_error }
    end

    self:cleanupPartialFile(partial_path)
    local writer = Archiver.Writer:new()
    if not writer:open(partial_path, "zip") then
        return { ok = false, error = writer.err or "Could not create chapter archive." }
    end

    return {
        ok = true,
        path = chapter_path,
        total = #page_result.pages,
        job = {
            credentials = credentials,
            pages = page_result.pages,
            writer = writer,
            chapter_path = chapter_path,
            partial_path = partial_path,
            current = 0,
            written = 0,
        },
    }
end

function Downloader:validatePage(binary)
    if not binary.body or #binary.body == 0 then
        return false, "Downloaded chapter page was empty."
    end

    local content_type = tostring(binary.content_type or ""):lower()
    if not content_type:match("^image/") then
        return false, "Downloaded chapter page was not an image."
    end

    return true
end

function Downloader:finalizeChapterArchive(job)
    local written = job.written
    if written == nil then
        written = job.current
    end

    if written ~= #job.pages then
        self:cleanupPartialFile(job.partial_path)
        return {
            ok = false,
            error = "Chapter archive page count did not match Suwayomi page count.",
            current = job.current,
            total = #job.pages,
            path = job.chapter_path,
        }
    end

    local renamed, rename_error = os.rename(job.partial_path, job.chapter_path)
    if not renamed then
        if self:chapterExists(job.chapter_path) then
            self:cleanupPartialFile(job.partial_path)
            return {
                ok = true,
                done = true,
                skipped = true,
                current = job.current,
                total = #job.pages,
                path = job.chapter_path,
            }
        end
        self:cleanupPartialFile(job.partial_path)
        local error_message = "Could not finalize chapter archive."
        if rename_error and tostring(rename_error) ~= "" then
            error_message = error_message .. " " .. tostring(rename_error)
        end
        return {
            ok = false,
            error = error_message,
            current = job.current,
            total = #job.pages,
            path = job.chapter_path,
        }
    end

    return {
        ok = true,
        done = true,
        current = job.current,
        total = #job.pages,
        path = job.chapter_path,
    }
end

function Downloader:downloadNextPage(job)
    if not job or not job.pages then
        return { ok = false, error = "Invalid chapter download job." }
    end

    if job.current >= #job.pages then
        if job.writer then
            local closed, close_error = self:closeArchiveWriter(job.writer)
            job.writer = nil
            if not closed then
                return self:failAndCleanup(close_error, job.partial_path)
            end
        end
        return self:finalizeChapterArchive(job)
    end

    local next_index = job.current + 1
    local binary = callWithTransientRetry(function()
        return SuwayomiAPI.downloadBinary(job.credentials, job.pages[next_index])
    end)
    if not binary.ok then
        return self:failAndCleanup(binary.error, job.partial_path, job.writer)
    end
    local valid_page, validation_error = self:validatePage(binary)
    if not valid_page then
        return self:failAndCleanup(validation_error, job.partial_path, job.writer)
    end

    local ext = binary.content_type == "image/webp" and "webp"
        or binary.content_type == "image/png" and "png"
        or "jpg"

    local entry_name = string.format("%04d.%s", next_index, ext)
    if not job.writer:addFileFromMemory(entry_name, binary.body) then
        return self:failAndCleanup(job.writer.err or "Could not write chapter archive.", job.partial_path, job.writer)
    end

    job.current = next_index
    job.written = (job.written or 0) + 1
    local done = job.current == #job.pages
    if done then
        local closed, close_error = self:closeArchiveWriter(job.writer)
        job.writer = nil
        if not closed then
            return self:failAndCleanup(close_error, job.partial_path)
        end
        return self:finalizeChapterArchive(job)
    end

    return {
        ok = true,
        done = done,
        current = job.current,
        total = #job.pages,
        path = job.chapter_path,
    }
end

function Downloader:downloadChapter(credentials, download_directory, manga, chapter)
    local direct_result = self:downloadDirectChapterArchive(credentials, download_directory, manga, chapter)
    if direct_result then
        return direct_result
    end

    local start_result = self:startChapterDownload(credentials, download_directory, manga, chapter)
    if not start_result.ok or start_result.skipped then
        return start_result
    end

    local result
    repeat
        result = self:downloadNextPage(start_result.job)
        if not result.ok then
            return result
        end
    until result.done

    return { ok = true, skipped = result and result.skipped, path = start_result.path }
end

function Downloader:downloadChapterWithProgress(credentials, download_directory, manga, chapter, progress_path)
    local direct_result = self:downloadDirectChapterArchive(credentials, download_directory, manga, chapter)
    if direct_result then
        self:writeProgress(
            progress_path,
            direct_result.skipped and "skipped" or (direct_result.ok and "downloaded" or "failed"),
            direct_result.ok and 1 or 0,
            direct_result.ok and 1 or 0,
            direct_result.path,
            direct_result.error
        )
        return direct_result
    end

    local start_result = self:startChapterDownload(credentials, download_directory, manga, chapter)
    if not start_result.ok or start_result.skipped then
        self:writeProgress(
            progress_path,
            start_result.skipped and "skipped" or (start_result.ok and "downloaded" or "failed"),
            start_result.ok and 1 or 0,
            start_result.ok and 1 or 0,
            start_result.path,
            start_result.error
        )
        return start_result
    end

    local result
    repeat
        result = self:downloadNextPage(start_result.job)
        if not result.ok then
            self:writeProgress(progress_path, "failed", 0, start_result.total, start_result.path, result.error)
            return result
        end
        self:writeProgress(
            progress_path,
            result.skipped and "skipped" or (result.done and "downloaded" or "downloading"),
            result.current,
            result.total,
            result.path
        )
    until result.done

    return { ok = true, path = start_result.path }
end

return Downloader
