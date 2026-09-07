-- Boundary: HomeController.
--
-- Responsibility: Owns the plugin home dialog, main-menu entry, and generic KOReader message/loading helpers.
-- Owned state: Plugin UI state only; it does not own persisted settings or network state.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and the plugin i18n facade are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local SuwayomiUI = require("suwayomi/ui")
local I18n = require("suwayomi/i18n")

local HomeController = {}
HomeController.__index = HomeController
local READER_RETURN_MENU_ID = "suwayomi_reader_return"

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function HomeController:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function downloadFailureCount(self)
    local queue = self.getDownloadQueue and self:getDownloadQueue()
    return queue and queue.getFailedCount and queue:getFailedCount() or 0
end

local function downloadsActionText(failed_count)
    if failed_count > 0 then
        return I18n.count(failed_count, "Downloads · %1 failed", "Downloads · %1 failed")
    end
    return I18n.t("Downloads")
end

local function ensureReaderReturnMenuOrder()
    local ok, reader_menu_order = pcall(require, "ui/elements/reader_menu_order")
    local main_order = ok and reader_menu_order and reader_menu_order.main or nil
    if type(main_order) ~= "table" then
        return
    end
    for _, item_id in ipairs(main_order) do
        if item_id == READER_RETURN_MENU_ID then
            return
        end
    end
    table.insert(main_order, 1, READER_RETURN_MENU_ID)
end

function Methods:showNotImplemented(message)
    self:showMessage(message)
end


function Methods:showTopLevelScreen(route_id, callback)
    local widget = callback()
    if widget and self.trackSuwayomiScreen then
        self:trackSuwayomiScreen(route_id, widget)
    end
    return widget
end


function Methods:buildHomeActions(failed_count)
    failed_count = failed_count or downloadFailureCount(self)
    return {
        {
            id = "library",
            text = I18n.t("Library"),
            callback = function()
                return self:showTopLevelScreen("library", function()
                    return self:showLibrary()
                end)
            end,
        },
        {
            id = "browse",
            text = I18n.t("Browse"),
            callback = function()
                return self:showTopLevelScreen("browse", function()
                    return self:browseSuwayomi()
                end)
            end,
        },
        {
            id = "downloads",
            text = downloadsActionText(failed_count),
            callback = function()
                return self:showTopLevelScreen("downloads", function()
                    return self:showDownloads()
                end)
            end,
        },
        {
            id = "sync",
            text = I18n.t("Sync"),
            callback = function()
                self:syncReadStateNow()
            end,
        },
        {
            id = "settings",
            text = I18n.t("Settings"),
            callback = function()
                return self:showTopLevelScreen("settings", function()
                    return self:showSettings()
                end)
            end,
        },
        {
            id = "close",
            text = I18n.t("Close plugin"),
            close_before_select = false,
            callback = function()
                if self.closeSuwayomiPlugin then
                    self:closeSuwayomiPlugin()
                end
            end,
        },
    }
end


function Methods:showHome()
    local failed_count = downloadFailureCount(self)
    local dialog
    dialog = SuwayomiUI.showHomeDialog({
        actions = self:buildHomeActions(failed_count),
        onClose = function()
            if self.current_home_dialog == dialog then
                self.current_home_dialog = nil
                self.current_home_failed_count = nil
            end
            if self.suwayomi_navigation then
                self.suwayomi_navigation:pop(dialog)
            end
        end,
    }, function(action)
        if action and action.callback then
            action.callback()
        end
    end)
    self.current_home_dialog = dialog
    self.current_home_failed_count = failed_count
    if dialog and self.trackSuwayomiScreen then
        self:trackSuwayomiScreen("home", dialog)
    end
    return dialog
end


function Methods:refreshHomeDownloads()
    local dialog = self.current_home_dialog
    if not dialog or not SuwayomiUI.updateHomeDownloadsLabel then
        return false
    end
    if self.isSuwayomiScreenActive and not self:isSuwayomiScreenActive(dialog) then
        self.current_home_dialog = nil
        self.current_home_failed_count = nil
        return false
    end
    local failed_count = downloadFailureCount(self)
    if failed_count == self.current_home_failed_count then
        return false
    end
    if SuwayomiUI.updateHomeDownloadsLabel(dialog, downloadsActionText(failed_count)) == false then
        return false
    end
    self.current_home_failed_count = failed_count
    return true
end


function Methods:showLibrary()
    return self:getClient():showLibrary()
end


function Methods:closeMenu(menu)
    if menu and UIManager.close then
        UIManager:close(menu)
    end
end


function Methods:showMessage(message, options)
    options = options or {}
    UIManager:show(InfoMessage:new{
        text = message,
        timeout = options.timeout,
    })
end


function Methods:withLoadingMessage(key, message, callback)
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


function Methods:showLoadingMessage(message, cancel)
    local loading_message = InfoMessage:new{
        text = message,
        suwayomi_loading = true,
        dismiss_callback = cancel,
    }
    UIManager:show(loading_message)
    if UIManager.forceRePaint then
        UIManager:forceRePaint()
    end
    return loading_message
end


function Methods:closeLoadingMessage(loading_message)
    if loading_message and UIManager.close then
        UIManager:close(loading_message)
    end
end


function Methods:onSuwayomiAction()
    self:showNotImplemented(I18n.t("Open Search > Suwayomi to access the plugin menu."))
end


function Methods:addToMainMenu(menu_items)
    if self:isBookMode() then
        local context = self.getCurrentReaderReturnContext and self:getCurrentReaderReturnContext() or nil
        if context then
            ensureReaderReturnMenuOrder()
            menu_items[READER_RETURN_MENU_ID] = {
                text = I18n.t("Go to Suwayomi"),
                sorting_hint = "main",
                callback = function()
                    self:returnToSuwayomiChapters()
                end,
            }
        end
        return
    end

    menu_items.suwayomi = {
        text = I18n.t("Suwayomi"),
        sorting_hint = "search",
        callback = function(menu)
            self:closeMenu(menu)
            if self.needsOnboardingSetup and self:needsOnboardingSetup() then
                self:showOnboardingSetup({ first_run = true })
                return
            end
            self:showHome()
        end,
    }
end


HomeController.methods = Methods

return HomeController
