-- Boundary: Browse extension management flow.
--
-- Responsibility: render extension menus and coordinate extension fetch/install/update/uninstall
-- worker results without blocking KOReader UI callbacks on network work.
-- Owned state: plugin-bound current extension menu/action and active worker.
-- Dependencies: KOReader UI helpers, plugin i18n facade, Suwayomi settings,
-- subprocess job helper, and Browse extension worker.
-- External data: extension records, source refresh results, credentials, and
-- worker files are treated as untrusted until normalized locally.

local UIManager = require("ui/uimanager")
local SuwayomiExtensionWorker = require("suwayomi/browse/extension_worker")
local SubprocessJob = require("suwayomi/subprocess/job")
local SuwayomiSettings = require("suwayomi/settings")
local SourceLanguages = require("suwayomi/source_languages")
local I18n = require("suwayomi/i18n")
local FFIUtil = require("ffi/util")

local Extensions = {}
local Methods = {}

local function getUI()
    return require("suwayomi/ui")
end

local function refreshVisibleSourceList(self, credentials, sources)
    if not self.current_sources_menu or type(sources) ~= "table" then
        return false
    end
    if type(self.filterSourcesByLanguage) ~= "function" or type(self.showSourceList) ~= "function" then
        return false
    end
    return self:showSourceList(self:filterSourcesByLanguage(sources), {
        credentials = credentials,
        all_sources = sources,
    })
end

local function trim(value)
    value = value == nil and "" or tostring(value)
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value
end

local function lower(value)
    return tostring(value or ""):lower()
end

local function credentialField(credentials, field)
    return tostring(type(credentials) == "table" and credentials[field] or "")
end

local function credentialsMatch(left, right)
    return credentialField(left, "server_url") == credentialField(right, "server_url")
        and credentialField(left, "auth_method") == credentialField(right, "auth_method")
        and credentialField(left, "username") == credentialField(right, "username")
        and credentialField(left, "password") == credentialField(right, "password")
end

local function addSearchField(fields, value)
    if value == nil or value == "" then
        return
    end
    table.insert(fields, tostring(value))
end

local function extensionMatchesSearch(extension, query)
    if query == "" then
        return true
    end
    if type(extension) ~= "table" then
        return false
    end

    local fields = {}
    addSearchField(fields, extension.name)
    addSearchField(fields, extension.pkg_name)
    addSearchField(fields, extension.apk_name)
    addSearchField(fields, extension.lang)
    addSearchField(fields, SourceLanguages.formatLabel(extension.lang))
    addSearchField(fields, extension.version_name)
    addSearchField(fields, extension.version_code)
    addSearchField(fields, extension.repository)
    addSearchField(fields, extension.repo)

    return lower(table.concat(fields, " ")):find(query, 1, true) ~= nil
end

local function filterExtensionsBySearch(extensions, query)
    query = lower(trim(query))
    if query == "" then
        return extensions
    end

    local filtered = {}
    for _ , extension in ipairs(extensions or {}) do
        if extensionMatchesSearch(extension, query) then
            table.insert(filtered, extension)
        end
    end
    return filtered
end

local function extensionTimeoutMessage(action)
    if action == "install" then
        return I18n.t("Extension install timed out.")
    end
    if action == "update" then
        return I18n.t("Extension update timed out.")
    end
    if action == "uninstall" then
        return I18n.t("Extension uninstall timed out.")
    end
    return I18n.t("Extension list loading timed out.")
end

local function refreshWarningMessage(action, refresh_kind, error_message)
    if not error_message or error_message == "" then
        return nil
    end
    if action == "install" and refresh_kind == "extension" then
        return I18n.f("Extension install succeeded, but extension list refresh failed: %1", error_message)
    end
    if action == "install" and refresh_kind == "source" then
        return I18n.f("Extension install succeeded, but source refresh failed: %1", error_message)
    end
    if action == "update" and refresh_kind == "extension" then
        return I18n.f("Extension update succeeded, but extension list refresh failed: %1", error_message)
    end
    if action == "update" and refresh_kind == "source" then
        return I18n.f("Extension update succeeded, but source refresh failed: %1", error_message)
    end
    if action == "uninstall" and refresh_kind == "extension" then
        return I18n.f("Extension uninstall succeeded, but extension list refresh failed: %1", error_message)
    end
    if action == "uninstall" and refresh_kind == "source" then
        return I18n.f("Extension uninstall succeeded, but source refresh failed: %1", error_message)
    end
    return nil
end

local function showRefreshWarnings(self, result)
    if not result or not result.ok or not self.showMessage then
        return
    end
    local extension_warning = refreshWarningMessage(result.action, "extension", result.extension_refresh_error)
    if extension_warning then
        self:showMessage(extension_warning)
    end
    local source_warning = refreshWarningMessage(result.action, "source", result.source_refresh_error)
    if source_warning then
        self:showMessage(source_warning)
    end
