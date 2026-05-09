package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

local modules_to_clear = {
    "ffi/util",
    "gettext",
    "ui/uimanager",
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
        messages = {},
        refresh_count = 0,
        saved_languages = options.languages or { "en", "ru" },
        saved_browse_settings = options.browse_settings or {
            show_nsfw_sources = false,
            hide_in_library_results = false,
        },
        saved_parallel = options.parallel or 2,
        saved_keep_next = options.keep_next or 0,
        saved_category_behavior = options.category_behavior or "automatic",
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
                return { server_url = "https://suwayomi.example" }
            end,
            save = function(_, credentials)
                state.saved_credentials = credentials
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
                return ""
            end,
            loadMaxParallelChapterDownloads = function()
                return state.saved_parallel
            end,
            saveMaxParallelChapterDownloads = function(_, value)
                state.saved_parallel = value
                return value
            end,
            loadKeepNextUnreadDownloads = function()
                return state.saved_keep_next
            end,
            saveKeepNextUnreadDownloads = function(_, value)
                state.saved_keep_next = value
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
            showKeepNextUnreadDownloadsMenu = function(menu_options)
                state.keep_next_menu_options = menu_options
                return { name = "keep-next-unread-downloads-menu" }
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
    end
    function plugin:getDownloadDirectorySummary()
        return "not set"
    end
    function plugin:chooseDownloadDirectory(callback)
        state.choose_download_callback = callback
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

    it("exports settings dialog and settings menu methods", function()
        helper.assertControllerModule("suwayomi/plugin/settings_controller", {
            "showSettings",
            "showLoginDialog",
            "showDownloadDirectoryDialog",
            "buildSettingsMenu",
        })
    end)

    it("builds settings menu callbacks and saves login changes", function()
        local plugin, state = installController()
        local menu = plugin:showSettings()

        assert.are.equal("Connection", menu[1].text)
        assert.are.equal("Library", menu[2].text)
        assert.are.equal("Browse", menu[3].text)
        assert.are.equal("Downloads", menu[4].text)
        assert.are.equal("Login information", menu[1].sub_item_table[1].text)
        assert.is_true(menu[1].sub_item_table[1].keep_menu_open)

        menu[1].sub_item_table[1].callback(state.touchmenu)
        state.login_dialog_options.onSave({ server_url = "https://new.example" })

        assert.are.equal("https://new.example", state.saved_credentials.server_url)
        assert.are.equal(1, state.refresh_count)
        assert.are.equal("Suwayomi login settings saved for https://new.example.", state.messages[#state.messages])
    end)

    it("tracks source language state and refreshes settings when the language menu closes", function()
        local plugin, state = installController()
        local browse_items = plugin:buildSettingsMenu()[3].sub_item_table

        assert.are.equal("Source languages: EN, RU", browse_items[1].text_func())
        browse_items[1].callback(state.touchmenu)
        assert.is_true(state.language_menu_options.languages[1].enabled)
        assert.is_false(state.language_menu_options.languages[3].enabled)

        state.language_menu_options.onToggle("de", true)
        assert.are.same({ "en", "ru", "de" }, state.saved_languages)
        assert.are.equal("language-menu", state.language_menu_options.menu.name)

        state.language_menu_options.onClose()
        assert.are.equal(1, state.refresh_count)
        assert.are.equal("Suwayomi source languages saved: EN, RU, DE", state.messages[#state.messages])
    end)

    it("toggles browse settings through menu callbacks", function()
        local plugin, state = installController()
        local browse_items = plugin:buildSettingsMenu()[3].sub_item_table

        assert.are.equal("Show NSFW sources: no", browse_items[2].text_func())
        assert.are.equal("Hide in-library results: no", browse_items[3].text_func())

        browse_items[2].callback(state.touchmenu)
        browse_items[3].callback(state.touchmenu)

        assert.are.same({
            show_nsfw_sources = true,
            hide_in_library_results = true,
        }, state.saved_browse_settings)
        assert.are.equal(2, state.refresh_count)
        assert.are.equal("Suwayomi Browse setting saved.", state.messages[#state.messages])
    end)

    it("saves parallel download and keep-next settings from downloads settings", function()
        local plugin, state = installController({ keep_next = 10 })
        local download_items = plugin:buildSettingsMenu()[4].sub_item_table

        assert.are.equal("Parallel downloads: 2", download_items[2].text_func())
        download_items[2].callback(state.touchmenu)
        assert.are.same({ 1, 2, 3, 4 }, state.parallel_menu_options.choices)
        state.parallel_menu_options.onSelect(3)

        assert.are.equal(3, state.saved_parallel)
        assert.is_nil(plugin.download_queue)
        assert.are.equal("parallel-downloads-menu", state.parallel_menu_options.menu.name)
        assert.are.equal("Suwayomi parallel chapter downloads saved: 3", state.messages[#state.messages])

        assert.are.equal("Keep next unread downloaded: 10 chapters", download_items[3].text_func())
        download_items[3].callback(state.touchmenu)
        assert.are.same({ 0, 5, 10, 50 }, state.keep_next_menu_options.choices)
        state.keep_next_menu_options.onSelect(5)

        assert.are.equal(5, state.saved_keep_next)
        assert.are.equal("keep-next-unread-downloads-menu", state.keep_next_menu_options.menu.name)
        assert.are.equal("Keep next unread downloaded: 5 chapters", state.messages[#state.messages])
    end)

    it("saves category picker behavior and reports unavailable persistence", function()
        local plugin, state = installController()
        local library_item = plugin:buildSettingsMenu()[2].sub_item_table[1]

        assert.are.equal("Category picker: automatic", library_item.text_func())
        library_item.callback(state.touchmenu)
        assert.are.same({ "automatic", "always", "never" }, state.category_menu_options.choices)
        state.category_menu_options.onSelect("always")

        assert.are.equal("always", state.saved_category_behavior)
        assert.are.equal("library-category-picker-menu", state.category_menu_options.menu.name)
        assert.are.equal("Suwayomi library category picker saved: always", state.messages[#state.messages])

        local unavailable_plugin, unavailable_state = installController({ no_category_persistence = true })
        local unavailable_item = unavailable_plugin:buildSettingsMenu()[2].sub_item_table[1]
        assert.are.equal("Category picker: automatic", unavailable_item.text_func())
        unavailable_item.callback(unavailable_state.touchmenu)
        assert.are.equal("Library category picker settings are unavailable.", unavailable_state.messages[#unavailable_state.messages])
    end)
end)
