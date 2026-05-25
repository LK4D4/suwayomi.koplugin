package.path = "?.lua;" .. package.path

-- Source catalog specs cover filtering/cache/render delegation that used to
-- live in the Browse controller. Worker scheduling stays in controller specs.
local helper = require("spec/support/controller_module_spec_helper")

local settings_calls
local ui_calls
local next_tick_callbacks
local debug_logs

local function resetModules()
    for _, name in ipairs({
        "suwayomi/browse/source_catalog",
        "suwayomi/i18n",
        "suwayomi/source_languages",
        "suwayomi/settings",
        "suwayomi/ui",
        "ui/uimanager",
        "suwayomi/debug",
    }) do
        package.loaded[name] = nil
        package.preload[name] = nil
    end
end

local function installMarkerI18n()
    package.preload["suwayomi/i18n"] = function()
        return {
            t = function(text)
                return "tx:" .. tostring(text)
            end,
            f = function(text, ...)
                local values = { ... }
                return ("tx:" .. tostring(text)):gsub("%%(%d+)", function(index)
                    return tostring(values[tonumber(index)] or "")
                end)
            end,
        }
    end
end

local function stubDependencies()
    helper.stubControllerDependencies()
    installMarkerI18n()
    settings_calls = {}
    ui_calls = {}
    next_tick_callbacks = {}
    debug_logs = {}

    package.preload["ui/uimanager"] = function()
        return {
            nextTick = function(_, callback)
                table.insert(next_tick_callbacks, callback)
            end,
        }
    end

    package.preload["suwayomi/settings"] = function()
        return {
            loadSourceLanguages = function()
                return { "en" }
            end,
            loadSourceCache = function(_, credentials)
                settings_calls.loaded_cache_for = credentials
                local server_url = type(credentials) == "table" and credentials.server_url or credentials
                return { server_url = server_url, sources = { { id = "cached", lang = "en" } }, updated_at = 100 }
            end,
            saveSourceCache = function(_, credentials, sources, updated_at)
                local server_url = type(credentials) == "table" and credentials.server_url or credentials
                settings_calls.saved_cache = {
                    credentials = credentials,
                    server_url = server_url,
                    sources = sources,
                    updated_at = updated_at,
                }
                return settings_calls.saved_cache
            end,
        }
    end

    package.preload["suwayomi/ui"] = function()
        return {
            showSourcesMenu = function(sources, onSelect, options)
                ui_calls.shown_count = (ui_calls.shown_count or 0) + 1
                ui_calls.shown = {
                    sources = sources,
                    onSelect = onSelect,
                    options = options,
                }
                return { kind = "sources-menu" }
            end,
            updateSourcesMenu = function(menu, sources, onSelect, options)
                ui_calls.updated = {
                    menu = menu,
                    sources = sources,
                    onSelect = onSelect,
                    options = options,
                }
                return menu
            end,
            showLanguageMenu = function(options)
                ui_calls.language_menu = {
                    options = options,
                }
                return { kind = "language-menu" }
            end,
            showExtensionsMenu = function(extensions, onSelect, options)
                ui_calls.extensions_menu = {
                    extensions = extensions,
                    onSelect = onSelect,
                    options = options,
                }
                return { kind = "extensions-menu" }
            end,
            updateExtensionsMenu = function(menu, extensions, onSelect, options)
                ui_calls.updated_extensions_menu = {
                    menu = menu,
                    extensions = extensions,
                    onSelect = onSelect,
                    options = options,
                }
            end,
            showExtensionActionMenu = function(extension, onSelect, options)
                ui_calls.extension_actions = {
                    extension = extension,
                    onSelect = onSelect,
                    options = options,
                }
                return { kind = "extension-actions-menu" }
            end,
            updateLanguageMenu = function(menu, options, onToggle)
                ui_calls.updated_language_menu = {
                    menu = menu,
                    options = options,
                    onToggle = onToggle,
                }
            end,
        }
    end

    package.preload["suwayomi/debug"] = function()
        return {
            log = function(entry)
                table.insert(debug_logs, entry)
            end,
        }
    end
