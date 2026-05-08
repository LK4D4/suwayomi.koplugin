local Dispatcher = require("dispatcher") -- luacheck:ignore
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local SuwayomiAPI = require("suwayomi_api")
local SuwayomiClient = require("suwayomi_client")
local SuwayomiDownloadQueue = require("suwayomi_download_queue")
local SuwayomiReadSyncWorker = require("suwayomi_read_sync_worker")
local SuwayomiSourceFetchWorker = require("suwayomi_source_fetch_worker")
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
    source_fetch_poll_interval_seconds = 0.5,
    source_cache_refresh_delay_seconds = 0.1,
    source_fetch_watchdog_timeout_seconds = 60,
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

function SuwayomiPlugin:createClient()
    return SuwayomiClient:new{
        api = SuwayomiAPI,
        ui = SuwayomiUI,
        settings = SuwayomiSettings,
        debug = SuwayomiDebug,
        plugin = self,
        gettext = _,
    }
end

function SuwayomiPlugin:getClient()
    if not self.client then
        self.client = self:createClient()
    end
    return self.client
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

function SuwayomiPlugin:getHomeMenuOptions()
    return {
        title_bar_left_icon = "appbar.filebrowser",
        on_title_bar_left_tap = function(menu)
            if menu and UIManager.close then
                UIManager:close(menu)
            end
            self:showHome()
            return true
        end,
    }
end

function SuwayomiPlugin:buildHomeActions()
    return {
        {
            id = "library",
            text = _("Library"),
            callback = function()
                self:showLibrary()
            end,
        },
        {
            id = "browse",
            text = _("Browse"),
            callback = function()
                self:browseSuwayomi()
            end,
        },
        {
            id = "downloads",
            text = _("Downloads"),
            callback = function()
                self:showDownloads()
            end,
        },
        {
            id = "sync",
            text = _("Sync"),
            callback = function()
                self:syncReadStateNow()
            end,
        },
        {
            id = "settings",
            text = _("Settings"),
            callback = function()
                self:showSettings()
            end,
        },
        {
            id = "close",
            text = _("Close"),
        },
    }
end

function SuwayomiPlugin:showHome()
    return SuwayomiUI.showHomeDialog({
        actions = self:buildHomeActions(),
    }, function(action)
        if action and action.callback then
            action.callback()
        end
    end)
end

function SuwayomiPlugin:showLibrary()
    return self:getClient():showLibrary()
end

function SuwayomiPlugin:isDownloadsSnapshotEmpty(snapshot)
    return #(snapshot.active or {}) == 0
        and #(snapshot.queued or {}) == 0
        and #(snapshot.failed or {}) == 0
end

function SuwayomiPlugin:closeMenu(menu)
    if menu and UIManager.close then
        UIManager:close(menu)
    end
end

function SuwayomiPlugin:getDownloadJobTitle(job)
    local manga_title = job and job.manga and job.manga.title or nil
    local chapter_name = job and job.chapter and job.chapter.name or nil
    if manga_title and manga_title ~= "" and chapter_name and chapter_name ~= "" then
        return manga_title .. " / " .. chapter_name
    end
    return manga_title or chapter_name or tostring(job and job.key or "")
end

function SuwayomiPlugin:canOpenDownloadJobChapterList(job)
    return job and job.manga and job.manga.id ~= nil and tostring(job.manga.id) ~= ""
end

function SuwayomiPlugin:formatCancelQueuedDownloadMessage(state)
    if state == "downloading" then
        return _("Download is already downloading.")
    end
    return _("Download is no longer queued.")
end

function SuwayomiPlugin:showDownloadsActions(menu, snapshot)
    if not SuwayomiUI.showChapterActionsMenu then
        self:closeMenu(menu)
        self:showHome()
        return
    end

    local actions = {
        { id = "home", text = _("Suwayomi home") },
    }
    if #(snapshot.queued or {}) > 0 then
        table.insert(actions, { id = "cancel_queued", text = _("Cancel queued downloads") })
    end
    if #(snapshot.failed or {}) > 0 then
        table.insert(actions, { id = "clear_failed", text = _("Clear failed") })
    end

    SuwayomiUI.showChapterActionsMenu({
        title = _("Suwayomi Downloads"),
        actions = actions,
    }, function(action)
        if not action then
            return
        end
        local queue = self:getDownloadQueue()
        if action.id == "home" then
            self:closeMenu(menu)
            self:showHome()
        elseif action.id == "cancel_queued" then
            queue:cancelQueued()
            self:closeMenu(menu)
            self:showDownloads()
        elseif action.id == "clear_failed" then
            queue:clearFailed()
            self:closeMenu(menu)
            self:showDownloads()
        end
    end)
end

function SuwayomiPlugin:showQueuedDownloadActions(job, menu)
    if not SuwayomiUI.showChapterActionsMenu then
        return
    end

    local actions = {
        { id = "cancel_queued", text = _("Cancel queued download") },
    }
    if self:canOpenDownloadJobChapterList(job) then
        table.insert(actions, { id = "open_chapter_list", text = _("Open chapter list") })
    end

    SuwayomiUI.showChapterActionsMenu({
        title = self:getDownloadJobTitle(job),
        actions = actions,
    }, function(action)
        if action and action.id == "cancel_queued" then
            local cancelled, state = self:getDownloadQueue():cancelPending(job.manga, job.chapter)
            self:closeMenu(menu)
            if not cancelled then
                self:showMessage(self:formatCancelQueuedDownloadMessage(state), { timeout = 2 })
            end
            self:showDownloads()
        elseif action and action.id == "open_chapter_list" then
            self:closeMenu(menu)
            self:showMangaActions(job.manga, {
                onMangaUpdated = function()
                    self:showDownloads()
                end,
            })
        end
    end)
end

function SuwayomiPlugin:showActiveDownloadActions(job, menu)
    if not SuwayomiUI.showChapterActionsMenu then
        return
    end
    if not self:canOpenDownloadJobChapterList(job) then
        self:showMessage(_("This download cannot be opened right now."), { timeout = 2 })
        return
    end

    SuwayomiUI.showChapterActionsMenu({
        title = self:getDownloadJobTitle(job),
        actions = {
            { id = "open_chapter_list", text = _("Open chapter list") },
        },
    }, function(action)
        if action and action.id == "open_chapter_list" then
            self:closeMenu(menu)
            self:showMangaActions(job.manga, {
                onMangaUpdated = function()
                    self:showDownloads()
                end,
            })
        end
    end)
end

