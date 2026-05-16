package.path = "?.lua;" .. package.path

describe("suwayomi/debug", function()
    local logs
    local file_lines
    local loaded_configs
    local original_loadfile
    local original_io_open

    local function loadDebug()
        package.loaded["suwayomi/debug"] = nil
        local debug = require("suwayomi/debug")
        if debug._resetForTests then
            debug._resetForTests()
        end
        return debug
    end

    before_each(function()
        logs = {}
        file_lines = {}
        loaded_configs = {}

        package.loaded["suwayomi/debug"] = nil
        package.loaded.datastorage = nil
        package.loaded.logger = nil
        package.loaded.socket = nil

        package.preload.datastorage = function()
            return {
                getSettingsDir = function()
                    return "/mock/settings"
                end,
            }
        end

        package.preload.logger = function()
            return {
                info = function(message)
                    table.insert(logs, message)
                end,
            }
        end

        package.preload.socket = function()
            return {
                gettime = function()
                    return 100
                end,
            }
        end

        original_loadfile = loadfile
        _G.loadfile = function(path)
            local config = loaded_configs[path]
            if config == nil then
                return nil, "missing"
            end
            return function()
                return config
            end
        end

        original_io_open = io.open
        io.open = function(path, mode)
            if path ~= "/mock/settings/suwayomi_debug.log" then
                return original_io_open(path, mode)
            end
            assert.are.equal("a", mode)
            return {
                write = function(_, ...)
                    table.insert(file_lines, table.concat({ ... }, ""))
                end,
                close = function() end,
            }
        end
    end)

    after_each(function()
        _G.loadfile = original_loadfile
        io.open = original_io_open
        package.preload.datastorage = nil
        package.preload.logger = nil
        package.preload.socket = nil
        package.loaded["suwayomi/debug"] = nil
        package.loaded.datastorage = nil
        package.loaded.logger = nil
        package.loaded.socket = nil
    end)

    it("does not log when the QA debug config is missing", function()
        local debug = loadDebug()

        debug.log({ operation = "browseSuwayomi", event = "end", elapsed_ms = 123 })

        assert.are.same({}, logs)
        assert.are.same({}, file_lines)
    end)

    it("logs redacted events when the QA debug config enables logging", function()
        loaded_configs["/mock/settings/suwayomi_dl_debug.lua"] = {
            enabled = true,
            log_to_file = true,
            log_to_koreader_log = true,
        }
        local debug = loadDebug()

        debug.log({
            operation = "login",
            event = "request",
            password = "secret",
            elapsed_ms = 42,
        })

        assert.are.equal(1, #logs)
        assert.truthy(logs[1]:match("SuwayomiDL"))
        assert.truthy(logs[1]:match("operation=login"))
        assert.truthy(logs[1]:match("password=<redacted>"))
        assert.are.equal(1, #file_lines)
        assert.truthy(file_lines[1]:match("operation=login"))
        assert.truthy(file_lines[1]:match("password=<redacted>"))
    end)

    it("redacts user data, paths, and URLs from QA debug events", function()
        loaded_configs["/mock/settings/suwayomi_dl_debug.lua"] = {
            enabled = true,
            log_to_file = true,
            log_to_koreader_log = true,
        }
        local debug = loadDebug()

        debug.log({
            operation = "globalSearch",
            event = "start",
            username = "alice",
            query = "frieren",
            title = "Sousou no Frieren",
            source_name = "MangaDex",
            server_url = "https://suwayomi.example/api/graphql",
            token = "token-123",
            secret = "secret-123",
            cookie = "sid=abc",
            path = "/storage/emulated/0/Books/Frieren/Ch. 1.cbz",
            unknown_field = "plain but user-provided",
            status = "cached",
            code = 200,
            code_type = "number",
            request_bytes = 128,
            response_bytes = 256,
            same_origin = false,
            queued_count = 3,
        })

        assert.truthy(logs[1]:match("username=<redacted>"))
        assert.truthy(logs[1]:match("query=<redacted>"))
        assert.truthy(logs[1]:match("title=<redacted>"))
        assert.truthy(logs[1]:match("source_name=<redacted>"))
        assert.truthy(logs[1]:match("server_url=<redacted>"))
        assert.truthy(logs[1]:match("token=<redacted>"))
        assert.truthy(logs[1]:match("secret=<redacted>"))
        assert.truthy(logs[1]:match("cookie=<redacted>"))
        assert.truthy(logs[1]:match("path=<redacted>"))
        assert.truthy(logs[1]:match("unknown_field=<redacted>"))
        assert.truthy(logs[1]:match("status=cached"))
        assert.truthy(logs[1]:match("code=200"))
        assert.truthy(logs[1]:match("code_type=number"))
        assert.truthy(logs[1]:match("request_bytes=128"))
        assert.truthy(logs[1]:match("response_bytes=256"))
        assert.truthy(logs[1]:match("same_origin=false"))
        assert.truthy(logs[1]:match("queued_count=3"))
        assert.is_nil(logs[1]:match("frieren"))
        assert.is_nil(logs[1]:match("suwayomi.example"))
        assert.is_nil(logs[1]:match("/storage"))
        assert.is_nil(logs[1]:match("token%-123"))
        assert.is_nil(logs[1]:match("sid=abc"))
        assert.is_nil(logs[1]:match("plain but user%-provided"))
    end)

    it("skips fast timing events when a slow threshold is configured", function()
        local now = 100
        package.preload.socket = function()
            return {
                gettime = function()
                    return now
                end,
            }
        end
        loaded_configs["/mock/settings/suwayomi_dl_debug.lua"] = {
            enabled = true,
            log_to_file = true,
            slow_threshold_ms = 250,
        }
        local debug = loadDebug()

        local result = debug.time("fastOperation", function()
            now = 100.1
            return "ok"
        end)

        assert.are.equal("ok", result)
        assert.are.same({}, logs)
        assert.are.same({}, file_lines)
    end)

    it("logs slow timing events when a slow threshold is configured", function()
        local now = 100
        package.preload.socket = function()
            return {
                gettime = function()
                    return now
                end,
            }
        end
        loaded_configs["/mock/settings/suwayomi_dl_debug.lua"] = {
            enabled = true,
            log_to_file = true,
            slow_threshold_ms = 250,
        }
        local debug = loadDebug()

        debug.time("slowOperation", function()
            now = 100.3
        end)

        assert.are.equal(1, #file_lines)
        assert.truthy(file_lines[1]:match("operation=slowOperation"))
        assert.truthy(file_lines[1]:match("elapsed_ms=300"))
    end)
end)
