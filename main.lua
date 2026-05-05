local Dispatcher = require("dispatcher") -- luacheck:ignore
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local SuwayomiAPI = require("suwayomi_api")
local SuwayomiDownloadQueue = require("suwayomi_download_queue")
local SuwayomiReadSyncWorker = require("suwayomi_read_sync_worker")
local SuwayomiSettings = require("suwayomi_settings")
local SuwayomiUI = require("suwayomi_ui")
local SuwayomiDebug = require("suwayomi_debug")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local SOURCE_LANGUAGE_OPTIONS = {
    { code = "en", label = "EN" },
    { code = "ru", label = "RU" },
    { code = "de", label = "DE" },
    { code = "es", label = "ES" },
    { code = "fr", label = "FR" },
}

local SuwayomiPlugin = WidgetContainer:extend{
    name = "suwayomi_dl",
    is_doc_only = false,
    selection_mode = false,
    max_batch_queue_chapters = 50,
    read_sync_batch_size = 50,
    read_sync_delay_seconds = 0.5,
    read_sync_poll_interval_seconds = 0.5,
    read_sync_failure_delay_seconds = 5,
    read_sync_max_failure_delay_seconds = 300,
    read_sync_watchdog_timeout_seconds = 60,
}

function SuwayomiPlugin:createDownloadQueue()
    return SuwayomiDownloadQueue:new{
        settings = SuwayomiSettings,
        downloader = require("suwayomi_downloader"),
        ui_manager = UIManager,
        ffi_util = require("ffi/util"),
        max_active_chapters = SuwayomiSettings.loadMaxParallelChapterDownloads
            and SuwayomiSettings:loadMaxParallelChapterDownloads()
            or nil,
        debug_logger = SuwayomiDebug.log,
        getCredentials = function()
            return SuwayomiSettings:load()
        end,
        onStatusChanged = function()
            if self.chapter_menu_refresh_suppressed and self.chapter_menu_refresh_suppressed > 0 then
                self.pending_chapter_menu_refresh = true
                return
            end
            self:refreshChapterMenu({ quick = true })
        end,
        onMessage = function(message)
            self:showMessage(message)
        end,
    }
end

function SuwayomiPlugin:getDownloadQueue()
    if not self.download_queue then
        self.download_queue = self:createDownloadQueue()
    end
    return self.download_queue
end

function SuwayomiPlugin:withChapterMenuRefreshSuppressed(callback)
    self.chapter_menu_refresh_suppressed = (self.chapter_menu_refresh_suppressed or 0) + 1
    local ok, result = pcall(callback)
    self.chapter_menu_refresh_suppressed = (self.chapter_menu_refresh_suppressed or 1) - 1
    if self.chapter_menu_refresh_suppressed <= 0 then
        self.chapter_menu_refresh_suppressed = nil
    end
    if not ok then
        error(result)
    end
    return result
end

function SuwayomiPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("suwayomi_action", {
        category = "none",
        event = "SuwayomiAction",
        title = _("Suwayomi"),
        filemanager = true,
    })
end

function SuwayomiPlugin:isBookMode()
    return self.document ~= nil or (self.ui and self.ui.document ~= nil)
end

function SuwayomiPlugin:init()
    if SuwayomiAPI.setDebugLogger then
        SuwayomiAPI.setDebugLogger(SuwayomiDebug.log)
    end
    SuwayomiDebug.log({ operation = "plugin_init", event = "start" })
    self:onDispatcherRegisterActions()
    self.selected_chapters = self.selected_chapters or {}
    self.selection_mode = self.selection_mode == true
    self:getDownloadQueue():recover()
    if not self:isBookMode() then
        self.ui.menu:registerToMainMenu(self)
    end
    SuwayomiDebug.log({ operation = "plugin_init", event = "end" })
end

function SuwayomiPlugin:showNotImplemented(message)
    self:showMessage(message)
end

function SuwayomiPlugin:showMessage(message, options)
    options = options or {}
    UIManager:show(InfoMessage:new{
        text = message,
        timeout = options.timeout,
    })
end

function SuwayomiPlugin:withLoadingMessage(key, message, callback)
    self.loading_operations = self.loading_operations or {}
    if self.loading_operations[key] then
        return nil
    end

    self.loading_operations[key] = true
    local loading_message = InfoMessage:new{
        text = message,
        suwayomi_loading = true,
    }
    UIManager:show(loading_message)
    if UIManager.forceRePaint then
        UIManager:forceRePaint()
    end

    local results = { pcall(callback) }
    local ok = table.remove(results, 1)

    if UIManager.close then
        UIManager:close(loading_message)
    end
    self.loading_operations[key] = nil

    if not ok then
        error(results[1])
    end
    return unpack(results)
end

function SuwayomiPlugin:onSuwayomiAction()
    self:showNotImplemented(_("Open Search > Suwayomi to access the plugin menu."))
end

function SuwayomiPlugin:showLoginDialog()
    SuwayomiUI.showLoginDialog({
        credentials = SuwayomiSettings:load(),
        onSave = function(credentials)
            local saved_credentials = SuwayomiSettings:save(credentials)
            UIManager:nextTick(function()
                self:showMessage(T(_("Suwayomi login settings saved for %1."), saved_credentials.server_url))
            end)
        end,
    })
end

function SuwayomiPlugin:buildSourceLanguageSet(source_languages)
    local selected = {}
    for _, lang in ipairs(source_languages or {}) do
        selected[lang] = true
    end
    return selected
end

function SuwayomiPlugin:filterSourcesByLanguage(sources)
    local selected = self:buildSourceLanguageSet(SuwayomiSettings:loadSourceLanguages())
    local filtered = {}

    for _, source in ipairs(sources or {}) do
        if source.lang == "localsourcelang" or selected[source.lang] then
            table.insert(filtered, source)
        end
    end

    return filtered
end

function SuwayomiPlugin:showSourceLanguageDialog()
    local selected = self:buildSourceLanguageSet(SuwayomiSettings:loadSourceLanguages())
    local language_menu

    local function buildLanguages()
        local languages = {}
        for _, language in ipairs(SOURCE_LANGUAGE_OPTIONS) do
            table.insert(languages, {
                code = language.code,
                label = language.label,
                enabled = selected[language.code] == true,
            })
        end
        return languages
    end

    local function saveSelectedLanguages()
        local saved_languages = {}
        for _, language in ipairs(SOURCE_LANGUAGE_OPTIONS) do
            if selected[language.code] then
                table.insert(saved_languages, language.code)
            end
        end
        SuwayomiSettings:saveSourceLanguages(saved_languages)
    end

    local function showSavedSummary()
        local labels = {}
        for _, language in ipairs(SOURCE_LANGUAGE_OPTIONS) do
            if selected[language.code] then
                table.insert(labels, language.label)
            end
        end
        local summary = #labels > 0 and table.concat(labels, ", ") or _("none")
        self:showMessage(T(_("Suwayomi source languages saved: %1"), summary))
    end

    local function onToggle(code, enabled)
        if enabled then
            selected[code] = true
        else
            selected[code] = nil
        end

        saveSelectedLanguages()
        if SuwayomiUI.updateLanguageMenu then
            SuwayomiUI.updateLanguageMenu(language_menu, {
                languages = buildLanguages(),
                onClose = showSavedSummary,
            }, onToggle)
        end
    end

    language_menu = SuwayomiUI.showLanguageMenu({
        languages = buildLanguages(),
        onToggle = onToggle,
        onClose = showSavedSummary,
    })
end

function SuwayomiPlugin:browseSuwayomi()
    return SuwayomiDebug.time("browseSuwayomi", function()
        local credentials = SuwayomiSettings:load()
        if credentials.server_url == "" then
            self:showMessage(_("Set up your Suwayomi server login first."))
            return
        end

        self:schedulePendingReadSync(credentials)

        local result = self:withLoadingMessage("sources", _("Loading sources..."), function()
            return SuwayomiAPI.fetchSources(credentials)
        end)
        if not result then
            return
        end
        if not result.ok then
            self:showMessage(_(result.error))
            return
        end

        local filtered_sources = self:filterSourcesByLanguage(result.sources)
        SuwayomiDebug.log({
            operation = "browseSuwayomi",
            event = "sources_loaded",
            source_count = #(result.sources or {}),
            filtered_source_count = #filtered_sources,
        })
        if #filtered_sources == 0 then
            self:showMessage(_("No Suwayomi sources match the selected languages."))
            return
        end

        SuwayomiUI.showSourcesMenu(filtered_sources, function(source)
            self:showMangaForSource(source)
        end)
    end)
end

