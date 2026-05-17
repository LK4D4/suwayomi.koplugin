-- Boundary: SettingsController.
--
-- Responsibility: Owns settings menu orchestration and settings dialogs.
-- Owned state: Accepts persisted settings values and user-selected filesystem paths; values stay normalized through suwayomi/settings.lua.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and gettext are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local UIManager = require("ui/uimanager")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local OnboardingConnectionWorker = require("suwayomi/plugin/onboarding_connection_worker")
local SubprocessJob = require("suwayomi/subprocess/job")
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


function Methods:getOnboardingCredentialsKey(credentials)
    credentials = credentials or {}
    return table.concat({
        tostring(credentials.server_url or ""),
        tostring(credentials.username or ""),
        tostring(credentials.password or ""),
        tostring(credentials.auth_method or "basic_auth"),
    }, "\n")
end


function Methods:hasOnboardingConnectionTestPassed(credentials)
    return self.onboarding_connection_test_key ~= nil
        and self.onboarding_connection_test_key == self:getOnboardingCredentialsKey(credentials)
end


function Methods:clearOnboardingConnectionTest()
    self.onboarding_connection_test_key = nil
    local active = self.onboarding_connection_test_active
    if not active then
        return
    end
    self.onboarding_connection_test_active = nil
    SubprocessJob.cancel(active)
    self:closeLoadingMessage(active.loading_message)
end


function Methods:needsOnboardingSetup()
    local credentials = SuwayomiSettings:load()
    if not credentials.server_url or credentials.server_url == "" then
        return true
    end
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    return not download_directory or download_directory == ""
end


function Methods:getOnboardingConnectionResultPath()
    return SubprocessJob.buildResultPath("onboarding_connection")
end


function Methods:startOnboardingConnectionTest(credentials, options)
    options = options or {}
    if self.onboarding_connection_test_active then
        self:showMessage(_("Connection test already running."))
        return false
    end

    self.onboarding_connection_test_key = nil
    local update_dialog = options.update_dialog ~= false
    if update_dialog then
        SuwayomiUI.updateOnboardingConnectionDialogStatus(self.onboarding_connection_dialog, "testing")
    end
    local active = {
        credentials = credentials,
        result_path = self:getOnboardingConnectionResultPath(),
        loading_message = self:showLoadingMessage(_("Testing Suwayomi connection...")),
        show_continue_message = options.show_continue_message ~= false,
        update_dialog = update_dialog,
    }
    active = SubprocessJob.start({
        active = active,
        ffi_util = FFIUtil,
        ui_manager = UIManager,
        poll_interval_seconds = self.onboarding_connection_poll_interval_seconds or 0.5,
        timeout_seconds = self.onboarding_connection_timeout_seconds or 25,
        run = function(path)
            OnboardingConnectionWorker:run(credentials, path)
        end,
        read_result = function(path)
            return OnboardingConnectionWorker:readResult(path)
        end,
        on_finish = function(finished_active, result)
            self:finishOnboardingConnectionTest(finished_active, result)
        end,
        on_timeout = function(timed_out_active)
            self.onboarding_connection_test_active = nil
            self:closeLoadingMessage(timed_out_active and timed_out_active.loading_message)
            if timed_out_active and timed_out_active.update_dialog ~= false then
                SuwayomiUI.updateOnboardingConnectionDialogStatus(self.onboarding_connection_dialog, "failed")
            end
            self:showMessage(_("Suwayomi connection test timed out."))
            if timed_out_active then
                timed_out_active.canceled = true
                SubprocessJob.cleanup(timed_out_active)
            end
        end,
        on_error = function(err)
            self.onboarding_connection_test_active = nil
            self:closeLoadingMessage(active.loading_message)
            if active.update_dialog then
                SuwayomiUI.updateOnboardingConnectionDialogStatus(self.onboarding_connection_dialog, "failed")
            end
            self:showMessage(T(_("Could not start connection test: %1"), err or _("unknown error")))
        end,
    })
    self.onboarding_connection_test_active = active and not active.cleaned and active or nil
    return active ~= nil
