-- Boundary: SettingsController.
--
-- Responsibility: Owns settings menu orchestration and settings dialogs.
-- Owned state: Accepts persisted settings values and user-selected filesystem paths; values stay normalized through suwayomi/settings.lua.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and gettext are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local UIManager = require("ui/uimanager")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local SettingsController = {}
SettingsController.__index = SettingsController

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function SettingsController:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

function Methods:showLibrarySettings(touchmenu_instance)
    return self:showLibraryCategoryPickerBehaviorDialog(touchmenu_instance)
end


function Methods:showSettings()
    if SuwayomiUI.showSettingsMenu then
        return SuwayomiUI.showSettingsMenu(self:buildSettingsMenu())
    end
    self:showMessage(_("Settings are unavailable."))
end


function Methods:refreshSettingsMenu(touchmenu_instance)
    if touchmenu_instance and touchmenu_instance.updateItems then
        touchmenu_instance:updateItems()
    end
end


function Methods:showLoginDialog(touchmenu_instance)
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


function Methods:loadBrowseSettings()
    if SuwayomiSettings.loadBrowseSettings then
        return SuwayomiSettings:loadBrowseSettings()
    end
    return {
        show_nsfw_sources = false,
        hide_in_library_results = false,
    }
end


function Methods:getBrowseSettingSummary(key)
    return self:loadBrowseSettings()[key] and _("yes") or _("no")
end


function Methods:toggleBrowseSetting(key, touchmenu_instance)
    if not SuwayomiSettings.saveBrowseSettings then
        self:showMessage(_("Browse settings are unavailable."))
        return
    end
    local browse_settings = self:loadBrowseSettings()
    browse_settings[key] = not browse_settings[key]
    SuwayomiSettings:saveBrowseSettings(browse_settings)
    self:refreshSettingsMenu(touchmenu_instance)
    self:showMessage(_("Suwayomi Browse setting saved."))
end


function Methods:showDownloadDirectoryDialog(touchmenu_instance)
    self:chooseDownloadDirectory(function()
        self:refreshSettingsMenu(touchmenu_instance)
    end)
end


function Methods:showParallelDownloadsDialog(touchmenu_instance)
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


function Methods:getKeepNextUnreadDownloadsSummary()
    local value = SuwayomiSettings:loadKeepNextUnreadDownloads()
    if value == 0 then
        return _("off")
    end
    return T(self:pluralize(value, _("%1 chapter"), _("%1 chapters")), value)
end


function Methods:showKeepNextUnreadDownloadsDialog(touchmenu_instance)
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


function Methods:getLibraryCategoryPickerBehaviorSummary()
    if SuwayomiSettings.loadLibraryCategoryPickerBehavior then
        return SuwayomiSettings:loadLibraryCategoryPickerBehavior()
    end
    return "automatic"
end


function Methods:showLibraryCategoryPickerBehaviorDialog(touchmenu_instance)
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


function Methods:buildSettingsMenu()
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
                        return T(_("Show NSFW sources: %1"), self:getBrowseSettingSummary("show_nsfw_sources"))
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:toggleBrowseSetting("show_nsfw_sources", touchmenu_instance)
                    end,
                },
                {
                    text_func = function()
                        return T(
                            _("Hide in-library results: %1"),
                            self:getBrowseSettingSummary("hide_in_library_results")
                        )
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:toggleBrowseSetting("hide_in_library_results", touchmenu_instance)
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


SettingsController.methods = Methods

return SettingsController