end

local function loadCatalog()
    resetModules()
    stubDependencies()
    return require("suwayomi/browse/source_catalog")
end

local function buildController(catalog, overrides)
    local controller
    controller = {
        messages = {},
        shown_sources = {},
        buildSourceLanguageSet = function(_, source_languages)
            local selected = {}
            for _, lang in ipairs(source_languages or {}) do
                selected[lang] = true
            end
            return selected
        end,
        loadBrowseSettings = function()
            return { show_nsfw_sources = false }
        end,
        getTitleBarMenuOptions = function(_, options)
            controller.title_menu_options = options
            return { title_bar_left_icon = "appbar.menu" }
        end,
        getClient = function()
            return {
                showGlobalSearch = function(_, sources)
                    controller.global_search_sources = sources
                    return "global-search"
                end,
                showMangaForSource = function(_, source)
                    controller.selected_source = source
                    return "manga-for-source"
                end,
            }
        end,
        showMessage = function(self, message)
            table.insert(self.messages, message)
        end,
    }
    for name, method in pairs(catalog.methods) do
        controller[name] = method
    end
    for key, value in pairs(overrides or {}) do
        controller[key] = value
    end
    return controller
end

describe("suwayomi/browse/source_catalog", function()
    after_each(resetModules)

    it("exports plugin-bound source catalog methods", function()
        local catalog = loadCatalog()

        assert(type(catalog) == "table")
        assert(type(catalog.methods) == "table")
        assert(type(catalog.methods.sourceMatchesBrowseSettings) == "function")
        assert(type(catalog.methods.getSourceLanguageFilterChoices) == "function")
        assert(type(catalog.methods.setSourceLanguageFilter) == "function")
        assert(type(catalog.methods.toggleSourceLanguageFilter) == "function")
        assert(type(catalog.methods.filterSourcesByLanguage) == "function")
        assert(type(catalog.methods.loadSourceCache) == "function")
        assert(type(catalog.methods.saveSourceCache) == "function")
        assert(type(catalog.methods.showSourceList) == "function")
        assert(type(catalog.methods.showFetchedSources) == "function")
        assert(type(catalog.methods.showCachedSources) == "function")
        assert(type(catalog.methods.showMangaForSource) == "function")
    end)

    it("filters sources to english by default while allowing local source language", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        local filtered = controller:filterSourcesByLanguage({
            { id = "english", lang = "en" },
            { id = "local", lang = "localsourcelang" },
            { id = "all", lang = "all" },
            { id = "spanish", lang = "es" },
            { id = "nsfw", lang = "en", is_nsfw = true },
        })

        assert.are.same({ "english", "local" }, { filtered[1].id, filtered[2].id })
    end)

    it("builds named source language choices from available sources", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        local choices = controller:getSourceLanguageFilterChoices({
            { id = "english", lang = "en" },
            { id = "local", lang = "localsourcelang" },
            { id = "all", lang = "all" },
            { id = "spanish", lang = "es" },
            { id = "japanese", lang = "ja" },
            { id = "duplicate", lang = "en" },
        })

        assert.are.same({
            { code = "all", label = "All", enabled = false },
            { code = "en", label = "English", enabled = true },
            { code = "es", label = "Español", enabled = false },
            { code = "ja", label = "日本語", enabled = false },
        }, choices)
    end)

    it("refreshes the source list when Browse language filters change", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        controller:showFetchedSources({
            ok = true,
            sources = {
                { id = "english", lang = "en" },
                { id = "spanish", lang = "es" },
                { id = "japanese", lang = "ja" },
            },
        }, { credentials = { server_url = "https://suwayomi.example" } })

        assert.are.same({ "english" }, { ui_calls.shown.sources[1].id })
        local source_menu = controller.current_sources_menu

        controller.title_menu_options.onSelect({ id = "source_language_filter" }, nil, { anchor = "anchor" })
        assert.are.equal("tx:Source languages", ui_calls.language_menu.options.title)
        assert.are.same(source_menu, controller.current_sources_menu)
        assert.are.same({
            { code = "en", label = "English", enabled = true },
            { code = "es", label = "Español", enabled = false },
            { code = "ja", label = "日本語", enabled = false },
        }, ui_calls.language_menu.options.languages)

        ui_calls.language_menu.options.onToggle("es", true)

        assert.are.same({ "english", "spanish" }, {
            ui_calls.updated.sources[1].id,
            ui_calls.updated.sources[2].id,
        })
        assert.are.same(source_menu, ui_calls.updated.menu)
        assert.are.same(source_menu, controller.current_sources_menu)
        assert.are.same({
            { code = "en", label = "English", enabled = true },
            { code = "es", label = "Español", enabled = true },
            { code = "ja", label = "日本語", enabled = false },
        }, ui_calls.updated_language_menu.options.languages)

        ui_calls.updated_language_menu.onToggle("en", false)

        assert.are.same({ "spanish" }, { ui_calls.updated.sources[1].id })
        assert.are.same({ server_url = "https://suwayomi.example" }, ui_calls.updated.options.thumbnail_credentials)
    end)

    it("adds Extensions to the source title menu", function()
        local catalog = loadCatalog()
        local started
        local controller = buildController(catalog, {
            showExtensions = function()
                started = true
            end,
        })

        controller:showFetchedSources({
            ok = true,
            sources = {
                { id = "english", lang = "en" },
            },
        }, { credentials = { server_url = "https://suwayomi.example" } })

        assert.are.equal("extensions", controller.title_menu_options.actions[3].id)
        controller.title_menu_options.onSelect({ id = "extensions" })
        assert.is_true(started)
    end)

    it("filters multiple selected source languages plus local source", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        controller:toggleSourceLanguageFilter("es", true)

        local filtered = controller:filterSourcesByLanguage({
            { id = "english", lang = "en" },
            { id = "spanish", lang = "es" },
            { id = "japanese", lang = "ja" },
            { id = "local", lang = "localsourcelang" },
        })

        assert.are.same({ "english", "spanish", "local" }, {
            filtered[1].id,
            filtered[2].id,
            filtered[3].id,
        })
    end)

    it("allows nsfw sources when browse settings opt in", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog, {
            loadBrowseSettings = function()
                return { show_nsfw_sources = true }
            end,
        })

        local filtered = controller:filterSourcesByLanguage({
            { id = "nsfw", lang = "en", is_nsfw = true },
        })

        assert.are.equal("nsfw", filtered[1].id)
    end)

    it("loads and saves the source cache for the credential server url", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        local cache = controller:loadSourceCache({ server_url = "https://suwayomi.example" })
        local saved = controller:saveSourceCache({ server_url = "https://suwayomi.example" }, {
            { id = "saved", lang = "en" },
        })

        assert.are.equal("https://suwayomi.example", settings_calls.loaded_cache_for.server_url)
        assert.are.equal("cached", cache.sources[1].id)
        assert.are.equal("https://suwayomi.example", settings_calls.saved_cache.credentials.server_url)
        assert.are.equal("https://suwayomi.example", settings_calls.saved_cache.server_url)
        assert.are.equal("saved", settings_calls.saved_cache.sources[1].id)
        assert(type(settings_calls.saved_cache.updated_at) == "number")
        assert.are.same(settings_calls.saved_cache, saved)
    end)

    it("saves, filters, logs, and renders fetched sources", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        controller:showFetchedSources({
            ok = true,
            sources = {
                { id = "english", lang = "en" },
                { id = "spanish", lang = "es" },
            },
        }, { credentials = { server_url = "https://suwayomi.example" } })

        assert.are.equal("https://suwayomi.example", settings_calls.saved_cache.server_url)
        assert.are.same({ "english" }, { ui_calls.shown.sources[1].id })
        assert.are.same({ server_url = "https://suwayomi.example" }, ui_calls.shown.options.thumbnail_credentials)
        assert.are.equal("sources_loaded", debug_logs[1].event)
        assert.are.equal(2, debug_logs[1].source_count)
        assert.are.equal(1, debug_logs[1].filtered_source_count)
    end)

    it("ignores corrupt non-table source rows when rendering fetched sources", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        controller:showFetchedSources({
            ok = true,
            sources = {
                "broken",
                true,
                7,
                { id = "english", lang = "en" },
            },
        })

        assert.are.same({ "english" }, { ui_calls.shown.sources[1].id })
        assert.are.equal(4, debug_logs[1].source_count)
        assert.are.equal(1, debug_logs[1].filtered_source_count)
    end)

    it("saves silent refreshed sources without reopening a closed source menu", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        local rendered = controller:showFetchedSources({
            ok = true,
            sources = {
                { id = "english", lang = "en" },
            },
        }, {
            credentials = { server_url = "https://suwayomi.example" },
            silent = true,
            refresh = true,
        })

        assert.is_true(rendered)
        assert.are.equal("english", settings_calls.saved_cache.sources[1].id)
        assert.is_nil(ui_calls.shown)
        assert.is_nil(ui_calls.updated)
        assert.are.equal("sources_refreshed", debug_logs[1].event)
    end)

    it("keeps the Browse source menu reachable when the default language has no matches", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        controller:showFetchedSources({
            ok = true,
            sources = {
                { id = "spanish", lang = "es" },
            },
        }, { credentials = { server_url = "https://suwayomi.example" } })

        assert.are.equal(0, #ui_calls.shown.sources)
        assert.are.equal("source_language_filter", controller.title_menu_options.actions[2].id)
        assert.are.equal("tx:Source languages: English", controller.title_menu_options.actions[2].text)

        controller.title_menu_options.onSelect({ id = "source_language_filter" })
        ui_calls.language_menu.options.onToggle("es", true)

        assert.are.same({ "spanish" }, { ui_calls.updated.sources[1].id })
    end)

    it("omits the Browse language action when no source languages exist", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        controller:showFetchedSources({
            ok = true,
            sources = {
                { id = "local", lang = "localsourcelang" },
            },
        })

        assert.are.equal("global_search", controller.title_menu_options.actions[1].id)
        assert.are.equal("extensions", controller.title_menu_options.actions[2].id)
        assert.is_nil(controller.title_menu_options.actions[3])
    end)

    it("reports fetched source failures unless silent", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        controller:showFetchedSources(nil)
        controller:showFetchedSources({ ok = false, error = "boom" })
        controller:showFetchedSources({ ok = false, error = "quiet" }, { silent = true })

        assert.are.same({ "tx:Could not load Suwayomi sources.", "boom" }, controller.messages)
    end)

    it("keeps language labels raw while translating language menu chrome", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        controller:showFetchedSources({
            ok = true,
            sources = {
                { id = "english", lang = "en" },
                { id = "spanish", lang = "es" },
            },
        }, { credentials = { server_url = "https://suwayomi.example" } })

        controller.title_menu_options.onSelect({ id = "source_language_filter" })

        assert.are.equal("tx:Source languages", ui_calls.language_menu.options.title)
        assert.are.same({
            { code = "en", label = "English", enabled = true },
            { code = "es", label = "Español", enabled = false },
        }, ui_calls.language_menu.options.languages)
    end)

    it("translates title-bar actions while keeping source names raw", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        controller:showSourceList({
            { id = "mangadex", name = "MangaDex", lang = "en" },
        }, {
            credentials = { server_url = "https://suwayomi.example" },
        })

        assert.are.equal("tx:Suwayomi Sources", controller.title_menu_options.title)
        assert.are.equal("tx:Global search", controller.title_menu_options.actions[1].text)
        assert.are.equal("tx:Source languages: English", controller.title_menu_options.actions[2].text)
        assert.are.equal("tx:Extensions", controller.title_menu_options.actions[3].text)
        assert.are.equal("MangaDex", ui_calls.shown.sources[1].name)
    end)

    it("translates source load failure fallback and empty-language feedback", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        controller:showFetchedSources(nil)
        controller:showFetchedSources({ ok = false })
        controller:showFetchedSources({
            ok = true,
            sources = {},
        })

        assert.are.same({
            "tx:Could not load Suwayomi sources.",
            "tx:Could not load Suwayomi sources.",
            "tx:No Suwayomi sources match the selected languages.",
        }, controller.messages)
    end)

    it("renders cached sources with a new menu when any source survives filtering", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        local rendered = controller:showCachedSources({
            sources = {
                { id = "english", lang = "en" },
                { id = "spanish", lang = "es" },
            },
            updated_at = os.time() - 5,
        }, {
            credentials = { server_url = "https://suwayomi.example" },
        })

        assert.is_true(rendered)
        assert.are.equal("english", ui_calls.shown.sources[1].id)
        assert.are.same({ server_url = "https://suwayomi.example" }, ui_calls.shown.options.thumbnail_credentials)
        assert.are.equal("source_cache_hit", debug_logs[1].event)
    end)

    it("renders cached source menu controls when the current language removes all sources", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        local rendered = controller:showCachedSources({
            sources = {
                { id = "spanish", lang = "es" },
            },
        })

        assert.is_true(rendered)
        assert.are.equal(0, #ui_calls.shown.sources)
        assert.are.equal("source_language_filter", controller.title_menu_options.actions[2].id)
    end)

    it("updates an existing source menu and keeps global search in the title menu", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)
        controller.current_sources_menu = { kind = "existing-menu" }

        local menu = controller:showSourceList({ { id = "english", lang = "en" } }, {
            credentials = { server_url = "https://suwayomi.example" },
        })
        local search_result = controller.title_menu_options.onSelect(controller.title_menu_options.actions[1])
        local manga_result = controller:showMangaForSource({ id = "english" })

        assert.are.same(controller.current_sources_menu, menu)
        assert.are.equal("tx:Suwayomi Sources", controller.title_menu_options.title)
        assert.are.equal("global_search", controller.title_menu_options.actions[1].id)
        assert.are.equal("source_language_filter", controller.title_menu_options.actions[2].id)
        assert.are.equal("tx:Global search", controller.title_menu_options.actions[1].text)
        assert.are.equal("tx:Source languages: English", controller.title_menu_options.actions[2].text)
        assert.are.equal("tx:Extensions", controller.title_menu_options.actions[3].text)
        assert.are.equal("appbar.menu", ui_calls.updated.options.title_bar_left_icon)
        assert.are.same({ server_url = "https://suwayomi.example" }, ui_calls.updated.options.thumbnail_credentials)
        assert.is_nil(ui_calls.updated.options.on_global_search)
        assert.are.equal("global-search", search_result)
        assert.are.equal("manga-for-source", manga_result)
        assert.are.equal("english", controller.global_search_sources[1].id)
        assert.are.equal("english", controller.selected_source.id)
    end)

    it("defers source row selection until the sources menu finishes handling the tap", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        controller:showSourceList({ { id = "english", lang = "en" } })
        ui_calls.shown.onSelect({ id = "english" })

        assert.is_nil(controller.selected_source)
        assert.are.equal(1, #next_tick_callbacks)

        next_tick_callbacks[1]()

        assert.are.equal("english", controller.selected_source.id)
    end)

    it("clears stale source menu state when the sources menu closes", function()
        local catalog = loadCatalog()
        local controller = buildController(catalog)

        local menu = controller:showSourceList({ { id = "english", lang = "en" } })
        assert.are.same(menu, controller.current_sources_menu)
        assert.is_function(ui_calls.shown.options.close_callback)

        ui_calls.shown.options.close_callback()

        assert.is_nil(controller.current_sources_menu)

        controller:showSourceList({ { id = "local", lang = "localsourcelang" } })

        assert.are.equal(2, ui_calls.shown_count)
        assert.is_nil(ui_calls.updated)
    end)
end)
