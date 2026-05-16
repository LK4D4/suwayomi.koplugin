package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

local ui_calls

local function resetModules()
    for _, name in ipairs({
        "suwayomi/browse/extensions",
        "suwayomi/ui",
        "suwayomi/settings",
        "suwayomi/subprocess/job",
        "suwayomi/browse/extension_worker",
    }) do
        package.loaded[name] = nil
        package.preload[name] = nil
    end
end

local function stubDependencies(options)
    options = options or {}
    helper.stubControllerDependencies()
    ui_calls = {}

    package.preload["suwayomi/ui"] = function()
        return {
            showExtensionsMenu = function(extensions, onSelect, menu_options)
                ui_calls.extensions_menu = {
                    extensions = extensions,
                    onSelect = onSelect,
                    options = menu_options,
                }
                return { kind = "extensions-menu" }
            end,
            updateExtensionsMenu = function(menu, extensions, onSelect, menu_options)
                ui_calls.updated_extensions_menu = {
                    menu = menu,
                    extensions = extensions,
                    onSelect = onSelect,
                    options = menu_options,
                }
            end,
            showExtensionActionMenu = function(extension, onSelect, menu_options)
                ui_calls.extension_actions = {
                    extension = extension,
                    onSelect = onSelect,
                    options = menu_options,
                }
                return { kind = "extension-actions-menu" }
            end,
            showExtensionSearchPrompt = function(query, onSearch)
                ui_calls.extension_search_prompt = {
                    query = query,
                    onSearch = onSearch,
                }
                return { kind = "extension-search-prompt" }
            end,
        }
    end

    package.preload["suwayomi/settings"] = function()
        return {
            load = function()
                return options.credentials or { server_url = "https://suwayomi.example" }
            end,
        }
    end

    package.preload["suwayomi/browse/extension_worker"] = function()
        return {
            run = function() end,
            readResult = function() end,
        }
    end
end

local function loadExtensions(options)
    resetModules()
    stubDependencies(options)
    return require("suwayomi/browse/extensions")
end

local function loadExtensionsWithSubprocessStub(onStart)
    resetModules()
    stubDependencies()
    package.preload["suwayomi/subprocess/job"] = function()
        return {
            buildResultPath = function()
                return "/settings/extensions.json"
            end,
            start = function(options)
                if onStart then
                    onStart(options)
                end
                return options.active
            end,
            schedulePoll = function() end,
            poll = function() end,
        }
    end
    return require("suwayomi/browse/extensions")
end

local function buildController(extension_module, overrides)
    local controller
    controller = {
        messages = {},
        saved_source_cache = nil,
        getTitleBarMenuOptions = function(_, options)
            controller.title_menu_options = options
            return { title_bar_left_icon = "appbar.menu" }
        end,
        showMessage = function(self, message)
            table.insert(self.messages, message)
        end,
        showLoadingMessage = function(_, message)
            return { message = message }
        end,
        closeLoadingMessage = function(_, loading_message)
            controller.closed_loading = loading_message
        end,
        saveSourceCache = function(_, credentials, sources)
            controller.saved_source_cache = {
                credentials = credentials,
                sources = sources,
            }
        end,
    }
    for name, method in pairs(extension_module.methods) do
        controller[name] = method
    end
    for key, value in pairs(overrides or {}) do
        controller[key] = value
    end
    return controller
end