end


function Methods:finishOnboardingConnectionTest(active, result)
    if active and active.canceled then
        return
    end
    self.onboarding_connection_test_active = nil
    self:closeLoadingMessage(active and active.loading_message)
    if result and result.ok == true then
        self.onboarding_connection_test_key = self:getOnboardingCredentialsKey(active and active.credentials)
        if active and active.update_dialog ~= false then
            SuwayomiUI.updateOnboardingConnectionDialogStatus(self.onboarding_connection_dialog, "passed")
        end
        local message = result.message or _("Connection test passed.")
        if active and active.show_continue_message == false then
            self:showMessage(message)
        else
            self:showMessage(message .. " " .. _("You can continue."))
        end
        return
    end
    if active and active.update_dialog ~= false then
        SuwayomiUI.updateOnboardingConnectionDialogStatus(self.onboarding_connection_dialog, "failed")
    end
    self:showMessage((result and result.error) or _("Could not connect to Suwayomi."))
end


function Methods:startSettingsConnectionTest()
    return self:startOnboardingConnectionTest(SuwayomiSettings:load(), {
        show_continue_message = false,
        update_dialog = false,
    })
end


function Methods:pollOnboardingConnectionTest()
    SubprocessJob.poll(self.onboarding_connection_test_active)
end


function Methods:getOnboardingDialogCredentials()
    local credentials = SuwayomiSettings:load()
    if not credentials.server_url or credentials.server_url == "" then
        credentials.server_url = "https://"
    end
    return credentials
end


function Methods:finishOnboardingSetup()
    if self.showHome then
        UIManager:nextTick(function()
            if self.closeSuwayomiPlugin then
                self:closeSuwayomiPlugin()
            end
            self:showHome()
        end)
        return
    end
    self:showMessage(_("Suwayomi setup complete."))
end


function Methods:showOnboardingDirectoryStep()
    self:chooseDownloadDirectory(function()
        self:finishOnboardingSetup()
    end, {
        next_tick = true,
        suppress_saved_message = true,
    })
end


function Methods:showOnboardingConnectionStep(options)
    options = options or {}
    self:clearOnboardingConnectionTest()
    self.onboarding_connection_dialog = SuwayomiUI.showOnboardingConnectionDialog({
        credentials = self:getOnboardingDialogCredentials(),
        connection_status = "untested",
        onTestConnection = function(credentials)
            self:startOnboardingConnectionTest(credentials)
        end,
        onClose = function()
            self:clearOnboardingConnectionTest()
            self.onboarding_connection_dialog = nil
        end,
        canContinue = function(credentials)
            return self:hasOnboardingConnectionTestPassed(credentials)
        end,
        onContinue = function(credentials)
            if not self:hasOnboardingConnectionTestPassed(credentials) then
                SuwayomiUI.updateOnboardingConnectionDialogStatus(self.onboarding_connection_dialog, "untested")
                self:showMessage(_("Test connection before continuing."))
                return false
            end

            SuwayomiSettings:save(credentials)
            local download_directory = SuwayomiSettings:loadDownloadDirectory()
            local should_choose_directory = options.first_run == false
                or not download_directory
                or download_directory == ""
            if should_choose_directory then
                UIManager:nextTick(function()
                    self:showOnboardingDirectoryStep(options)
                end)
            else
                UIManager:nextTick(function()
                    self:finishOnboardingSetup()
                end)
            end
            return true
        end,
    })
    return self.onboarding_connection_dialog
end


function Methods:showOnboardingSetup(options)
    options = options or {}
    local credentials = SuwayomiSettings:load()
    if options.first_run == false then
        return self:showOnboardingConnectionStep(options)
    end
    if not credentials.server_url or credentials.server_url == "" then
        return self:showOnboardingConnectionStep(options)
    end
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        return self:showOnboardingDirectoryStep(options)
    end
    self:finishOnboardingSetup()
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
        if self.download_queue then
            self.download_queue.max_active_chapters = saved_value
            if self.download_queue.process then
                self.download_queue:process()
            end
        end
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

