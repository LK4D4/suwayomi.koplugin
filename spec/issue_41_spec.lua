package.path = "?.lua;" .. package.path

local json = require("dkjson")

describe("GraphQL source failures through the downloader", function()
    local api, downloader, credentials, counts, sleeps, events, saved, protected_response, refresh_response
    local modules = { "suwayomi/api", "suwayomi/api/transport", "suwayomi/api/parsers", "suwayomi/api/queries",
        "suwayomi/downloads/downloader", "suwayomi/downloads/archive", "suwayomi/downloads/progress_file",
        "suwayomi/paths", "suwayomi/fs", "socket", "socket.http", "ltn12", "ffi/util" }
    local private = "private-library access.1.signature refresh.1.signature"

    local function failure(message, extra)
        local payload = extra or {}
        payload.errors = { { message = message } }
        return json.encode(payload)
    end

    local function authError(field)
        return { path = { field }, message = "Exception while fetching data (/" .. field .. ") : Unauthorized\n"
            .. "suwayomi.tachidesk.server.user.UserTypeKt.requireUser\n"
            .. "suwayomi.tachidesk.graphql.directives.RequireAuthDirectiveWiring\n" .. private }
    end

    local function safe(value)
        local encoded = json.encode(value)
        for _, secret in ipairs({ "private-library", "access.1.signature", "refresh.1.signature" }) do
            assert.is_nil(encoded:find(secret, 1, true))
        end
    end

    local function download()
        return downloader:startChapterDownload(credentials, "/unused", { id = 1 }, { id = 2 },
            { attempt_id = string.rep("1", 32) })
    end

    before_each(function()
        saved = {}
        for _, name in ipairs(modules) do
            saved[name] = { package.loaded[name], package.preload[name] }
            package.loaded[name], package.preload[name] = nil, nil
        end
        counts, sleeps, events = { login = 0, refresh = 0, protected = 0 }, {}, {}
        credentials = { server_url = "http://example.test", username = "fixture", password = "fixture" }
        refresh_response = { body = [[{"data":{"refreshToken":{"accessToken":"renewed.1.signature"}}}]] }
        package.loaded.socket = { gettime = function() return 0 end,
            sleep = function(seconds) sleeps[#sleeps + 1] = seconds end }
        package.loaded.ltn12 = { source = { string = function(value) return value end } }
        package.loaded["socket.http"] = { request = function(options)
            if options.url:match("/login%.html$") then
                counts.login = counts.login + 1
                return 1, 303, { ["set-cookie"] = "JSESSIONID=fixture; Path=/" }
            end
            local body = json.decode(options.source)
            if body.query:find("LoginInput", 1, true) then
                counts.login = counts.login + 1
                options.sink([[{"data":{"login":{"accessToken":"access.1.signature","refreshToken":"refresh.1.signature"}}}]])
                return 1, 200
            end
            if body.query:find("RefreshTokenInput", 1, true) then
                counts.refresh = counts.refresh + 1
                if refresh_response.body then options.sink(refresh_response.body) end
                if refresh_response.code == "timeout" then return nil, "timeout" end
                return 1, refresh_response.code or 200
            end
            counts.protected = counts.protected + 1
            local response = type(protected_response) == "function"
                and protected_response(counts.protected, body.query) or protected_response
            options.sink(response)
            return 1, 200
        end }
        package.loaded["suwayomi/fs"] = {}
        package.loaded["ffi/util"] = { joinPath = function(base, name) return base .. "/" .. name end }
        api = require("suwayomi/api")
        api.setDebugLogger(function(event) events[#events + 1] = event end)
        downloader = require("suwayomi/downloads/downloader")
        downloader.getTargetPath = function() return "/unused", "/unused/chapter.cbz" end
        downloader.getChapterPathCandidates = function() return {} end
    end)

    after_each(function()
        for _, name in ipairs(modules) do
            package.loaded[name], package.preload[name] = saved[name][1], saved[name][2]
        end
    end)

    for _, method in ipairs({ "basic_auth", "simple_login", "ui_login" }) do
        it("bounds source timeout retries without exposing response text under " .. method, function()
            credentials.auth_method = method
            protected_response = failure("java.net.SocketTimeoutException: timeout " .. private)
            local result = download()
            assert.is_false(result.ok)
            assert.is_true(result.retryable)
            assert.are.equal(3, counts.protected)
            assert.same({ 0.5, 1 }, sleeps)
            assert.are.equal(0, counts.refresh)
            safe(result); safe(events); safe(credentials)
            local path = os.tmpname()
            os.remove(path)
            downloader:writeProgress(path, "failed", 0, 0, result.path, result.error, result.retryable)
            local progress = require("suwayomi/downloads/progress_file").read(path)
            os.remove(path)
            assert.is_true(progress.retryable)
            safe(progress)
        end)

        it("does not retry permanent source failures under " .. method, function()
            credentials.auth_method = method
            protected_response = failure("Chapter page not found " .. private)
            local result = download()
            assert.is_false(result.retryable)
            assert.are.equal(1, counts.protected)
            assert.same({}, sleeps)
            safe(result); safe(events)
        end)

        it("keeps definite authentication rejection out of download retries under " .. method, function()
            credentials.auth_method = method
            protected_response = json.encode({ data = json.null, errors = { authError("fetchChapterPages") } })
            local result = download()
            assert.is_false(result.retryable)
            assert.same({}, sleeps)
            assert.are.equal(method == "basic_auth" and 1 or 2, counts.protected)
            assert.are.equal(method == "ui_login" and 1 or 0, counts.refresh)
            safe(result); safe(events)
        end)

        it("retains safe legacy schema fallback under " .. method, function()
            credentials.auth_method = method
            protected_response = function(count)
                if count == 1 then return failure('Cannot query field "isNsfw" on type "Source" ' .. private) end
                return [[{"data":{"sources":{"nodes":[{"id":"local","name":"Fixture"}]}}}]]
            end
            local result = api.fetchSources(credentials)
            assert.is_true(result.ok)
            assert.are.equal("local", result.sources[1].id)
            assert.are.equal(2, counts.protected)
            assert.are.equal(0, counts.refresh)
            safe(result); safe(events)
        end)

        it("does not retry unknown schema errors under " .. method, function()
            credentials.auth_method = method
            protected_response = failure('Cannot query field "pages" ' .. private)
            local result = download()
            assert.is_false(result.retryable)
            assert.same({}, sleeps)
            assert.are.equal(1, counts.protected)
            assert.are.equal(0, counts.refresh)
            safe(result); safe(events)
        end)
    end

    it("never replays partially executed mutations for schema-looking errors", function()
        credentials.auth_method = "ui_login"
        protected_response = failure('Cannot query field "genre" ' .. private,
            { data = { fetchManga = { manga = { id = 1 } } } })
        local result = api.refreshManga(credentials, 1)
        assert.is_false(result.ok)
        assert.are.equal(1, counts.protected)
        assert.are.equal(0, counts.refresh)
        safe(result); safe(events)
    end)

    it("does not replay a partially rejected mutation even with timeout text", function()
        credentials.auth_method = "ui_login"
        protected_response = json.encode({ data = { fetchManga = { manga = { id = 1 } } },
            errors = { authError("fetchChapters"), { message = "timeout " .. private } } })
        local result = api.refreshManga(credentials, 1)
        assert.is_false(result.ok)
        assert.is_false(result.retryable)
        assert.are.equal(1, counts.protected)
        assert.are.equal(0, counts.refresh)
        safe(result); safe(events)
    end)

    it("does not turn refresh server failure into login fallback or mutation replay", function()
        credentials.auth_method = "ui_login"
        refresh_response = { code = 503, body = private }
        protected_response = json.encode({ data = json.null,
            errors = { authError("fetchManga"), authError("fetchChapters") } })
        local result = api.refreshManga(credentials, 1)
        assert.is_false(result.ok)
        assert.are.equal(1, counts.login)
        assert.are.equal(1, counts.refresh)
        assert.are.equal(1, counts.protected)
        safe(result); safe(events)
    end)
end)
