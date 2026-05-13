-- Boundary: persisted plugin settings.
--
-- Responsibility: load, normalize, save, and flush Suwayomi plugin settings from
-- KOReader's settings directory.
-- Owned state: cached LuaSettings handle and settings file path.
-- Dependencies: datastorage and luasettings.
-- External data: stored settings tables are treated as optional and normalized
-- before callers consume them.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local SuwayomiSettings = {
    settings_file = DataStorage:getSettingsDir() .. "/suwayomi_dl.lua",
    settings = nil,
}

local DEFAULT_CREDENTIALS = {
    server_url = "",
    username = "",
    password = "",
    auth_method = "basic_auth",
}

local DEFAULT_SOURCE_LANGUAGES = { "en" }
local DEFAULT_BROWSE_SETTINGS = {
    show_nsfw_sources = false,
    hide_in_library_results = false,
}
local DEFAULT_LIBRARY_CATEGORY_PICKER_BEHAVIOR = "automatic"
local LIBRARY_CATEGORY_PICKER_BEHAVIORS = {
    automatic = true,
    always = true,
    never = true,
}
local DEFAULT_DOWNLOAD_DIRECTORY = ""
local DEFAULT_MAX_PARALLEL_CHAPTER_DOWNLOADS = 2
local MIN_PARALLEL_CHAPTER_DOWNLOADS = 1
local MAX_PARALLEL_CHAPTER_DOWNLOADS = 4
local DEFAULT_MANGA_KEEP_NEXT_UNREAD_DOWNLOADS = 0
local MANGA_KEEP_NEXT_UNREAD_DOWNLOAD_LIMITS = {
    [0] = true,
    [5] = true,
    [10] = true,
    [50] = true,
}

local function copyTable(source)
    local target = {}
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

function SuwayomiSettings:normalizeMaxParallelChapterDownloads(value)
    local normalized = tonumber(value) or DEFAULT_MAX_PARALLEL_CHAPTER_DOWNLOADS
    normalized = math.floor(normalized)
    if normalized < MIN_PARALLEL_CHAPTER_DOWNLOADS then
        return MIN_PARALLEL_CHAPTER_DOWNLOADS
    end
    if normalized > MAX_PARALLEL_CHAPTER_DOWNLOADS then
        return MAX_PARALLEL_CHAPTER_DOWNLOADS
    end
    return normalized
end

function SuwayomiSettings:normalizeMangaKeepNextUnreadDownloads(value)
    local normalized = tonumber(value) or DEFAULT_MANGA_KEEP_NEXT_UNREAD_DOWNLOADS
    normalized = math.floor(normalized)
    if MANGA_KEEP_NEXT_UNREAD_DOWNLOAD_LIMITS[normalized] then
        return normalized
    end
    return DEFAULT_MANGA_KEEP_NEXT_UNREAD_DOWNLOADS
end

function SuwayomiSettings:getMangaKeepNextUnreadDownloadsKey(manga)
    if type(manga) ~= "table" then
        return nil
    end
    local key = manga.id or manga.title
    if key == nil or tostring(key) == "" then
        return nil
    end
    return tostring(key)
end

function SuwayomiSettings:open()
    if not self.settings then
        self.settings = LuaSettings:open(self.settings_file)
    end
    return self.settings
end

function SuwayomiSettings:getSettingsDir()
    return DataStorage:getSettingsDir()
end

function SuwayomiSettings:normalizeServerURL(server_url)
    if not server_url or server_url == "" then
        return ""
    end

    if server_url:match("^%a+://") then
        return server_url
    end

    return "http://" .. server_url
end

function SuwayomiSettings:load()
    local credentials = self:open():readSetting("credentials", copyTable(DEFAULT_CREDENTIALS))
    if credentials.auth_method == nil or credentials.auth_method == "" then
        credentials.auth_method = DEFAULT_CREDENTIALS.auth_method
    end
    return credentials
end

function SuwayomiSettings:save(credentials)
    local normalized = {
        server_url = self:normalizeServerURL(credentials.server_url),
        username = credentials.username or "",
        password = credentials.password or "",
        auth_method = credentials.auth_method or DEFAULT_CREDENTIALS.auth_method,
    }

    self:open():saveSetting("credentials", normalized):flush()
    return normalized
end

function SuwayomiSettings:loadSourceLanguages()
    return self:open():readSetting("source_languages", copyTable(DEFAULT_SOURCE_LANGUAGES))
end

function SuwayomiSettings:saveSourceLanguages(source_languages)
    local normalized = {}
    for _, lang in ipairs(source_languages or {}) do
        table.insert(normalized, lang)
    end

    self:open():saveSetting("source_languages", normalized):flush()
    return normalized
end

function SuwayomiSettings:normalizeBrowseSettings(browse_settings)
    browse_settings = type(browse_settings) == "table" and browse_settings or {}
    return {
        show_nsfw_sources = browse_settings.show_nsfw_sources == true,
        hide_in_library_results = browse_settings.hide_in_library_results == true,
    }
end