function SuwayomiPlugin:showDownloads()
    local queue = self:getDownloadQueue()
    local snapshot = queue:getSnapshot()
    if self:isDownloadsSnapshotEmpty(snapshot) then
        self:showMessage(_("No active downloads."))
        return
    end

    return SuwayomiUI.showDownloadsMenu(snapshot, {
        onSelectActive = function(job, menu)
            self:showActiveDownloadActions(job, menu)
        end,
        onSelectQueued = function(job, menu)
            self:showQueuedDownloadActions(job, menu)
        end,
        onRetryFailed = function(job, menu)
            local ok = queue:retryFailed(job.key)
            self:closeMenu(menu)
            if ok then
                self:showMessage(_("Download queued."), { timeout = 2 })
            else
                self:showMessage(_("Could not retry download."))
            end
            self:showDownloads()
        end,
        onClearFailed = function(menu)
            local cleared = queue:clearFailed()
            self:closeMenu(menu)
            self:showMessage(T(_("Cleared %1 failed downloads."), cleared), { timeout = 2 })
            self:showDownloads()
        end,
    }, {
        title_bar_left_icon = "appbar.menu",
        on_title_bar_left_tap = function(menu)
            self:showDownloadsActions(menu, snapshot)
            return true
        end,
    })
end

function SuwayomiPlugin:showLibrarySettings(touchmenu_instance)
    return self:showLibraryCategoryPickerBehaviorDialog(touchmenu_instance)
end

function SuwayomiPlugin:showSettings()
    if SuwayomiUI.showSettingsMenu then
        return SuwayomiUI.showSettingsMenu(self:buildSettingsMenu())
    end
    self:showMessage(_("Settings are unavailable."))
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

function SuwayomiPlugin:showLoadingMessage(message)
    local loading_message = InfoMessage:new{
        text = message,
        suwayomi_loading = true,
    }
    UIManager:show(loading_message)
    if UIManager.forceRePaint then
        UIManager:forceRePaint()
    end
    return loading_message
end

function SuwayomiPlugin:closeLoadingMessage(loading_message)
    if loading_message and UIManager.close then
        UIManager:close(loading_message)
    end
end

function SuwayomiPlugin:getSourceFetchResultPath()
    local settings_dir = SuwayomiSettings.getSettingsDir and SuwayomiSettings:getSettingsDir() or "."
    self.source_fetch_result_counter = (self.source_fetch_result_counter or 0) + 1
    return tostring(settings_dir or "."):gsub("/+$", "")
        .. "/suwayomi_dl_source_fetch_"
        .. tostring(os.time())
        .. "_"
        .. tostring(self.source_fetch_result_counter)
        .. ".json"
end

function SuwayomiPlugin:onSuwayomiAction()
    self:showNotImplemented(_("Open Search > Suwayomi to access the plugin menu."))
end

function SuwayomiPlugin:refreshSettingsMenu(touchmenu_instance)
    if touchmenu_instance and touchmenu_instance.updateItems then
        touchmenu_instance:updateItems()
    end
end

