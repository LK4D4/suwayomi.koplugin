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
local SourceFilters = require("suwayomi/source_filters")

local SuwayomiSettings = {
    settings_file = DataStorage:getSettingsDir() .. "/suwayomi.lua",
    settings = nil,
}

local DEFAULT_CREDENTIALS = {
    server_url = "",
    username = "",
    password = "",
    auth_method = "basic_auth",
}
local SUPPORTED_AUTH_METHODS = {
    basic_auth = true,
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
local DEFAULT_DELETE_CHAPTERS_SETTINGS = {
    delete_after_mark_read = false,
    delete_finished_while_reading = 0,
}
local DELETE_FINISHED_WHILE_READING_LIMITS = {
    [0] = true,
    [1] = true,
    [2] = true,
    [3] = true,
    [4] = true,
    [5] = true,
}
local DEFAULT_MANGA_KEEP_NEXT_UNREAD_DOWNLOADS = 0
local MANGA_KEEP_NEXT_UNREAD_DOWNLOAD_LIMITS = {
    [0] = true,
    [5] = true,
    [10] = true,
    [50] = true,
}
local FINISHED_CLEANUP_VERSION = 1

local function copyTable(source)
    local target = {}
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

local function emptyFinishedCleanupJournal()
    return { version = FINISHED_CLEANUP_VERSION, next_sequence = 1, mangas = {} }
end

local function finiteNonNegative(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or value < 0 then
        return nil
    end
    return value
end

local function tablesEqual(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do
        if not tablesEqual(value, right[key]) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function normalizeFinishedCleanupJournal(value)
    if type(value) ~= "table" then
        return emptyFinishedCleanupJournal(), true
    end
    if value.version ~= nil and value.version ~= FINISHED_CLEANUP_VERSION then
        return value, false, "unsupported_version"
    end

    local normalized = emptyFinishedCleanupJournal()
    local max_sequence = 0
    if type(value.mangas) == "table" then
        for manga_key, manga in pairs(value.mangas) do
            local key = type(manga_key) == "string" and manga_key or tostring(manga_key)
            if key ~= "" and type(manga) == "table" and type(manga.records) == "table" then
                local by_chapter = {}
                for _, record in pairs(manga.records) do
                    if type(record) == "table" and type(record.chapter_id) == "string"
                        and record.chapter_id ~= "" and type(record.path) == "string" and record.path ~= "" then
                        local sequence = finiteNonNegative(record.sequence)
                        local retry_count = finiteNonNegative(record.retry_count)
                        local retry_after = finiteNonNegative(record.retry_after)
                        if sequence and retry_count and retry_after then
                            local accepted = { chapter_id = record.chapter_id, path = record.path,
                                sequence = sequence, retry_count = retry_count, retry_after = retry_after }
                            local previous = by_chapter[record.chapter_id]
                            if not previous or sequence > previous.sequence then
                                by_chapter[record.chapter_id] = accepted
                            end
                            if sequence > max_sequence then max_sequence = sequence end
                        end
                    end
                end
                local records = {}
                for _, record in pairs(by_chapter) do table.insert(records, record) end
                table.sort(records, function(left, right)
                    if left.sequence == right.sequence then return left.chapter_id < right.chapter_id end
                    return left.sequence < right.sequence
                end)
                if #records > 0 then normalized.mangas[key] = { records = records } end
            end
        end
    end
    local next_sequence = finiteNonNegative(value.next_sequence) or 1
    normalized.next_sequence = math.max(1, next_sequence, max_sequence + 1)
    return normalized, not tablesEqual(value, normalized)
end

local function toStringOrDefault(value, default)
    if value == nil then
        return default or ""
    end
    return tostring(value)
end

local function normalizeDownloadDirectory(value)
    if type(value) ~= "string" then
        return DEFAULT_DOWNLOAD_DIRECTORY
    end
    return value
end

local function rollingHash(text, seed, multiplier)
    local hash = seed
    multiplier = multiplier or 131
    for index = 1, #text do
        hash = (hash * multiplier + text:byte(index)) % 4294967296
    end
    return hash
end

local function hashText(text)
    return string.format(
        "%08x%08x",
        rollingHash(text, 2166136261, 131),
        rollingHash(text, 16777619, 65599)
    )
end

function SuwayomiSettings:normalizeCredentials(credentials)
    if type(credentials) ~= "table" then
        credentials = {}
    end
    local auth_method = toStringOrDefault(credentials.auth_method, DEFAULT_CREDENTIALS.auth_method)
    if not SUPPORTED_AUTH_METHODS[auth_method] then
        auth_method = DEFAULT_CREDENTIALS.auth_method
    end
    return {
        server_url = self:normalizeServerURL(toStringOrDefault(credentials.server_url, DEFAULT_CREDENTIALS.server_url)),
        username = toStringOrDefault(credentials.username, DEFAULT_CREDENTIALS.username),
        password = toStringOrDefault(credentials.password, DEFAULT_CREDENTIALS.password),
        auth_method = auth_method,
    }
end

function SuwayomiSettings:getAuthIdentity(credentials)
    if type(credentials) ~= "table" then
        return ""
    end
    local normalized = self:normalizeCredentials(credentials)
    return hashText(table.concat({
        normalized.auth_method,
        normalized.username,
        normalized.password,
    }, "\n"))
end

function SuwayomiSettings:getSourceCacheScope(credentials_or_url)
    if type(credentials_or_url) == "table" then
        local credentials = self:normalizeCredentials(credentials_or_url)
        return credentials.server_url, self:getAuthIdentity(credentials)
    end
    return tostring(credentials_or_url or ""), ""
end

function SuwayomiSettings:normalizeChapterLedgerEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local normalized = {
        manga_id = entry.manga_id ~= nil and tostring(entry.manga_id) or nil,
        manga_title = entry.manga_title ~= nil and tostring(entry.manga_title) or nil,
        chapter_id = entry.chapter_id ~= nil and tostring(entry.chapter_id) or nil,
        chapter_name = entry.chapter_name ~= nil and tostring(entry.chapter_name) or nil,
        path = entry.path ~= nil and tostring(entry.path) or nil,
        read = entry.read == true,
        pending_read_sync = entry.pending_read_sync == true or nil,
    }
    if entry.pending_read_state ~= nil then
        normalized.pending_read_state = entry.pending_read_state == true or entry.pending_read_state == 1
    end
    return normalized
end

function SuwayomiSettings:normalizeChapterLedger(ledger)
    if type(ledger) ~= "table" then
        return {}
    end
    local normalized = {}
    for key, entry in pairs(ledger) do
        local normalized_entry = self:normalizeChapterLedgerEntry(entry)
        if normalized_entry then
            normalized[tostring(key)] = normalized_entry
        end
    end
    return normalized
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

function SuwayomiSettings:normalizeDeleteChaptersSettings(value)
    if type(value) ~= "table" then
        return copyTable(DEFAULT_DELETE_CHAPTERS_SETTINGS)
    end

    local delete_finished_while_reading = tonumber(value.delete_finished_while_reading)
        or DEFAULT_DELETE_CHAPTERS_SETTINGS.delete_finished_while_reading
    delete_finished_while_reading = math.floor(delete_finished_while_reading)
    if not DELETE_FINISHED_WHILE_READING_LIMITS[delete_finished_while_reading] then
        delete_finished_while_reading = DEFAULT_DELETE_CHAPTERS_SETTINGS.delete_finished_while_reading
    end

    return {
        delete_after_mark_read = value.delete_after_mark_read == true,
        delete_finished_while_reading = delete_finished_while_reading,
    }
end

function SuwayomiSettings:normalizeMangaKeepNextUnreadDownloads(value)
    local normalized = tonumber(value) or DEFAULT_MANGA_KEEP_NEXT_UNREAD_DOWNLOADS
    normalized = math.floor(normalized)
    if MANGA_KEEP_NEXT_UNREAD_DOWNLOAD_LIMITS[normalized] then
        return normalized
    end
    return DEFAULT_MANGA_KEEP_NEXT_UNREAD_DOWNLOADS
end

function SuwayomiSettings:getMangaSettingsKey(manga)
    if type(manga) ~= "table" then
        return nil
    end
    local key = manga.id or manga.title
    if key == nil or tostring(key) == "" then
        return nil
    end
    return tostring(key)
end

function SuwayomiSettings:getMangaKeepNextUnreadDownloadsKey(manga)
    return self:getMangaSettingsKey(manga)
end

function SuwayomiSettings:normalizeMangaScanlatorFilter(scanlator)
    if type(scanlator) ~= "string" and type(scanlator) ~= "number" then
        return nil
    end
    local normalized = tostring(scanlator)
    if normalized == "" then
        return nil
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
    return self:normalizeCredentials(self:open():readSetting("credentials", copyTable(DEFAULT_CREDENTIALS)))
end

function SuwayomiSettings:save(credentials)
    credentials = self:normalizeCredentials(credentials)
    self:open():saveSetting("credentials", credentials):flush()
    return credentials
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

function SuwayomiSettings:loadSourceCache(credentials_or_url)
    local server_url, auth_identity = self:getSourceCacheScope(credentials_or_url)
    local cache = self:open():readSetting("source_cache", nil)
    if type(cache) ~= "table"
        or cache.server_url ~= server_url
        or tostring(cache.auth_identity or "") ~= auth_identity
    then
        return nil
    end
    cache.sources = type(cache.sources) == "table" and cache.sources or {}
    cache.updated_at = tonumber(cache.updated_at) or 0
    return cache
end

function SuwayomiSettings:saveSourceCache(credentials_or_url, sources, updated_at)
    local server_url, auth_identity = self:getSourceCacheScope(credentials_or_url)
    local normalized = {
        server_url = server_url,
        auth_identity = auth_identity,
        sources = {},
        updated_at = tonumber(updated_at) or os.time(),
    }
    for _, source in ipairs(sources or {}) do
        table.insert(normalized.sources, source)
    end

    self:open():saveSetting("source_cache", normalized):flush()
    return normalized
end

local function emptySourceFilterDraft()
    return {
        query = "",
        filters = {},
    }
end

function SuwayomiSettings:loadSourceFilterDraft(credentials_or_url, source_id)
    local server_url, auth_identity = self:getSourceCacheScope(credentials_or_url)
    local drafts = self:open():readSetting("source_filter_drafts", nil)
    if type(drafts) ~= "table"
        or drafts.server_url ~= server_url
        or tostring(drafts.auth_identity or "") ~= auth_identity
        or type(drafts.sources) ~= "table"
    then
        return emptySourceFilterDraft()
    end

    local draft = drafts.sources[tostring(source_id or "")]
    if draft == nil then
        return emptySourceFilterDraft()
    end
    return SourceFilters.normalizeDraft(draft)
end

local function loadDraftStore(settings, credentials_or_url)
    local server_url, auth_identity = settings:getSourceCacheScope(credentials_or_url)
    local drafts = settings:open():readSetting("source_filter_drafts", nil)
    if type(drafts) ~= "table"
        or drafts.server_url ~= server_url
        or tostring(drafts.auth_identity or "") ~= auth_identity
        or type(drafts.sources) ~= "table"
    then
        drafts = {
            server_url = server_url,
            auth_identity = auth_identity,
            sources = {},
        }
    end
    return drafts
end

function SuwayomiSettings:saveSourceFilterDraft(credentials_or_url, source_id, draft)
    local source_key = tostring(source_id or "")
    local normalized = SourceFilters.normalizeDraft(draft)
    local drafts = loadDraftStore(self, credentials_or_url)
    drafts.sources[source_key] = normalized
    self:open():saveSetting("source_filter_drafts", drafts):flush()
    return normalized
end

function SuwayomiSettings:clearSourceFilterDraft(credentials_or_url, source_id)
    local source_key = tostring(source_id or "")
    local drafts = loadDraftStore(self, credentials_or_url)
    drafts.sources[source_key] = nil
    self:open():saveSetting("source_filter_drafts", drafts):flush()
    return emptySourceFilterDraft()
end

function SuwayomiSettings:loadDownloadDirectory()
    return normalizeDownloadDirectory(self:open():readSetting("download_directory", DEFAULT_DOWNLOAD_DIRECTORY))
end

function SuwayomiSettings:saveDownloadDirectory(path)
    local normalized = normalizeDownloadDirectory(path)
    self:open():saveSetting("download_directory", normalized):flush()
    return normalized
end

function SuwayomiSettings:loadDownloadQueue()
    local normalized, changed = self:normalizeDownloadQueue(self:open():readSetting("download_queue", {}))
    if changed then
        self:open():saveSetting("download_queue", normalized):flush()
    end
    return normalized
end

function SuwayomiSettings:normalizeDownloadQueue(jobs)
    local normalized = {}
    if type(jobs) ~= "table" then
        return normalized, jobs ~= nil
    end

    local changed = false
    local numeric_keys = {}
    for key in pairs(jobs) do
        if type(key) == "number" and key > 0 and math.floor(key) == key then
            table.insert(numeric_keys, key)
        else
            changed = true
        end
    end
    table.sort(numeric_keys)

    for index, key in ipairs(numeric_keys) do
        if key ~= index then
            changed = true
        end
        local job = jobs[key]
        if type(job) == "table" then
            table.insert(normalized, job)
        else
            changed = true
        end
    end

    return normalized, changed
end

function SuwayomiSettings:saveDownloadQueue(jobs)
    local normalized = self:normalizeDownloadQueue(jobs)
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

function SuwayomiSettings:loadDeleteChaptersSettings()
    return self:normalizeDeleteChaptersSettings(
        self:open():readSetting("delete_chapters_settings", DEFAULT_DELETE_CHAPTERS_SETTINGS)
    )
end

function SuwayomiSettings:saveDeleteChaptersSettings(value)
    local normalized = self:normalizeDeleteChaptersSettings(value)
    self:open():saveSetting("delete_chapters_settings", normalized):flush()
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

function SuwayomiSettings:loadMangaScanlatorFilter(manga)
    local key = self:getMangaSettingsKey(manga)
    if not key then
        return nil
    end
    local filters = self:open():readSetting("manga_scanlator_filters", {})
    if type(filters) ~= "table" then
        return nil
    end
    return self:normalizeMangaScanlatorFilter(filters[key])
end

function SuwayomiSettings:saveMangaScanlatorFilter(manga, scanlator)
    local key = self:getMangaSettingsKey(manga)
    local normalized = self:normalizeMangaScanlatorFilter(scanlator)
    if not key then
        return normalized
    end

    local filters = self:open():readSetting("manga_scanlator_filters", {})
    if type(filters) ~= "table" then
        filters = {}
    end
    if normalized then
        filters[key] = normalized
    else
        filters[key] = nil
    end
    self:open():saveSetting("manga_scanlator_filters", filters):flush()
    return normalized
end

function SuwayomiSettings:loadChapterLedger()
    return self:normalizeChapterLedger(self:open():readSetting("chapter_ledger", {}))
end

function SuwayomiSettings:saveChapterLedger(ledger)
    local normalized = self:normalizeChapterLedger(ledger)
    self:open():saveSetting("chapter_ledger", normalized):flush()
    return normalized
end

function SuwayomiSettings:normalizeFinishedChapterCleanupJournal(value)
    return normalizeFinishedCleanupJournal(value)
end

function SuwayomiSettings:loadFinishedChapterCleanupJournal()
    local raw = self:open():readSetting("finished_chapter_cleanup", nil)
    local journal, changed, error_code = normalizeFinishedCleanupJournal(raw)
    if error_code then return journal, error_code end
    if changed then
        self:open():saveSetting("finished_chapter_cleanup", journal):flush()
    end
    return journal
end

function SuwayomiSettings:saveFinishedChapterCleanupJournal(journal)
    local normalized, _, error_code = normalizeFinishedCleanupJournal(journal)
    if error_code then return normalized, error_code end
    self:open():saveSetting("finished_chapter_cleanup", normalized):flush()
    return normalized
end

function SuwayomiSettings:clearFinishedChapterCleanupJournal()
    local journal = emptyFinishedCleanupJournal()
    self:open():saveSetting("finished_chapter_cleanup", journal):flush()
    return journal
end

function SuwayomiSettings:loadReaderReturnContexts()
    local contexts = self:open():readSetting("reader_return_contexts", {})
    if type(contexts) ~= "table" then
        return {}
    end
    return contexts
end

function SuwayomiSettings:saveReaderReturnContexts(contexts)
    if type(contexts) ~= "table" then
        contexts = {}
    end
    self:open():saveSetting("reader_return_contexts", contexts):flush()
    return contexts
end

return SuwayomiSettings