end

function Methods:getExtensionWorkerResultPath()
    return SubprocessJob.buildResultPath("extensions")
end

function Methods:scheduleExtensionWorkerPoll()
    SubprocessJob.schedulePoll(self.extension_worker_active)
end

function Methods:startExtensionWorker(credentials, request, options)
    options = options or {}
    request = request or { action = "fetch" }
    if self.extension_worker_active then
        if not options.silent and self.showMessage then
            self:showMessage(I18n.t("Extension task already running."))
        end
        return false
    end

    local result_path = self:getExtensionWorkerResultPath()
    local active = {
        credentials = credentials,
        request = request,
        options = options,
        result_path = result_path,
        loading_message = not options.silent
            and self:showLoadingMessage(options.loading_message or I18n.t("Loading extensions..."))
            or nil,
    }

    active = SubprocessJob.start({
        active = active,
        ffi_util = FFIUtil,
        ui_manager = UIManager,
        poll_interval_seconds = self.source_fetch_poll_interval_seconds,
        timeout_seconds = self.source_fetch_watchdog_timeout_seconds,
        run = function(path)
            SuwayomiExtensionWorker:run(credentials, request, path)
        end,
        read_result = function(path)
            return SuwayomiExtensionWorker:readResult(path)
        end,
        on_finish = function(finished_active, result)
            self:finishExtensionWorker(finished_active, result)
        end,
        on_timeout = function(timed_out_active)
            if self.extension_worker_active == timed_out_active then
                self.extension_worker_active = nil
            end
            self:closeLoadingMessage(timed_out_active and timed_out_active.loading_message)
            if not options.silent then
                self:showMessage(extensionTimeoutMessage(timed_out_active and timed_out_active.request and timed_out_active.request.action))
            end
        end,
        on_cleanup = function(cleaned_active)
            if self.extension_worker_active == cleaned_active then
                self.extension_worker_active = nil
            end
        end,
        on_error = function(err)
            self.extension_worker_active = nil
            self:closeLoadingMessage(active.loading_message)
            if not options.silent then
                local message = trim(err)
                if message ~= "" then
                    self:showMessage(I18n.f("Could not start extension task: %1", message))
                else
                    self:showMessage(I18n.t("Could not start extension task: unknown error"))
                end
            end
        end,
    })
    self.extension_worker_active = active and not active.cleaned and active or nil
    return active ~= nil
end

function Methods:cancelExtensionWorker()
    local active = self.extension_worker_active
    if not active then
        return false
    end
    active.canceled = true
    self.extension_worker_active = nil
    self:closeLoadingMessage(active.loading_message)
    if SubprocessJob.cancel then
        SubprocessJob.cancel(active)
    end
    return true
end

function Methods:finishExtensionWorker(active, result)
    if active and active.canceled then
        return false
    end
    self.extension_worker_active = nil
    self:closeLoadingMessage(active and active.loading_message)
    if not credentialsMatch(active and active.credentials, SuwayomiSettings:load()) then
        return false
    end
    if result
        and result.ok
        and type(result.sources) == "table"
        and result.action
        and result.action ~= "fetch"
        and result.source_refresh_ok ~= false
    then
        self:saveSourceCache(active and active.credentials, result.sources)
        refreshVisibleSourceList(self, active and active.credentials, result.sources)
    end
    showRefreshWarnings(self, result)
    self:showFetchedExtensions(result, {
        credentials = active and active.credentials,
        action = result and result.action,
        updated_pkg_name = result
            and type(result.updated_extension) == "table"
            and result.updated_extension.pkg_name
            or nil,
        force_new = active and active.options and active.options.force_new,
    })
    return true
end

function Methods:pollExtensionWorker()
    SubprocessJob.poll(self.extension_worker_active)
end

function Methods:showExtensions()
    local credentials = SuwayomiSettings:load()
    if credentials.server_url == "" then
        self:showMessage(I18n.t("Set up your Suwayomi server login first."))
        if self.showOnboardingSetup then
            self:showOnboardingSetup({ first_run = true })
        end
        return
    end
    return self:startExtensionWorker(credentials, {
        action = "fetch",
    }, {
        loading_message = I18n.t("Loading extensions..."),
        force_new = true,
    })
end

local function extensionActionMessage(action)
    if action == "install" then
        return I18n.t("Installing extension...")
    end
    if action == "update" then
        return I18n.t("Updating extension...")
    end
    if action == "uninstall" then
        return I18n.t("Uninstalling extension...")
    end
    return I18n.t("Updating extension...")
end