function SuwayomiPlugin:showLoginDialog(touchmenu_instance)
    SuwayomiUI.showLoginDialog({
        credentials = SuwayomiSettings:load(),
        onSave = function(credentials)
            local saved_credentials = SuwayomiSettings:save(credentials)
            self:refreshSettingsMenu(touchmenu_instance)
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

function SuwayomiPlugin:loadSourceCache(credentials)
    if not SuwayomiSettings.loadSourceCache then
        return nil
    end
    return SuwayomiSettings:loadSourceCache(credentials and credentials.server_url or "")
end

function SuwayomiPlugin:saveSourceCache(credentials, sources)
    if not SuwayomiSettings.saveSourceCache then
        return nil
    end
    return SuwayomiSettings:saveSourceCache(credentials and credentials.server_url or "", sources or {}, os.time())
end

function SuwayomiPlugin:showSourceLanguageDialog(touchmenu_instance)
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
        self:refreshSettingsMenu(touchmenu_instance)
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

function SuwayomiPlugin:getSourceLanguageSummary()
    local selected = self:buildSourceLanguageSet(SuwayomiSettings:loadSourceLanguages())
    local labels = {}
    for _, language in ipairs(SOURCE_LANGUAGE_OPTIONS) do
        if selected[language.code] then
            table.insert(labels, language.label)
        end
    end
    return #labels > 0 and table.concat(labels, ", ") or _("none")
end

function SuwayomiPlugin:getDownloadDirectoryChooserStartDir()
    local ok, lfs = pcall(require, "lfs")
    if not ok or not lfs or not lfs.attributes then
        return nil
    end

    local function directoryExists(path)
        return path and path ~= "" and lfs.attributes(path, "mode") == "directory"
    end

    local function joinPath(base, name)
        if base:sub(-1) == "/" then
            return base .. name
        end
        return base .. "/" .. name
    end

    local function getDefaultMangaDirectory(home_dir)
        if not directoryExists(home_dir) then
            return nil
        end

        local books_dir = joinPath(home_dir, "Books")
        if not directoryExists(books_dir) then
            return nil
        end

        local manga_dir = joinPath(books_dir, "Manga")
        if directoryExists(manga_dir) then
            return manga_dir
        end

        if lfs.mkdir then
            local ok = lfs.mkdir(manga_dir)
            if ok and directoryExists(manga_dir) then
                return manga_dir
            end
        end
        return nil
    end

    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if directoryExists(download_directory) then
        return download_directory
    end

    local reader_settings = _G.G_reader_settings
    if reader_settings and reader_settings.readSetting then
        local home_dir = reader_settings:readSetting("home_dir")
        if directoryExists(home_dir) then
            return home_dir
        end
    end

    local device_ok, Device = pcall(require, "device")
    if device_ok and Device and directoryExists(Device.home_dir) then
        local default_manga_dir = getDefaultMangaDirectory(Device.home_dir)
        if default_manga_dir then
            return default_manga_dir
        end
        return Device.home_dir
    end
    return nil
end

function SuwayomiPlugin:getDownloadDirectorySummary()
    local path = SuwayomiSettings:loadDownloadDirectory()
    if not path or path == "" then
        return _("not set")
    end

    path = tostring(path):gsub("/+$", "")
    local parts = {}
    for part in path:gmatch("[^/]+") do
        table.insert(parts, part)
    end
    if #parts >= 2 then
        return parts[#parts - 1] .. "/" .. parts[#parts]
    end
    return path
end

function SuwayomiPlugin:showDownloadDirectoryDialog(touchmenu_instance)
    SuwayomiUI.showDirectoryChooser(function(path)
        local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
        self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
        self:refreshSettingsMenu(touchmenu_instance)
    end, self:getDownloadDirectoryChooserStartDir())
end

function SuwayomiPlugin:showParallelDownloadsDialog(touchmenu_instance)
    local parallel_menu
    local choices = { 1, 2, 3, 4 }
    local function onSelect(value)
        local saved_value = SuwayomiSettings:saveMaxParallelChapterDownloads(value)
        self.download_queue = nil
        self:showMessage(T(_("Suwayomi parallel chapter downloads saved: %1"), saved_value))
        self:refreshSettingsMenu(touchmenu_instance)
        if SuwayomiUI.updateParallelDownloadsMenu then
            SuwayomiUI.updateParallelDownloadsMenu(parallel_menu, {
                current = saved_value,
                choices = choices,
                onSelect = onSelect,
            })
        end
    end

    parallel_menu = SuwayomiUI.showParallelDownloadsMenu({
        current = SuwayomiSettings:loadMaxParallelChapterDownloads(),
        choices = choices,
        onSelect = onSelect,
    })
end

function SuwayomiPlugin:getKeepNextUnreadDownloadsSummary()
    local value = SuwayomiSettings:loadKeepNextUnreadDownloads()
    if value == 0 then
        return _("off")
    end
    return T(self:pluralize(value, _("%1 chapter"), _("%1 chapters")), value)
end

function SuwayomiPlugin:showKeepNextUnreadDownloadsDialog(touchmenu_instance)
    local keep_menu
    local choices = { 0, 5, 10, 50 }
    local function onSelect(value)
        local saved_value = SuwayomiSettings:saveKeepNextUnreadDownloads(value)
        self:refreshSettingsMenu(touchmenu_instance)
        self:showMessage(T(
            _("Keep next unread downloaded: %1"),
            saved_value == 0 and _("off") or T(self:pluralize(saved_value, _("%1 chapter"), _("%1 chapters")), saved_value)
        ))
        if SuwayomiUI.updateKeepNextUnreadDownloadsMenu then
            SuwayomiUI.updateKeepNextUnreadDownloadsMenu(keep_menu, {
                current = saved_value,
                choices = choices,
                onSelect = onSelect,
            })
        end
    end

    keep_menu = SuwayomiUI.showKeepNextUnreadDownloadsMenu({
        current = SuwayomiSettings:loadKeepNextUnreadDownloads(),
        choices = choices,
        onSelect = onSelect,
    })
end

function SuwayomiPlugin:getLibraryCategoryPickerBehaviorSummary()
    if SuwayomiSettings.loadLibraryCategoryPickerBehavior then
        return SuwayomiSettings:loadLibraryCategoryPickerBehavior()
    end
    return "automatic"
end

function SuwayomiPlugin:showLibraryCategoryPickerBehaviorDialog(touchmenu_instance)
    if not SuwayomiSettings.loadLibraryCategoryPickerBehavior
        or not SuwayomiSettings.saveLibraryCategoryPickerBehavior
    then
        self:showMessage(_("Library category picker settings are unavailable."))
        return
    end

    local picker_menu
    local choices = { "automatic", "always", "never" }
    local function onSelect(behavior)
        local saved_behavior = SuwayomiSettings:saveLibraryCategoryPickerBehavior(behavior)
        self:refreshSettingsMenu(touchmenu_instance)
        self:showMessage(T(_("Suwayomi library category picker saved: %1"), saved_behavior))
        if SuwayomiUI.updateLibraryCategoryPickerBehaviorMenu then
            SuwayomiUI.updateLibraryCategoryPickerBehaviorMenu(picker_menu, {
                current = saved_behavior,
                choices = choices,
                onSelect = onSelect,
            })
        end
    end

    picker_menu = SuwayomiUI.showLibraryCategoryPickerBehaviorMenu({
        current = SuwayomiSettings:loadLibraryCategoryPickerBehavior(),
        choices = choices,
        onSelect = onSelect,
    })
end

function SuwayomiPlugin:showSourceList(sources, options)
    options = options or {}
    if not options.force_new and self.current_sources_menu and SuwayomiUI.updateSourcesMenu then
        SuwayomiUI.updateSourcesMenu(self.current_sources_menu, sources, function(source)
            self:showMangaForSource(source)
        end, self:getHomeMenuOptions())
        return self.current_sources_menu
    end

    self.current_sources_menu = SuwayomiUI.showSourcesMenu(sources, function(source)
        self:showMangaForSource(source)
    end, self:getHomeMenuOptions())
    return self.current_sources_menu
end

function SuwayomiPlugin:showFetchedSources(result, options)
    options = options or {}
    if not result then
        if not options.silent then
            self:showMessage(_("Could not load Suwayomi sources."))
        end
        return
    end
    if not result.ok then
        if not options.silent then
            self:showMessage(_(result.error or "Could not load Suwayomi sources."))
        end
        return
    end

    self:saveSourceCache(options.credentials, result.sources)
    local filtered_sources = self:filterSourcesByLanguage(result.sources)
    SuwayomiDebug.log({
        operation = "browseSuwayomi",
        event = options.refresh and "sources_refreshed" or "sources_loaded",
        source_count = #(result.sources or {}),
        filtered_source_count = #filtered_sources,
    })
    if #filtered_sources == 0 then
        if not options.silent then
            self:showMessage(_("No Suwayomi sources match the selected languages."))
        end
        return
    end

    self:showSourceList(filtered_sources)
end

function SuwayomiPlugin:showCachedSources(cache)
    local filtered_sources = self:filterSourcesByLanguage(cache and cache.sources or {})
    SuwayomiDebug.log({
        operation = "browseSuwayomi",
        event = "source_cache_hit",
        source_count = #(cache and cache.sources or {}),
        filtered_source_count = #filtered_sources,
        cache_age_seconds = math.max(0, os.time() - (tonumber(cache and cache.updated_at) or os.time())),
    })
    if #filtered_sources == 0 then
        return false
    end

    self:showSourceList(filtered_sources, { force_new = true })
    return true
end

function SuwayomiPlugin:scheduleSourceCacheRefresh(credentials)
    if self.source_cache_refresh_scheduled or self.source_fetch_active then
        return
    end

    self.source_cache_refresh_scheduled = true
    UIManager:scheduleIn(self.source_cache_refresh_delay_seconds, function()
        self.source_cache_refresh_scheduled = false
        self:startSourceFetchWorker(credentials, {
            refresh = true,
            silent = true,
        })
    end)
end

function SuwayomiPlugin:scheduleSourceFetchPoll()
    if self.source_fetch_poll_scheduled or not self.source_fetch_active then
        return
    end

    self.source_fetch_poll_scheduled = true
    UIManager:scheduleIn(self.source_fetch_poll_interval_seconds, function()
        self:pollSourceFetch()
    end)
end

function SuwayomiPlugin:startSourceFetchWorker(credentials, options)
    options = options or {}
    options.credentials = options.credentials or credentials
    if self.source_fetch_active then
        return false
    end

    local result_path = self:getSourceFetchResultPath()
    os.remove(result_path)
    os.remove(result_path .. ".tmp")

    local active = {
        credentials = credentials,
        options = options,
        result_path = result_path,
        started_at = os.time(),
        loading_message = not options.silent
            and self:showLoadingMessage(options.loading_message or _("Loading sources..."))
            or nil,
    }
    self.source_fetch_active = active

    local pid, err = FFIUtil.runInSubProcess(function()
        SuwayomiSourceFetchWorker:run(credentials, result_path)
    end)

    if not pid then
        self.source_fetch_active = nil
        self:closeLoadingMessage(active.loading_message)
        os.remove(result_path)
        os.remove(result_path .. ".tmp")
        if not options.silent then
            self:showMessage(T(_("Could not start source loading: %1"), err or _("unknown error")))
        end
        return false
    end

    active.pid = pid
    if FFIUtil.isSubProcessDone(pid) then
        self:pollSourceFetch()
    else
        self:scheduleSourceFetchPoll()
    end
    return true
end

function SuwayomiPlugin:finishSourceFetch(active, result)
    self.source_fetch_active = nil
    self:closeLoadingMessage(active and active.loading_message)
    if active and active.result_path then
        os.remove(active.result_path)
        os.remove(active.result_path .. ".tmp")
    end
    self:showFetchedSources(result, active and active.options or {})
end

function SuwayomiPlugin:pollSourceFetch()
    self.source_fetch_poll_scheduled = false
    local active = self.source_fetch_active
    if not active then
        return
    end

    local done = FFIUtil.isSubProcessDone(active.pid)
    if not done then
        if not active.terminating
            and os.time() - (active.started_at or os.time()) > self.source_fetch_watchdog_timeout_seconds
        then
            if FFIUtil.terminateSubProcess then
                pcall(FFIUtil.terminateSubProcess, active.pid)
            end
            active.terminating = true
        end
        self:scheduleSourceFetchPoll()
        return
    end

    local result = SuwayomiSourceFetchWorker:readResult(active.result_path)
    self:finishSourceFetch(active, result)
end

function SuwayomiPlugin:browseSuwayomi()
    return SuwayomiDebug.time("browseSuwayomi", function()
        local credentials = SuwayomiSettings:load()
        if credentials.server_url == "" then
            self:showMessage(_("Set up your Suwayomi server login first."))
            return
        end

        self:schedulePendingReadSync(credentials)

        local cache = self:loadSourceCache(credentials)
        if cache and #(cache.sources or {}) > 0 and self:showCachedSources(cache) then
            self:scheduleSourceCacheRefresh(credentials)
            return
        end

        self:startSourceFetchWorker(credentials, { credentials = credentials })
    end)
end

function SuwayomiPlugin:showMangaForSource(source)
    return self:getClient():showMangaForSource(source)
end

function SuwayomiPlugin:attachSourceToManga(manga, source)
    return self:getClient():attachSourceToManga(manga, source)
end

function SuwayomiPlugin:isMangaUninitialized(manga)
    return manga and manga.initialized == false
end

function SuwayomiPlugin:applyMangaRefreshResult(manga, refreshed_manga)
    if type(manga) ~= "table" or type(refreshed_manga) ~= "table" then
        return manga
    end
    for key, value in pairs(refreshed_manga) do
        manga[key] = value
    end
    return manga
end

function SuwayomiPlugin:refreshUninitializedMangaForChapters(manga)
    if not self:isMangaUninitialized(manga) or not manga.id or not SuwayomiAPI.refreshManga then
        return nil, false
    end

    local credentials = SuwayomiSettings:load()
    local result = self:withLoadingMessage("refresh-manga", _("Refreshing chapters..."), function()
        return SuwayomiAPI.refreshManga(credentials, manga.id)
    end)
    if not result then
        return nil, true
    end
    if not result.ok then
        self:showMessage(_(result.error))
        return nil, true
    end
    if type(result.chapters) ~= "table" then
        self:showMessage(_("Suwayomi server did not refresh manga."))
        return nil, true
    end

    self:applyMangaRefreshResult(manga, result.manga)
    return {
        ok = true,
        manga = manga,
        chapters = result.chapters,
    }, true
end

function SuwayomiPlugin:showChapterResultForManga(manga, result)
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
    self:setCurrentMangaChapterContext(manga, chapters)

    self.current_chapter_options = self:buildChapterMenuOptions(manga, chapters)
    self.current_chapter_menu = SuwayomiUI.showChapterMenu(self.current_chapter_options, function(chapter)
        self:handleChapterTap(manga, chapter)
    end, function(chapter)
        self:toggleChapterSelection(manga, chapter)
    end)
    return true
end

function SuwayomiPlugin:showChaptersForManga(manga)
    return SuwayomiDebug.time("showChaptersForManga", {
        manga_id = manga and manga.id,
    }, function()
        local result, refresh_attempted = self:refreshUninitializedMangaForChapters(manga)
        if not result and refresh_attempted then
            return
        end
        if not result and not refresh_attempted then
            local credentials = SuwayomiSettings:load()
            result = self:withLoadingMessage("chapters", _("Loading chapters..."), function()
                return SuwayomiAPI.fetchChaptersForManga(credentials, manga.id)
            end)
        end
        if not result then
            return
        end
        return self:showChapterResultForManga(manga, result)
    end)
end

function SuwayomiPlugin:canOpenFirstUnreadMangaChapter(manga)
    local chapter = manga and manga.first_unread_chapter
    if not chapter then
        return false
    end

    return self:isChapterDownloaded(manga, chapter) == true
end

function SuwayomiPlugin:getMangaActions(manga)
    local actions = {
        { id = "open_chapters", text = _("Open chapters") },
    }

    if self:canOpenFirstUnreadMangaChapter(manga) then
        table.insert(actions, { id = "open_first_unread", text = _("Open first unread") })
    end

    table.insert(actions, { id = "refresh_chapters", text = _("Refresh chapters") })
    if manga and manga.in_library == true then
        table.insert(actions, { id = "remove_from_library", text = _("Remove from library") })
    else
        table.insert(actions, { id = "add_to_library", text = _("Add to library") })
    end
    table.insert(actions, { id = "download_first_unread", text = _("Download first unread") })
    table.insert(actions, { id = "download_next_10_unread", text = _("Download next 10 unread") })
    table.insert(actions, { id = "more", text = _("More...") })

    return actions
end

function SuwayomiPlugin:showMangaActions(manga, options)
    options = options or {}
    if not SuwayomiUI.showMangaActionsMenu then
        return self:showChaptersForManga(manga)
    end

    return SuwayomiUI.showMangaActionsMenu({
        title = manga and (manga.title or tostring(manga.id)) or _("Manga actions"),
        actions = self:getMangaActions(manga),
    }, function(action)
        if action then
            self:performMangaAction(manga, action.id, options)
        end
    end)
end

function SuwayomiPlugin:updateMangaFromLibraryStateResponse(manga, updated_manga, in_library)
    if type(manga) ~= "table" then
        return
    end
    manga.in_library = in_library == true
    if type(updated_manga) == "table" then
        for key, value in pairs(updated_manga) do
            manga[key] = value
        end
        manga.in_library = updated_manga.in_library
        if manga.in_library == nil then
            manga.in_library = in_library == true
        end
    end
    if self.getClient then
        local client = self:getClient()
        if client and client.formatLibraryMangaRow then
            manga.menu_text = client:formatLibraryMangaRow(manga)
        end
    end
end

function SuwayomiPlugin:setMangaLibraryState(manga, in_library, options)
    options = options or {}
    if not manga or not manga.id then
        self:showMessage(_("This manga cannot be updated right now."))
        return false
    end

    local credentials = SuwayomiSettings:load()
    local loading_key = in_library and "add-manga-library" or "remove-manga-library"
    local loading_message = in_library and _("Adding to library...") or _("Removing from library...")
    local result = self:withLoadingMessage(loading_key, loading_message, function()
        return SuwayomiAPI.updateMangaLibraryState(credentials, manga.id, in_library)
    end)
    if not result then
        return false
    end
    if not result.ok then
        self:showMessage(_(result.error))
        return false
    end

    self:updateMangaFromLibraryStateResponse(manga, result.manga, in_library)
    if options.onMangaUpdated then
        options.onMangaUpdated(manga)
    end
    if in_library then
        self:showMessage(_("Added to library."))
    else
        self:showMessage(_("Removed from library."))
    end
    return true
end

function SuwayomiPlugin:addMangaToLibrary(manga, options)
    return self:setMangaLibraryState(manga, true, options)
end

function SuwayomiPlugin:confirmRemoveMangaFromLibrary(manga, options)
    options = options or {}
    if not manga or not manga.id then
        self:showMessage(_("This manga cannot be updated right now."))
        return false
    end

    local callback = function()
        self:setMangaLibraryState(manga, false, options)
    end
    if SuwayomiUI.showConfirm then
        SuwayomiUI.showConfirm({
            text = T(_("Remove %1 from your Suwayomi library?"), manga.title or tostring(manga.id)),
            ok_text = _("Remove"),
            ok_callback = callback,
            cancel_text = _("Cancel"),
        })
    else
        callback()
    end
    return true
end

function SuwayomiPlugin:refreshMangaChapters(manga)
    if not manga or not manga.id then
        self:showMessage(_("This manga cannot be refreshed right now."))
        return false
    end

    local credentials = SuwayomiSettings:load()
    local result = self:withLoadingMessage("refresh-manga", _("Refreshing chapters..."), function()
        return SuwayomiAPI.refreshManga(credentials, manga.id)
    end)
    if result and not result.ok then
        self:showMessage(_(result.error))
        return false
    end
    if result and type(result.manga) == "table" then
        for key, value in pairs(result.manga) do
            manga[key] = value
        end
    end
    if result and type(result.chapters) == "table" then
        return self:showChapterResultForManga(manga, result)
    end
    return self:showChaptersForManga(manga)
end

function SuwayomiPlugin:isCurrentChapterContextForManga(manga)
    if not self.current_chapter_context or not manga then
        return false
    end
    return self:getChapterSelectionKey(self.current_chapter_context.manga, {})
        == self:getChapterSelectionKey(manga, {})
end

function SuwayomiPlugin:setCurrentMangaChapterContext(manga, chapters)
    if self.current_chapter_context and not self:isCurrentChapterContextForManga(manga) then
        self:clearChapterSelection(true)
    end
    self.current_scanlator_filter = nil
    self.current_chapter_context = {
        manga = manga,
        chapters = chapters or {},
    }
    return self.current_chapter_context
end

function SuwayomiPlugin:ensureMangaChapterContext(manga)
    if self:isCurrentChapterContextForManga(manga)
        and self.current_chapter_context
        and #(self.current_chapter_context.chapters or {}) > 0
    then
        return self.current_chapter_context
    end

    if not manga or not manga.id then
        self:showMessage(_("This manga has no chapters loaded."))
        return nil
    end

    local result, refresh_attempted = self:refreshUninitializedMangaForChapters(manga)
    if not result and refresh_attempted then
        return nil
    end
    if not result and not refresh_attempted then
        local credentials = SuwayomiSettings:load()
        result = self:withLoadingMessage("chapters", _("Loading chapters..."), function()
            return SuwayomiAPI.fetchChaptersForManga(credentials, manga.id)
        end)
    end
    if not result then
        return nil
    end
    if not result.ok then
        self:showMessage(_(result.error))
        return nil
    end
    if not result.chapters or #result.chapters == 0 then
        self:showMessage(_("This manga has no chapters."))
        return nil
    end

    return self:setCurrentMangaChapterContext(manga, self:mergeChaptersWithReadLedger(manga, result.chapters))
end

function SuwayomiPlugin:getFirstUnreadChapterForManga(manga)
    local context = self:ensureMangaChapterContext(manga)
    if not context then
        return nil
    end

    for _, chapter in ipairs(context.chapters or {}) do
        if chapter.is_read ~= true then
            return chapter
        end
    end
    return nil
end

function SuwayomiPlugin:getUnreadChaptersForManga(manga)
    local context = self:ensureMangaChapterContext(manga)
    local chapters = {}
    if not context then
        return chapters
    end
    for _, chapter in ipairs(context.chapters or {}) do
        if chapter.is_read ~= true then
            table.insert(chapters, chapter)
        end
    end
    return chapters
end

function SuwayomiPlugin:getAllChaptersForManga(manga)
    local context = self:ensureMangaChapterContext(manga)
    if not context then
        return {}
    end
    return context.chapters or {}
end

function SuwayomiPlugin:showMoreMangaActions(manga, options)
    if not SuwayomiUI.showMangaActionsMenu then
        return false
    end
    return SuwayomiUI.showMangaActionsMenu({
        title = _("More..."),
        actions = {
            { id = "download_next_5_unread", text = _("Download next 5 unread") },
            { id = "download_next_50_unread", text = _("Download next 50 unread") },
            { id = "download_all_unread", text = _("Download all unread") },
            { id = "download_all_chapters", text = _("Download all chapters") },
            { id = "keep_downloaded", text = _("Keep downloaded") },
            { id = "delete_read_downloaded", text = _("Delete read downloads") },
        },
    }, function(action)
        if action then
            self:performMangaAction(manga, action.id, options)
        end
    end)
end

function SuwayomiPlugin:showKeepDownloadedMangaActions(manga, options)
    if not SuwayomiUI.showMangaActionsMenu then
        return false
    end
    return SuwayomiUI.showMangaActionsMenu({
        title = _("Keep downloaded"),
        actions = {
            { id = "keep_next_5_unread", text = _("Keep next 5 unread") },
            { id = "keep_next_10_unread", text = _("Keep next 10 unread") },
            { id = "keep_next_50_unread", text = _("Keep next 50 unread") },
            { id = "stop_keep_unread", text = _("Stop keeping unread") },
        },
    }, function(action)
        if action then
            self:performMangaAction(manga, action.id, options)
        end
    end)
end

function SuwayomiPlugin:performMangaAction(manga, action_id, options)
    options = options or {}
    if action_id == "open_chapters" then
        self:showChaptersForManga(manga)
        return true
    end
    if action_id == "open_first_unread" then
        local chapter = self:getFirstUnreadChapterForManga(manga)
            or (manga and manga.first_unread_chapter)
        if chapter then
            return self:openChapter(manga, chapter)
        end
        return false
    end
    if action_id == "refresh_chapters" then
        return self:refreshMangaChapters(manga)
    end
    if action_id == "add_to_library" then
        return self:addMangaToLibrary(manga, options)
    end
    if action_id == "remove_from_library" then
        return self:confirmRemoveMangaFromLibrary(manga, options)
    end
    if action_id == "more" then
        self:showMoreMangaActions(manga, options)
        return true
    end
    if action_id == "keep_downloaded" then
        self:showKeepDownloadedMangaActions(manga, options)
        return true
    end
    if action_id == "download_first_unread" then
        return self:downloadNextUnreadChaptersForManga(manga, 1, false)
    end
    local next_unread_count = tostring(action_id or ""):match("^download_next_(%d+)_unread$")
    if next_unread_count then
        local limit = tonumber(next_unread_count)
        return self:downloadNextUnreadChaptersForManga(manga, limit, limit >= 50)
    end
    if action_id == "download_all_unread" then
        return self:confirmDownloadAllUnreadChaptersForManga(manga)
    end
    if action_id == "download_all_chapters" then
        return self:confirmDownloadAllChaptersForManga(manga)
    end
    local keep_unread_count = tostring(action_id or ""):match("^keep_next_(%d+)_unread$")
    if keep_unread_count then
        return self:keepNextUnreadChaptersForManga(manga, tonumber(keep_unread_count))
    end
    if action_id == "stop_keep_unread" then
        SuwayomiSettings:saveKeepNextUnreadDownloads(0)
        self:showMessage(_("Stopped keeping unread chapters downloaded."))
        return true
    end
    if action_id == "delete_read_downloaded" then
        if self:ensureMangaChapterContext(manga) then
            self:confirmDeleteReadChaptersFromDevice()
        end
        return true
    end
    return false
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

function SuwayomiPlugin:addChapterSelectionMarker(menu_status)
    if menu_status and menu_status ~= "" then
        return "● " .. menu_status
    end
    return "●"
end

function SuwayomiPlugin:stripChapterSelectionStatus(menu_status)
    if not menu_status then
        return nil
    end
    local stripped = tostring(menu_status):gsub("^●%s*", "", 1)
    if stripped == "" then
        return nil
    end
    return stripped
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
    for _, chapter in ipairs(self:getVisibleChapters(chapters)) do
        if self:isChapterSelected(manga, chapter) then
            table.insert(selected, chapter)
        end
    end
    return selected
end

function SuwayomiPlugin:getChapterScanlator(chapter)
    local scanlator = chapter and chapter.scanlator
    if scanlator == nil then
        return nil
    end
    scanlator = tostring(scanlator)
    if scanlator == "" then
        return nil
    end
    return scanlator
end

function SuwayomiPlugin:getChapterScanlatorChoices(chapters)
    local choices = {}
    local seen = {}
    for _, chapter in ipairs(chapters or {}) do
        local scanlator = self:getChapterScanlator(chapter)
        if scanlator and not seen[scanlator] then
            seen[scanlator] = true
            table.insert(choices, scanlator)
        end
    end
    return choices
end

function SuwayomiPlugin:getVisibleChapters(chapters)
    if not self.current_scanlator_filter then
        return chapters or {}
    end

    local visible = {}
    for _, chapter in ipairs(chapters or {}) do
        if self:getChapterScanlator(chapter) == self.current_scanlator_filter then
            table.insert(visible, chapter)
        end
    end
    return visible
end

function SuwayomiPlugin:formatChapterListTitle(manga)
    local selected_count = self:getSelectedChapterCount()
    local title = manga.title
    if self.selection_mode then
        title = T(_("%1 selected"), selected_count)
    end
    if self.current_scanlator_filter then
        title = title .. " - " .. self.current_scanlator_filter
    end
    return title
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
    local chapters = self:getVisibleChapters(context and context.chapters or {})

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

function SuwayomiPlugin:markCurrentContextChapterReadFromLedger(entry)
    if not self.current_chapter_context or type(entry) ~= "table" or entry.read ~= true then
        return false
    end

    local context = self.current_chapter_context
    local manga = context.manga or {}
    if entry.manga_id and tostring(manga.id or "") ~= tostring(entry.manga_id) then
        return false
    end

    for _, chapter in ipairs(context.chapters or {}) do
        local same_id = entry.chapter_id and tostring(chapter.id or "") == tostring(entry.chapter_id)
        local same_name = entry.chapter_name and tostring(chapter.name or "") == tostring(entry.chapter_name)
        if same_id or same_name then
            chapter.is_read = true
            return true
        end
    end
    return false
end

function SuwayomiPlugin:getKeepNextUnreadDownloadsPolicyLimit()
    if not SuwayomiSettings.loadKeepNextUnreadDownloads then
        return 0
    end
    local limit = tonumber(SuwayomiSettings:loadKeepNextUnreadDownloads()) or 0
    if limit == 5 or limit == 10 or limit == 50 then
        return limit
    end
    return 0
end

function SuwayomiPlugin:applyKeepNextUnreadDownloadsPolicy()
    if not self.current_chapter_context then
        return 0
    end

    local limit = self:getKeepNextUnreadDownloadsPolicyLimit()
    if limit <= 0 then
        return 0
    end

    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getUnreadDownloadBufferCandidates(manga, limit)
    if #chapters == 0 then
        return 0
    end

    return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
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
                self:markCurrentContextChapterReadFromLedger(entry)
                self:autoDeleteReadLocalDownloadFromLedgerEntry(entry, ledger)
            end
        end
    end

    if changed then
        self:saveChapterLedger(ledger)
        self:applyKeepNextUnreadDownloadsPolicy()
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
            if item.is_read == true then
                local deleted = self:autoDeleteReadLocalDownload(manga, item, {
                    ledger = ledger,
                    skip_refresh = true,
                })
                if deleted then
                    chapter_exists = false
                end
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
        item.menu_text = item.name
        item.menu_status = self:getDownloadQueue():formatChapterMenuStatus(item, status)
        if self.selection_mode then
            if self:isChapterSelected(manga, item) then
                item.menu_status = self:addChapterSelectionMarker(item.menu_status)
            end
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
    local visible_chapters = self:getVisibleChapters(chapters)

    return {
        title = self:formatChapterListTitle(manga),
        chapters = self:buildChapterMenuItems(manga, visible_chapters, ledger),
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
            item.menu_text = item.name
            item.menu_status = self:getDownloadQueue():formatChapterMenuStatus(item, status)
        elseif cached and cached.menu_text then
            item.menu_text = self:stripChapterSelectionMarker(cached.menu_text)
            item.menu_status = self:stripChapterSelectionStatus(cached.menu_status)
        elseif item.is_read then
            item.menu_text = item.name
            item.menu_status = self:getDownloadQueue():formatChapterMenuStatus(item, { state = "read" })
        else
            item.menu_text = item.name
            item.menu_status = nil
        end

        if self.selection_mode then
            if self:isChapterSelected(manga, item) then
                item.menu_status = self:addChapterSelectionMarker(item.menu_status)
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
    local visible_chapters = self:getVisibleChapters(chapters)

    return {
        title = self:formatChapterListTitle(manga),
        chapters = self:buildQuickChapterMenuItems(manga, visible_chapters),
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
    else
        table.insert(actions, { id = "download", text = _("Download") })
    end

    if chapter.is_read == true then
        table.insert(actions, { id = "mark_unread", text = _("Mark as unread") })
    else
        table.insert(actions, { id = "mark_read", text = _("Mark as read") })
        table.insert(actions, { id = "mark_previous_read", text = _("Mark previous as read") })
        table.insert(actions, { id = "mark_through_read", text = _("Mark through here") })
    end
    if downloaded then
        table.insert(actions, { id = "delete", text = _("Delete from device") })
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
    local status = self:getDownloadQueue():getStatus(manga, chapter)
    if status and status.state == "downloading" then
        if not options.quiet_active then
            self:showMessage(_("This chapter is downloading. Wait for it to finish before deleting it."))
        end
        return false, "downloading"
    end

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

    local ledger = options.ledger or self:loadChapterLedger()
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
        if not options.ledger then
            self:saveChapterLedger(ledger)
        end
    end
    self:getDownloadQueue():clearStatus(manga, chapter, { quiet = true })

    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    return true, cancelled and "queued" or "deleted"
end

function SuwayomiPlugin:autoDeleteReadLocalDownload(manga, chapter, options)
    options = options or {}
    if self:getKeepNextUnreadDownloadsPolicyLimit() <= 0 then
        return false, "disabled"
    end
    if not chapter or (chapter.is_read ~= true and options.assume_read ~= true) then
        return false, "unread"
    end

    return self:deleteChapterFromDeviceWithOptions(manga, chapter, {
        ledger = options.ledger,
        quiet_active = true,
        quiet_missing = true,
        skip_refresh = options.skip_refresh ~= false,
    })
end

function SuwayomiPlugin:autoDeleteReadLocalDownloadFromLedgerEntry(entry, ledger)
    if self:getKeepNextUnreadDownloadsPolicyLimit() <= 0 then
        return false, "disabled"
    end
    if type(entry) ~= "table" or entry.read ~= true then
        return false, "unread"
    end
    local manga = {
        id = entry.manga_id,
        title = entry.manga_title,
    }
    local chapter = {
        id = entry.chapter_id,
        name = entry.chapter_name,
        is_read = true,
    }
    local status = self:getDownloadQueue():getStatus(manga, chapter)
    if status and status.state == "downloading" then
        return false, "downloading"
    end

    local cancelled, queue_state = self:getDownloadQueue():cancelPending(manga, chapter)
    if queue_state == "downloading" then
        return false, "downloading"
    end

    local chapter_path = entry.path
    if type(chapter_path) ~= "string" or chapter_path == "" then
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

    entry.path = nil
    self:getDownloadQueue():clearStatus(manga, chapter, { quiet = true })
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
    self:autoDeleteReadLocalDownload(manga, chapter, {
        assume_read = true,
        ledger = options.ledger,
        skip_refresh = true,
    })
    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    if not options.skip_schedule then
        self:schedulePendingReadSync()
    end
    if not options.skip_keep_policy then
        self:applyKeepNextUnreadDownloadsPolicy()
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
            skip_keep_policy = true,
        })
    end

    self:refreshChapterMenu({ ledger = ledger })
    self:saveChapterLedger(ledger)
    self:schedulePendingReadSync()
    self:applyKeepNextUnreadDownloadsPolicy()
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
        table.insert(actions, { id = "mark_read_selected", text = _("Mark read") })
        table.insert(actions, { id = "mark_unread_selected", text = _("Mark unread") })
        table.insert(actions, { id = "clear_selection", text = _("Clear selection") })
        table.insert(actions, { id = "delete_selected", text = _("Delete downloads") })
        if #(self:getChapterScanlatorChoices((self.current_chapter_context and self.current_chapter_context.chapters) or {})) > 0 then
            table.insert(actions, { id = "scanlator_filter", text = _("Scanlator filter") })
        end
        return actions
    end

    if self.current_chapter_context and #(self:getVisibleChapters(self.current_chapter_context.chapters or {})) > 0 then
        table.insert(actions, { id = "select_all", text = _("Select all") })
    end

    table.insert(actions, { id = "bulk_downloads", text = _("Bulk downloads") })
    table.insert(actions, { id = "delete_read_downloaded", text = _("Delete read downloads") })
    if #(self:getChapterScanlatorChoices((self.current_chapter_context and self.current_chapter_context.chapters) or {})) > 0 then
        table.insert(actions, { id = "scanlator_filter", text = _("Scanlator filter") })
    end

    return actions
end

function SuwayomiPlugin:getBulkDownloadActions()
    local actions = {}

    table.insert(actions, { id = "download_next_5_unread", text = _("Download 5 unread") })
    table.insert(actions, { id = "download_next_10_unread", text = _("Download 10 unread") })
    table.insert(actions, { id = "download_next_50_unread", text = _("Download 50 unread") })
    table.insert(actions, { id = "keep_next_5_unread", text = _("Keep 5 unread") })
    table.insert(actions, { id = "keep_next_10_unread", text = _("Keep 10 unread") })
    table.insert(actions, { id = "keep_next_50_unread", text = _("Keep 50 unread") })

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
    for _, chapter in ipairs(self:getVisibleChapters((self.current_chapter_context and self.current_chapter_context.chapters) or {})) do
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

    for _, chapter in ipairs(self:getVisibleChapters((self.current_chapter_context and self.current_chapter_context.chapters) or {})) do
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
    for _, chapter in ipairs(self:getVisibleChapters((self.current_chapter_context and self.current_chapter_context.chapters) or {})) do
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
        end, self:getDownloadDirectoryChooserStartDir())
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

function SuwayomiPlugin:getDownloadDirectoryOrChoose(callback)
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if download_directory and download_directory ~= "" then
        return download_directory
    end

    SuwayomiUI.showDirectoryChooser(function(path)
        local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
        self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
        callback(saved_path)
    end, self:getDownloadDirectoryChooserStartDir())
    return nil
end

function SuwayomiPlugin:downloadNextUnreadChaptersForManga(manga, limit, confirm)
    if not self:ensureMangaChapterContext(manga) then
        return false
    end

    local function queue(download_directory)
        local chapters = self:getNextUnreadChaptersForDownload(manga, limit)
        if #chapters == 0 then
            self:showMessage(_("No unread chapters available to download."))
            return 0
        end

        if confirm then
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

        return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
    end

    local download_directory = self:getDownloadDirectoryOrChoose(queue)
    if not download_directory then
        return true
    end
    queue(download_directory)
    return true
end

function SuwayomiPlugin:confirmDownloadAllUnreadChaptersForManga(manga)
    if not self:ensureMangaChapterContext(manga) then
        return false
    end

    local function queue(download_directory)
        local chapters = self:getUnreadChaptersForManga(manga)
        if #chapters == 0 then
            self:showMessage(_("No unread chapters available to download."))
            return 0
        end

        return self:showBulkActionConfirmation(
            T(
                self:pluralize(#chapters, _("Queue downloads for all %1 unread chapter?"), _("Queue downloads for all %1 unread chapters?")),
                #chapters
            ),
            _("Queue"),
            function()
                self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
            end
        )
    end

    local download_directory = self:getDownloadDirectoryOrChoose(queue)
    if not download_directory then
        return true
    end
    queue(download_directory)
    return true
end

function SuwayomiPlugin:confirmDownloadAllChaptersForManga(manga)
    if not self:ensureMangaChapterContext(manga) then
        return false
    end

    local function queue(download_directory)
        local chapters = self:getAllChaptersForManga(manga)
        if #chapters == 0 then
            self:showMessage(_("This manga has no chapters."))
            return 0
        end

        return self:showBulkActionConfirmation(
            T(
                self:pluralize(#chapters, _("Queue downloads for all %1 chapter?"), _("Queue downloads for all %1 chapters?")),
                #chapters
            ),
            _("Queue"),
            function()
                self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
            end
        )
    end

    local download_directory = self:getDownloadDirectoryOrChoose(queue)
    if not download_directory then
        return true
    end
    queue(download_directory)
    return true
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
        end, self:getDownloadDirectoryChooserStartDir())
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

function SuwayomiPlugin:keepNextUnreadChaptersForManga(manga, limit)
    if not self:ensureMangaChapterContext(manga) then
        return false
    end

    local requested_limit = tonumber(limit) or 0
    local saved_limit

    local function savePolicy()
        saved_limit = SuwayomiSettings:saveKeepNextUnreadDownloads(requested_limit)
        self:showMessage(T(_("Keep next unread downloaded: %1 chapters"), saved_limit))
        return saved_limit
    end

    if requested_limit <= 0 then
        savePolicy()
        return true
    end

    local function queue(download_directory)
        local chapters = self:getUnreadDownloadBufferCandidates(manga, requested_limit)
        if #chapters == 0 then
            savePolicy()
            self:showMessage(_("Next unread chapter buffer is already downloaded or queued."))
            return 0
        end

        if requested_limit >= 50 then
            return self:showBulkActionConfirmation(
                T(
                    self:pluralize(
                        #chapters,
                        _("Queue %1 missing download to keep the next %2 unread chapters available?"),
                        _("Queue %1 missing downloads to keep the next %2 unread chapters available?")
                    ),
                    #chapters,
                    requested_limit
                ),
                _("Queue"),
                function()
                    savePolicy()
                    self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
                end
            )
        end

        savePolicy()
        return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
    end

    local download_directory = self:getDownloadDirectoryOrChoose(queue)
    if not download_directory then
        return true
    end
    queue(download_directory)
    return true
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
        end, self:getDownloadDirectoryChooserStartDir())
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
        end, self:getDownloadDirectoryChooserStartDir())
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
        end, self:getDownloadDirectoryChooserStartDir())
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
            skip_keep_policy = true,
        })
    end

    self:clearChapterSelection(true)
    self:refreshChapterMenu({ ledger = ledger })
    self:saveChapterLedger(ledger)
    self:schedulePendingReadSync()
    self:applyKeepNextUnreadDownloadsPolicy()
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
    if action_id == "scanlator_filter" then
        self:showScanlatorFilterActions()
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