describe("suwayomi/browse/extensions", function()
    after_each(resetModules)

    it("exports plugin-bound extension management methods", function()
        local extensions = loadExtensions()

        assert(type(extensions.methods.showExtensions) == "function")
        assert(type(extensions.methods.showFetchedExtensions) == "function")
        assert(type(extensions.methods.showExtensionActions) == "function")
        assert(type(extensions.methods.startExtensionWorker) == "function")
        assert(type(extensions.methods.pollExtensionWorker) == "function")
    end)

    it("opens onboarding setup when extension credentials are missing", function()
        local extensions = loadExtensions({ credentials = { server_url = "" } })
        local controller = buildController(extensions, {
            showOnboardingSetup = function(self, options)
                self.setup_options = options
            end,
            startExtensionWorker = function()
                error("unexpected worker")
            end,
        })

        controller:showExtensions()

        assert.are.equal("Set up your Suwayomi server login first.", controller.messages[#controller.messages])
        assert.is_true(controller.setup_options.first_run)
    end)

    it("renders fetched extension rows with refresh action", function()
        local extensions = loadExtensions()
        local started
        local controller = buildController(extensions, {
            startExtensionWorker = function(_, credentials, request)
                started = {
                    credentials = credentials,
                    request = request,
                }
            end,
        })

        controller:showFetchedExtensions({
            ok = true,
            extensions = {
                { pkg_name = "pkg.mangadex", name = "MangaDex" },
            },
        }, { credentials = { server_url = "https://suwayomi.example" } })

        assert.are.equal("pkg.mangadex", ui_calls.extensions_menu.extensions[1].pkg_name)
        assert.are.equal("search_extensions", controller.title_menu_options.actions[1].id)
        assert.are.equal("refresh_extensions", controller.title_menu_options.actions[2].id)
        controller.title_menu_options.onSelect(controller.title_menu_options.actions[2])
        assert.are.equal("fetch", started.request.action)
    end)

    it("filters fetched extensions from title menu search and clears the query", function()
        local extensions = loadExtensions()
        local controller = buildController(extensions)

        controller:showFetchedExtensions({
            ok = true,
            extensions = {
                { pkg_name = "pkg.akuma", name = "Akuma", lang = "en", is_installed = true },
                { pkg_name = "pkg.buondua", name = "Buon Dua", lang = "vi", is_installed = false },
                { pkg_name = "pkg.comick", name = "Comick", lang = "all", has_update = true },
            },
        }, { credentials = { server_url = "https://suwayomi.example" } })

        assert.are.equal("search_extensions", controller.title_menu_options.actions[1].id)
        controller.title_menu_options.onSelect({ id = "search_extensions" })
        assert.are.equal("", ui_calls.extension_search_prompt.query)

        ui_calls.extension_search_prompt.onSearch(" buon ")

        assert.are.equal("buon", controller.current_extension_search_query)
        assert.are.equal("pkg.buondua", ui_calls.updated_extensions_menu.extensions[1].pkg_name)
        assert.are.equal(1, #ui_calls.updated_extensions_menu.extensions)
        assert.are.equal("clear_extension_search", controller.title_menu_options.actions[2].id)

        controller.title_menu_options.onSelect({ id = "clear_extension_search" })

        assert.are.equal("", controller.current_extension_search_query)
        assert.are.equal(3, #ui_calls.updated_extensions_menu.extensions)
        assert.are.equal("search_extensions", controller.title_menu_options.actions[1].id)
        assert.are.equal("refresh_extensions", controller.title_menu_options.actions[2].id)
    end)

    it("keeps the tracked extensions screen current after search updates", function()
        local extensions = loadExtensions()
        local tracked = {}
        local controller = buildController(extensions, {
            trackSuwayomiScreen = function(_, route_id, menu)
                table.insert(tracked, {
                    route_id = route_id,
                    menu = menu,
                })
            end,
        })

        controller:showFetchedExtensions({
            ok = true,
            extensions = {
                { pkg_name = "pkg.akuma", name = "Akuma", is_installed = true },
                { pkg_name = "pkg.buondua", name = "Buon Dua", is_installed = false },
            },
        }, { credentials = { server_url = "https://suwayomi.example" } })

        controller.title_menu_options.onSelect({ id = "search_extensions" })
        ui_calls.extension_search_prompt.onSearch("buon")

        controller.title_menu_options.onSelect({ id = "clear_extension_search" })

        assert.are.equal(3, #tracked)
        assert.are.equal("browse-extensions", tracked[1].route_id)
        assert.are.equal(tracked[1].menu, tracked[2].menu)
        assert.are.equal(tracked[1].menu, tracked[3].menu)
    end)

    it("clears active extension search when closing filtered results", function()
        local extensions = loadExtensions()
        local controller = buildController(extensions)

        controller:showFetchedExtensions({
            ok = true,
            extensions = {
                { pkg_name = "pkg.akuma", name = "Akuma", is_installed = true },
                { pkg_name = "pkg.buondua", name = "Buon Dua", is_installed = false },
            },
        }, { credentials = { server_url = "https://suwayomi.example" } })

        controller.title_menu_options.onSelect({ id = "search_extensions" })
        ui_calls.extension_search_prompt.onSearch("buon")

        assert.is_function(ui_calls.updated_extensions_menu.options.on_close)
        assert.is_true(ui_calls.updated_extensions_menu.options.on_close())
        assert.are.equal("", controller.current_extension_search_query)
        assert.are.equal(2, #ui_calls.updated_extensions_menu.extensions)
    end)

    it("opens extension list fetches as a new menu", function()
        local extensions = loadExtensions()
        local started
        local controller = buildController(extensions, {
            startExtensionWorker = function(_, credentials, request, options)
                started = {
                    credentials = credentials,
                    request = request,
                    options = options,
                }
            end,
        })

        controller:showExtensions()

        assert.are.equal("fetch", started.request.action)
        assert.is_true(started.options.force_new)
    end)

    it("shows feedback when an extension task is already running", function()
        local extensions = loadExtensions()
        local controller = buildController(extensions, {
            extension_worker_active = { request = { action = "install" } },
        })

        local started = controller:startExtensionWorker({ server_url = "https://suwayomi.example" }, {
            action = "install",
            pkg_name = "pkg.mangadex",
        })

        assert.is_false(started)
        assert.are.same({ "Extension task already running." }, controller.messages)
    end)

    it("clears active extension fetch state and closes loading UI on timeout", function()
        local started_options
        local extensions = loadExtensionsWithSubprocessStub(function(options)
            started_options = options
        end)
        local controller = buildController(extensions)

        assert.is_true(controller:startExtensionWorker({ server_url = "https://suwayomi.example" }, {
            action = "fetch",
        }))
        started_options.active.loading_message = { message = "Loading extensions..." }
        started_options.on_timeout(started_options.active)

        assert.is_nil(controller.extension_worker_active)
        assert.are.equal("Loading extensions...", controller.closed_loading.message)
        assert.are.same({ "Extension list loading timed out." }, controller.messages)
        assert.is_true(controller:startExtensionWorker({ server_url = "https://suwayomi.example" }, {
            action = "fetch",
        }))
    end)

    it("uses action-aware timeout feedback for extension mutations", function()
        local started_options
        local extensions = loadExtensionsWithSubprocessStub(function(options)
            started_options = options
        end)
        local controller = buildController(extensions)

        assert.is_true(controller:startExtensionWorker({ server_url = "https://suwayomi.example" }, {
            action = "install",
            pkg_name = "pkg.mangadex",
        }))
        started_options.active.loading_message = { message = "Installing extension..." }
        started_options.on_timeout(started_options.active)

        assert.is_nil(controller.extension_worker_active)
        assert.are.equal("Installing extension...", controller.closed_loading.message)
        assert.are.same({ "Extension install timed out." }, controller.messages)
        assert.is_true(controller:startExtensionWorker({ server_url = "https://suwayomi.example" }, {
            action = "update",
            pkg_name = "pkg.mangadex",
        }))
    end)

    it("starts install/update actions from extension action menus", function()
        local extensions = loadExtensions()
        local started
        local controller = buildController(extensions, {
            current_extension_credentials = { server_url = "https://suwayomi.example" },
            startExtensionWorker = function(_, credentials, request)
                started = {
                    credentials = credentials,
                    request = request,
                }
            end,
        })

        controller:showExtensionActions({
            pkg_name = "pkg.mangadex",
            name = "MangaDex",
            is_installed = false,
        })

        ui_calls.extension_actions.onSelect("install")

        assert.are.equal("install", started.request.action)
        assert.are.equal("pkg.mangadex", started.request.pkg_name)
        assert.are.equal("https://suwayomi.example", started.credentials.server_url)
    end)

    it("starts uninstall actions from installed extension action menus", function()
        local extensions = loadExtensions()
        local started
        local controller = buildController(extensions, {
            current_extension_credentials = { server_url = "https://suwayomi.example" },
            startExtensionWorker = function(_, credentials, request, options)
                started = {
                    credentials = credentials,
                    request = request,
                    options = options,
                }
            end,
        })

        controller:showExtensionActions({
            pkg_name = "pkg.mangadex",
            name = "MangaDex",
            is_installed = true,
        })

        ui_calls.extension_actions.onSelect("uninstall")

        assert.are.equal("uninstall", started.request.action)
        assert.are.equal("pkg.mangadex", started.request.pkg_name)
        assert.are.equal("https://suwayomi.example", started.credentials.server_url)
        assert.are.equal("Uninstalling extension...", started.options.loading_message)
    end)

    it("updates source cache from successful install results without showing source menu", function()
        local extensions = loadExtensions()
        local controller = buildController(extensions)

        controller:finishExtensionWorker({
            credentials = { server_url = "https://suwayomi.example" },
            loading_message = { message = "Installing extension..." },
        }, {
            ok = true,
            action = "install",
            sources = {
                { id = "source-mangadex", name = "MangaDex" },
            },
            extensions = {
                { pkg_name = "pkg.mangadex", name = "MangaDex", is_installed = true },
            },
        })

        assert.are.equal("source-mangadex", controller.saved_source_cache.sources[1].id)
        assert.are.equal("https://suwayomi.example", controller.saved_source_cache.credentials.server_url)
        assert.are.equal("pkg.mangadex", ui_calls.extensions_menu.extensions[1].pkg_name)
        assert.are.equal("Installing extension...", controller.closed_loading.message)
    end)

    it("keeps old source cache when extension update source refresh fails", function()
        local extensions = loadExtensions()
        local refreshed_sources
        local controller = buildController(extensions, {
            current_sources_menu = { kind = "sources-menu" },
            filterSourcesByLanguage = function(_, sources)
                return sources
            end,
            showSourceList = function(_, sources, options)
                refreshed_sources = {
                    sources = sources,
                    options = options,
                }
            end,
        })
        controller.saved_source_cache = {
            credentials = { server_url = "https://suwayomi.example" },
            sources = {
                { id = "old-source", name = "Old Source" },
            },
        }

        controller:finishExtensionWorker({
            credentials = { server_url = "https://suwayomi.example" },
            loading_message = { message = "Updating extension..." },
        }, {
            ok = true,
            action = "update",
            source_refresh_ok = false,
            source_refresh_error = "Connection timed out while waiting for Suwayomi.",
            sources = {},
            extensions = {
                { pkg_name = "pkg.mangadex", name = "MangaDex", is_installed = true },
            },
        })

        assert.are.equal("old-source", controller.saved_source_cache.sources[1].id)
        assert.is_nil(refreshed_sources)
        assert.are.equal("pkg.mangadex", ui_calls.extensions_menu.extensions[1].pkg_name)
        assert.are.equal("Updating extension...", controller.closed_loading.message)
    end)

    it("does not clear source cache from extension list fetch results", function()
        local extensions = loadExtensions()
        local controller = buildController(extensions)
        controller.saved_source_cache = {
            credentials = { server_url = "https://suwayomi.example" },
            sources = {
                { id = "old-source", name = "Old Source" },
            },
        }

        controller:finishExtensionWorker({
            credentials = { server_url = "https://suwayomi.example" },
        }, {
            ok = true,
            action = "fetch",
            sources = {},
            extensions = {
                { pkg_name = "pkg.mangadex", name = "MangaDex", is_installed = false },
            },
        })

        assert.are.equal("old-source", controller.saved_source_cache.sources[1].id)
        assert.are.equal("pkg.mangadex", ui_calls.extensions_menu.extensions[1].pkg_name)
    end)

    it("refreshes an open source menu after extension install changes sources", function()
        local extensions = loadExtensions()
        local refreshed_sources
        local controller = buildController(extensions, {
            current_sources_menu = { kind = "sources-menu" },
            filterSourcesByLanguage = function(_, sources)
                return sources
            end,
            showSourceList = function(_, sources, options)
                refreshed_sources = {
                    sources = sources,
                    options = options,
                }
            end,
        })

        controller:finishExtensionWorker({
            credentials = { server_url = "https://suwayomi.example" },
        }, {
            ok = true,
            action = "install",
            sources = {
                { id = "source-mangadex", name = "MangaDex" },
            },
            extensions = {
                { pkg_name = "pkg.mangadex", name = "MangaDex", is_installed = true },
            },
        })

        assert.are.equal("source-mangadex", refreshed_sources.sources[1].id)
        assert.are.equal("source-mangadex", refreshed_sources.options.all_sources[1].id)
        assert.are.equal("https://suwayomi.example", refreshed_sources.options.credentials.server_url)
    end)

    it("refreshes an open source menu after extension uninstall removes all sources", function()
        local extensions = loadExtensions()
        local refreshed_sources
        local controller = buildController(extensions, {
            current_sources_menu = { kind = "sources-menu" },
            filterSourcesByLanguage = function(_, sources)
                return sources
            end,
            showSourceList = function(_, sources, options)
                refreshed_sources = {
                    sources = sources,
                    options = options,
                }
            end,
        })

        controller:finishExtensionWorker({
            credentials = { server_url = "https://suwayomi.example" },
        }, {
            ok = true,
            action = "uninstall",
            sources = {},
            extensions = {
                { pkg_name = "pkg.mangadex", name = "MangaDex", is_installed = false },
            },
        })

        assert.are.equal(0, #controller.saved_source_cache.sources)
        assert.are.equal(0, #refreshed_sources.sources)
        assert.are.equal(0, #refreshed_sources.options.all_sources)
    end)
end)
