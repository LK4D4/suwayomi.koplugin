-- Boundary: KOReader plugin lifecycle and composition shell.
--
-- Responsibility: register KOReader actions, compose controller method tables,
-- and attach disposable hosts to the process-owned download service.
-- Owned state: plugin instance fields only.
-- Dependencies: KOReader runtime modules and plugin-local suwayomi/* modules.
-- External data: delegated to focused controllers and services.

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local SuwayomiAPI = require("suwayomi/api")
local SuwayomiClient = require("suwayomi/client")
local DownloadService = require("suwayomi/downloads/service")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local SuwayomiNavigation = require("suwayomi/navigation")
local SuwayomiDebug = require("suwayomi/debug")
local HomeController = require("suwayomi/plugin/home")
local TitleMenuController = require("suwayomi/plugin/title_menu")
local SettingsController = require("suwayomi/plugin/settings_controller")
local ReaderReturn = require("suwayomi/reader_return")
local BrowseController = require("suwayomi/browse/controller")
local DownloadsDirectory = require("suwayomi/downloads/directory")
local MangaController = require("suwayomi/manga/controller")
local ChapterContext = require("suwayomi/chapters/context")
local ChapterMenu = require("suwayomi/chapters/menu")
local ChapterActions = require("suwayomi/chapters/actions")
local FinishedChapterCleanup = require("suwayomi/chapters/finished_cleanup")
local DownloadsController = require("suwayomi/downloads/controller")
local ReadSyncLedger = require("suwayomi/readsync/ledger")
local KoreaderMetadata = require("suwayomi/readsync/koreader_metadata")
local ReadSyncController = require("suwayomi/readsync/controller")
local I18n = require("suwayomi/i18n")

local SuwayomiPlugin = WidgetContainer:extend{
    name = "suwayomi",
    is_doc_only = false,
    selection_mode = false,
    max_batch_queue_chapters = 50,
    read_sync_batch_size = 50,
    read_sync_delay_seconds = 0.5,
    read_sync_poll_interval_seconds = 0.5,
    read_sync_failure_delay_seconds = 5,
    read_sync_max_failure_delay_seconds = 300,
    read_sync_watchdog_timeout_seconds = 60,
    finished_cleanup_retry_delay_seconds = 5,
    finished_cleanup_max_retry_delay_seconds = 300,
    finished_cleanup_batch_size = 25,
    source_fetch_poll_interval_seconds = 0.5,
    source_cache_refresh_delay_seconds = 0.1,
    source_fetch_watchdog_timeout_seconds = 60,
    global_search_poll_interval_seconds = 0.5,
    global_search_source_timeout_seconds = 15,
    global_search_max_active_sources = 3,
    source_manga_poll_interval_seconds = 0.5,
    source_manga_timeout_seconds = 15,
}

function SuwayomiPlugin:createDownloadQueue()
    return DownloadService.get():getQueue()
end

function SuwayomiPlugin:getDownloadQueue()
    return self:createDownloadQueue()
end

function SuwayomiPlugin:onDownloadSnapshot(snapshot, message, full_refresh, changed_mangas)
    if self.download_host_closed then return end
    self.download_snapshot = snapshot
    if message then self:showMessage(message) end
    if self.chapter_menu_refresh_suppressed and self.chapter_menu_refresh_suppressed > 0 then
        self.pending_chapter_menu_refresh = true
        return
    end
    local navigation = self.suwayomi_navigation
    if not navigation then return end
    for _, field in ipairs({ "current_chapter_menu", "current_downloads_menu", "current_home_dialog" }) do
        if self[field] and not navigation:contains(self[field]) then self[field] = nil end
    end
    if navigation:isCurrent(self.current_chapter_menu) then
        local context = self.current_chapter_context
        local affected = changed_mangas and context and context.manga and changed_mangas[tostring(context.manga.id)]
        self:refreshChapterMenu((full_refresh or affected) and {} or { quick = true })
    end
    if navigation:isCurrent(self.current_downloads_menu) then self:refreshDownloadsMenu() end
    if navigation:isCurrent(self.current_home_dialog) then self:refreshHomeDownloads() end
end

function SuwayomiPlugin:createClient()
    return SuwayomiClient:new{
        api = SuwayomiAPI,
        ui = SuwayomiUI,
        settings = SuwayomiSettings,
        debug = SuwayomiDebug,
        plugin = self,
        gettext = I18n.t,
    }
end

function SuwayomiPlugin:getClient()
    if not self.client then
        self.client = self:createClient()
    end
    return self.client
end

function SuwayomiPlugin:getNavigation()
    if not self.suwayomi_navigation then
        self.suwayomi_navigation = SuwayomiNavigation.new(UIManager, function()
            DownloadService.get():notify(nil, true)
        end)
    end
    return self.suwayomi_navigation
end

function SuwayomiPlugin:trackSuwayomiScreen(route_id, widget, options)
    if widget == nil then
        return nil
    end
    return self:getNavigation():push(route_id, widget, options)
end

function SuwayomiPlugin:replaceSuwayomiBranch(route_id, widget, options)
    if widget == nil then
        return nil
    end
    return self:getNavigation():replaceBranch(route_id, widget, options)
end

function SuwayomiPlugin:isSuwayomiScreenActive(widget)
    if not self.suwayomi_navigation then
        return false
    end
    return self.suwayomi_navigation:contains(widget)
end

function SuwayomiPlugin:closeSuwayomiPlugin()
    self.suwayomi_plugin_closing = true
    local ok, err = pcall(function()
        if self.cancelReaderReturnRequest then
            self:cancelReaderReturnRequest()
        end
        if self.cancelMangaNetworkRequests then
            self:cancelMangaNetworkRequests()
        end
        if self.client and self.client.cancelLibraryNetworkRequests then
            self.client:cancelLibraryNetworkRequests()
        end
        if self.cancelSourceFetchWorker then
            self:cancelSourceFetchWorker()
        end
        if self.cancelExtensionWorker then
            self:cancelExtensionWorker()
        end
        if self.cancelPendingReadSync then
            self:cancelPendingReadSync({ close = true })
        end
        if self.suwayomi_navigation then
            self.suwayomi_navigation:closeAll()
        end
        self.current_sources_menu = nil
        self.current_chapter_menu = nil
    end)
    self.suwayomi_plugin_closing = nil
    if not ok then
        error(err)
    end
end

function SuwayomiPlugin:onCloseWidget()
    self:retireChapterHost()
    self:cancelSourceFetchWorker()
    self.download_host_closed = true
    if self.detach_download_subscription then self.detach_download_subscription() end
    self.detach_download_subscription = nil
    self.download_snapshot = nil
end

function SuwayomiPlugin:withChapterMenuRefreshSuppressed(callback)
    self.chapter_menu_refresh_suppressed = (self.chapter_menu_refresh_suppressed or 0) + 1
    local ok, result = pcall(callback)
    self.chapter_menu_refresh_suppressed = (self.chapter_menu_refresh_suppressed or 1) - 1
    local should_refresh_chapters = false
    if self.chapter_menu_refresh_suppressed <= 0 then
        self.chapter_menu_refresh_suppressed = nil
        should_refresh_chapters = ok and self.pending_chapter_menu_refresh == true
        if should_refresh_chapters then
            self.pending_chapter_menu_refresh = nil
        end
    end
    if not ok then
        error(result)
    end
    if should_refresh_chapters then
        self:refreshChapterMenu({ quick = true })
        if self.refreshDownloadsMenu then
            self:refreshDownloadsMenu()
        end
        if self.refreshHomeDownloads then
            self:refreshHomeDownloads()
        end
    end
    return result
end

function SuwayomiPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("suwayomi_action", {
        category = "none",
        event = "SuwayomiAction",
        title = I18n.t("Suwayomi"),
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
    local service = DownloadService.get()
    if not self.detach_download_subscription and not self.download_host_closed then
        self.detach_download_subscription = service:subscribe(function(snapshot, message, full_refresh, changed_mangas)
            self:onDownloadSnapshot(snapshot, message, full_refresh, changed_mangas)
        end)
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    SuwayomiDebug.log({ operation = "plugin_init", event = "end" })
end


local CONTROLLER_MODULES = {
    HomeController,
    TitleMenuController,
    SettingsController,
    ReaderReturn,
    BrowseController,
    DownloadsDirectory,
    MangaController,
    ChapterContext,
    ChapterMenu,
    ChapterActions,
    FinishedChapterCleanup,
    DownloadsController,
    ReadSyncLedger,
    KoreaderMetadata,
    ReadSyncController,
}

-- Method installation keeps KOReader callback names stable while moving feature logic into documented modules.
local function installControllerMethods(target, controller_module)
    for name, method in pairs(controller_module.methods or {}) do
        target[name] = method
    end
end

for _, controller_module in ipairs(CONTROLLER_MODULES) do
    installControllerMethods(SuwayomiPlugin, controller_module)
end

-- The policy remains shared with focused controller tests; production calls use
-- one adapter so its timers never retain a retired FileManager or ReaderUI.
for name in pairs(FinishedChapterCleanup.methods) do
    SuwayomiPlugin[name] = function(_, ...)
        local service = DownloadService.get()
        return service.cleanup[name](service.cleanup, ...)
    end
end

return SuwayomiPlugin
