package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

local modules_to_clear = {
    "ffi/util",
    "gettext",
    "ui/uimanager",
    "suwayomi/subprocess/job",
    "suwayomi/plugin/onboarding_connection_worker",
    "suwayomi/settings",
    "suwayomi/ui",
    "suwayomi/plugin/settings_controller",
}

local function clearModules()
    for _, name in ipairs(modules_to_clear) do
        package.loaded[name] = nil
        package.preload[name] = nil
    end
end

local function installController(options)
    options = options or {}
    clearModules()
    local state = {
        events = {},
        messages = {},
        refresh_count = 0,
        saved_languages = options.languages or { "en", "ru" },
        saved_browse_settings = options.browse_settings or {
            show_nsfw_sources = false,
            hide_in_library_results = false,
        },
        saved_parallel = options.parallel or 2,
        saved_delete_chapters_settings = options.delete_chapters_settings or {
            delete_after_mark_read = false,
            delete_finished_while_reading = 0,
        },
        saved_category_behavior = options.category_behavior or "automatic",
        credentials = options.credentials or { server_url = "https://suwayomi.example" },
        download_directory = options.download_directory or "",
    }

    package.preload.gettext = function()
        return function(text)
            return text
        end
    end
    package.preload["ffi/util"] = function()
        return {
            template = function(template_string, ...)
                local result = template_string
                for index, value in ipairs({...}) do
                    result = result:gsub("%%" .. index, tostring(value))
                end
                return result
            end,
        }
    end
    package.preload["ui/uimanager"] = function()
        return {
            nextTick = function(_, callback)
                callback()
            end,
        }
    end
    package.preload["suwayomi/settings"] = function()
        local settings = {
            load = function()
                return state.credentials
            end,
            save = function(_, credentials)
                state.saved_credentials = credentials
                state.credentials = credentials
                return credentials
            end,
            loadSourceLanguages = function()
                return state.saved_languages
            end,
            saveSourceLanguages = function(_, languages)
                state.saved_languages = languages
                return languages
            end,
            loadBrowseSettings = function()
                return state.saved_browse_settings
            end,
            saveBrowseSettings = function(_, browse_settings)
                state.saved_browse_settings = browse_settings
                return browse_settings
            end,
            loadDownloadDirectory = function()
                return state.download_directory
            end,
            loadMaxParallelChapterDownloads = function()
                return state.saved_parallel
            end,
            saveMaxParallelChapterDownloads = function(_, value)
                state.saved_parallel = value
                return value
            end,
            loadDeleteChaptersSettings = function()
                return state.saved_delete_chapters_settings
            end,
            saveDeleteChaptersSettings = function(_, value)
                state.saved_delete_chapters_settings = value
                return value
            end,
            loadLibraryCategoryPickerBehavior = function()
                return state.saved_category_behavior
            end,
            saveLibraryCategoryPickerBehavior = function(_, behavior)
                state.saved_category_behavior = behavior
                return behavior
            end,
        }
        if options.no_category_persistence then
            settings.loadLibraryCategoryPickerBehavior = nil
            settings.saveLibraryCategoryPickerBehavior = nil
        end
        return settings
    end
    package.preload["suwayomi/ui"] = function()
        return {
            showSettingsMenu = function(items)
                state.settings_menu = items
                return items
            end,
            showLoginDialog = function(dialog_options)
                state.login_dialog_options = dialog_options
            end,
            showOnboardingConnectionDialog = function(dialog_options)
                state.onboarding_connection_options = dialog_options
                return state.onboarding_connection_dialog or { name = "connection-dialog" }
            end,
            updateOnboardingConnectionDialogStatus = function(dialog, status)
                state.connection_status_updates = state.connection_status_updates or {}
                table.insert(state.connection_status_updates, { dialog = dialog, status = status })
            end,
            showLanguageMenu = function(menu_options)
                state.language_menu_options = menu_options
                return { name = "language-menu" }
            end,
            updateLanguageMenu = function(menu, menu_options)
                state.language_menu_options = menu_options
                state.language_menu_options.menu = menu
            end,
            showParallelDownloadsMenu = function(menu_options)
                state.parallel_menu_options = menu_options
                return { name = "parallel-downloads-menu" }
            end,
            updateParallelDownloadsMenu = function(menu, menu_options)
                state.parallel_menu_options = menu_options
                state.parallel_menu_options.menu = menu
            end,
            showDeleteFinishedWhileReadingMenu = function(menu_options)
                state.delete_finished_menu_options = menu_options
                return { name = "delete-finished-menu" }
            end,
            updateDeleteFinishedWhileReadingMenu = function(menu, menu_options)
                state.delete_finished_menu_options = menu_options
                state.delete_finished_menu_options.menu = menu
            end,
            updateKeepNextUnreadDownloadsMenu = function(menu, menu_options)
                state.keep_next_menu_options = menu_options
                state.keep_next_menu_options.menu = menu
            end,
            showLibraryCategoryPickerBehaviorMenu = function(menu_options)
                state.category_menu_options = menu_options
                return { name = "library-category-picker-menu" }
            end,
            updateLibraryCategoryPickerBehaviorMenu = function(menu, menu_options)
                state.category_menu_options = menu_options
                state.category_menu_options.menu = menu
            end,
        }
    end
    package.preload["suwayomi/subprocess/job"] = function()
        return {
            buildResultPath = function()
                return "/mock/settings/suwayomi_dl_onboarding_connection.json"
            end,
            start = function(job_options)
                state.started_connection_job = job_options
                return job_options.active
            end,
            cancel = function(active)
                state.canceled_connection_job = active
                if active then
                    active.canceled = true
                end
            end,
            poll = function() end,
        }
    end
    package.preload["suwayomi/plugin/onboarding_connection_worker"] = function()
        return {
            run = function() end,
            readResult = function()
                return { ok = true, message = "Connection test passed." }
            end,
        }
    end

    local controller = require("suwayomi/plugin/settings_controller")
    local plugin = {
        messages = state.messages,
        download_queue = { stale = true },
    }
    for name, method in pairs(controller.methods) do
        plugin[name] = method
    end
    function plugin:showMessage(message)
        table.insert(self.messages, message)
        table.insert(state.events, "message:" .. message)
    end
    function plugin:showLoadingMessage(message)
        state.loading_message = { message = message }
        return state.loading_message
    end
    function plugin:closeLoadingMessage(message)
        state.closed_loading_message = message
    end
    function plugin:getDownloadDirectorySummary()
        return "not set"
    end
    function plugin:chooseDownloadDirectory(callback, choose_options)
        state.choose_download_callback = callback
        state.choose_download_options = choose_options
    end
    function plugin:closeSuwayomiPlugin()
        state.closed_plugin = true
        table.insert(state.events, "close")
    end
    function plugin:showHome()
        state.home_count = (state.home_count or 0) + 1
        table.insert(state.events, "home")
    end
    function plugin:pluralize(value, singular, plural)
        return value == 1 and singular or plural
    end
    state.touchmenu = {
        updateItems = function()
            state.refresh_count = state.refresh_count + 1
        end,
    }
    return plugin, state