function SuwayomiPlugin:setScanlatorFilter(scanlator)
    self.current_scanlator_filter = scanlator
    self:clearChapterSelection(true)
    self:refreshChapterMenu()
    return true
end

function SuwayomiPlugin:getScanlatorFilterActions()
    local actions = {
        { id = "scanlator_filter_all", text = _("All scanlators") },
    }
    local context = self.current_chapter_context
    for _, scanlator in ipairs(self:getChapterScanlatorChoices(context and context.chapters or {})) do
        table.insert(actions, {
            id = "scanlator_filter_value",
            text = scanlator,
            scanlator = scanlator,
        })
    end
    return actions
end

function SuwayomiPlugin:showScanlatorFilterActions()
    if not SuwayomiUI.showChapterActionsMenu then
        return false
    end

    SuwayomiUI.showChapterActionsMenu({
        title = _("Scanlator filter"),
        actions = self:getScanlatorFilterActions(),
    }, function(action)
        if action.id == "scanlator_filter_all" then
            self:setScanlatorFilter(nil)
        else
            self:setScanlatorFilter(action.scanlator)
        end
    end)
    return true
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
    local title = _("Chapter downloads")
    if count > 0 then
        title = T(
            self:pluralize(count, _("%1 selected chapter"), _("%1 selected chapters")),
            count
        )
    end
    local options = {
        title = title,
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
    local ledger_entry = ledger[key]
    if not ledger_entry or ledger_entry.read == true then
        return false
    end

    ledger_entry.read = true
    ledger_entry.pending_read_sync = true
    ledger_entry.pending_read_state = true
    self:markCurrentContextChapterReadFromLedger(ledger_entry)
    self:autoDeleteReadLocalDownloadFromLedgerEntry(ledger_entry, ledger)
    self:saveChapterLedger(ledger)

    self:schedulePendingReadSync()
    self:applyKeepNextUnreadDownloadsPolicy()
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
        end, self:getDownloadDirectoryChooserStartDir())
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