function SuwayomiPlugin:showMangaForSource(source)
    return SuwayomiDebug.time("showMangaForSource", {
        source_id = source and source.id,
    }, function()
        local credentials = SuwayomiSettings:load()
        local result = self:withLoadingMessage("manga", _("Loading manga..."), function()
            return SuwayomiAPI.fetchMangaForSource(credentials, source.id)
        end)
        if not result then
            return
        end
        if not result.ok then
            self:showMessage(_(result.error))
            return
        end

        SuwayomiDebug.log({
            operation = "showMangaForSource",
            event = "manga_loaded",
            source_id = source and source.id,
            manga_count = #(result.manga or {}),
        })
        if not result.manga or #result.manga == 0 then
            self:showMessage(_("This source has no manga."))
            return
        end

        SuwayomiUI.showMangaMenu(result.manga, function(manga)
            self:showChaptersForManga(manga)
        end)
    end)
end

function SuwayomiPlugin:showChaptersForManga(manga)
    return SuwayomiDebug.time("showChaptersForManga", {
        manga_id = manga and manga.id,
    }, function()
        local credentials = SuwayomiSettings:load()
        local result = self:withLoadingMessage("chapters", _("Loading chapters..."), function()
            return SuwayomiAPI.fetchChaptersForManga(credentials, manga.id)
        end)
        if not result then
            return
        end
        if not result.ok then
            self:showMessage(_(result.error))
            return
        end

        SuwayomiDebug.log({
            operation = "showChaptersForManga",
            event = "chapters_loaded",
            manga_id = manga and manga.id,
            chapter_count = #(result.chapters or {}),
        })
        if not result.chapters or #result.chapters == 0 then
            self:showMessage(_("This manga has no chapters."))
            return
        end

        local chapters = self:mergeChaptersWithReadLedger(manga, result.chapters)
        if self.current_chapter_context
            and self:getChapterSelectionKey(self.current_chapter_context.manga, {}) ~= self:getChapterSelectionKey(manga, {})
        then
            self:clearChapterSelection(true)
        end
        self.current_chapter_context = {
            manga = manga,
            chapters = chapters,
        }

        self.current_chapter_options = self:buildChapterMenuOptions(manga, chapters)
        self.current_chapter_menu = SuwayomiUI.showChapterMenu(self.current_chapter_options, function(chapter)
            self:handleChapterTap(manga, chapter)
        end, function(chapter)
            self:toggleChapterSelection(manga, chapter)
        end)
    end)
end

function SuwayomiPlugin:getChapterDownloadKey(manga, chapter)
    return self:getDownloadQueue():getKey(manga, chapter)
end

function SuwayomiPlugin:getChapterProgressPath(manga, chapter, download_directory)
    return self:getDownloadQueue():buildProgressPath(manga, chapter, download_directory)
end

function SuwayomiPlugin:getChapterDownloadStatus(manga, chapter)
    return self:getDownloadQueue():getStatus(manga, chapter)
end

function SuwayomiPlugin:setChapterDownloadStatus(manga, chapter, status)
    self:getDownloadQueue():setStatus(manga, chapter, status)
end

function SuwayomiPlugin:formatChapterMenuText(chapter, status)
    return self:getDownloadQueue():formatChapterMenuText(chapter, status)
end

function SuwayomiPlugin:getChapterSelectionKey(manga, chapter)
    return tostring(manga.id or manga.title or "") .. ":" .. tostring(chapter.id or chapter.name or "")
end

function SuwayomiPlugin:isChapterSelected(manga, chapter)
    local manga_id = type(manga) == "table" and (manga.id or manga.title) or manga
    local chapter_id = type(chapter) == "table" and (chapter.id or chapter.name) or chapter
    local key = tostring(manga_id or "") .. ":" .. tostring(chapter_id or "")
    return self.selected_chapters and self.selected_chapters[key] == true
end

function SuwayomiPlugin:getSelectedChapterCount()
    local count = 0
    for _, selected in pairs(self.selected_chapters or {}) do
        if selected then
            count = count + 1
        end
    end
    return count
end

function SuwayomiPlugin:getSelectedChapters(manga, chapters)
    local selected = {}
    for _, chapter in ipairs(chapters or {}) do
        if self:isChapterSelected(manga, chapter) then
            table.insert(selected, chapter)
        end
    end
    return selected
end

function SuwayomiPlugin:clearChapterSelection(skip_refresh)
    self.selected_chapters = {}
    self.selection_mode = false
    if not skip_refresh then
        self:refreshChapterMenu()
    end
end

function SuwayomiPlugin:selectAllChapters()
    local context = self.current_chapter_context
    local manga = context and context.manga
    local chapters = context and context.chapters or {}

    self.selected_chapters = {}
    for _, chapter in ipairs(chapters) do
        self.selected_chapters[self:getChapterSelectionKey(manga, chapter)] = true
    end
    self.selection_mode = self:getSelectedChapterCount() > 0
    self:refreshChapterMenu()
    return self:getSelectedChapterCount()
end

function SuwayomiPlugin:toggleChapterSelection(manga, chapter)
    self.selected_chapters = self.selected_chapters or {}
    local key = self:getChapterSelectionKey(manga, chapter)
    if self.selected_chapters[key] then
        self.selected_chapters[key] = nil
    else
        self.selected_chapters[key] = true
    end
    self.selection_mode = self:getSelectedChapterCount() > 0
    self:refreshChapterMenu()
end

function SuwayomiPlugin:handleChapterTap(manga, chapter)
    if self.selection_mode then
        self:toggleChapterSelection(manga, chapter)
        return
    end

    self:showChapterActions(manga, chapter)
end

function SuwayomiPlugin:loadChapterLedger()
    if not SuwayomiSettings.loadChapterLedger then
        return {}
    end
    return SuwayomiSettings:loadChapterLedger() or {}
end

function SuwayomiPlugin:saveChapterLedger(ledger)
    if not SuwayomiSettings.saveChapterLedger then
        return ledger or {}
    end
    return SuwayomiSettings:saveChapterLedger(ledger or {})
end

function SuwayomiPlugin:upsertChapterLedgerEntryInLedger(ledger, manga, chapter, updates)
    ledger = ledger or {}
    local key = self:getChapterLedgerKey(manga, chapter)
    local existing = ledger[key] or {}

    local entry = {
        manga_id = tostring(manga.id or existing.manga_id or ""),
        manga_title = manga.title or existing.manga_title,
        chapter_id = tostring(chapter.id or existing.chapter_id or ""),
        chapter_name = chapter.name or existing.chapter_name,
        read = existing.read == true,
        path = existing.path,
        pending_read_sync = existing.pending_read_sync == true or nil,
        pending_read_state = existing.pending_read_state,
    }

    for update_key, value in pairs(updates or {}) do
        entry[update_key] = value
    end

    ledger[key] = entry
    return entry
end

function SuwayomiPlugin:upsertChapterLedgerEntry(manga, chapter, updates)
    local ledger = self:loadChapterLedger()
    local entry = self:upsertChapterLedgerEntryInLedger(ledger, manga, chapter, updates)
    self:saveChapterLedger(ledger)
    return entry
end

function SuwayomiPlugin:getChapterLedgerKey(manga, chapter)
    return self:getChapterDownloadKey(manga, chapter)
end

function SuwayomiPlugin:mergeChaptersWithReadLedger(manga, chapters)
    local ledger = self:loadChapterLedger()
    local changed = false
    local merged = {}

    for _, chapter in ipairs(chapters or {}) do
        local item = {}
        for key, value in pairs(chapter) do
            item[key] = value
        end

        local key = self:getChapterLedgerKey(manga, item)
        local entry = ledger[key]
        local suwayomi_is_read = item.is_read == true
        local pending_read_state
        if entry and entry.pending_read_sync == true then
            if entry.pending_read_state ~= nil then
                pending_read_state = entry.pending_read_state == true
            else
                pending_read_state = entry.read == true
            end
        end
        local is_read = pending_read_state
        if is_read == nil then
            is_read = suwayomi_is_read
        end
        item._suwayomi_is_read = suwayomi_is_read
        item.is_read = is_read

        if is_read or pending_read_state ~= nil then
            ledger[key] = {
                manga_id = tostring(manga.id or ""),
                manga_title = manga.title,
                chapter_id = tostring(item.id or ""),
                chapter_name = item.name,
                read = is_read == true,
                path = entry and entry.path or nil,
                pending_read_sync = pending_read_state ~= nil and true or nil,
                pending_read_state = pending_read_state,
            }
            changed = true
        elseif entry and entry.read == true then
            if entry.path then
                entry.read = nil
                entry.pending_read_sync = nil
                ledger[key] = entry
            else
                ledger[key] = nil
            end
            changed = true
        end

        table.insert(merged, item)
    end

    if changed then
        self:saveChapterLedger(ledger)
    end

    return merged
end