function SuwayomiSettings:loadBrowseSettings()
    return self:normalizeBrowseSettings(
        self:open():readSetting("browse_settings", copyTable(DEFAULT_BROWSE_SETTINGS))
    )
end

function SuwayomiSettings:saveBrowseSettings(browse_settings)
    local normalized = self:normalizeBrowseSettings(browse_settings)
    self:open():saveSetting("browse_settings", normalized):flush()
    return normalized
end

function SuwayomiSettings:normalizeLibraryCategoryPickerBehavior(behavior)
    if LIBRARY_CATEGORY_PICKER_BEHAVIORS[behavior] then
        return behavior
    end
    return DEFAULT_LIBRARY_CATEGORY_PICKER_BEHAVIOR
end

function SuwayomiSettings:loadLibraryCategoryPickerBehavior()
    return self:normalizeLibraryCategoryPickerBehavior(
        self:open():readSetting("library_category_picker_behavior", DEFAULT_LIBRARY_CATEGORY_PICKER_BEHAVIOR)
    )
end

function SuwayomiSettings:saveLibraryCategoryPickerBehavior(behavior)
    local normalized = self:normalizeLibraryCategoryPickerBehavior(behavior)
    self:open():saveSetting("library_category_picker_behavior", normalized):flush()
    return normalized
end

function SuwayomiSettings:loadSourceCache(server_url)
    local cache = self:open():readSetting("source_cache", nil)
    if type(cache) ~= "table" or cache.server_url ~= server_url then
        return nil
    end
    cache.sources = type(cache.sources) == "table" and cache.sources or {}
    cache.updated_at = tonumber(cache.updated_at) or 0
    return cache
end

function SuwayomiSettings:saveSourceCache(server_url, sources, updated_at)
    local normalized = {
        server_url = server_url or "",
        sources = {},
        updated_at = tonumber(updated_at) or os.time(),
    }
    for _, source in ipairs(sources or {}) do
        table.insert(normalized.sources, source)
    end

    self:open():saveSetting("source_cache", normalized):flush()
    return normalized
end

function SuwayomiSettings:loadDownloadDirectory()
    return self:open():readSetting("download_directory", DEFAULT_DOWNLOAD_DIRECTORY)
end

function SuwayomiSettings:saveDownloadDirectory(path)
    local normalized = path or ""
    self:open():saveSetting("download_directory", normalized):flush()
    return normalized
end

function SuwayomiSettings:loadDownloadQueue()
    return self:open():readSetting("download_queue", {})
end

function SuwayomiSettings:saveDownloadQueue(jobs)
    local normalized = {}
    for _, job in ipairs(jobs or {}) do
        table.insert(normalized, job)
    end

    self:open():saveSetting("download_queue", normalized):flush()
    return normalized
end

function SuwayomiSettings:loadMaxParallelChapterDownloads()
    return self:normalizeMaxParallelChapterDownloads(
        self:open():readSetting("max_parallel_chapter_downloads", DEFAULT_MAX_PARALLEL_CHAPTER_DOWNLOADS)
    )
end

function SuwayomiSettings:saveMaxParallelChapterDownloads(value)
    local normalized = self:normalizeMaxParallelChapterDownloads(value)
    self:open():saveSetting("max_parallel_chapter_downloads", normalized):flush()
    return normalized
end

function SuwayomiSettings:loadMangaKeepNextUnreadDownloads(manga)
    local key = self:getMangaKeepNextUnreadDownloadsKey(manga)
    if not key then
        return DEFAULT_MANGA_KEEP_NEXT_UNREAD_DOWNLOADS
    end
    local limits = self:open():readSetting("manga_keep_next_unread_downloads", {})
    if type(limits) ~= "table" then
        return DEFAULT_MANGA_KEEP_NEXT_UNREAD_DOWNLOADS
    end
    return self:normalizeMangaKeepNextUnreadDownloads(limits[key])
end

function SuwayomiSettings:saveMangaKeepNextUnreadDownloads(manga, limit)
    local key = self:getMangaKeepNextUnreadDownloadsKey(manga)
    local normalized = self:normalizeMangaKeepNextUnreadDownloads(limit)
    if not key then
        return normalized
    end

    local limits = self:open():readSetting("manga_keep_next_unread_downloads", {})
    if type(limits) ~= "table" then
        limits = {}
    end
    if normalized > 0 then
        limits[key] = normalized
    else
        limits[key] = nil
    end
    self:open():saveSetting("manga_keep_next_unread_downloads", limits):flush()
    return normalized
end

function SuwayomiSettings:loadChapterLedger()
    return self:open():readSetting("chapter_ledger", {})
end

function SuwayomiSettings:saveChapterLedger(ledger)
    self:open():saveSetting("chapter_ledger", ledger or {}):flush()
    return ledger or {}
end

function SuwayomiSettings:loadReaderReturnContexts()
    return self:open():readSetting("reader_return_contexts", {})
end

function SuwayomiSettings:saveReaderReturnContexts(contexts)
    self:open():saveSetting("reader_return_contexts", contexts or {}):flush()
    return contexts or {}
end

return SuwayomiSettings