end

describe("suwayomi/plugin/settings_controller", function()
    after_each(clearModules)

    local function findMenuItem(items, text)
        for _, item in ipairs(items or {}) do
            if item.text == text then
                return item
            end
        end
    end

    it("exports settings dialog and settings menu methods", function()
        helper.assertControllerModule("suwayomi/plugin/settings_controller", {
            "showSettings",
            "showLoginDialog",
            "showOnboardingSetup",
            "startOnboardingConnectionTest",
            "showDownloadDirectoryDialog",
            "buildSettingsMenu",
        })
    end)

    it("builds settings menu callbacks and saves login changes", function()
        local plugin, state = installController()
        local menu = plugin:showSettings()
        local connection_menu = findMenuItem(menu, "Connection")

        assert.are.equal("Setup wizard", menu[1].text)
        assert.are.equal("Connection", menu[2].text)
        assert.are.equal("Library", menu[3].text)
        assert.are.equal("Browse", menu[4].text)
        assert.are.equal("Downloads", menu[5].text)
        assert.are.equal("Login information", connection_menu.sub_item_table[1].text)
        assert.are.equal("Test connection", connection_menu.sub_item_table[2].text)
        assert.is_nil(connection_menu.sub_item_table[3])
        assert.is_true(connection_menu.sub_item_table[1].keep_menu_open)
        assert.is_true(connection_menu.sub_item_table[2].keep_menu_open)

        menu[1].callback()
        assert.truthy(state.onboarding_connection_options)

        connection_menu.sub_item_table[1].callback(state.touchmenu)
        state.login_dialog_options.onSave({ server_url = "https://new.example" })

        assert.are.equal("https://new.example", state.saved_credentials.server_url)
        assert.are.equal(1, state.refresh_count)
        assert.are.equal("Suwayomi login settings saved.", state.messages[#state.messages])

        connection_menu.sub_item_table[2].callback(state.touchmenu)
        assert.are.equal("https://new.example", state.started_connection_job.active.credentials.server_url)
        state.started_connection_job.on_finish(state.started_connection_job.active, {
            ok = true,
            message = "Connection test passed.",
        })
        assert.are.equal("Connection test passed.", state.messages[#state.messages])
    end)

    it("keeps settings root groups and callback routes stable", function()
        local plugin, state = installController()
        local menu = plugin:buildSettingsMenu()
        local connection_menu = findMenuItem(menu, "Connection")
        local library_menu = findMenuItem(menu, "Library")
        local browse_menu = findMenuItem(menu, "Browse")
        local downloads_menu = findMenuItem(menu, "Downloads")

        assert.are.equal("Setup wizard", menu[1].text)
        assert.are.equal("Connection", menu[2].text)
        assert.are.equal("Library", menu[3].text)
        assert.are.equal("Browse", menu[4].text)
        assert.are.equal("Downloads", menu[5].text)

        menu[1].callback(state.touchmenu)
        assert.truthy(state.onboarding_connection_options)

        connection_menu.sub_item_table[1].callback(state.touchmenu)
        assert.truthy(state.login_dialog_options)

        connection_menu.sub_item_table[2].callback(state.touchmenu)
        assert.truthy(state.started_connection_job)

        library_menu.sub_item_table[1].callback(state.touchmenu)
        assert.are.same({ "automatic", "always", "never" }, state.category_menu_options.choices)

        browse_menu.sub_item_table[1].callback(state.touchmenu)
        browse_menu.sub_item_table[2].callback(state.touchmenu)
        assert.is_true(state.saved_browse_settings.show_nsfw_sources)
        assert.is_true(state.saved_browse_settings.hide_in_library_results)

        downloads_menu.sub_item_table[1].callback(state.touchmenu)
        assert.truthy(state.choose_download_callback)
        assert.are.same({ suppress_saved_message = true }, state.choose_download_options)

        downloads_menu.sub_item_table[2].callback(state.touchmenu)
        assert.are.same({ 1, 2, 3, 4 }, state.parallel_menu_options.choices)

        downloads_menu.sub_item_table[3].callback(state.touchmenu)
        assert.is_true(state.saved_delete_chapters_settings.delete_after_mark_read)

        downloads_menu.sub_item_table[4].callback(state.touchmenu)
        assert.are.same({ 0, 1, 2, 3, 4, 5 }, state.delete_finished_menu_options.choices)
    end)

    it("runs first-run setup as connection test then download folder", function()
        local plugin, state = installController({
            credentials = { server_url = "" },
            download_directory = "",
        })
        plugin.startOnboardingConnectionTest = function(self, credentials)
            state.tested_credentials = credentials
            self.onboarding_connection_test_key = self:getOnboardingCredentialsKey(credentials)
        end

        assert.is_true(plugin:needsOnboardingSetup())
        plugin:showOnboardingSetup({ first_run = true })

        assert.are.equal("https://", state.onboarding_connection_options.credentials.server_url)
        assert.is_false(state.onboarding_connection_options.onContinue({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }))
        assert.are.equal("Test connection before continuing.", state.messages[#state.messages])
        assert.is_nil(state.saved_credentials)

        state.onboarding_connection_options.onTestConnection({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })
        assert.is_true(state.onboarding_connection_options.onContinue({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }))

        assert.are.equal("https://suwayomi.example", state.saved_credentials.server_url)
        assert.truthy(state.choose_download_callback)
        assert.are.same({
            next_tick = true,
            suppress_saved_message = true,
        }, state.choose_download_options)

        state.choose_download_callback("/storage/emulated/0/Books/Manga")

        assert.are.equal("Test connection before continuing.", state.messages[#state.messages])
        assert.is_true(state.closed_plugin)
        assert.are.equal(1, state.home_count)
    end)

    it("requires settings setup wizard to test current connection before continuing", function()
        local plugin, state = installController({
            credentials = { server_url = "https://suwayomi.example" },
            download_directory = "/storage/emulated/0/Books/Manga",
        })
        plugin.startOnboardingConnectionTest = function(self, credentials)
            state.tested_credentials = credentials
            self.onboarding_connection_test_key = self:getOnboardingCredentialsKey(credentials)
        end

        plugin:showOnboardingSetup({ first_run = false })

        assert.truthy(state.onboarding_connection_options)
        assert.are.equal("https://suwayomi.example", state.onboarding_connection_options.credentials.server_url)
        assert.is_function(state.onboarding_connection_options.canContinue)
        assert.is_false(state.onboarding_connection_options.canContinue({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }))
        assert.is_false(state.onboarding_connection_options.onContinue({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }))
        assert.are.equal("Test connection before continuing.", state.messages[#state.messages])
        assert.is_nil(state.saved_credentials)
        assert.is_nil(state.choose_download_callback)

        state.onboarding_connection_options.onTestConnection({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })
        assert.is_false(state.onboarding_connection_options.canContinue({
            server_url = "https://changed.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }))
        assert.is_false(state.onboarding_connection_options.canContinue({
            server_url = "https://suwayomi.example",
            username = "bob",
            password = "secret",
            auth_method = "basic_auth",
        }))
        assert.is_false(state.onboarding_connection_options.canContinue({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "changed",
            auth_method = "basic_auth",
        }))
        assert.is_false(state.onboarding_connection_options.onContinue({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "changed",
            auth_method = "basic_auth",
        }))
        assert.is_nil(state.saved_credentials)

        assert.is_true(state.onboarding_connection_options.canContinue({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }))
        assert.is_true(state.onboarding_connection_options.onContinue({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }))
        assert.truthy(state.choose_download_callback)
    end)

    it("invalidates previous onboarding connection tests when reopening setup", function()
        local plugin, state = installController({
            credentials = {
                server_url = "https://suwayomi.example",
                username = "alice",
                password = "secret",
                auth_method = "basic_auth",
            },
            download_directory = "/storage/emulated/0/Books/Manga",
        })
        plugin.onboarding_connection_test_key = plugin:getOnboardingCredentialsKey(state.credentials)

        plugin:showOnboardingSetup({ first_run = false })

        assert.is_false(state.onboarding_connection_options.canContinue({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }))
        assert.is_false(state.onboarding_connection_options.onContinue({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }))
        assert.is_nil(state.saved_credentials)
        assert.is_nil(state.choose_download_callback)
    end)

    it("ignores in-flight onboarding connection results after reopening setup", function()
        local plugin, state = installController({
            credentials = {
                server_url = "https://suwayomi.example",
                username = "alice",
                password = "secret",
                auth_method = "basic_auth",
            },
            download_directory = "/storage/emulated/0/Books/Manga",
        })
        plugin:startOnboardingConnectionTest(state.credentials)
        local old_active = plugin.onboarding_connection_test_active

        plugin:showOnboardingSetup({ first_run = false })
        plugin:finishOnboardingConnectionTest(old_active, {
            ok = true,
            message = "Connection test passed.",
        })

        assert.is_true(old_active.canceled)
        assert.are.equal(old_active, state.canceled_connection_job)
        assert.is_nil(plugin.onboarding_connection_test_active)
        assert.is_false(state.onboarding_connection_options.canContinue(state.credentials))
        assert.is_false(state.onboarding_connection_options.onContinue(state.credentials))
        assert.is_nil(state.saved_credentials)
        assert.is_nil(state.choose_download_callback)
    end)

    it("cancels in-flight onboarding connection tests when setup closes", function()
        local plugin, state = installController({
            credentials = {
                server_url = "https://suwayomi.example",
                username = "alice",
                password = "secret",
                auth_method = "basic_auth",
            },
            download_directory = "/storage/emulated/0/Books/Manga",
        })
        plugin:showOnboardingSetup({ first_run = false })
        state.onboarding_connection_options.onTestConnection(state.credentials)
        local active = plugin.onboarding_connection_test_active

        state.onboarding_connection_options.onClose()
        plugin:finishOnboardingConnectionTest(active, {
            ok = true,
            message = "Connection test passed.",
        })

        assert.is_true(active.canceled)
        assert.are.equal(active, state.canceled_connection_job)
        assert.is_nil(plugin.onboarding_connection_test_active)
        assert.is_nil(plugin.onboarding_connection_test_key)
        assert.is_false(state.onboarding_connection_options.canContinue(state.credentials))
        assert.are.equal("testing", state.connection_status_updates[#state.connection_status_updates].status)
        assert.are.same({}, state.messages)
    end)

    it("closes settings before landing home after settings-launched setup", function()
        local plugin, state = installController({
            credentials = { server_url = "https://suwayomi.example" },
            download_directory = "/storage/emulated/0/Books/Manga",
        })
        plugin.startOnboardingConnectionTest = function(self, credentials)
            self.onboarding_connection_test_key = self:getOnboardingCredentialsKey(credentials)
        end

        plugin:buildSettingsMenu()[1].callback()
        state.onboarding_connection_options.onTestConnection({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })
        assert.is_true(state.onboarding_connection_options.onContinue({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }))
        state.choose_download_callback("/storage/emulated/0/Books/Manga")

        assert.are.same({
            next_tick = true,
            suppress_saved_message = true,
        }, state.choose_download_options)
        assert.are.equal(0, #state.messages)
        assert.is_true(state.closed_plugin)
        assert.are.equal(1, state.home_count)
    end)

    it("lands home without a completion toast after setup folder selection", function()
        local plugin, state = installController({
            credentials = { server_url = "https://suwayomi.example" },
            download_directory = "/storage/emulated/0/Books/Manga",
        })
        plugin.startOnboardingConnectionTest = function(self, credentials)
            self.onboarding_connection_test_key = self:getOnboardingCredentialsKey(credentials)
        end

        plugin:buildSettingsMenu()[1].callback()
        state.onboarding_connection_options.onTestConnection({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })
        assert.is_true(state.onboarding_connection_options.onContinue({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }))
        state.choose_download_callback("/storage/emulated/0/Books/Manga")

        assert.are.same({
            "close",
            "home",
        }, state.events)
    end)

    it("uses a device-friendly timeout for onboarding connection tests", function()
        local plugin, state = installController()

        plugin:startOnboardingConnectionTest({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.are.equal(25, state.started_connection_job.timeout_seconds)
    end)

    it("marks onboarding connection status during and after tests", function()
        local plugin, state = installController()
        state.onboarding_connection_dialog = { name = "connection-dialog" }
        plugin.onboarding_connection_dialog = state.onboarding_connection_dialog
        plugin:startOnboardingConnectionTest({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.are.same({
            { dialog = plugin.onboarding_connection_dialog, status = "testing" },
        }, state.connection_status_updates)

        plugin:finishOnboardingConnectionTest({
            credentials = {
                server_url = "https://suwayomi.example",
                username = "alice",
                password = "secret",
                auth_method = "basic_auth",
            },
            loading_message = state.loading_message,
        }, {
            ok = true,
            message = "Connection test passed. Found 85 sources.",
        })

        assert.are.equal("passed", state.connection_status_updates[#state.connection_status_updates].status)
        assert.are.equal("Connection test passed. Found 85 sources. You can continue.", state.messages[#state.messages])
    end)

    it("keeps source language filtering out of plugin settings", function()
        local plugin, state = installController()
        local browse_items = findMenuItem(plugin:buildSettingsMenu(), "Browse").sub_item_table

        assert.are.equal("Show NSFW sources: no", browse_items[1].text_func())
        assert.are.equal("Hide in-library results: no", browse_items[2].text_func())
        assert.is_nil(state.language_menu_options)
    end)

    it("toggles browse settings through menu callbacks", function()
        local plugin, state = installController()
        local browse_items = findMenuItem(plugin:buildSettingsMenu(), "Browse").sub_item_table

        assert.are.equal("Show NSFW sources: no", browse_items[1].text_func())
        assert.are.equal("Hide in-library results: no", browse_items[2].text_func())

        browse_items[1].callback(state.touchmenu)
        browse_items[2].callback(state.touchmenu)

        assert.are.same({
            show_nsfw_sources = true,
            hide_in_library_results = true,
        }, state.saved_browse_settings)
        assert.are.equal(2, state.refresh_count)
        assert.are.same({}, state.messages)
    end)

    it("saves parallel download settings from downloads settings", function()
        local plugin, state = installController()
        local download_items = findMenuItem(plugin:buildSettingsMenu(), "Downloads").sub_item_table

        assert.are.equal("Parallel downloads: 2", download_items[2].text_func())
        download_items[2].callback(state.touchmenu)
        assert.are.same({ 1, 2, 3, 4 }, state.parallel_menu_options.choices)
        state.parallel_menu_options.onSelect(3)

        assert.are.equal(3, state.saved_parallel)
        assert.are.equal(3, plugin.download_queue.max_active_chapters)
        assert.are.equal("parallel-downloads-menu", state.parallel_menu_options.menu.name)
        assert.are.same({}, state.messages)
        assert.are.equal("Delete after manual mark-read: no", download_items[3].text_func())
    end)

    it("updates an existing download queue limit without abandoning active jobs", function()
        local plugin, state = installController()
        local process_count = 0
        plugin.download_queue = {
            max_active_chapters = 2,
            process = function()
                process_count = process_count + 1
            end,
        }
        local download_items = findMenuItem(plugin:buildSettingsMenu(), "Downloads").sub_item_table

        download_items[2].callback(state.touchmenu)
        state.parallel_menu_options.onSelect(4)

        assert.are.equal(4, state.saved_parallel)
        assert.are.equal(4, plugin.download_queue.max_active_chapters)
        assert.are.equal(1, process_count)
        assert.are.same({}, state.messages)
    end)

    it("saves category picker behavior and reports unavailable persistence", function()
        local plugin, state = installController()
        local library_item = findMenuItem(plugin:buildSettingsMenu(), "Library").sub_item_table[1]

        assert.are.equal("Category picker: automatic", library_item.text_func())
        library_item.callback(state.touchmenu)
        assert.are.same({ "automatic", "always", "never" }, state.category_menu_options.choices)
        state.category_menu_options.onSelect("always")

        assert.are.equal("always", state.saved_category_behavior)
        assert.are.equal("library-category-picker-menu", state.category_menu_options.menu.name)
        assert.are.same({}, state.messages)

        local unavailable_plugin, unavailable_state = installController({ no_category_persistence = true })
        local unavailable_item = findMenuItem(unavailable_plugin:buildSettingsMenu(), "Library").sub_item_table[1]
        assert.are.equal("Category picker: automatic", unavailable_item.text_func())
        unavailable_item.callback(unavailable_state.touchmenu)
        assert.are.equal("Library category picker settings are unavailable.", unavailable_state.messages[#unavailable_state.messages])
    end)

    it("builds delete chapter settings and saves their changes", function()
        local plugin, state = installController()
        local download_items = findMenuItem(plugin:buildSettingsMenu(), "Downloads").sub_item_table

        assert.are.equal("Delete after manual mark-read: no", download_items[3].text_func())
        assert.are.equal("Delete while reading: Disabled", download_items[4].text_func())

        download_items[3].callback(state.touchmenu)

        assert.is_true(state.saved_delete_chapters_settings.delete_after_mark_read)
        assert.are.equal(1, state.refresh_count)
        assert.are.same({}, state.messages)

        download_items[4].callback(state.touchmenu)
        assert.are.equal(0, state.delete_finished_menu_options.current)

        state.delete_finished_menu_options.onSelect(2)

        assert.are.equal(2, state.saved_delete_chapters_settings.delete_finished_while_reading)
        assert.are.same({}, state.messages)
        assert.are.equal(2, state.delete_finished_menu_options.current)
        assert.are.equal("delete-finished-menu", state.delete_finished_menu_options.menu.name)
    end)
end)