function SuwayomiPlugin:getKoreaderMetadataPathForDocument(document_path)
    if not document_path or document_path == "" then
        return nil
    end

    local base_path, extension = document_path:match("^(.*)%.([^%.%/]+)$")
    if not base_path or not extension then
        return nil
    end

    return base_path .. ".sdr/metadata." .. extension .. ".lua"
end

function SuwayomiPlugin:ensureDirectory(path)
    if not path or path == "" then
        return false
    end

    local ok, lfs = pcall(require, "lfs")
    if not ok or not lfs then
        return false
    end

    if lfs.attributes(path, "mode") == "directory" then
        return true
    end

    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path and lfs.attributes(parent, "mode") ~= "directory" then
        self:ensureDirectory(parent)
    end

    return lfs.mkdir(path) or lfs.attributes(path, "mode") == "directory"
end

function SuwayomiPlugin:loadKoreaderMetadataTable(chapter_path)
    local metadata_path = self:getKoreaderMetadataPathForDocument(chapter_path)
    local metadata = {
        doc_path = chapter_path,
    }
    local handle = metadata_path and io.open(metadata_path, "r")
    if not handle then
        return metadata, metadata_path
    end

    local content = handle:read("*a") or ""
    handle:close()

    local loader = loadstring(content)
    if not loader then
        return metadata, metadata_path
    end

    setfenv(loader, {})
    local ok, parsed = pcall(loader)
    if ok and type(parsed) == "table" then
        parsed.doc_path = parsed.doc_path or chapter_path
        return parsed, metadata_path
    end

    return metadata, metadata_path
end

local function sortLuaKeys(left, right)
    local left_type = type(left)
    local right_type = type(right)
    if left_type == right_type then
        return tostring(left) < tostring(right)
    end
    return left_type < right_type
end

function SuwayomiPlugin:serializeLuaValue(value, indent)
    indent = indent or 0
    local value_type = type(value)
    if value_type == "string" then
        return string.format("%q", value)
    end
    if value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end
    if value_type ~= "table" then
        return "nil"
    end

    local next_indent = indent + 4
    local current_padding = string.rep(" ", indent)
    local next_padding = string.rep(" ", next_indent)
    local keys = {}
    for key in pairs(value) do
        table.insert(keys, key)
    end
    table.sort(keys, sortLuaKeys)

    local lines = { "{" }
    for _, key in ipairs(keys) do
        local item = value[key]
        if item ~= nil then
            table.insert(lines, next_padding
                .. "["
                .. self:serializeLuaValue(key, 0)
                .. "] = "
                .. self:serializeLuaValue(item, next_indent)
                .. ",")
        end
    end
    table.insert(lines, current_padding .. "}")
    return table.concat(lines, "\n")
end

function SuwayomiPlugin:saveKoreaderMetadataTable(metadata_path, metadata)
    if not metadata_path then
        return false
    end

    local metadata_dir = metadata_path:match("^(.*)/[^/]+$")
    if metadata_dir and not self:ensureDirectory(metadata_dir) then
        return false
    end

    local handle = io.open(metadata_path, "w")
    if not handle then
        return false
    end

    handle:write("return ", self:serializeLuaValue(metadata, 0), "\n")
    handle:close()
    return true
end

function SuwayomiPlugin:setKoreaderChapterReadState(chapter_path, is_read)
    if not chapter_path or chapter_path == "" then
        return false
    end

    local metadata, metadata_path = self:loadKoreaderMetadataTable(chapter_path)
    metadata.doc_path = metadata.doc_path or chapter_path
    metadata.summary = type(metadata.summary) == "table" and metadata.summary or {}

    if is_read then
        metadata.percent_finished = 1
        metadata.summary.status = "complete"
    else
        metadata.percent_finished = 0
        metadata.summary.status = nil
    end

    return self:saveKoreaderMetadataTable(metadata_path, metadata)
end

function SuwayomiPlugin:isKoreaderMetadataFinished(metadata_path)
    local handle = metadata_path and io.open(metadata_path, "r")
    if not handle then
        return false
    end

    local content = handle:read("*a") or ""
    handle:close()

    local status = content:match('%["status"%]%s*=%s*"([^"]+)"')
    if status == "complete" or status == "completed" or status == "finished" then
        return true
    end

    local percent_finished = tonumber(content:match('%["percent_finished"%]%s*=%s*([%d%.]+)'))
    return percent_finished ~= nil and percent_finished >= 1
end

function SuwayomiPlugin:isChapterPathFinishedInKoreader(chapter_path)
    return self:isKoreaderMetadataFinished(self:getKoreaderMetadataPathForDocument(chapter_path))
end

function SuwayomiPlugin:getKoreaderHistoryPath()
    if not SuwayomiSettings.getSettingsDir then
        return nil
    end

    local settings_dir = SuwayomiSettings:getSettingsDir()
    if not settings_dir or settings_dir == "" then
        return nil
    end

    return settings_dir .. "/history.lua"
end

function SuwayomiPlugin:loadKoreaderHistoryPaths()
    local history_path = self:getKoreaderHistoryPath()
    local handle = history_path and io.open(history_path, "r")
    if not handle then
        return {}
    end

    local content = handle:read("*a") or ""
    handle:close()

    local loader = loadstring(content)
    if not loader then
        return {}
    end

    setfenv(loader, {})
    local ok, history = pcall(loader)
    if not ok or type(history) ~= "table" then
        return {}
    end

    local paths = {}
    for _, entry in pairs(history) do
        if type(entry) == "table" and type(entry.file) == "string" and entry.file ~= "" then
            paths[entry.file] = true
        end
    end
    return paths
end

function SuwayomiPlugin:reconcileDownloadedChapterLedger(ledger)
    ledger = ledger or self:loadChapterLedger()
    local history_paths = self:loadKoreaderHistoryPaths()
    local changed = false
    local read_count = 0

    for _, entry in pairs(ledger or {}) do
        if type(entry) == "table" and type(entry.path) == "string" and entry.path ~= "" then
            local metadata_finished = self:isChapterPathFinishedInKoreader(entry.path)
            local history_read = history_paths[entry.path] == true
            if (metadata_finished or history_read) and entry.read ~= true then
                entry.read = true
                entry.pending_read_sync = true
                entry.pending_read_state = true
                changed = true
                read_count = read_count + 1
            end
        end
    end

    if changed then
        self:saveChapterLedger(ledger)
    end

    return read_count
end

