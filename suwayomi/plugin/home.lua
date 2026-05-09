--[[
HomeController
Responsibility: Owns the plugin home dialog, main-menu entry, and generic KOReader message/loading helpers.
Owned state: Plugin UI state only; it does not own persisted settings or network state.
Dependencies: KOReader UI helpers, Suwayomi runtime modules, and gettext are required at module load to match the original plugin runtime.
External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local SuwayomiAPI = require("suwayomi/api")
local SuwayomiReadSyncWorker = require("suwayomi/readsync/worker")
local SuwayomiSourceFetchWorker = require("suwayomi/browse/source_fetch_worker")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local SuwayomiDebug = require("suwayomi/debug")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local HomeController = {}
HomeController.__index = HomeController

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function HomeController:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

function Methods:showNotImplemented(message)
    self:showMessage(message)
end


function Methods:getHomeMenuOptions()
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


function Methods:buildHomeActions()
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


function Methods:showHome()
    return SuwayomiUI.showHomeDialog({
        actions = self:buildHomeActions(),
    }, function(action)
        if action and action.callback then
            action.callback()
        end
    end)
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


function Methods:showLoadingMessage(message)
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


function Methods:closeLoadingMessage(loading_message)
    if loading_message and UIManager.close then
        UIManager:close(loading_message)
    end
end


function Methods:onSuwayomiAction()
    self:showNotImplemented(_("Open Search > Suwayomi to access the plugin menu."))
end


function Methods:addToMainMenu(menu_items)
    menu_items.suwayomi_dl = {
        text = _("Suwayomi"),
        sorting_hint = "search",
        callback = function()
            self:showHome()
        end,
    }
end


HomeController.methods = Methods

return HomeController
