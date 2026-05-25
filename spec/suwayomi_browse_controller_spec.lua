package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

local function clearModules()
    for _, name in ipairs({
        "suwayomi/browse/controller",
        "suwayomi/browse/source_catalog",
        "suwayomi/browse/extensions",
        "suwayomi/browse/source_fetch_worker",
        "suwayomi/i18n",
        "suwayomi/subprocess/job",
        "suwayomi/settings",
        "suwayomi/debug",
        "ui/uimanager",
        "ffi/util",
        "gettext",
    }) do
        package.loaded[name] = nil
        package.preload[name] = nil
    end
end

local function installMarkerI18n()
    package.preload["suwayomi/i18n"] = function()
        return {
            t = function(text)
                return "tx:" .. text
            end,
            f = function(text, ...)
                local args = { ... }
                return "tx:" .. (text:gsub("%%(%d+)", function(index)
                    return tostring(args[tonumber(index)])
                end))
            end,
        }
    end
end

local function installControllerWithSourceFetchStub(config)
    config = config or {}
    clearModules()
    helper.stubControllerDependencies()
    installMarkerI18n()
    local started_options
    local scheduled_callback
    package.preload["ui/uimanager"] = function()
        return {
            scheduleIn = function(_, _, callback)
                scheduled_callback = callback
            end,
        }
    end
    package.preload["suwayomi/browse/source_catalog"] = function()
        return { methods = {} }
    end
    package.preload["suwayomi/browse/extensions"] = function()
        return { methods = {} }
    end
    package.preload["suwayomi/browse/source_fetch_worker"] = function()
        return {
            run = function() end,
            readResult = function() end,
        }
    end
    package.preload["suwayomi/subprocess/job"] = function()
        return {
            buildResultPath = function()
                return "/settings/source_fetch.json"
            end,
            start = function(options)
                started_options = options
                return options.active
            end,
            schedulePoll = function() end,
            poll = function() end,
        }
    end
    package.preload["suwayomi/settings"] = function()
        return {
            load = function()
                return config.credentials or { server_url = "https://suwayomi.example" }
            end,
        }
    end
    package.preload["suwayomi/debug"] = function()
        return {
            time = function(_, callback)
                return callback()
            end,
        }
    end

    return require("suwayomi/browse/controller"), function()
        return started_options
    end, function()
        return scheduled_callback
    end
end

local function buildController(controller_module)
    local controller
    controller = {
        messages = {},
        showMessage = function(self, message)
            table.insert(self.messages, message)
        end,
        showLoadingMessage = function(_, message)
            return { message = message }
        end,
        closeLoadingMessage = function(_, loading_message)
            controller.closed_loading = loading_message
        end,
    }
    for name, method in pairs(controller_module.methods) do
        controller[name] = method
    end
    return controller
end

