-- Boundary: ChapterLocalDownloads.
--
-- Responsibility: Resolve device-local chapter paths and remove managed sidecars before their archive.
-- Owned state: None; settings and downloader modules remain the source of truth.
-- Dependencies: Suwayomi settings and downloader path helpers.
-- External data: Download directory, manga/chapter metadata, and filesystem paths are treated as untrusted boundary inputs.

local SuwayomiSettings = require("suwayomi/settings")

local ChapterLocalDownloads = {}
ChapterLocalDownloads.__index = ChapterLocalDownloads

function ChapterLocalDownloads:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

function Methods:getChapterPath(manga, chapter)
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        return nil
    end

    local SuwayomiDownloader = require("suwayomi/downloads/downloader")
    if SuwayomiDownloader.findExistingChapterPath then
        local existing_path = SuwayomiDownloader:findExistingChapterPath(download_directory, manga, chapter)
        if existing_path then
            return existing_path
        end
    end

    local _, chapter_path = SuwayomiDownloader:getTargetPath(download_directory, manga, chapter)
    return chapter_path
end

function Methods:isChapterDownloaded(manga, chapter)
    local chapter_path = self:getChapterPath(manga, chapter)
    if not chapter_path then
        return false, nil
    end

    local SuwayomiDownloader = require("suwayomi/downloads/downloader")
    if SuwayomiDownloader.findExistingChapterPath then
        local download_directory = SuwayomiSettings:loadDownloadDirectory()
        local existing_path = SuwayomiDownloader:findExistingChapterPath(download_directory, manga, chapter)
        if existing_path then
            return true, existing_path
        end
    end
    return SuwayomiDownloader:chapterExists(chapter_path), chapter_path
end

function Methods:chapterArchiveExists(chapter_path)
    if not chapter_path or chapter_path == "" then
        return false
    end

    local SuwayomiDownloader = require("suwayomi/downloads/downloader")
    return SuwayomiDownloader:chapterExists(chapter_path)
end

local function removeFile(path)
    local removed, _message, code = os.remove(path)
    -- ENOENT/ENOTDIR are already absent; permission and IO failures must retry.
    return removed == true or code == 2 or code == 20
end

function Methods:removeChapterArchiveAndSidecars(chapter_path, metadata_paths)
    -- Keep the archive until metadata removal succeeds. A failed attempt or
    -- restart can still resolve hash-based sidecars from the original archive.
    if type(metadata_paths) ~= "table" then metadata_paths = { metadata_paths } end
    for _, metadata_path in ipairs(metadata_paths) do
        if not removeFile(metadata_path) or not removeFile(metadata_path .. ".old") then
            return false
        end
        local metadata_dir = metadata_path:match("^(.*)/[^/]+$")
        if metadata_dir then
            -- KOReader creates a `.sdr` sidecar directory. This intentionally
            -- keeps the previous non-recursive cleanup behavior: remove only an
            -- empty sidecar directory and ignore failures for non-empty dirs.
            os.remove(metadata_dir)
        end
    end
    return removeFile(chapter_path)
end

ChapterLocalDownloads.methods = Methods

return ChapterLocalDownloads
