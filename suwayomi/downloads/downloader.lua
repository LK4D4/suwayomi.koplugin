local lfs = require("lfs")
local Archiver = require("ffi/archiver")
local SuwayomiAPI = require("suwayomi/api")
local SuwayomiPaths = require("suwayomi/paths")

local Downloader = {}

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
        writer:close()
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

function Downloader:isArchiveContentType(content_type)
    content_type = tostring(content_type or ""):lower()
    return content_type:match("comicbook") ~= nil
        or content_type:match("cbz") ~= nil
        or content_type:match("zip") ~= nil
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

    local archive_result = SuwayomiAPI.downloadChapterArchive(credentials, chapter.id, partial_path)
    if not archive_result.ok then
        self:cleanupPartialFile(partial_path)
        return nil
    end
    if (archive_result.bytes or 0) <= 0 or not self:isArchiveContentType(archive_result.content_type) then
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

    handle:write("state=", tostring(state or ""), "\n")
    handle:write("current=", tostring(current or 0), "\n")
    handle:write("total=", tostring(total or 0), "\n")
    handle:write("path=", tostring(path or ""), "\n")
    if error_message then
        handle:write("error=", tostring(error_message), "\n")
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

    local page_result = SuwayomiAPI.fetchChapterPages(credentials, chapter.id)
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
            job.writer:close()
            job.writer = nil
        end
        return self:finalizeChapterArchive(job)
    end

    local next_index = job.current + 1
    local binary = SuwayomiAPI.downloadBinary(job.credentials, job.pages[next_index])
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
        job.writer:close()
        job.writer = nil
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