describe("suwayomi/browse/controller", function()
    after_each(clearModules)

    it("exports source cache, worker, and browse flow methods", function()
        helper.assertControllerModule("suwayomi/browse/controller", {
            "filterSourcesByLanguage",
            "showFetchedSources",
            "showCachedSources",
            "showMangaForSource",
            "startSourceFetchWorker",
            "pollSourceFetch",
            "browseSuwayomi",
            "showExtensions",
            "startExtensionWorker",
            "pollExtensionWorker",
        })
    end)

    it("clears active source fetch state and closes loading UI on timeout", function()
        local controller_module, get_started_options = installControllerWithSourceFetchStub()
        local controller = buildController(controller_module)

        assert.is_true(controller:startSourceFetchWorker({ server_url = "https://suwayomi.example" }))
        local started_options = get_started_options()
        started_options.active.loading_message = { message = "Loading sources..." }
        started_options.on_timeout(started_options.active)

        assert.is_nil(controller.source_fetch_active)
        assert.are.equal("Loading sources...", controller.closed_loading.message)
        assert.are.same({ "tx:Source loading timed out." }, controller.messages)
        assert.is_true(controller:startSourceFetchWorker({ server_url = "https://suwayomi.example" }))
    end)

    it("translates source fetch loading, timeout, and startup errors", function()
        local controller_module, get_started_options = installControllerWithSourceFetchStub()
        local controller = buildController(controller_module)

        assert.is_true(controller:startSourceFetchWorker({ server_url = "https://suwayomi.example" }))
        local started_options = get_started_options()

        assert.are.equal("tx:Loading sources...", started_options.active.loading_message.message)

        started_options.on_timeout(started_options.active)
        assert.are.same({ "tx:Source loading timed out." }, controller.messages)

        controller.messages = {}
        package.loaded["suwayomi/browse/controller"] = nil
        package.loaded["suwayomi/subprocess/job"] = nil
        package.preload["suwayomi/subprocess/job"] = function()
            return {
                buildResultPath = function()
                    return "/settings/source_fetch.json"
                end,
                start = function(options)
                    options.on_error("spawn failed")
                    return nil
                end,
                schedulePoll = function() end,
                poll = function() end,
            }
        end

        controller_module = require("suwayomi/browse/controller")
        controller = buildController(controller_module)

        assert.is_false(controller:startSourceFetchWorker({ server_url = "https://suwayomi.example" }))
        assert.are.same({ "tx:Could not start source loading: spawn failed" }, controller.messages)
    end)

    it("keeps silent source fetch timeout cleanup quiet", function()
        local controller_module, get_started_options = installControllerWithSourceFetchStub()
        local controller = buildController(controller_module)

        assert.is_true(controller:startSourceFetchWorker({ server_url = "https://suwayomi.example" }, {
            silent = true,
        }))
        local started_options = get_started_options()
        started_options.on_timeout(started_options.active)

        assert.is_nil(controller.source_fetch_active)
        assert.are.same({}, controller.messages)
    end)

    it("cancels source fetch workers and ignores late completions after plugin close", function()
        local started_options
        local canceled = {}
        clearModules()
        helper.stubControllerDependencies()
        package.preload["ui/uimanager"] = function()
            return {
                scheduleIn = function() end,
            }
        end
        package.preload["suwayomi/browse/source_catalog"] = function()
            return { methods = {} }
        end
        package.preload["suwayomi/browse/extensions"] = function()
            return { methods = {} }
        end
        package.preload["suwayomi/browse/source_fetch_worker"] = function()
            return {
                run = function() end,
                readResult = function() end,
            }
        end
        package.preload["suwayomi/subprocess/job"] = function()
            return {
                buildResultPath = function()
                    return "/settings/source_fetch.json"
                end,
                start = function(options)
                    started_options = options
                    return options.active
                end,
                cancel = function(active)
                    table.insert(canceled, active)
                    active.canceled = true
                end,
                schedulePoll = function() end,
                poll = function() end,
            }
        end
        package.preload["suwayomi/settings"] = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example" }
                end,
            }
        end
        package.preload["suwayomi/debug"] = function()
            return {
                time = function(_, callback)
                    return callback()
                end,
            }
        end

        local controller_module = require("suwayomi/browse/controller")
        local controller = buildController(controller_module)
        local rendered = false
        controller.showFetchedSources = function()
            rendered = true
        end

        assert.is_true(controller:startSourceFetchWorker({ server_url = "https://suwayomi.example" }))
        assert.is_true(controller:cancelSourceFetchWorker())
        assert.are.equal(1, #canceled)
        assert.is_nil(controller.source_fetch_active)

        controller:finishSourceFetch(started_options.active, {
            ok = true,
            sources = {
                { id = "src", display_name = "Late Source" },
            },
        })

        assert.is_false(rendered)
    end)

    it("drops stale source fetch results after credentials change", function()
        local controller_module = installControllerWithSourceFetchStub({
            credentials = {
                server_url = "https://new.example",
                username = "bob",
                password = "secret",
                auth_method = "basic_auth",
            },
        })
        local controller = buildController(controller_module)
        local rendered
        controller.showFetchedSources = function()
            rendered = true
        end

        local result = controller:finishSourceFetch({
            credentials = {
                server_url = "https://old.example",
                username = "alice",
                password = "secret",
                auth_method = "basic_auth",
            },
            loading_message = { message = "Loading sources..." },
            options = {},
        }, {
            ok = true,
            sources = {
                { id = "source-mangadex" },
            },
        })

        assert.is_false(result)
        assert.is_nil(rendered)
        assert.are.equal("Loading sources...", controller.closed_loading.message)
    end)

    it("cancels scheduled silent source refresh when credentials change before timer fires", function()
        local config = {
            credentials = {
                server_url = "https://new.example",
                username = "bob",
                password = "secret",
                auth_method = "basic_auth",
            },
        }
        local controller_module, get_started_options, get_scheduled_callback = installControllerWithSourceFetchStub(config)
        local controller = buildController(controller_module)

        controller:scheduleSourceCacheRefresh({
            server_url = "https://old.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })
        get_scheduled_callback()()

        assert.is_nil(get_started_options())
        assert.is_nil(controller.source_fetch_active)
    end)

    it("translates missing setup message before Browse opens onboarding", function()
        helper.stubControllerDependencies()
        for _, name in ipairs({
            "suwayomi/browse/controller",
            "suwayomi/i18n",
            "suwayomi/settings",
            "suwayomi/debug",
        }) do
            package.loaded[name] = nil
            package.preload[name] = nil
        end
        installMarkerI18n()
        package.preload["suwayomi/settings"] = function()
            return {
                load = function()
                    return { server_url = "" }
                end,
            }
        end
        package.preload["suwayomi/debug"] = function()
            return {
                time = function(_, callback)
                    return callback()
                end,
            }
        end

        local controller = require("suwayomi/browse/controller")
        local plugin = {
            messages = {},
            setup_options = nil,
            showMessage = function(self, message)
                table.insert(self.messages, message)
            end,
            showOnboardingSetup = function(self, options)
                self.setup_options = options
            end,
            schedulePendingReadSync = function()
                error("unexpected sync")
            end,
            loadSourceCache = function()
                error("unexpected cache")
            end,
            startSourceFetchWorker = function()
                error("unexpected worker")
            end,
        }
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        plugin:browseSuwayomi()

        assert.are.equal("tx:Set up your Suwayomi server login first.", plugin.messages[#plugin.messages])
        assert.is_true(plugin.setup_options.first_run)
    end)
end)