function Methods:loadDeleteChaptersSettings()
    if SuwayomiSettings.loadDeleteChaptersSettings then
        return SuwayomiSettings:loadDeleteChaptersSettings()
    end
    return {
        delete_after_mark_read = false,
        delete_finished_while_reading = 0,
    }
end

function Methods:getDeleteChaptersSettingSummary(key)
    local settings = self:loadDeleteChaptersSettings()
    if key == "delete_after_mark_read" then
        return settings.delete_after_mark_read and _("yes") or _("no")
    end
    if key == "delete_finished_while_reading" then
        return self:getDeleteFinishedWhileReadingLabel(settings.delete_finished_while_reading)
    end
    return ""
end

function Methods:getDeleteFinishedWhileReadingLabel(value)
    local labels = {
        [0] = _("Disabled"),
        [1] = _("Last read chapter"),
        [2] = _("Second to last read chapter"),
        [3] = _("Third to last read chapter"),
        [4] = _("Fourth to last read chapter"),
        [5] = _("Fifth to last read chapter"),
    }
    return labels[tonumber(value) or 0] or labels[0]
end

function Methods:toggleDeleteAfterMarkRead(touchmenu_instance)
    if not SuwayomiSettings.saveDeleteChaptersSettings then
        self:showMessage(_("Delete chapter settings are unavailable."))
        return
    end
    local settings = self:loadDeleteChaptersSettings()
    settings.delete_after_mark_read = not settings.delete_after_mark_read
    SuwayomiSettings:saveDeleteChaptersSettings(settings)
    self:refreshSettingsMenu(touchmenu_instance)
    self:showMessage(_("Suwayomi delete chapter setting saved."))
end

function Methods:showDeleteFinishedWhileReadingDialog(touchmenu_instance)
    if not SuwayomiSettings.saveDeleteChaptersSettings then
        self:showMessage(_("Delete chapter settings are unavailable."))
        return
    end

    local delete_menu
    local choices = { 0, 1, 2, 3, 4, 5 }
    local function onSelect(value)
        local settings = self:loadDeleteChaptersSettings()
        settings.delete_finished_while_reading = value
        local saved_settings = SuwayomiSettings:saveDeleteChaptersSettings(settings)
        self:refreshSettingsMenu(touchmenu_instance)
        self:showMessage(T(
            _("Suwayomi delete-while-reading setting saved: %1"),
            self:getDeleteFinishedWhileReadingLabel(saved_settings.delete_finished_while_reading)
        ))
        if SuwayomiUI.updateDeleteFinishedWhileReadingMenu then
            SuwayomiUI.updateDeleteFinishedWhileReadingMenu(delete_menu, {
                current = saved_settings.delete_finished_while_reading,
                choices = choices,
                onSelect = onSelect,
            })
        end
    end

    delete_menu = SuwayomiUI.showDeleteFinishedWhileReadingMenu({
        current = self:loadDeleteChaptersSettings().delete_finished_while_reading,
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
            text = _("Setup wizard"),
            keep_menu_open = true,
            callback = function()
                self:showOnboardingSetup({ first_run = false })
            end,
        },
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
                {
                    text = _("Test connection"),
                    keep_menu_open = true,
                    callback = function()
                        self:startSettingsConnectionTest()
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
                            _("Delete after manual mark-read: %1"),
                            self:getDeleteChaptersSettingSummary("delete_after_mark_read")
                        )
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:toggleDeleteAfterMarkRead(touchmenu_instance)
                    end,
                },
                {
                    text_func = function()
                        return T(
                            _("Delete while reading: %1"),
                            self:getDeleteChaptersSettingSummary("delete_finished_while_reading")
                        )
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showDeleteFinishedWhileReadingDialog(touchmenu_instance)
                    end,
                },
            },
        },
    }
end


SettingsController.methods = Methods

return SettingsController
