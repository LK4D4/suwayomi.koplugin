-- Boundary: one-chapter device-local downloader.
--
-- Responsibility: download pages or direct archives, validate page data, write
-- ordered CBZ files, clean partial files, and report progress.
-- Owned state: none.
-- Dependencies: filesystem loader, KOReader archiver, API facade, and path helpers.
-- External data: page URLs, archive bytes, filesystem paths, and API responses
-- are validated before final CBZ rename.

local lfs = require("suwayomi/fs")
local SuwayomiAPI = require("suwayomi/api")
local ProgressFile = require("suwayomi/downloads/progress_file")
local Archive = require("suwayomi/downloads/archive")
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

function Downloader:getChapterPathCandidates(download_directory, manga, chapter)
    if SuwayomiPaths.getChapterPathCandidates then
        return SuwayomiPaths.getChapterPathCandidates(download_directory, manga, chapter)
    end
    local _, chapter_path = self:getTargetPath(download_directory, manga, chapter)
    return chapter_path and { chapter_path } or {}
end

function Downloader:findExistingPathInCandidates(candidates)
    for _, path in ipairs(candidates or {}) do
        if self:chapterExists(path) then
            return path
        end
    end
    return nil
end

function Downloader:findExistingChapterPath(download_directory, manga, chapter)
    return self:findExistingPathInCandidates(self:getChapterPathCandidates(download_directory, manga, chapter))
end

