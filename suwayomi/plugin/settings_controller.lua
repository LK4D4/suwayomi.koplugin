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
local RetentionLabels = require("suwayomi/settings/retention_labels")

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

local ONBOARDING_RESULT_MESSAGES = {
    connection_test_passed = "Connection test passed.",
    connection_test_passed_after_retry = "Connection test passed after retry.",
}

local ONBOARDING_RESULT_ERRORS = {
    missing_server_url = "Enter a Suwayomi server URL first.",
    could_not_connect = "Could not connect to Suwayomi.",
}

local function externalErrorMessage(error_message)
    if type(error_message) ~= "string" or error_message:match("^%s*$") then
        return nil
    end
    return error_message
end

local function translateResultMessage(result)
    local message_id = result and result.message_id
    local msgid = message_id and ONBOARDING_RESULT_MESSAGES[message_id]
    if msgid then
        return I18n.t(msgid)
    end
    return (result and result.message) or I18n.t("Connection test passed.")
end

local function translateResultError(result)
    local external_error = result and externalErrorMessage(result.error)
    if external_error then
        return external_error
    end
    local error_id = result and result.error_id
    local msgid = error_id and ONBOARDING_RESULT_ERRORS[error_id]
    if msgid then
        return I18n.t(msgid)
    end
    return I18n.t("Could not connect to Suwayomi.")
end

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
            local saved, err = SuwayomiSettings:save(credentials)
            if not saved then
                self:showMessage(err or I18n.t("Failed to save settings."))
                return
            end
            self:getDownloadQueue().refill:wake()
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
        local message = translateResultMessage(result)
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
    self:showMessage(translateResultError(result))
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
        onAuthMethodChanged = function()
            self.onboarding_connection_test_key = nil
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

            local saved, err = SuwayomiSettings:save(credentials)
            if not saved then
                self:showMessage(err or I18n.t("Failed to save settings."))
                return false
            end
            self:getDownloadQueue().refill:wake()
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
    local saved, err = SuwayomiSettings:saveBrowseSettings(browse_settings)
    if not saved then
        self:showMessage(err or I18n.t("Failed to save settings."))
        return
    end
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
        local saved_value, err = SuwayomiSettings:saveMaxParallelChapterDownloads(value)
        if not saved_value then
            self:showMessage(err or I18n.t("Failed to save settings."))
            return
        end
        local queue = self.getDownloadQueue and self:getDownloadQueue() or self.download_queue
        if queue then
            queue.max_active_chapters = saved_value
            if queue.process then
                queue:process()
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
    return RetentionLabels.format(value)
end

function Methods:toggleDeleteAfterMarkRead(touchmenu_instance)
    if not SuwayomiSettings.saveDeleteChaptersSettings then
        self:showMessage(I18n.t("Delete chapter settings are unavailable."))
        return
    end
    local settings = self:loadDeleteChaptersSettings()
    settings.delete_after_mark_read = not settings.delete_after_mark_read
    local saved, err = SuwayomiSettings:saveDeleteChaptersSettings(settings)
    if not saved then
        self:showMessage(err or I18n.t("Failed to save settings."))
        return
    end
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
        local previous_value = settings.delete_finished_while_reading
        settings.delete_finished_while_reading = value
        local saved, err = SuwayomiSettings:saveDeleteChaptersSettings(settings)
        if not saved then
            self:showMessage(err or I18n.t("Failed to save settings."))
            return
        end
        if previous_value ~= value and self.onFinishedCleanupSettingChanged then
            self:onFinishedCleanupSettingChanged(previous_value, value)
        end
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
        local saved, err = SuwayomiSettings:saveLibraryCategoryPickerBehavior(behavior)
        if not saved then
            self:showMessage(err or I18n.t("Failed to save settings."))
            return
        end
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
                    help_text = I18n.t("New manual mark-read actions may remove only the local archive. Busy downloads keep running; request deletion again after they finish. Accepted removal continues with this setting Off."),
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:toggleDeleteAfterMarkRead(touchmenu_instance)
                    end,
                },
                {
                    text_func = function()
                        return I18n.f(
                            "Finish retention: %1",
                            self:getDeleteChaptersSettingSummary("delete_finished_while_reading")
                        )
                    end,
                    help_text = I18n.t("Keep the newest recorded completions per manga, not chapter-list positions. Completion requires completed status and close, or a plugin manual mark-read action. Live readers remain protected."),
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showDeleteFinishedWhileReadingDialog(touchmenu_instance)
                    end,
                },
                {
                    text = I18n.t("Download help"),
                    keep_menu_open = true,
                    sub_item_table = {
                        {
                            text = I18n.t("Next downloads and download ahead"),
                            callback = function()
                                self:showMessage(I18n.t("Download next adds eligible unread downloads. Download ahead fills the earliest unread positions; existing downloads and queue work count. Both use source order and the exact saved scanlator filter, never a silent fallback to All.")
                                    .. "\n\n" .. I18n.t("Ahead five with two existing positions needs only three downloads. Next five can add five more. Neither starts at the current reader page."))
                            end,
                        },
                        {
                            text = I18n.t("When download ahead runs"),
                            callback = function()
                                self:showMessage(I18n.t("Refill follows completed close, including native next-file reading; manual read/unread; actual read reconciliation; successful chapter load/return/refresh; and ahead or scanlator changes. Repaint, progress, and cancellation do not create refill requests. Pending work survives offline operation and restart."))
                            end,
                        },
                        {
                            text = I18n.t("Retry, Stop, and Cancel"),
                            callback = function()
                                self:showMessage(I18n.t("Refill Retry reevaluates the buffer; it does not retry failed chapters or override pending deletion. Stop download ahead turns the policy Off but keeps accepted jobs. Cancel retires the current refill for that manga; Cancel all retires every refill. Cancellation keeps ahead enabled for later reading or chapter actions."))
                            end,
                        },
                        {
                            text = I18n.t("Completion and archive removal"),
                            callback = function()
                                self:showMessage(I18n.t("Completed status plus close counts; reaching the last page alone does not. Manual completions also count for retention. Historical read flags do not authorize deletion. A completion without an archive occupies a position but cannot authorize deleting a later download.")
                                    .. "\n\n" .. I18n.t("Keep 2 newest completions: after completing A, B, then C in one manga, A becomes eligible for removal. B and C remain. Live readers stay protected."))
                            end,
                        },
                        {
                            text = I18n.t("Accepted manual deletion"),
                            callback = function()
                                self:showMessage(I18n.t("Mark-read can succeed even when deletion is busy or blocked. Accepted removal keeps sidecars, backups, and reading metadata. Unread or a later accepted deliberate Download/Retry revokes remaining removal; failed, uncertain, duplicate, or automatic downloads do not. See the README for examples and safety details."))
                            end,
                        },
                    },
                },
            },
        },
    }
end


SettingsController.methods = Methods

return SettingsController