function Methods:showExtensionActions(extension)
    local SuwayomiUI = getUI()
    return SuwayomiUI.showExtensionActionMenu(extension, function(action)
        return self:startExtensionWorker(self.current_extension_credentials, {
            action = action,
            pkg_name = extension and extension.pkg_name,
        }, {
            loading_message = extensionActionMessage(action),
        })
    end, self.getTitleBarMenuOptions and self:getTitleBarMenuOptions({
        title = extension and extension.name or I18n.c("extension title", "Extension"),
        actions = {},
    }) or {})
end

function Methods:showFetchedExtensions(result, options)
    local SuwayomiUI = getUI()
    options = options or {}
    if not result then
        self:showMessage(I18n.t("Could not load Suwayomi extensions."))
        return
    end
    if not result.ok then
        self:showMessage(result.error or I18n.t("Could not load Suwayomi extensions."))
        return
    end

    local extensions = type(result.extensions) == "table" and result.extensions or {}
    self.current_extensions_all = extensions
    local menu
    local function selectExtension(extension)
        return self:showExtensionActions(extension)
    end
    local buildExtensionMenuOptions
    local function trackExtensionsMenu(target_menu)
        if target_menu and self.trackSuwayomiScreen then
            self:trackSuwayomiScreen("browse-extensions", target_menu)
        end
    end
    local function currentSearchQuery()
        return trim(self.current_extension_search_query)
    end
    local function visibleExtensions()
        return filterExtensionsBySearch(extensions, currentSearchQuery())
    end
    local function activeSearchQuery()
        local query = currentSearchQuery()
        return query ~= "" and query or nil
    end
    local function updateVisibleExtensions(target_menu)
        if target_menu and SuwayomiUI.updateExtensionsMenu then
            SuwayomiUI.updateExtensionsMenu(target_menu, visibleExtensions(), selectExtension, buildExtensionMenuOptions(target_menu))
            trackExtensionsMenu(target_menu)
        end
        return target_menu
    end
    local function applySearch(query)
        self.current_extension_search_query = trim(query)
        return updateVisibleExtensions(self.current_extensions_menu)
    end
    local function showSearchPrompt()
        if SuwayomiUI.showExtensionSearchPrompt then
            return SuwayomiUI.showExtensionSearchPrompt(currentSearchQuery(), applySearch)
        end
        return false
    end
    buildExtensionMenuOptions = function(target_menu)
        local query = activeSearchQuery()
        local actions = {
            {
                id = "search_extensions",
                text = query
                    and I18n.cf("extension action", "Search extensions: %1", query)
                    or I18n.c("extension action", "Search extensions"),
            },
        }
        if query then
            table.insert(actions, {
                id = "clear_extension_search",
                text = I18n.cf("extension action", "Clear search: %1", query),
            })
        end
        table.insert(actions, { id = "refresh_extensions", text = I18n.t("Refresh extension list") })

        local menu_options = {}
        if self.getTitleBarMenuOptions then
            menu_options = self:getTitleBarMenuOptions({
                title = I18n.t("Suwayomi Extensions"),
                actions = actions,
                onSelect = function(action)
                    if action and action.id == "search_extensions" then
                        return showSearchPrompt()
                    elseif action and action.id == "clear_extension_search" then
                        return applySearch("")
                    elseif action and action.id == "refresh_extensions" then
                        return self:startExtensionWorker(options.credentials, {
                            action = "fetch",
                        }, {
                            loading_message = I18n.t("Refreshing extensions..."),
                        })
                    end
                end,
            }) or {}
        end
        menu_options.close_callback = function()
            if self.current_extensions_menu == (target_menu or menu) then
                self.current_extensions_menu = nil
            end
        end
        menu_options.thumbnail_credentials = options.credentials
        if query or options.action ~= "uninstall" then
            menu_options.focus_extension_pkg_name = options.updated_pkg_name
        elseif options.updated_pkg_name then
            menu_options.itemnumber = 1
        end
        if query then
            menu_options.empty_text = I18n.t("No matching extensions")
            menu_options.show_empty_extension_sections = true
            menu_options.on_close = function()
                applySearch("")
                return true
            end
        end
        return menu_options
    end

    self.current_extension_credentials = options.credentials
    if not options.force_new and self.current_extensions_menu and SuwayomiUI.updateExtensionsMenu then
        local existing_menu = self.current_extensions_menu
        SuwayomiUI.updateExtensionsMenu(existing_menu, visibleExtensions(), selectExtension, buildExtensionMenuOptions(existing_menu))
        trackExtensionsMenu(existing_menu)
        return self.current_extensions_menu
    end

    menu = SuwayomiUI.showExtensionsMenu(visibleExtensions(), selectExtension, buildExtensionMenuOptions())
    self.current_extensions_menu = menu
    trackExtensionsMenu(menu)
    return self.current_extensions_menu
end

Extensions.methods = Methods

return Extensions