function SuwayomiPlugin:buildChapterMenuItems(manga, chapters, ledger)
    local started_at = SuwayomiDebug.now()
    local SuwayomiDownloader = require("suwayomi_downloader")
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    local history_paths = self:loadKoreaderHistoryPaths()
    local items = {}
    local downloaded_count = 0
    local metadata_finished_count = 0
    local history_read_count = 0
    local metadata_write_count = 0
    local ledger_upsert_count = 0

    for _, chapter in ipairs(chapters or {}) do
        local item = {}
        for key, value in pairs(chapter) do
            item[key] = value
        end

        local chapter_exists = false
        local chapter_path
        if download_directory and download_directory ~= "" then
            _, chapter_path = SuwayomiDownloader:getTargetPath(download_directory, manga, item)
            chapter_exists = SuwayomiDownloader:chapterExists(chapter_path)
            local metadata_finished = chapter_exists and self:isChapterPathFinishedInKoreader(chapter_path)
            local history_read = chapter_exists and history_paths[chapter_path] == true
            if chapter_exists then
                downloaded_count = downloaded_count + 1
            end
            if metadata_finished then
                metadata_finished_count = metadata_finished_count + 1
            end
            if history_read then
                history_read_count = history_read_count + 1
            end
            if metadata_finished or history_read then
                item.is_read = true
                if item._suwayomi_is_read ~= true then
                    item.pending_read_sync = true
                end
            end
            if chapter_exists and item.is_read == true and not metadata_finished then
                self:setKoreaderChapterReadState(chapter_path, true)
                metadata_write_count = metadata_write_count + 1
            end
        end

        local status = self:getChapterDownloadStatus(manga, item)
        if not status then
            if chapter_exists then
                status = { state = "downloaded" }
            elseif item.is_read then
                status = { state = "read" }
            end
        end
        item.menu_text = self:formatChapterMenuText(item, status)
        if self.selection_mode then
            if self:isChapterSelected(manga, item) then
                item.menu_text = "[x] " .. item.menu_text
            else
                item.menu_text = "[ ] " .. item.menu_text
            end
        end

        if chapter_exists then
            local updates = {
                path = chapter_path,
                read = item.is_read == true,
                pending_read_sync = item.pending_read_sync == true or nil,
            }
            if ledger then
                self:upsertChapterLedgerEntryInLedger(ledger, manga, item, updates)
            else
                self:upsertChapterLedgerEntry(manga, item, updates)
            end
            ledger_upsert_count = ledger_upsert_count + 1
        end

        table.insert(items, item)
    end

    SuwayomiDebug.log({
        operation = "buildChapterMenuItems",
        event = "end",
        manga_id = manga and manga.id,
        chapter_count = #(chapters or {}),
        downloaded_count = downloaded_count,
        metadata_finished_count = metadata_finished_count,
        history_read_count = history_read_count,
        metadata_write_count = metadata_write_count,
        ledger_upsert_count = ledger_upsert_count,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return items
end

function SuwayomiPlugin:buildChapterMenuOptions(manga, chapters, ledger)
    local selected_count = self:getSelectedChapterCount()
    local title = manga.title
    if self.selection_mode then
        title = T(_("%1 selected"), selected_count)
    end

    return {
        title = title,
        chapters = self:buildChapterMenuItems(manga, chapters, ledger),
        title_bar_left_icon = "appbar.menu",
        on_title_bar_left_tap = function()
            self:showBulkChapterActions(manga)
            return true
        end,
    }
end

function SuwayomiPlugin:buildCachedChapterMenuMap()
    local items_by_key = {}
    for _, item in ipairs((self.current_chapter_options and self.current_chapter_options.chapters) or {}) do
        items_by_key[self:getChapterDownloadKey(
            self.current_chapter_context.manga,
            item
        )] = item
    end
    return items_by_key
end

function SuwayomiPlugin:buildQuickChapterMenuItems(manga, chapters)
    local cached_items = self:buildCachedChapterMenuMap()
    local items = {}
    for _, chapter in ipairs(chapters or {}) do
        local item = {}
        for key, value in pairs(chapter) do
            item[key] = value
        end

        local cached = cached_items[self:getChapterDownloadKey(manga, item)]
        local status = self:getChapterDownloadStatus(manga, item)
        if status then
            item.menu_text = self:formatChapterMenuText(item, status)
        elseif cached and cached.menu_text then
            item.menu_text = self:stripChapterSelectionMarker(cached.menu_text)
        elseif item.is_read then
            item.menu_text = self:formatChapterMenuText(item, { state = "read" })
        else
            item.menu_text = item.name
        end

        if self.selection_mode then
            if self:isChapterSelected(manga, item) then
                item.menu_text = "[x] " .. item.menu_text
            else
                item.menu_text = "[ ] " .. item.menu_text
            end
        end

        table.insert(items, item)
    end
    return items
end

function SuwayomiPlugin:stripChapterSelectionMarker(menu_text)
    return tostring(menu_text or ""):gsub("^%[[x ]%]%s+", "", 1)
end

function SuwayomiPlugin:buildQuickChapterMenuOptions(manga, chapters)
    local selected_count = self:getSelectedChapterCount()
    local title = manga.title
    if self.selection_mode then
        title = T(_("%1 selected"), selected_count)
    end

    return {
        title = title,
        chapters = self:buildQuickChapterMenuItems(manga, chapters),
        title_bar_left_icon = "appbar.menu",
        on_title_bar_left_tap = function()
            self:showBulkChapterActions(manga)
            return true
        end,
    }
end

function SuwayomiPlugin:getChapterPath(manga, chapter)
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        return nil
    end

    local SuwayomiDownloader = require("suwayomi_downloader")
    local _, chapter_path = SuwayomiDownloader:getTargetPath(download_directory, manga, chapter)
    return chapter_path
end

function SuwayomiPlugin:isChapterDownloaded(manga, chapter)
    local chapter_path = self:getChapterPath(manga, chapter)
    if not chapter_path then
        return false, nil
    end

    local SuwayomiDownloader = require("suwayomi_downloader")
    return SuwayomiDownloader:chapterExists(chapter_path), chapter_path
end

function SuwayomiPlugin:getChapterActions(manga, chapter)
    local downloaded = self:isChapterDownloaded(manga, chapter)
    local actions = {}

    if downloaded then
        table.insert(actions, { id = "open", text = _("Open") })
        table.insert(actions, { id = "delete", text = _("Delete from device") })
    else
        table.insert(actions, { id = "download", text = _("Download") })
    end

    if chapter.is_read == true then
        table.insert(actions, { id = "mark_unread", text = _("Mark as unread") })
    else
        table.insert(actions, { id = "mark_read", text = _("Mark as read") })
        table.insert(actions, { id = "mark_previous_read", text = _("Mark previous as read") })
        table.insert(actions, { id = "mark_through_read", text = _("Mark this and previous as read") })
    end
    return actions
end

function SuwayomiPlugin:openChapter(manga, chapter)
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    if not downloaded or not chapter_path then
        self:showMessage(_("Download the chapter first."))
        return false
    end

    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI then
        self:showMessage(_("KOReader could not open this chapter right now."))
        return false
    end

    if ReaderUI.instance and ReaderUI.instance.switchDocument then
        ReaderUI.instance:switchDocument(chapter_path)
    elseif ReaderUI.showReader then
        ReaderUI:showReader(chapter_path)
    else
        self:showMessage(_("KOReader could not open this chapter right now."))
        return false
    end

    return true
end

function SuwayomiPlugin:deleteChapterFromDevice(manga, chapter)
    return self:deleteChapterFromDeviceWithOptions(manga, chapter)
end

function SuwayomiPlugin:deleteChapterFromDeviceWithOptions(manga, chapter, options)
    options = options or {}
    local cancelled, queue_state = self:getDownloadQueue():cancelPending(manga, chapter)
    if queue_state == "downloading" then
        if not options.quiet_active then
            self:showMessage(_("This chapter is downloading. Wait for it to finish before deleting it."))
        end
        return false, "downloading"
    end

    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    if not downloaded or not chapter_path then
        if not options.quiet_missing then
            self:showMessage(_("This chapter is not downloaded."))
        end
        return false, cancelled and "queued" or "missing"
    end

    local metadata_path = self:getKoreaderMetadataPathForDocument(chapter_path)
    os.remove(chapter_path)
    if metadata_path then
        os.remove(metadata_path)
        os.remove(metadata_path .. ".old")
        local metadata_dir = metadata_path:match("^(.*)/[^/]+$")
        if metadata_dir then
            os.remove(metadata_dir)
        end
    end

    local ledger = self:loadChapterLedger()
    local key = self:getChapterLedgerKey(manga, chapter)
    local entry = ledger[key]
    if not entry then
        for existing_key, existing in pairs(ledger) do
            if tostring(existing.manga_id or "") == tostring(manga.id or "")
                and tostring(existing.chapter_id or "") == tostring(chapter.id or "")
            then
                key = existing_key
                entry = existing
                break
            end
        end
    end
    if entry then
        entry.path = nil
        if entry.read ~= true and entry.pending_read_sync ~= true then
            ledger[key] = nil
        else
            ledger[key] = entry
        end
        self:saveChapterLedger(ledger)
    end
    self:getDownloadQueue():clearStatus(manga, chapter, { quiet = true })

    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    return true, cancelled and "queued" or "deleted"
end

function SuwayomiPlugin:markChapterRead(manga, chapter, options)
    local started_at = SuwayomiDebug.now()
    options = options or {}
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    local metadata_updated = false
    if downloaded and chapter_path then
        metadata_updated = self:setKoreaderChapterReadState(chapter_path, true)
    end
    local updates = {
        path = chapter_path,
        read = true,
        pending_read_sync = true,
        pending_read_state = true,
    }
    if options.ledger then
        self:upsertChapterLedgerEntryInLedger(options.ledger, manga, chapter, updates)
    else
        self:upsertChapterLedgerEntry(manga, chapter, updates)
    end

    if self.current_chapter_context and self.current_chapter_context.chapters then
        for _, current in ipairs(self.current_chapter_context.chapters) do
            if tostring(current.id or "") == tostring(chapter.id or "") then
                current.is_read = true
                break
            end
        end
    end
    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    if not options.skip_schedule then
        self:schedulePendingReadSync()
    end
    if not options.skip_refresh or not options.skip_schedule then
        SuwayomiDebug.log({
            operation = "markChapterRead",
            event = "end",
            manga_id = manga and manga.id,
            chapter_id = chapter and chapter.id,
            downloaded = downloaded == true,
            metadata_updated = metadata_updated == true,
            skip_refresh = options.skip_refresh == true,
            skip_schedule = options.skip_schedule == true,
            elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
        })
    end
    return true
end

function SuwayomiPlugin:markChapterUnread(manga, chapter, options)
    local started_at = SuwayomiDebug.now()
    options = options or {}
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    local metadata_updated = false
    if downloaded and chapter_path then
        metadata_updated = self:setKoreaderChapterReadState(chapter_path, false)
    end
    local updates = {
        path = chapter_path,
        read = false,
        pending_read_sync = true,
        pending_read_state = false,
    }
    if options.ledger then
        self:upsertChapterLedgerEntryInLedger(options.ledger, manga, chapter, updates)
    else
        self:upsertChapterLedgerEntry(manga, chapter, updates)
    end

    if self.current_chapter_context and self.current_chapter_context.chapters then
        for _, current in ipairs(self.current_chapter_context.chapters) do
            if tostring(current.id or "") == tostring(chapter.id or "") then
                current.is_read = false
                break
            end
        end
    end

    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    if not options.skip_schedule then
        self:schedulePendingReadSync()
    end
    if not options.skip_refresh or not options.skip_schedule then
        SuwayomiDebug.log({
            operation = "markChapterUnread",
            event = "end",
            manga_id = manga and manga.id,
            chapter_id = chapter and chapter.id,
            downloaded = downloaded == true,
            metadata_updated = metadata_updated == true,
            skip_refresh = options.skip_refresh == true,
            skip_schedule = options.skip_schedule == true,
            elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
        })
    end
    return true
end

function SuwayomiPlugin:getChaptersThrough(chapter)
    local chapters = {}
    if not self.current_chapter_context or not self.current_chapter_context.chapters then
        return chapters
    end

    local found = false
    for _, current in ipairs(self.current_chapter_context.chapters) do
        table.insert(chapters, current)
        if tostring(current.id or "") == tostring(chapter.id or "") then
            found = true
            break
        end
    end
    if not found then
        return {}
    end
    return chapters
end

function SuwayomiPlugin:getChaptersBefore(chapter)
    local chapters = self:getChaptersThrough(chapter)
    if #chapters > 0 then
        table.remove(chapters)
    end
    return chapters
end

function SuwayomiPlugin:markChapterListRead(manga, chapters)
    local started_at = SuwayomiDebug.now()
    if #chapters == 0 then
        return 0
    end

    local ledger = self:loadChapterLedger()
    for _, current in ipairs(chapters) do
        self:markChapterRead(manga, current, {
            ledger = ledger,
            skip_refresh = true,
            skip_schedule = true,
        })
    end

    self:refreshChapterMenu({ ledger = ledger })
    self:saveChapterLedger(ledger)
    self:schedulePendingReadSync()
    SuwayomiDebug.log({
        operation = "markChapterListRead",
        event = "end",
        manga_id = manga and manga.id,
        chapter_count = #chapters,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return #chapters
end

function SuwayomiPlugin:markChaptersBeforeRead(manga, chapter)
    return self:markChapterListRead(manga, self:getChaptersBefore(chapter))
end

function SuwayomiPlugin:markChaptersReadThrough(manga, chapter)
    return self:markChapterListRead(manga, self:getChaptersThrough(chapter))
end

function SuwayomiPlugin:performChapterAction(manga, chapter, action_id)
    if action_id == "open" then
        return self:openChapter(manga, chapter)
    end
    if action_id == "download" then
        self:enqueueChapterDownload(manga, chapter)
        return true
    end
    if action_id == "delete" then
        return self:deleteChapterFromDevice(manga, chapter)
    end
    if action_id == "mark_read" then
        return self:markChapterRead(manga, chapter)
    end
    if action_id == "mark_previous_read" then
        return self:markChaptersBeforeRead(manga, chapter)
    end
    if action_id == "mark_through_read" then
        return self:markChaptersReadThrough(manga, chapter)
    end
    if action_id == "mark_unread" then
        return self:markChapterUnread(manga, chapter)
    end
    return false
end

function SuwayomiPlugin:getBulkChapterActions()
    local actions = {}

    if self:getSelectedChapterCount() > 0 then
        table.insert(actions, { id = "download_selected", text = _("Download selected") })
        table.insert(actions, { id = "delete_selected", text = _("Delete selected from device") })
        table.insert(actions, { id = "mark_read_selected", text = _("Mark selected as read") })
        table.insert(actions, { id = "mark_unread_selected", text = _("Mark selected as unread") })
        table.insert(actions, { id = "clear_selection", text = _("Clear selection") })
        return actions
    end

    if self.current_chapter_context and #(self.current_chapter_context.chapters or {}) > 0 then
        table.insert(actions, { id = "select_all", text = _("Select all") })
    end

    table.insert(actions, { id = "bulk_downloads", text = _("Bulk downloads") })
    table.insert(actions, { id = "delete_read_downloaded", text = _("Delete read chapters from device") })

    return actions
end

function SuwayomiPlugin:getBulkDownloadActions()
    local actions = {}

    table.insert(actions, { id = "download_next_5_unread", text = _("Download next 5 unread") })
    table.insert(actions, { id = "download_next_10_unread", text = _("Download next 10 unread") })
    table.insert(actions, { id = "download_next_50_unread", text = _("Download next 50 unread") })
    table.insert(actions, { id = "keep_next_5_unread", text = _("Keep next 5 unread downloaded") })
    table.insert(actions, { id = "keep_next_10_unread", text = _("Keep next 10 unread downloaded") })
    table.insert(actions, { id = "keep_next_50_unread", text = _("Keep next 50 unread downloaded") })

    return actions
end

function SuwayomiPlugin:pluralize(count, singular, plural)
    if count == 1 then
        return singular
    end
    return plural
end

function SuwayomiPlugin:formatBulkDownloadMessage(queued, skipped)
    local parts = {}
    if queued > 0 then
        table.insert(parts, T(
            self:pluralize(queued, _("Queued %1 selected chapter download."), _("Queued %1 selected chapter downloads.")),
            queued
        ))
    else
        table.insert(parts, _("No new downloads queued."))
    end

    if skipped > 0 then
        table.insert(parts, T(
            self:pluralize(skipped, _("Skipped %1 already downloaded or queued."), _("Skipped %1 already downloaded or queued.")),
            skipped
        ))
    end
    return table.concat(parts, " ")
end

function SuwayomiPlugin:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
    local started_at = SuwayomiDebug.now()
    local queued = 0
    local skipped = 0
    local capped = 0
    local queueable = {}
    for _, chapter in ipairs(chapters or {}) do
        local status = self:getDownloadQueue():getStatus(manga, chapter)
        local downloaded = self:isChapterDownloaded(manga, chapter)
        if downloaded or (status and (status.state == "queued" or status.state == "downloading" or status.state == "downloaded" or status.state == "skipped")) then
            skipped = skipped + 1
        elseif #queueable >= self.max_batch_queue_chapters then
            capped = capped + 1
        else
            table.insert(queueable, chapter)
        end
    end

    self:withChapterMenuRefreshSuppressed(function()
        queued = self:getDownloadQueue():enqueueBatch(manga, queueable, download_directory, { quiet_duplicate = true })
    end)
    skipped = skipped + (#queueable - queued)

    self:clearChapterSelection(true)
    self:refreshChapterMenu({ quick = true })

    if capped > 0 then
        self:showMessage(T(
            _("Queued first %1 downloads. Refine the chapter selection to queue more."),
            self.max_batch_queue_chapters
        ))
    elseif queued == 0 and skipped > 0 then
        self:showMessage(self:formatBulkDownloadMessage(queued, skipped))
    end
    SuwayomiDebug.log({
        operation = "enqueueSelectedChapterDownloads",
        event = "end",
        manga_id = manga and manga.id,
        requested_count = #(chapters or {}),
        queueable_count = #queueable,
        queued_count = queued,
        skipped_count = skipped,
        capped_count = capped,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return queued
end

function SuwayomiPlugin:canQueueChapterDownload(manga, chapter)
    if chapter.is_read == true then
        return false
    end

    local status = self:getDownloadQueue():getStatus(manga, chapter)
    if status and (
        status.state == "queued"
            or status.state == "downloading"
            or status.state == "downloaded"
            or status.state == "skipped"
    ) then
        return false
    end

    local downloaded = self:isChapterDownloaded(manga, chapter)
    return downloaded ~= true
end

function SuwayomiPlugin:isChapterDownloadAvailable(manga, chapter)
    local status = self:getDownloadQueue():getStatus(manga, chapter)
    if status and (
        status.state == "queued"
            or status.state == "downloading"
            or status.state == "downloaded"
            or status.state == "skipped"
    ) then
        return true
    end

    local downloaded = self:isChapterDownloaded(manga, chapter)
    return downloaded == true
end

function SuwayomiPlugin:getNextUnreadChaptersForDownload(manga, limit)
    local chapters = {}
    for _, chapter in ipairs((self.current_chapter_context and self.current_chapter_context.chapters) or {}) do
        if self:canQueueChapterDownload(manga, chapter) then
            table.insert(chapters, chapter)
            if #chapters >= limit then
                break
            end
        end
    end
    return chapters
end

function SuwayomiPlugin:getUnreadDownloadBufferCandidates(manga, limit)
    local missing = {}
    local unread_count = 0

    for _, chapter in ipairs((self.current_chapter_context and self.current_chapter_context.chapters) or {}) do
        if chapter.is_read ~= true then
            unread_count = unread_count + 1
            if not self:isChapterDownloadAvailable(manga, chapter) then
                table.insert(missing, chapter)
            end
            if unread_count >= limit then
                break
            end
        end
    end

    return missing, unread_count
end

function SuwayomiPlugin:showBulkActionConfirmation(text, ok_text, callback)
    if SuwayomiUI.showConfirm then
        SuwayomiUI.showConfirm({
            text = text,
            ok_text = ok_text,
            ok_callback = callback,
        })
    else
        callback()
    end
    return true
end

function SuwayomiPlugin:getReadChaptersFromCurrentContext()
    local read_chapters = {}
    for _, chapter in ipairs((self.current_chapter_context and self.current_chapter_context.chapters) or {}) do
        if chapter.is_read == true then
            table.insert(read_chapters, chapter)
        end
    end
    return read_chapters
end

function SuwayomiPlugin:confirmNextUnreadChapterDownloads(limit)
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        SuwayomiUI.showDirectoryChooser(function(path)
            local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
            self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
            self:confirmNextUnreadChapterDownloads(limit)
        end)
        return 0
    end

    local chapters = self:getNextUnreadChaptersForDownload(manga, limit)
    if #chapters == 0 then
        self:showMessage(_("No unread chapters available to download."))
        return 0
    end

    return self:showBulkActionConfirmation(
        T(
            self:pluralize(#chapters, _("Queue %1 unread chapter download?"), _("Queue %1 unread chapter downloads?")),
            #chapters
        ),
        _("Queue"),
        function()
            self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
        end
    )
end

function SuwayomiPlugin:confirmKeepNextUnreadChaptersDownloaded(limit)
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        SuwayomiUI.showDirectoryChooser(function(path)
            local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
            self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
            self:confirmKeepNextUnreadChaptersDownloaded(limit)
        end)
        return 0
    end

    local chapters = self:getUnreadDownloadBufferCandidates(manga, limit)
    if #chapters == 0 then
        self:showMessage(_("Next unread chapter buffer is already downloaded or queued."))
        return 0
    end

    return self:showBulkActionConfirmation(
        T(
            self:pluralize(
                #chapters,
                _("Queue %1 missing download to keep the next %2 unread chapters available?"),
                _("Queue %1 missing downloads to keep the next %2 unread chapters available?")
            ),
            #chapters,
            limit
        ),
        _("Queue"),
        function()
            self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
        end
    )
end

function SuwayomiPlugin:enqueueNextUnreadChapterDownloads(limit)
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        SuwayomiUI.showDirectoryChooser(function(path)
            local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
            self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
            self:enqueueNextUnreadChapterDownloads(limit)
        end)
        return 0
    end

    local chapters = self:getNextUnreadChaptersForDownload(manga, limit)
    if #chapters == 0 then
        self:showMessage(_("No unread chapters available to download."))
        return 0
    end

    return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
end

function SuwayomiPlugin:keepNextUnreadChaptersDownloaded(limit)
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        SuwayomiUI.showDirectoryChooser(function(path)
            local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
            self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
            self:keepNextUnreadChaptersDownloaded(limit)
        end)
        return 0
    end

    local chapters = self:getUnreadDownloadBufferCandidates(manga, limit)
    if #chapters == 0 then
        self:showMessage(_("Next unread chapter buffer is already downloaded or queued."))
        return 0
    end

    return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
end

function SuwayomiPlugin:downloadSelectedChapters()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getSelectedChapters(manga, self.current_chapter_context.chapters)
    if #chapters == 0 then
        self:showMessage(_("No chapters selected."))
        return 0
    end

    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        SuwayomiUI.showDirectoryChooser(function(path)
            local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
            self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
            self:enqueueSelectedChapterDownloads(manga, chapters, saved_path)
        end)
        return 0
    end

    return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
end

function SuwayomiPlugin:formatActiveDownloadCount(count)
    if count == 1 then
        return _("1 download is still in progress.")
    end
    return T(_("%1 downloads are still in progress."), count)
end

function SuwayomiPlugin:formatBulkDeleteMessage(deleted, canceled, missing, active)
    local parts = {}
    if deleted > 0 then
        table.insert(parts, T(
            self:pluralize(deleted, _("Deleted %1 selected chapter from device."), _("Deleted %1 selected chapters from device.")),
            deleted
        ))
    end
    if canceled > 0 then
        table.insert(parts, T(
            self:pluralize(canceled, _("Canceled %1 queued download."), _("Canceled %1 queued downloads.")),
            canceled
        ))
    end
    if missing > 0 then
        table.insert(parts, T(
            self:pluralize(missing, _("Skipped %1 not downloaded."), _("Skipped %1 not downloaded.")),
            missing
        ))
    end
    if active > 0 then
        table.insert(parts, self:formatActiveDownloadCount(active))
    end
    if #parts == 0 then
        return _("No selected chapters were deleted.")
    end
    return table.concat(parts, " ")
end

function SuwayomiPlugin:deleteSelectedChapters()
    local started_at = SuwayomiDebug.now()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getSelectedChapters(manga, self.current_chapter_context.chapters)
    if #chapters == 0 then
        self:showMessage(_("No chapters selected."))
        return 0
    end

    local deleted = 0
    local canceled = 0
    local missing = 0
    local active = 0
    self:withChapterMenuRefreshSuppressed(function()
        for _, chapter in ipairs(chapters) do
            local ok, state = self:deleteChapterFromDeviceWithOptions(manga, chapter, {
                quiet_active = true,
                quiet_missing = true,
                skip_refresh = true,
            })
            if ok then
                deleted = deleted + 1
                if state == "queued" then
                    canceled = canceled + 1
                end
            elseif state == "downloading" then
                active = active + 1
            elseif state == "queued" then
                canceled = canceled + 1
            elseif state == "missing" then
                missing = missing + 1
            end
        end
    end)

    self:clearChapterSelection(true)
    self:refreshChapterMenu()

    if missing > 0 or active > 0 then
        self:showMessage(self:formatBulkDeleteMessage(deleted, 0, missing, active))
    end
    SuwayomiDebug.log({
        operation = "deleteSelectedChapters",
        event = "end",
        requested_count = #chapters,
        deleted_count = deleted,
        missing_count = missing,
        active_count = active,
        canceled_count = canceled,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return deleted
end

function SuwayomiPlugin:deleteReadChaptersFromDevice()
    local started_at = SuwayomiDebug.now()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local read_chapters = self:getReadChaptersFromCurrentContext()

    if #read_chapters == 0 then
        self:showMessage(_("No read chapters to delete."))
        return 0
    end

    local deleted = 0
    local missing = 0
    local active = 0
    self:withChapterMenuRefreshSuppressed(function()
        for _, chapter in ipairs(read_chapters) do
            local ok, state = self:deleteChapterFromDeviceWithOptions(manga, chapter, {
                quiet_active = true,
                quiet_missing = true,
                skip_refresh = true,
            })
            if ok then
                deleted = deleted + 1
            elseif state == "downloading" then
                active = active + 1
            elseif state == "missing" then
                missing = missing + 1
            end
        end
    end)

    self:refreshChapterMenu()

    if deleted == 0 or active > 0 then
        self:showMessage(self:formatBulkDeleteMessage(deleted, 0, missing, active))
    end
    SuwayomiDebug.log({
        operation = "deleteReadChaptersFromDevice",
        event = "end",
        requested_count = #read_chapters,
        deleted_count = deleted,
        missing_count = missing,
        active_count = active,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return deleted
end

function SuwayomiPlugin:confirmDeleteReadChaptersFromDevice()
    if not self.current_chapter_context then
        return 0
    end

    local read_chapters = self:getReadChaptersFromCurrentContext()
    if #read_chapters == 0 then
        self:showMessage(_("No read chapters to delete."))
        return 0
    end

    return self:showBulkActionConfirmation(
        T(
            self:pluralize(
                #read_chapters,
                _("Delete downloaded files for %1 read chapter?"),
                _("Delete downloaded files for %1 read chapters?")
            ),
            #read_chapters
        ),
        _("Delete"),
        function()
            self:deleteReadChaptersFromDevice()
        end
    )
end

function SuwayomiPlugin:markSelectedChaptersRead()
    local started_at = SuwayomiDebug.now()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getSelectedChapters(manga, self.current_chapter_context.chapters)
    if #chapters == 0 then
        self:showMessage(_("No chapters selected."))
        return 0
    end

    local ledger = self:loadChapterLedger()
    for _, chapter in ipairs(chapters) do
        self:markChapterRead(manga, chapter, {
            ledger = ledger,
            skip_refresh = true,
            skip_schedule = true,
        })
    end

    self:clearChapterSelection(true)
    self:refreshChapterMenu({ ledger = ledger })
    self:saveChapterLedger(ledger)
    self:schedulePendingReadSync()
    SuwayomiDebug.log({
        operation = "markSelectedChaptersRead",
        event = "end",
        manga_id = manga and manga.id,
        chapter_count = #chapters,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return #chapters
end

function SuwayomiPlugin:markSelectedChaptersUnread()
    local started_at = SuwayomiDebug.now()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getSelectedChapters(manga, self.current_chapter_context.chapters)
    if #chapters == 0 then
        self:showMessage(_("No chapters selected."))
        return 0
    end

    local ledger = self:loadChapterLedger()
    for _, chapter in ipairs(chapters) do
        self:markChapterUnread(manga, chapter, {
            ledger = ledger,
            skip_refresh = true,
            skip_schedule = true,
        })
    end

    self:clearChapterSelection(true)
    self:refreshChapterMenu({ ledger = ledger })
    self:saveChapterLedger(ledger)
    self:schedulePendingReadSync()
    SuwayomiDebug.log({
        operation = "markSelectedChaptersUnread",
        event = "end",
        manga_id = manga and manga.id,
        chapter_count = #chapters,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return #chapters
end

function SuwayomiPlugin:performBulkChapterAction(action_id)
    if action_id == "bulk_downloads" then
        self:showBulkDownloadActions()
        return true
    end
    local next_unread_count = tostring(action_id or ""):match("^download_next_(%d+)_unread$")
    if next_unread_count then
        local limit = tonumber(next_unread_count)
        if limit >= 50 then
            self:confirmNextUnreadChapterDownloads(limit)
        else
            self:enqueueNextUnreadChapterDownloads(limit)
        end
        return true
    end
    local keep_unread_count = tostring(action_id or ""):match("^keep_next_(%d+)_unread$")
    if keep_unread_count then
        local limit = tonumber(keep_unread_count)
        if limit >= 50 then
            self:confirmKeepNextUnreadChaptersDownloaded(limit)
        else
            self:keepNextUnreadChaptersDownloaded(limit)
        end
        return true
    end
    if action_id == "delete_read_downloaded" then
        self:confirmDeleteReadChaptersFromDevice()
        return true
    end
    if action_id == "download_selected" then
        self:downloadSelectedChapters()
        return true
    end
    if action_id == "delete_selected" then
        self:deleteSelectedChapters()
        return true
    end
    if action_id == "mark_read_selected" then
        self:markSelectedChaptersRead()
        return true
    end
    if action_id == "mark_unread_selected" then
        self:markSelectedChaptersUnread()
        return true
    end
    if action_id == "select_all" then
        self:selectAllChapters()
        return true
    end
    if action_id == "clear_selection" then
        self:clearChapterSelection()
        return true
    end
    return false
end

function SuwayomiPlugin:showBulkDownloadActions()
    if not SuwayomiUI.showChapterActionsMenu then
        return
    end

    SuwayomiUI.showChapterActionsMenu({
        title = _("Bulk downloads"),
        actions = self:getBulkDownloadActions(),
    }, function(action)
        self:performBulkChapterAction(action.id)
    end)
end

function SuwayomiPlugin:showBulkChapterActions(manga)
    if not SuwayomiUI.showChapterActionsMenu then
        self:downloadSelectedChapters()
        return
    end

    local count = self:getSelectedChapterCount()
    local options = {
        title = count > 0 and T(_("%1 selected chapters"), count) or _("Chapter downloads"),
        actions = self:getBulkChapterActions(),
    }

    SuwayomiUI.showChapterActionsMenu(options, function(action)
        self:performBulkChapterAction(action.id)
    end)
end

function SuwayomiPlugin:showChapterActions(manga, chapter)
    if not SuwayomiUI.showChapterActionsMenu then
        self:enqueueChapterDownload(manga, chapter)
        return
    end

    local options = {
        title = chapter.name,
        actions = self:getChapterActions(manga, chapter),
    }

    SuwayomiUI.showChapterActionsMenu(options, function(action)
        self:performChapterAction(manga, chapter, action.id)
    end)
end

function SuwayomiPlugin:getCurrentDocumentPath()
    if not self.ui then
        return nil
    end

    local document = self.ui.document
    return self.ui.document_path
        or self.ui.document_pathname
        or (document and (document.file or document.filename or document.path))
end

function SuwayomiPlugin:isCurrentDocumentFinished()
    local doc_settings = self.ui and self.ui.doc_settings
    if not doc_settings or not doc_settings.readSetting then
        return false
    end

    local summary = doc_settings:readSetting("summary")
    local status = summary and summary.status
    return status == "finished" or status == "complete" or status == "completed"
end

function SuwayomiPlugin:markLedgerEntryRead(entry)
    if not entry or entry.read == true then
        return false
    end

    local ledger = self:loadChapterLedger()
    local key = tostring(entry.manga_id or "") .. ":" .. tostring(entry.chapter_id or "")
    if not ledger[key] then
        return false
    end

    ledger[key].read = true
    ledger[key].pending_read_sync = true
    ledger[key].pending_read_state = true
    self:saveChapterLedger(ledger)

    self:schedulePendingReadSync()
    return true
end

function SuwayomiPlugin:hasPendingReadSync(ledger)
    for _, entry in pairs(ledger or {}) do
        if entry.pending_read_sync == true and entry.chapter_id then
            return true
        end
    end
    return false
end

function SuwayomiPlugin:buildPendingReadSyncBatch(ledger, max_count)
    local keys = {}
    for key, entry in pairs(ledger or {}) do
        if entry.pending_read_sync == true and entry.chapter_id then
            table.insert(keys, key)
        end
    end
    table.sort(keys)

    local batch = {}
    for _, key in ipairs(keys) do
        if max_count and #batch >= max_count then
            break
        end
        local entry = ledger[key]
        local desired_read_state = entry.pending_read_state
        if desired_read_state == nil then
            desired_read_state = entry.read == true
        end
        table.insert(batch, {
            key = key,
            chapter_id = tostring(entry.chapter_id),
            desired_read_state = desired_read_state == true,
        })
    end
    return batch
end

function SuwayomiPlugin:getReadSyncResultPath()
    local settings_dir = SuwayomiSettings.getSettingsDir and SuwayomiSettings:getSettingsDir() or "."
    self.pending_read_sync_result_counter = (self.pending_read_sync_result_counter or 0) + 1
    return tostring(settings_dir or "."):gsub("/+$", "")
        .. "/suwayomi_dl_read_sync_"
        .. tostring(os.time())
        .. "_"
        .. tostring(self.pending_read_sync_result_counter)
        .. ".json"
end

function SuwayomiPlugin:schedulePendingReadSyncPoll()
    if self.pending_read_sync_poll_scheduled or not self.pending_read_sync_active then
        return
    end

    self.pending_read_sync_poll_scheduled = true
    UIManager:scheduleIn(self.read_sync_poll_interval_seconds, function()
        self:pollPendingReadSync()
    end)
end

function SuwayomiPlugin:startPendingReadSyncWorker(credentials, max_count)
    if self.pending_read_sync_active then
        return true, 0
    end

    credentials = credentials or SuwayomiSettings:load()
    local ledger = self:loadChapterLedger()
    local batch = self:buildPendingReadSyncBatch(ledger, max_count)
    if #batch == 0 then
        return false, 0
    end
    if not credentials or credentials.server_url == "" then
        return false, #batch
    end

    local result_path = self:getReadSyncResultPath()
    os.remove(result_path)
    os.remove(result_path .. ".tmp")

    local pid, err = FFIUtil.runInSubProcess(function()
        SuwayomiReadSyncWorker:run(credentials, batch, result_path)
    end)

    if not pid then
        self:showMessage(T(_("Could not start read sync: %1"), err or _("unknown error")))
        return false, #batch
    end

    self.pending_read_sync_active = {
        pid = pid,
        credentials = credentials,
        batch = batch,
        result_path = result_path,
        started_at = os.time(),
    }
    self:schedulePendingReadSyncPoll()
    return true, #batch
end

function SuwayomiPlugin:getDesiredReadStateFromLedgerEntry(entry)
    if not entry then
        return nil
    end
    if entry.pending_read_state ~= nil then
        return entry.pending_read_state == true
    end
    return entry.read == true
end

function SuwayomiPlugin:applyPendingReadSyncResult(active, result)
    if not active or type(result) ~= "table" then
        return 0, active and #(active.batch or {}) or 0
    end

    local snapshot_by_key = {}
    for _, item in ipairs(active.batch or {}) do
        snapshot_by_key[item.key] = item.desired_read_state == true
    end

    local ledger = self:loadChapterLedger()
    local synced = 0
    local changed = false

    for _, item in ipairs(result.failures or {}) do
        SuwayomiDebug.log({
            operation = "read_sync",
            event = "failure",
            key = item.key,
            chapter_id = item.chapter_id,
            desired_read_state = item.desired_read_state == true,
            error = item.error or "Read sync failed.",
        })
    end

    for _, item in ipairs(result.successes or {}) do
        local key = item.key
        local entry = ledger[key]
        local desired_read_state = item.desired_read_state == true
        if entry
            and entry.pending_read_sync == true
            and snapshot_by_key[key] == desired_read_state
            and self:getDesiredReadStateFromLedgerEntry(entry) == desired_read_state
        then
            entry.pending_read_sync = nil
            entry.pending_read_state = nil
            synced = synced + 1
            changed = true
            if desired_read_state ~= true and not entry.path then
                ledger[key] = nil
            end
        else
            SuwayomiDebug.log({
                operation = "read_sync",
                event = "conflict",
                key = key,
                chapter_id = item.chapter_id,
                worker_desired_read_state = desired_read_state,
                current_desired_read_state = self:getDesiredReadStateFromLedgerEntry(entry),
                pending_read_sync = entry and entry.pending_read_sync == true or false,
            })
        end
    end

    if changed then
        self:saveChapterLedger(ledger)
    end

    return synced, tonumber(result.attempted) or #(active.batch or {})
end

function SuwayomiPlugin:finishPendingReadSync(active, synced, attempted)
    self.pending_read_sync_active = nil
    if active and active.result_path then
        os.remove(active.result_path)
        os.remove(active.result_path .. ".tmp")
    end

    if self:hasPendingReadSync(self:loadChapterLedger()) then
        local next_delay = self.read_sync_delay_seconds
        if attempted and attempted > 0 and synced == 0 then
            next_delay = self.pending_read_sync_failure_delay or self.read_sync_failure_delay_seconds
            self.pending_read_sync_failure_delay = math.min(
                next_delay * 2,
                self.read_sync_max_failure_delay_seconds
            )
        else
            self.pending_read_sync_failure_delay = nil
        end
        self:schedulePendingReadSync(active and active.credentials or nil, next_delay)
    else
        self.pending_read_sync_failure_delay = nil
    end
end

function SuwayomiPlugin:pollPendingReadSync()
    self.pending_read_sync_poll_scheduled = false
    local active = self.pending_read_sync_active
    if not active then
        return
    end

    local done = FFIUtil.isSubProcessDone(active.pid)
    if not done then
        if not active.terminating
            and os.time() - (active.started_at or os.time()) > self.read_sync_watchdog_timeout_seconds
        then
            if FFIUtil.terminateSubProcess then
                pcall(FFIUtil.terminateSubProcess, active.pid)
            end
            active.terminating = true
        end
        self:schedulePendingReadSyncPoll()
        return
    end

    local result = SuwayomiReadSyncWorker:readResult(active.result_path)
    local synced, attempted = self:applyPendingReadSyncResult(active, result)
    self:finishPendingReadSync(active, synced, attempted)
end

function SuwayomiPlugin:schedulePendingReadSync(credentials, delay_seconds)
    if self.pending_read_sync_scheduled then
        return
    end

    self.pending_read_sync_scheduled = true
    SuwayomiDebug.log({
        operation = "schedulePendingReadSync",
        event = "scheduled",
        delay_seconds = delay_seconds or self.read_sync_delay_seconds,
    })
    UIManager:scheduleIn(delay_seconds or self.read_sync_delay_seconds, function()
        self.pending_read_sync_scheduled = false
        if self.pending_read_sync_active then
            return
        end
        local sync_credentials = credentials or SuwayomiSettings:load()
        local started, attempted = self:startPendingReadSyncWorker(sync_credentials, self.read_sync_batch_size)
        if not started then
            if self:hasPendingReadSync(self:loadChapterLedger()) then
                local next_delay = self.read_sync_delay_seconds
                if attempted and attempted > 0 then
                    next_delay = self.pending_read_sync_failure_delay or self.read_sync_failure_delay_seconds
                    self.pending_read_sync_failure_delay = math.min(
                        next_delay * 2,
                        self.read_sync_max_failure_delay_seconds
                    )
                else
                    self.pending_read_sync_failure_delay = nil
                end
                self:schedulePendingReadSync(sync_credentials, next_delay)
            else
                self.pending_read_sync_failure_delay = nil
            end
        end
    end)
end

function SuwayomiPlugin:syncReadStateNow()
    if self.pending_read_sync_active then
        self:showMessage(_("Read state sync is already running."))
        return false
    end

    self:reconcileDownloadedChapterLedger()

    if not self:hasPendingReadSync(self:loadChapterLedger()) then
        self:showMessage(_("Read state is already synced."))
        return false
    end

    local credentials = SuwayomiSettings:load()
    if not credentials or credentials.server_url == "" then
        self:showMessage(_("Set up your Suwayomi server login first."))
        return false
    end

    local started = self:startPendingReadSyncWorker(credentials, self.read_sync_batch_size)
    if started then
        self:showMessage(_("Read state sync started."))
        return true
    end
    return false
end

function SuwayomiPlugin:onCloseDocument()
    local document_path = self:getCurrentDocumentPath()
    if not document_path or not self:isCurrentDocumentFinished() then
        return
    end

    local ledger = self:loadChapterLedger()
    for _, entry in pairs(ledger) do
        if entry.path == document_path then
            self:markLedgerEntryRead(entry)
            return
        end
    end
end

function SuwayomiPlugin:refreshChapterMenu(options)
    local started_at = SuwayomiDebug.now()
    options = options or {}
    if not self.current_chapter_context then
        return
    end
    self.pending_chapter_menu_refresh = false

    local menu_options_builder = options.quick
        and self.buildQuickChapterMenuOptions
        or self.buildChapterMenuOptions
    local menu_options = menu_options_builder(
        self,
        self.current_chapter_context.manga,
        self.current_chapter_context.chapters,
        options.ledger
    )
    self.current_chapter_options = self.current_chapter_options or {}
    self.current_chapter_options.title = menu_options.title
    self.current_chapter_options.chapters = menu_options.chapters
    self.current_chapter_options.title_bar_left_icon = menu_options.title_bar_left_icon
    self.current_chapter_options.on_title_bar_left_tap = menu_options.on_title_bar_left_tap

    if SuwayomiUI.updateChapterMenu then
        SuwayomiUI.updateChapterMenu(self.current_chapter_menu, menu_options, function(chapter)
            self:handleChapterTap(self.current_chapter_context.manga, chapter)
        end, function(chapter)
            self:toggleChapterSelection(self.current_chapter_context.manga, chapter)
        end)
    elseif self.current_chapter_menu and self.current_chapter_menu.updateItems then
        self.current_chapter_menu:updateItems(nil, true)
    end
    SuwayomiDebug.log({
        operation = "refreshChapterMenu",
        event = "end",
        quick = options.quick == true,
        chapter_count = #(self.current_chapter_context.chapters or {}),
        selected_count = self:getSelectedChapterCount(),
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
end

function SuwayomiPlugin:enqueueChapterDownload(manga, chapter)
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        SuwayomiUI.showDirectoryChooser(function(path)
            local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
            self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
            UIManager:nextTick(function()
                self:enqueueChapterDownload(manga, chapter)
            end)
        end)
        return
    end

    self:withChapterMenuRefreshSuppressed(function()
        self:getDownloadQueue():enqueue(manga, chapter, download_directory)
    end)
    self:refreshChapterMenu({ quick = true })
end

function SuwayomiPlugin:processChapterDownloadQueue()
    self:getDownloadQueue():process()
end

function SuwayomiPlugin:pollChapterDownload()
    self:getDownloadQueue():poll()
end

function SuwayomiPlugin:addToMainMenu(menu_items)
    menu_items.suwayomi_dl = {
        text = _("Suwayomi"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Browse Suwayomi"),
                callback = function()
                    self:browseSuwayomi()
                end
            },
            {
                text = _("Sync read state now"),
                callback = function()
                    self:syncReadStateNow()
                end
            },
            {
                text = _("Setup login information"),
                callback = function()
                    self:showLoginDialog()
                end
            },
            {
                text = _("Setup source languages"),
                callback = function()
                    self:showSourceLanguageDialog()
                end
            },
            {
                text = _("Setup download directory"),
                callback = function()
                    SuwayomiUI.showDirectoryChooser(function(path)
                        local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
                        self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
                    end)
                end
            },
            {
                text = _("Setup parallel downloads"),
                callback = function()
                    SuwayomiUI.showParallelDownloadsMenu({
                        current = SuwayomiSettings:loadMaxParallelChapterDownloads(),
                        choices = { 1, 2, 3, 4 },
                        onSelect = function(value)
                            local saved_value = SuwayomiSettings:saveMaxParallelChapterDownloads(value)
                            self.download_queue = nil
                            self:showMessage(T(_("Suwayomi parallel chapter downloads saved: %1"), saved_value))
                        end,
                    })
                end
            }
        }
    }
end

return SuwayomiPlugin
