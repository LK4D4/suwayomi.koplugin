-- Boundary: ChapterLocalDownloads.
--
-- Responsibility: Recover recorded readable chapters, resolve scope-safe local paths, and remove managed sidecars before their archive.
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

local function records()
    return SuwayomiSettings:loadReaderReturnContexts(), SuwayomiSettings:loadChapterLedger()
end

local function matchesManga(entry, manga)
    if type(entry) ~= "table" then return false end
    if manga.id ~= nil then return tostring(entry.manga_id or "") == tostring(manga.id) end
    return entry.manga_id == nil and manga.local_manga_path
        and type(entry.path) == "string"
        and entry.path:match("^(.*)[/\\][^/\\]+$") == manga.local_manga_path
end

local function compatible(entry, manga)
    return matchesManga(entry, manga) and entry.endpoint_scope == manga.endpoint_scope
end

local function currentScope(manga)
    return not manga.endpoint_scope or manga.endpoint_scope
        == SuwayomiSettings:normalizeEndpointScope(SuwayomiSettings:load().server_url)
end

local function matchesChapter(entry, chapter)
    if chapter.id ~= nil then return tostring(entry.chapter_id or "") == tostring(chapter.id) end
    return chapter.local_path ~= nil and entry.path == chapter.local_path
end

local function foreignPaths(manga, contexts, ledger)
    local paths = {}
    for _, collection in ipairs({ contexts, ledger }) do
        for _, entry in pairs(collection) do
            if type(entry) == "table" and entry.path and entry.endpoint_scope
                and entry.endpoint_scope ~= manga.endpoint_scope then paths[entry.path] = true end
        end
    end
    return paths
end

function Methods:getRecoveredChapters(manga)
    if type(manga) ~= "table" or not currentScope(manga) then return nil end
    local downloader = require("suwayomi/downloads/downloader")
    local by_path, chapters = {}, {}
    local contexts, ledger = records()
    local foreign_paths = foreignPaths(manga, contexts, ledger)
    for _, collection in ipairs({ contexts, ledger }) do
        for _, entry in pairs(collection) do
            if matchesManga(entry, manga) and (entry.endpoint_scope == nil or entry.endpoint_scope == manga.endpoint_scope)
                and type(entry.path) == "string" and entry.path ~= ""
                and not foreign_paths[entry.path] and downloader:chapterExists(entry.path) then
                local chapter = by_path[entry.path]
                if not chapter then
                    chapter = { local_path = entry.path }
                    by_path[entry.path] = chapter
                    chapters[#chapters + 1] = chapter
                end
                if entry.endpoint_scope == manga.endpoint_scope then
                    chapter.local_only = entry.endpoint_scope == nil
                elseif chapter.local_only == nil then
                    chapter.local_only = true
                end
                if entry.chapter_id ~= nil and tostring(entry.chapter_id) ~= "" then
                    chapter.id = chapter.id or entry.chapter_id
                end
                if entry.chapter_name and entry.chapter_name ~= "" then chapter.name = chapter.name or entry.chapter_name end
                for _, field in ipairs({ "source_order", "chapter_number", "scanlator", "thumbnail_url" }) do
                    if chapter[field] == nil then chapter[field] = entry[field] end
                end
                if entry.read ~= nil then chapter.is_read = entry.read == true end
                if entry.pending_read_sync then
                    chapter.pending_read_sync = true
                    if entry.pending_read_state ~= nil then chapter.is_read = entry.pending_read_state == true end
                end
            end
        end
    end
    if #chapters == 0 then return nil end
    for _, chapter in ipairs(chapters) do
        chapter.name = chapter.name or chapter.local_path:match("[^/\\]+$") or chapter.local_path
    end
    table.sort(chapters, function(a, b)
        local left, right = tonumber(a.source_order or a.chapter_number), tonumber(b.source_order or b.chapter_number)
        if left and right and left ~= right then return left < right end
        if left ~= nil and right == nil then return true end
        if left == nil and right ~= nil then return false end
        return a.local_path < b.local_path
    end)
    return chapters
end

function Methods:isLocalOnlyChapter(manga, chapter)
    if not manga or manga.local_only or not manga.id or not chapter or chapter.local_only or not chapter.id
        or not currentScope(manga) then return true end
    local ledger = SuwayomiSettings:loadChapterLedger()
    local entry = ledger[tostring(manga.id) .. ":" .. tostring(chapter.id)]
    return type(entry) == "table" and entry.endpoint_scope ~= nil
        and entry.endpoint_scope ~= manga.endpoint_scope
end

function Methods:getChapterPath(manga, chapter)
    if type(manga) ~= "table" or type(chapter) ~= "table" or not currentScope(manga) then return nil end
    local contexts, ledger = records()
    local foreign_paths = foreignPaths(manga, contexts, ledger)
    local recorded_path
    for _, collection in ipairs({ contexts, ledger }) do
        for _, entry in pairs(collection) do
            if (compatible(entry, manga)
                or (chapter.local_only and entry.endpoint_scope == nil and matchesManga(entry, manga)))
                and matchesChapter(entry, chapter)
                and type(entry.path) == "string" and entry.path ~= ""
                and (not chapter.local_path or chapter.local_path == entry.path)
                and not foreign_paths[entry.path] and self:chapterArchiveExists(entry.path) then
                recorded_path = entry.path
                break
            end
        end
        if recorded_path then break end
    end
    if recorded_path then return recorded_path end
    -- A recovered path is a recorded selection, never permission to probe a guessed path.
    if chapter.local_path or manga.local_only then return nil end
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        return nil
    end

    local SuwayomiDownloader = require("suwayomi/downloads/downloader")
    local chapter_path = SuwayomiDownloader.findExistingChapterPath
        and SuwayomiDownloader:findExistingChapterPath(download_directory, manga, chapter)
        or select(2, SuwayomiDownloader:getTargetPath(download_directory, manga, chapter))
    if foreign_paths[chapter_path] then return nil end
    return chapter_path
end

function Methods:isChapterDownloaded(manga, chapter)
    local chapter_path = self:getChapterPath(manga, chapter)
    if not chapter_path then
        return false, nil
    end

    return self:chapterArchiveExists(chapter_path), chapter_path
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

function Methods:removeChapterArchiveAndSidecars(chapter_path, metadata_paths, validate_archive)
    -- Keep the archive until metadata removal succeeds. A failed attempt or
    -- restart can still resolve hash-based sidecars from the original archive.
    if type(metadata_paths) ~= "table" then metadata_paths = { metadata_paths } end
    for _, metadata_path in ipairs(metadata_paths) do
        if validate_archive and not validate_archive() then return false end
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
    if validate_archive and not validate_archive() then return false end
    return removeFile(chapter_path)
end

ChapterLocalDownloads.methods = Methods

return ChapterLocalDownloads
