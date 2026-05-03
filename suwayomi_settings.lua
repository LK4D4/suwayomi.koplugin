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
local DEFAULT_DOWNLOAD_DIRECTORY = ""
local DEFAULT_MAX_PARALLEL_CHAPTER_DOWNLOADS = 2
local MIN_PARALLEL_CHAPTER_DOWNLOADS = 1
local MAX_PARALLEL_CHAPTER_DOWNLOADS = 4

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

function SuwayomiSettings:loadChapterLedger()
    return self:open():readSetting("chapter_ledger", {})
end

function SuwayomiSettings:saveChapterLedger(ledger)
    self:open():saveSetting("chapter_ledger", ledger or {}):flush()
    return ledger or {}
end

return SuwayomiSettings