function SuwayomiPlugin:buildSettingsMenu()
    return {
        {
            text = _("Connection"),
            sub_item_table = {
                {
                    text = _("Login information"),
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showLoginDialog(touchmenu_instance)
                    end,
                },
            },
        },
        {
            text = _("Library"),
            sub_item_table = {
                {
                    text_func = function()
                        return T(_("Category picker: %1"), self:getLibraryCategoryPickerBehaviorSummary())
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showLibrarySettings(touchmenu_instance)
                    end,
                },
            },
        },
        {
            text = _("Browse"),
            sub_item_table = {
                {
                    text_func = function()
                        return T(_("Source languages: %1"), self:getSourceLanguageSummary())
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showSourceLanguageDialog(touchmenu_instance)
                    end,
                },
            },
        },
        {
            text = _("Downloads"),
            sub_item_table = {
                {
                    text_func = function()
                        return T(_("Download directory: %1"), self:getDownloadDirectorySummary())
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showDownloadDirectoryDialog(touchmenu_instance)
                    end,
                },
                {
                    text_func = function()
                        return T(
                            _("Parallel downloads: %1"),
                            SuwayomiSettings:loadMaxParallelChapterDownloads()
                        )
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showParallelDownloadsDialog(touchmenu_instance)
                    end,
                },
                {
                    text_func = function()
                        return T(
                            _("Keep next unread downloaded: %1"),
                            self:getKeepNextUnreadDownloadsSummary()
                        )
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showKeepNextUnreadDownloadsDialog(touchmenu_instance)
                    end,
                },
            },
        },
    }
end

function SuwayomiPlugin:addToMainMenu(menu_items)
    menu_items.suwayomi_dl = {
        text = _("Suwayomi"),
        sorting_hint = "search",
        callback = function()
            self:showHome()
        end,
    }
end

return SuwayomiPlugin