function Downloader:getPartialPath(chapter_path, attempt_id)
    assert(type(attempt_id) == "string" and #attempt_id == 32 and attempt_id:match("^[0-9a-f]+$"), "Invalid download attempt ID")
    return tostring(chapter_path or "") .. "." .. attempt_id .. ".part"
end

function Downloader:getDirectPartialPath(chapter_path, attempt_id)
    assert(type(attempt_id) == "string" and #attempt_id == 32 and attempt_id:match("^[0-9a-f]+$"), "Invalid download attempt ID")
    return tostring(chapter_path or "") .. "." .. attempt_id .. ".direct.part"
end

function Downloader:chapterExists(chapter_path)
    local mode, message, code = lfs.attributes(chapter_path, "mode")
    if mode then
        return mode == "file", mode ~= "file" and "not_file" or nil
    end
    if message and code ~= 2 and code ~= 20 then
        return nil, "stat_failed"
    end
    return false
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

function Downloader:failAndCleanup(message, chapter_path, writer, retryable)
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
        retryable = retryable == true,
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
    if closed == false or close_error ~= nil or writer.err ~= nil then
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

local function beginAttempt(self, download_directory, manga, chapter, options)
    if not download_directory or download_directory == "" then
        return nil, { ok = false, error = "Set up a download directory first." }
    end
    options = options or {}
    local attempt_id, entropy_error = options.attempt_id
    if attempt_id == nil then attempt_id, entropy_error = Archive.newAttemptId() end
    if type(attempt_id) ~= "string" or #attempt_id ~= 32 or not attempt_id:match("^[0-9a-f]+$") then
        return nil, { ok = false, error = entropy_error or "Invalid download attempt ID." }
    end
    local manga_dir, chapter_path = self:getTargetPath(download_directory, manga, chapter)
    local attempt = { attempt_id = attempt_id, force = options.force == true,
        manga_dir = manga_dir, chapter_path = chapter_path }
    local candidates = self:getChapterPathCandidates(download_directory, manga, chapter)
    if attempt.force and options.repair_path ~= nil then
        local supported = false
        for _, path in ipairs(candidates) do
            if path == options.repair_path then supported = true; break end
        end
        if not supported then
            return nil, { ok = false, error = "Unsupported chapter repair path.", retryable = false }
        end
        attempt.chapter_path = options.repair_path
        attempt.manga_dir = options.repair_path:match("^(.*)/[^/]+$")
        candidates = { options.repair_path }
    end
    for _, path in ipairs(candidates) do
        local exists, inspection_error = self:chapterExists(path)
        if exists then
            if attempt.force then
                attempt.chapter_path = path
                attempt.manga_dir = path:match("^(.*)/[^/]+$")
                attempt.preserve_metadata = true
                break
            end
            local result = Archive.validate(path)
            return nil, {
                ok = result.state == "valid",
                skipped = result.state == "valid" or nil,
                archive_state = result.state ~= "valid" and result.state or nil,
                identity = result.identity,
                path = path,
                error = result.error,
                retryable = false,
            }
        elseif inspection_error then
            return nil, { ok = false, archive_state = "unverified", path = path,
                error = "Could not inspect existing chapter archive.", retryable = false }
        end
    end
    return attempt
end

function Downloader:finalizePartialArchive(partial_path, chapter_path, attempt_id, expected_pages, preserve_metadata)
    local stamped, stamp_error = Archive.stamp(partial_path, attempt_id, expected_pages)
    if not stamped then
        local result = self:failAndCleanup(stamp_error, partial_path)
        result.path = chapter_path
        return result, "validation"
    end
    local inspection = Archive.validate(partial_path)
    if inspection.state ~= "valid" then
        local result = self:failAndCleanup(inspection.error or "Could not verify chapter archive.", partial_path)
        result.path = chapter_path
        return result, "validation"
    end
    if preserve_metadata then
        local resolved, preserved, preservation_error = pcall(function()
            return require("suwayomi/readsync/koreader_metadata").preserveForReplacement(chapter_path, attempt_id)
        end)
        if not resolved or not preserved then
            local result = self:failAndCleanup("Could not preserve KOReader reading metadata. "
                .. tostring(resolved and preservation_error or preserved), partial_path)
            result.path = chapter_path
            return result
        end
    end
    -- The final is shared. Never delete it or adopt it after a failed rename.
    local renamed, rename_error = os.rename(partial_path, chapter_path)
    if not renamed then
        local result = self:failAndCleanup("Could not finalize chapter archive. " .. tostring(rename_error or ""), partial_path)
        result.path = chapter_path
        return result
    end
    return { ok = true, path = chapter_path, identity = Archive.identity(chapter_path) }
end

local function downloadDirect(self, credentials, chapter, attempt)
    if not SuwayomiAPI.downloadChapterArchive or not chapter or chapter.id == nil then
        return nil
    end
    local manga_dir, chapter_path = attempt.manga_dir, attempt.chapter_path
    local directory_ok, directory_error = self:ensureDirectory(manga_dir)
    if not directory_ok then
        return { ok = false, error = directory_error, path = chapter_path }
    end

    local partial_path = self:getDirectPartialPath(chapter_path, attempt.attempt_id)

    local archive_result = callWithTransientRetry(function()
        return SuwayomiAPI.downloadChapterArchive(credentials, chapter.id, partial_path)
    end)
    if not archive_result.ok then
        self:cleanupPartialFile(partial_path)
        -- The optional export returns HTTP 400 when no server-side download exists.
        if archive_result.status_code == 400 or archive_result.status_code == 404
            or archive_result.error == "Chapter archive not found." then
            return nil
        end
        archive_result.path = chapter_path
        return archive_result
    end
    if (archive_result.bytes or 0) <= 0 or not self:isArchiveContentType(archive_result.content_type) then
        self:cleanupPartialFile(partial_path)
        return nil
    end
    -- Only a count captured by this transfer is trustworthy; never fetch current
    -- chapter metadata merely to validate an offline/exported archive.
    local result, failure = self:finalizePartialArchive(partial_path, chapter_path, attempt.attempt_id,
        archive_result.expected_pages, attempt.preserve_metadata)
    if failure == "validation" then return nil end
    return result
end

function Downloader:downloadDirectChapterArchive(credentials, download_directory, manga, chapter, options)
    local attempt, result = beginAttempt(self, download_directory, manga, chapter, options)
    if not attempt then return result end
    return downloadDirect(self, credentials, chapter, attempt)
end

function Downloader:writeProgress(progress_path, state, current, total, path, error_message, retryable, details)
    if not progress_path or progress_path == "" then return end
    ProgressFile.writeFallback(progress_path, state, current, total, path, error_message, retryable, details)
end

local function startDownload(self, credentials, chapter, attempt)
    local manga_dir, chapter_path = attempt.manga_dir, attempt.chapter_path
    local partial_path = self:getPartialPath(chapter_path, attempt.attempt_id)

    local page_result = callWithTransientRetry(function()
        return SuwayomiAPI.fetchChapterPages(credentials, chapter.id)
    end)
    if not page_result.ok then
        return {
            ok = false,
            error = page_result.error,
            path = chapter_path,
            retryable = isRetryableResult(page_result),
        }
    end
    if #page_result.pages == 0 then
        return { ok = false, error = "Suwayomi server did not return chapter pages.", path = chapter_path }
    end

    local directory_ok, directory_error = self:ensureDirectory(manga_dir)
    if not directory_ok then
        return { ok = false, error = directory_error, path = chapter_path }
    end

    local available, Archiver = pcall(require, "ffi/archiver")
    if not available or type(Archiver) ~= "table" or not Archiver.Writer then
        return { ok = false, error = "Chapter archive writer is unavailable.", path = chapter_path, retryable = false }
    end
    local writer = Archiver.Writer:new()
    if not writer:open(partial_path, "zip") then
        local result = self:failAndCleanup(writer.err or "Could not create chapter archive.", partial_path, writer)
        result.path = chapter_path
        return result
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
            attempt_id = attempt.attempt_id,
            preserve_metadata = attempt.preserve_metadata,
            partial_path = partial_path,
            current = 0,
            written = 0,
        },
    }
