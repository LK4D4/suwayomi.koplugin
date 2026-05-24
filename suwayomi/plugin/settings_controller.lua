-- Boundary: SettingsController.
--
-- Responsibility: Owns settings menu orchestration and settings dialogs.
-- Owned state: Accepts persisted settings values and user-selected filesystem paths; values stay normalized through suwayomi/settings.lua.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and the plugin i18n facade are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local UIManager = require("ui/uimanager")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local OnboardingConnectionWorker = require("suwayomi/plugin/onboarding_connection_worker")
local SubprocessJob = require("suwayomi/subprocess/job")
local I18n = require("suwayomi/i18n")
local FFIUtil = require("ffi/util")

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

local function formatLibraryCategoryPickerBehavior(behavior)
    local labels = {
        automatic = I18n.t("Automatic"),
        always = I18n.t("Always ask"),
        never = I18n.t("Never ask"),
    }
    return labels[behavior] or tostring(behavior or "")
end

function Methods:showLibrarySettings(touchmenu_instance)
    return self:showLibraryCategoryPickerBehaviorDialog(touchmenu_instance)
end


function Methods:showSettings()
    if SuwayomiUI.showSettingsMenu then
        return SuwayomiUI.showSettingsMenu(self:buildSettingsMenu(), {
            title_bar_left_icon = "appbar.menu",
            on_title_bar_left_tap = function()
                if self.showHome then
                    self:showHome()
                end
                return true
            end,
        })
    end
    self:showMessage(I18n.t("Settings are unavailable."))
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
            SuwayomiSettings:save(credentials)
            self:refreshSettingsMenu(touchmenu_instance)
            UIManager:nextTick(function()
                self:showMessage(I18n.t("Suwayomi login settings saved."))
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
        self:showMessage(I18n.t("Connection test already running."))
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
        loading_message = self:showLoadingMessage(I18n.t("Testing Suwayomi connection...")),
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
            self:showMessage(I18n.t("Suwayomi connection test timed out."))
            if timed_out_active then
                timed_out_active.canceled = true
            end
        end,
        on_error = function(err)
            self.onboarding_connection_test_active = nil
            self:closeLoadingMessage(active.loading_message)
            if active.update_dialog then
                SuwayomiUI.updateOnboardingConnectionDialogStatus(self.onboarding_connection_dialog, "failed")
            end
            self:showMessage(I18n.f("Could not start connection test: %1", err or I18n.t("unknown error")))
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
        local message = result.message or I18n.t("Connection test passed.")
        if active and active.show_continue_message == false then
            self:showMessage(message)
        else
            self:showMessage(message .. " " .. I18n.t("You can continue."))
        end
        return
    end
    if active and active.update_dialog ~= false then
        SuwayomiUI.updateOnboardingConnectionDialogStatus(self.onboarding_connection_dialog, "failed")
    end
    self:showMessage((result and result.error) or I18n.t("Could not connect to Suwayomi."))
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
    self:showMessage(I18n.t("Suwayomi setup complete."))
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
                self:showMessage(I18n.t("Test connection before continuing."))
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
    return self:loadBrowseSettings()[key] and I18n.t("yes") or I18n.t("no")
end


function Methods:toggleBrowseSetting(key, touchmenu_instance)
    if not SuwayomiSettings.saveBrowseSettings then
        self:showMessage(I18n.t("Browse settings are unavailable."))
        return
    end
    local browse_settings = self:loadBrowseSettings()
    browse_settings[key] = not browse_settings[key]
    SuwayomiSettings:saveBrowseSettings(browse_settings)
    self:refreshSettingsMenu(touchmenu_instance)
end


function Methods:showDownloadDirectoryDialog(touchmenu_instance)
    self:chooseDownloadDirectory(function()
        self:refreshSettingsMenu(touchmenu_instance)
    end, {
        suppress_saved_message = true,
    })
end


function Methods:showParallelDownloadsDialog(touchmenu_instance)
    local choices = { 1, 2, 3, 4 }
    local function onSelect(value)
        local saved_value = SuwayomiSettings:saveMaxParallelChapterDownloads(value)
        if self.download_queue then
            self.download_queue.max_active_chapters = saved_value
            if self.download_queue.process then
                self.download_queue:process()
            end
        end
        self:refreshSettingsMenu(touchmenu_instance)
    end

    SuwayomiUI.showParallelDownloadsMenu({
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
        return settings.delete_after_mark_read and I18n.t("yes") or I18n.t("no")
    end
    if key == "delete_finished_while_reading" then
        return self:getDeleteFinishedWhileReadingLabel(settings.delete_finished_while_reading)
    end
    return ""
end

function Methods:getDeleteFinishedWhileReadingLabel(value)
    local labels = {
        [0] = I18n.t("Disabled"),
        [1] = I18n.t("Last read chapter"),
        [2] = I18n.t("Second to last read chapter"),
        [3] = I18n.t("Third to last read chapter"),
        [4] = I18n.t("Fourth to last read chapter"),
        [5] = I18n.t("Fifth to last read chapter"),
    }
    return labels[tonumber(value) or 0] or labels[0]
end

function Methods:toggleDeleteAfterMarkRead(touchmenu_instance)
    if not SuwayomiSettings.saveDeleteChaptersSettings then
        self:showMessage(I18n.t("Delete chapter settings are unavailable."))
        return
    end
    local settings = self:loadDeleteChaptersSettings()
    settings.delete_after_mark_read = not settings.delete_after_mark_read
    SuwayomiSettings:saveDeleteChaptersSettings(settings)
    self:refreshSettingsMenu(touchmenu_instance)
end

function Methods:showDeleteFinishedWhileReadingDialog(touchmenu_instance)
    if not SuwayomiSettings.saveDeleteChaptersSettings then
        self:showMessage(I18n.t("Delete chapter settings are unavailable."))
        return
    end

    local choices = { 0, 1, 2, 3, 4, 5 }
    local function onSelect(value)
        local settings = self:loadDeleteChaptersSettings()
        settings.delete_finished_while_reading = value
        SuwayomiSettings:saveDeleteChaptersSettings(settings)
        self:refreshSettingsMenu(touchmenu_instance)
    end

    SuwayomiUI.showDeleteFinishedWhileReadingMenu({
        current = self:loadDeleteChaptersSettings().delete_finished_while_reading,
        choices = choices,
        onSelect = onSelect,
    })
end


function Methods:getLibraryCategoryPickerBehaviorSummary()
    local behavior = "automatic"
    if SuwayomiSettings.loadLibraryCategoryPickerBehavior then
        behavior = SuwayomiSettings:loadLibraryCategoryPickerBehavior()
    end
    return formatLibraryCategoryPickerBehavior(behavior)
end


function Methods:showLibraryCategoryPickerBehaviorDialog(touchmenu_instance)
    if not SuwayomiSettings.loadLibraryCategoryPickerBehavior
        or not SuwayomiSettings.saveLibraryCategoryPickerBehavior
    then
        self:showMessage(I18n.t("Library category picker settings are unavailable."))
        return
    end

    local choices = { "automatic", "always", "never" }
    local function onSelect(behavior)
        SuwayomiSettings:saveLibraryCategoryPickerBehavior(behavior)
        self:refreshSettingsMenu(touchmenu_instance)
    end

    SuwayomiUI.showLibraryCategoryPickerBehaviorMenu({
        current = SuwayomiSettings:loadLibraryCategoryPickerBehavior(),
        choices = choices,
        onSelect = onSelect,
    })
end


function Methods:buildSettingsMenu()
    return {
        {
            text = I18n.t("Setup wizard"),
            keep_menu_open = true,
            callback = function()
                self:showOnboardingSetup({ first_run = false })
            end,
        },
        {
            text = I18n.t("Connection"),
            sub_item_table = {
                {
                    text = I18n.t("Login information"),
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showLoginDialog(touchmenu_instance)
                    end,
                },
                {
                    text = I18n.t("Test connection"),
                    keep_menu_open = true,
                    callback = function()
                        self:startSettingsConnectionTest()
                    end,
                },
            },
        },
        {
            text = I18n.t("Library"),
            sub_item_table = {
                {
                    text_func = function()
                        return I18n.f("Category picker: %1", self:getLibraryCategoryPickerBehaviorSummary())
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showLibrarySettings(touchmenu_instance)
                    end,
                },
            },
        },
        {
            text = I18n.t("Browse"),
            sub_item_table = {
                {
                    text_func = function()
                        return I18n.f("Show NSFW sources: %1", self:getBrowseSettingSummary("show_nsfw_sources"))
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:toggleBrowseSetting("show_nsfw_sources", touchmenu_instance)
                    end,
                },
                {
                    text_func = function()
                        return I18n.f(
                            "Hide in-library results: %1",
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
            text = I18n.t("Downloads"),
            sub_item_table = {
                {
                    text_func = function()
                        return I18n.f("Download directory: %1", self:getDownloadDirectorySummary())
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showDownloadDirectoryDialog(touchmenu_instance)
                    end,
                },
                {
                    text_func = function()
                        return I18n.f(
                            "Parallel downloads: %1",
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
                        return I18n.f(
                            "Delete after manual mark-read: %1",
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
                        return I18n.f(
                            "Delete while reading: %1",
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
