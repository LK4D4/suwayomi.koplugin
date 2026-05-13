-- Boundary: ChapterLocalDownloads.
--
-- Responsibility: Resolve device-local chapter archive paths and remove local archive sidecars.
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
    local _, chapter_path = SuwayomiDownloader:getTargetPath(download_directory, manga, chapter)
    return chapter_path
end

function Methods:isChapterDownloaded(manga, chapter)
    local chapter_path = self:getChapterPath(manga, chapter)
    if not chapter_path then
        return false, nil
    end

    local SuwayomiDownloader = require("suwayomi/downloads/downloader")
    return SuwayomiDownloader:chapterExists(chapter_path), chapter_path
end

function Methods:removeChapterArchiveAndSidecars(chapter_path, metadata_path)
    os.remove(chapter_path)
    local SuwayomiDownloader = require("suwayomi/downloads/downloader")
    if SuwayomiDownloader:chapterExists(chapter_path) then
        return false
    end

    if metadata_path then
        os.remove(metadata_path)
        os.remove(metadata_path .. ".old")
        local metadata_dir = metadata_path:match("^(.*)/[^/]+$")
        if metadata_dir then
            -- KOReader creates a `.sdr` sidecar directory. This intentionally
            -- keeps the previous non-recursive cleanup behavior: remove only an
            -- empty sidecar directory and ignore failures for non-empty dirs.
            os.remove(metadata_dir)
        end
    end
    return true
end

ChapterLocalDownloads.methods = Methods

return ChapterLocalDownloads