end

function Downloader:startChapterDownload(credentials, download_directory, manga, chapter, options)
    local attempt, result = beginAttempt(self, download_directory, manga, chapter, options)
    if not attempt then return result end
    return startDownload(self, credentials, chapter, attempt)
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

    local result = self:finalizePartialArchive(job.partial_path, job.chapter_path, job.attempt_id,
        #job.pages, job.preserve_metadata)
    result.done = result.ok
    result.current = job.current
    result.total = #job.pages
    return result
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
        local result = self:failAndCleanup(binary.error, job.partial_path, job.writer, isRetryableResult(binary))
        result.current = job.current
        result.total = #job.pages
        result.path = job.chapter_path
        return result
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

local function downloadChapter(self, credentials, download_directory, manga, chapter, progress_path, options)
    local function report(result, current, total)
        self:writeProgress(progress_path,
            result.skipped and "skipped" or (result.ok and "downloaded" or "failed"),
            result.current or current or 0, result.total or total or 0,
            result.path, result.error, result.retryable, result)
        return result
    end
    local attempt, result = beginAttempt(self, download_directory, manga, chapter, options)
    if not attempt then return report(result) end
    local direct_result = downloadDirect(self, credentials, chapter, attempt)
    if direct_result then return report(direct_result, direct_result.ok and 1 or 0, direct_result.ok and 1 or 0) end
    -- Share this attempt through optional-export fallback without inspecting a
    -- final that another worker may have published while the export ran.
    local start_result = startDownload(self, credentials, chapter, attempt)
    if not start_result.ok then return report(start_result) end
    repeat
        result = self:downloadNextPage(start_result.job)
        if not result.ok or result.done then
            result.path = result.path or start_result.path
            return report(result, start_result.job.current, start_result.total)
        end
        self:writeProgress(progress_path, "downloading", result.current, result.total, result.path)
    until result.done
end

function Downloader:downloadChapter(credentials, download_directory, manga, chapter, options)
    return downloadChapter(self, credentials, download_directory, manga, chapter, nil, options)
end

function Downloader:downloadChapterWithProgress(credentials, download_directory, manga, chapter, progress_path, options)
    return downloadChapter(self, credentials, download_directory, manga, chapter, progress_path, options)
end

return Downloader
