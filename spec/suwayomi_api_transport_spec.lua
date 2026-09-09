package.path = "?.lua;" .. package.path

-- Transport coverage owns HTTP client selection, URL/header construction,
-- status/error mapping, and binary streaming. Facade specs cover orchestration.
describe("suwayomi/api/transport", function()
    local transport

    local function clear_transport_stubs()
        package.loaded["socket.http"] = nil
        package.loaded["ssl.https"] = nil
        package.loaded.ltn12 = nil
        package.loaded.socket = nil
        package.preload["socket.http"] = nil
        package.preload["ssl.https"] = nil
        package.preload.ltn12 = nil
    end

    before_each(function()
        package.loaded["suwayomi/api/transport"] = nil
        clear_transport_stubs()
        transport = require("suwayomi/api/transport")
    end)

    after_each(function()
        clear_transport_stubs()
    end)

    local function valid_credentials()
        return {
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }
    end

    local function install_ltn12()
        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(chunk)
                            table.insert(target, chunk)
                        end
                    end,
                },
            }
        end
    end

    local function forbid_ltn12()
        package.preload.ltn12 = function()
            error("ltn12 should not be required before credentials are valid")
        end
    end

    it("builds auth headers and request URLs", function()
        assert.are.equal("Basic YWxpY2U6czNjcmV0", transport.buildBasicAuthHeader("alice", "s3cret"))

        local headers = transport.buildRequestHeaders(valid_credentials())
        assert.are.equal("application/json", headers["Content-Type"])
        assert.are.equal("Basic YWxpY2U6c2VjcmV0", headers.Authorization)

        assert.are.equal("https://suwayomi.example/api/graphql", transport.buildGraphQLEndpoint("https://suwayomi.example/"))
        assert.are.equal("https://suwayomi.example/api/v1/page/1", transport.buildRequestURL("https://suwayomi.example/", "/api/v1/page/1"))
        assert.are.equal("https://cdn.example/page.jpg", transport.buildRequestURL("https://suwayomi.example", "https://cdn.example/page.jpg"))
        assert.are.equal(
            "https://suwayomi.example/api/v1/chapter/398/download?markAsRead=false",
            transport.buildChapterArchiveDownloadURL("https://suwayomi.example/", "398")
        )
    end)

    it("silently logs in and reuses the session for GraphQL and page bytes", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "simple_login"
        credentials.username = "alice+reader"
        credentials.password = "secret&word"
        local logins = 0
        package.preload["ssl.https"] = function()
            return { request = function(options)
                assert.is_nil(options.headers.Authorization)
                assert.is_false(options.redirect)
                if options.url == "https://suwayomi.example/login.html" then
                    logins = logins + 1
                    assert.are.equal("user=alice%2Breader&pass=secret%26word", options.source)
                    return 1, 303, { ["set-cookie"] = "JSESSIONID=session-one; Path=/; HttpOnly", location = "/" }
                end
                if options.headers.Cookie ~= "JSESSIONID=session-one" then
                    return 1, 401
                end
                options.sink(options.method == "POST" and [[{"data":{"ok":true}}]] or "PNG")
                return 1, 200, { ["content-type"] = "image/png" }
            end }
        end

        local result = transport.performGraphQLRequest(credentials, [[{"query":"query { ok }"}]], "test")
        assert.is_true(result.ok)
        assert.are.equal([[{"data":{"ok":true}}]], result.response_body)
        assert.are.equal("PNG", transport.downloadBinary(credentials, "/page.png").body)
        assert.are.equal(1, logins)
        assert.is_nil(credentials.cookie)
    end)

    it("renews an expired session after a rejected single-field GraphQL mutation", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "simple_login"
        local logins, mutations = 0, 0
        package.preload["ssl.https"] = function()
            return { request = function(options)
                if options.url:match("/login%.html$") then
                    logins = logins + 1
                    return 1, 303, { ["set-cookie"] = "JSESSIONID=session-" .. logins .. "; Path=/" }
                end
                if options.headers.Cookie == "JSESSIONID=session-1" then
                    options.sink([[{"errors":[{"message":"Exception while fetching data (/updateChapter) : Unauthorized\r\n\r\nsuwayomi.tachidesk.server.user.UnauthorizedException: Unauthorized\n\tat suwayomi.tachidesk.server.user.UserTypeKt.requireUser(UserType.kt:27)\n\tat suwayomi.tachidesk.graphql.directives.RequireAuthDirectiveWiring.onField(RequireAuthDirectiveWiring.kt:35)","path":["updateChapter"]}],"data":null}]])
                else
                    mutations = mutations + 1
                    options.sink([[{"data":{"updateChapter":{"isRead":true}}}]])
                end
                return 1, 200
            end }
        end

        local result = transport.performGraphQLRequest(credentials,
            [[{"query":"mutation Read($input: UpdateChapterInput!) { updateChapter(input: $input) { isRead } }","variables":{"input":{"id":1,"isRead":true}}}]],
            "markRead")
        assert.is_true(result.ok)
        assert.are.equal([[{"data":{"updateChapter":{"isRead":true}}}]], result.response_body)
        assert.are.equal(2, logins)
        assert.are.equal(1, mutations)
    end)

    it("renews a refresh session only when every mutation root was rejected before execution", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "simple_login"
        local logins, refreshes = 0, 0
        package.preload["ssl.https"] = function()
            return { request = function(options)
                if options.url:match("/login%.html$") then
                    logins = logins + 1
                    return 1, 303, { ["set-cookie"] = "JSESSIONID=session-" .. logins .. "; Path=/" }
                end
                local json = require("dkjson")
                if options.headers.Cookie == "JSESSIONID=session-1" then
                    local errors = {}
                    for _, field in ipairs({ "fetchManga", "fetchChapters" }) do
                        errors[#errors + 1] = { path = { field }, message =
                            "Exception while fetching data (/" .. field .. ") : Unauthorized\r\n"
                            .. "suwayomi.tachidesk.server.user.UserTypeKt.requireUser\n"
                            .. "suwayomi.tachidesk.graphql.directives.RequireAuthDirectiveWiring" }
                    end
                    options.sink(json.encode({ errors = errors, data = {
                        fetchManga = json.null, fetchChapters = json.null,
                    } }))
                else
                    refreshes = refreshes + 1
                    options.sink([[{"data":{"fetchManga":{"manga":{"id":1}},"fetchChapters":{"chapters":[]}}}]])
                end
                return 1, 200
            end }
        end
        local result = transport.performGraphQLRequest(credentials,
            require("suwayomi/api/queries")._buildRefreshMangaMutation(1), "refreshManga")
        assert.is_true(result.ok)
        assert.are.equal(1, refreshes)
        assert.are.equal(2, logins)
    end)

    it("stops after one re-login when the server keeps rejecting the session", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "simple_login"
        local logins, requests = 0, 0
        package.preload["ssl.https"] = function()
            return { request = function(options)
                if options.url:match("/login%.html$") then
                    logins = logins + 1
                    return 1, 303, { ["set-cookie"] = "JSESSIONID=expired; Path=/" }
                end
                requests = requests + 1
                return 1, 401
            end }
        end
        local result = transport.downloadBinary(credentials, "/page.png")
        assert.is_false(result.ok)
        assert.is_false(result.retryable)
        assert.are.equal(401, result.status_code)
        assert.are.equal(2, logins)
        assert.are.equal(2, requests)
    end)

    it("rejects a login form response without trying the protected operation", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "simple_login"
        local requests = 0
        package.preload["ssl.https"] = function()
            return { request = function(options)
                requests = requests + 1
                assert.truthy(options.url:match("/login%.html$"))
                options.sink("<html>Invalid username or password</html>")
                return 1, 200, { ["set-cookie"] = "JSESSIONID=unauthenticated; Path=/" }
            end }
        end
        local result = transport.performGraphQLRequest(credentials, [[{"query":"query { __typename }"}]], "test")
        assert.is_false(result.ok)
        assert.is_false(result.retryable)
        assert.are.equal(1, requests)
        assert.is_nil(result.response_body)
    end)

    it("never replays a mutation after an ambiguous network failure", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "simple_login"
        local mutations, logins = 0, 0
        package.preload["ssl.https"] = function()
            return { request = function(options)
                if options.url:match("/login%.html$") then
                    logins = logins + 1
                    return 1, 303, { ["set-cookie"] = "JSESSIONID=valid; Path=/" }
                end
                mutations = mutations + 1
                return nil, "closed"
            end }
        end
        local result = transport.performGraphQLRequest(credentials,
            [[{"query":"mutation { updateChapter(input: {id: 1}) { id } }"}]], "markRead")
        assert.is_false(result.ok)
        assert.are.equal(1, mutations)
        assert.are.equal(1, logins)
    end)

    it("does not replay partially rejected multi-root mutations or partial GraphQL results", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "simple_login"
        local json = require("dkjson")
        local calls = 0
        local response
        package.preload["ssl.https"] = function()
            return { request = function(options)
                if options.url:match("/login%.html$") then
                    return 1, 303, { ["set-cookie"] = "JSESSIONID=valid; Path=/" }
                end
                calls = calls + 1
                options.sink(json.encode(response))
                return 1, 200
            end }
        end
        response = {
            data = json.null,
            errors = { { path = { "updateChapter" }, message =
                "Exception while fetching data (/updateChapter) : Unauthorized\r\n"
                .. "suwayomi.tachidesk.server.user.UserTypeKt.requireUser\n"
                .. "suwayomi.tachidesk.graphql.directives.RequireAuthDirectiveWiring" } },
        }
        transport.performGraphQLRequest(credentials,
            [[{"query":"mutation { updateChapter(input: {id: 1}) { id } updateManga(input: {id: 2}) { id } }"}]], "update")
        assert.are.equal(1, calls)
        response.data = { updateChapter = { id = 1 } }
        transport.performGraphQLRequest(credentials,
            [[{"query":"mutation { updateChapter(input: {id: 1}) { id } }"}]], "update")
        assert.are.equal(2, calls)
    end)

    it("scopes cookies to saved credentials and never sends them to external images", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "simple_login"
        local logins = 0
        package.preload["ssl.https"] = function()
            return { request = function(options)
                if options.url:match("/login%.html$") then
                    logins = logins + 1
                    assert.is_nil(options.headers.Cookie)
                    return 1, 303, { ["set-cookie"] = "JSESSIONID=session-" .. logins .. "; Path=/" }
                end
                if options.url == "https://cdn.example/page.png" then
                    assert.is_nil(options.headers.Cookie)
                    assert.is_nil(options.headers.Authorization)
                    return 1, 401
                end
                assert.are.equal("JSESSIONID=session-" .. logins, options.headers.Cookie)
                options.sink("PNG")
                return 1, 200
            end }
        end
        assert.is_true(transport.downloadBinary(credentials, "/page.png").ok)
        credentials.password = "changed"
        assert.is_true(transport.downloadBinary(credentials, "/page.png").ok)
        credentials.server_url = "https://other.example"
        assert.is_true(transport.downloadBinary(credentials, "/page.png").ok)
        assert.is_false(transport.downloadBinary(credentials, "https://cdn.example/page.png").ok)
        assert.are.equal(3, logins)
    end)

    it("restarts archive output after authentication rejection without retaining error bytes", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "simple_login"
        local logins = 0
        local path = os.tmpname()
        package.preload["ssl.https"] = function()
            return { request = function(options)
                if options.url:match("/login%.html$") then
                    logins = logins + 1
                    return 1, 303, { ["set-cookie"] = "JSESSIONID=session-" .. logins .. "; Path=/" }
                end
                if options.headers.Cookie == "JSESSIONID=session-1" then
                    options.sink("Unauthorized")
                    return 1, 401
                end
                options.sink("PK\003\004archive")
                return 1, 200
            end }
        end
        local result = transport.downloadChapterArchive(credentials, 1, path)
        local file = assert(io.open(path, "rb"))
        local bytes = file:read("*a")
        file:close()
        os.remove(path)
        assert.is_true(result.ok)
        assert.are.equal("PK\003\004archive", bytes)
        assert.are.equal(#bytes, result.bytes)
        assert.are.equal("PK\003\004", result.header_bytes)
        assert.are.equal(2, logins)
    end)

    local function ui_refresh_error(message)
        return require("dkjson").encode({ data = require("dkjson").null, errors = { {
            path = { "refreshToken" },
            message = "Exception while fetching data (/refreshToken) : " .. message .. "\r\n\r\n"
                .. "com.auth0.jwt.exceptions.TokenExpiredException: " .. message .. "\n"
                .. "\tat suwayomi.tachidesk.global.impl.util.Jwt.refreshJwt(Jwt.kt:81)\n"
                .. "\tat suwayomi.tachidesk.graphql.mutations.UserMutation.refreshToken(UserMutation.kt:62)",
        } } })
    end

    it("refreshes UI Login across GraphQL, pages, and archives without rotating the refresh token", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "ui_login"
        local json = require("dkjson")
        local logins, refreshes, requests = 0, 0, 0
        local path = os.tmpname()
        local events = {}
        package.preload["ssl.https"] = function()
            return { request = function(options)
                assert.is_false(options.redirect)
                assert.is_nil(options.headers.Cookie)
                local body = options.source and json.decode(options.source)
                if body and body.query:find("LoginInput", 1, true) then
                    assert.is_nil(options.headers.Authorization)
                    logins = logins + 1
                    options.sink(json.encode({ data = { login = {
                        accessToken = "access." .. logins .. ".signature",
                        refreshToken = "refresh." .. logins .. ".signature",
                    } } }))
                elseif body and body.query:find("RefreshTokenInput", 1, true) then
                    assert.is_nil(options.headers.Authorization)
                    assert.are.equal("refresh." .. logins .. ".signature", body.variables.input.refreshToken)
                    refreshes = refreshes + 1
                    if refreshes == 2 then
                        options.sink(ui_refresh_error("The Token has expired on 2026-09-01T00:00:00Z."))
                    else
                        options.sink(json.encode({ data = { refreshToken = {
                            accessToken = "renewed." .. refreshes .. ".signature",
                        } } }))
                    end
                else
                    requests = requests + 1
                    if requests % 2 == 1 then
                        if body then
                            options.sink([[{"data":null,"errors":[{"path":["updateChapter"],"message":"Exception while fetching data (/updateChapter) : Unauthorized\r\n\r\nsuwayomi.tachidesk.server.user.UnauthorizedException: Unauthorized\n\tat suwayomi.tachidesk.server.user.UserTypeKt.requireUser(UserType.kt:27)\n\tat suwayomi.tachidesk.graphql.directives.RequireAuthDirectiveWiring.onField(RequireAuthDirectiveWiring.kt:35)"}]}]])
                            return 1, 200
                        end
                        options.sink("Unauthorized")
                        return 1, 401
                    end
                    local expected = requests == 2 and "renewed.1.signature"
                        or requests == 4 and "access.2.signature" or "renewed.3.signature"
                    assert.are.equal("Bearer " .. expected, options.headers.Authorization)
                    options.sink(body and [[{"data":{"updateChapter":{"isRead":true}}}]]
                        or requests == 4 and "PNG" or "PK\003\004archive")
                end
                return 1, 200
            end }
        end
        local result = transport.performGraphQLRequest(credentials,
            [[{"query":"mutation { updateChapter(input: {id: 1}) { isRead } }"}]], "markRead",
            function(event) events[#events + 1] = event end)
        assert.is_true(result.ok)
        assert.are.equal([[{"data":{"updateChapter":{"isRead":true}}}]], result.response_body)
        assert.are.equal("PNG", transport.downloadBinary(credentials, "/page.png").body)
        result = transport.downloadChapterArchive(credentials, 1, path)
        local file = assert(io.open(path, "rb"))
        local bytes = file:read("*a")
        file:close()
        os.remove(path)
        assert.is_true(result.ok)
        assert.are.equal("PK\003\004archive", bytes)
        assert.are.equal(2, logins)
        assert.are.equal(3, refreshes)
        assert.are.equal(6, requests)
        assert.is_nil(json.encode(events):find("signature", 1, true))
        assert.is_nil(credentials.access_token)
        assert.is_nil(credentials.refresh_token)
    end)

    it("never substitutes login for an uncertain UI Login refresh failure", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "ui_login"
        local cases = {
            { code = "timeout" },
            { code = 500, body = ui_refresh_error("The Token has expired on 2026-09-01T00:00:00Z.") },
            { code = 401 },
            { code = 200, body = [[{"data":{"refreshToken":{}}}]] },
            { code = 200, body = [[{"errors":[{"path":["refreshToken"],"message":"secret refresh.1.signature"}]}]] },
            { code = 200, body = ui_refresh_error("Expired") .. "trailing" },
        }
        for _, failure in ipairs(cases) do
            package.loaded["suwayomi/api/transport"] = nil
            transport = require("suwayomi/api/transport")
            package.loaded["ssl.https"] = nil
            local logins, requests, refreshes = 0, 0, 0
            package.preload["ssl.https"] = function()
                return { request = function(options)
                    local body = options.source and require("dkjson").decode(options.source)
                    if body and body.query:find("LoginInput", 1, true) then
                        logins = logins + 1
                        options.sink([[{"data":{"login":{"accessToken":"access.1.signature","refreshToken":"refresh.1.signature"}}}]])
                        return 1, 200
                    elseif body then
                        refreshes = refreshes + 1
                        if failure.body then options.sink(failure.body) end
                        return type(failure.code) == "number" and 1 or nil, failure.code
                    end
                    requests = requests + 1
                    return 1, 401
                end }
            end
            local result = transport.downloadBinary(credentials, "/page.png")
            assert.is_false(result.ok)
            assert.are.equal(1, logins)
            assert.are.equal(1, refreshes)
            assert.are.equal(1, requests)
            assert.is_nil(result.response_body)
            assert.is_nil(result.error:find("signature", 1, true))
        end
    end)

    it("stops UI Login after one replay and does not renew arbitrary HTTP rejections", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "ui_login"
        local status, logins, refreshes, requests = 401, 0, 0, 0
        package.preload["ssl.https"] = function()
            return { request = function(options)
                local body = options.source and require("dkjson").decode(options.source)
                if body and body.query:find("LoginInput", 1, true) then
                    logins = logins + 1
                    options.sink([[{"data":{"login":{"accessToken":"access.1.signature","refreshToken":"refresh.1.signature"}}}]])
                elseif body then
                    refreshes = refreshes + 1
                    options.sink([[{"data":{"refreshToken":{"accessToken":"renewed.1.signature"}}}]])
                else
                    requests = requests + 1
                    return 1, status
                end
                return 1, 200
            end }
        end
        assert.is_false(transport.downloadBinary(credentials, "/page.png").ok)
        assert.are.equal(1, logins)
        assert.are.equal(1, refreshes)
        assert.are.equal(2, requests)
        status = 403
        assert.is_false(transport.downloadBinary(credentials, "/page.png").ok)
        assert.are.equal(2, logins)
        assert.are.equal(1, refreshes)
        assert.are.equal(3, requests)
        status = 400
        assert.is_false(transport.downloadBinary(credentials, "/page.png").ok)
        assert.are.equal(2, logins)
        assert.are.equal(1, refreshes)
        assert.are.equal(4, requests)
    end)

    it("rejects unsafe UI Login tokens before any protected request or secret result", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "ui_login"
        local calls = 0
        package.preload["ssl.https"] = function()
            return { request = function(options)
                calls = calls + 1
                assert.truthy(options.source:find("LoginInput", 1, true))
                options.sink([[{"data":{"login":{"accessToken":"secret\r\nInjected: value","refreshToken":"refresh.1.signature"}}}]])
                return 1, 200
            end }
        end
        local result = transport.downloadBinary(credentials, "/page.png")
        assert.is_false(result.ok)
        assert.are.equal(1, calls)
        assert.is_nil(result.response_body)
        assert.is_nil(result.error:find("secret", 1, true))
    end)

    it("isolates UI Login identities, module restarts, and external images", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "ui_login"
        local logins = 0
        package.preload["ssl.https"] = function()
            return { request = function(options)
                if options.url == "https://cdn.example/page.png" then
                    assert.is_nil(options.headers.Authorization)
                    assert.is_nil(options.headers.Cookie)
                    return 1, 401
                end
                if options.source then
                    logins = logins + 1
                    assert.is_nil(options.headers.Authorization)
                    options.sink(require("dkjson").encode({ data = { login = {
                        accessToken = "access." .. logins .. ".signature",
                        refreshToken = "refresh." .. logins .. ".signature",
                    } } }))
                else
                    assert.are.equal("Bearer access." .. logins .. ".signature", options.headers.Authorization)
                    options.sink("PNG")
                end
                return 1, 200
            end }
        end
        assert.is_false(transport.downloadBinary(credentials, "https://cdn.example/page.png").ok)
        assert.are.equal(0, logins)
        assert.are.equal("PNG", transport.downloadBinary(credentials, "/page.png").body)
        credentials.username = "bob"
        assert.are.equal("PNG", transport.downloadBinary(credentials, "/page.png").body)
        credentials.password = "changed"
        assert.are.equal("PNG", transport.downloadBinary(credentials, "/page.png").body)
        credentials.server_url = "https://other.example"
        assert.are.equal("PNG", transport.downloadBinary(credentials, "/page.png").body)
        package.loaded["suwayomi/api/transport"] = nil
        transport = require("suwayomi/api/transport")
        assert.are.equal("PNG", transport.downloadBinary(credentials, "/page.png").body)
        assert.is_false(transport.downloadBinary(credentials, "https://cdn.example/page.png").ok)
        assert.are.equal(5, logins)
    end)

    it("never recovers UI Login after partial mutation execution or ambiguous failures", function()
        install_ltn12()
        local credentials = valid_credentials()
        credentials.auth_method = "ui_login"
        local response
        local logins, mutations = 0, 0
        package.preload["ssl.https"] = function()
            return { request = function(options)
                if options.source:find("LoginInput", 1, true) then
                    logins = logins + 1
                    options.sink([[{"data":{"login":{"accessToken":"access.1.signature","refreshToken":"refresh.1.signature"}}}]])
                    return 1, 200
                end
                assert.is_nil(options.source:find("RefreshTokenInput", 1, true))
                mutations = mutations + 1
                if response then
                    options.sink(response)
                    return 1, 200
                end
                return nil, "closed"
            end }
        end
        local query = [[{"query":"mutation { updateChapter(input: {id: 1}) { id } updateManga(input: {id: 2}) { id } }"}]]
        local result = transport.performGraphQLRequest(credentials, query, "update")
        assert.is_false(result.ok)
        response = [[{"data":{"updateChapter":null,"updateManga":{"id":2}},"errors":[{"path":["updateChapter"],"message":"Exception while fetching data (/updateChapter) : Unauthorized\r\nsuwayomi.tachidesk.server.user.UserTypeKt.requireUser\nsuwayomi.tachidesk.graphql.directives.RequireAuthDirectiveWiring"}]}]]
        result = transport.performGraphQLRequest(credentials, query, "update")
        assert.is_false(result.ok)
        assert.is_nil(result.response_body)
        response = [[{"data":null,"errors":[{"path":["updateChapter"],"message":"access.1.signature"}]}]]
        result = transport.performGraphQLRequest(credentials, query, "update")
        assert.is_false(result.ok)
        assert.is_nil(result.error:find("signature", 1, true))
        assert.is_nil(result.response_body)
        assert.are.equal(1, logins)
        assert.are.equal(3, mutations)
    end)

    it("performs GraphQL requests with auth headers and debug metadata", function()
        install_ltn12()
        local request = {}
        local events = {}

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    request.url = options.url
                    request.method = options.method
                    request.headers = options.headers
                    request.source = options.source
                    request.timeout = options.timeout
                    options.sink([[{"data":{"ok":true}}]])
                    return 1, 200
                end,
            }
        end

        local result = transport.performGraphQLRequest(
            valid_credentials(),
            [[{"query":"query Test { ok }"}]],
            "testOperation",
            function(event)
                table.insert(events, event)
            end
        )

        assert.are.equal(true, result.ok)
        assert.are.equal([[{"data":{"ok":true}}]], result.response_body)
        assert.are.equal("https://suwayomi.example/api/graphql", request.url)
        assert.are.equal("POST", request.method)
        assert.are.equal("Basic YWxpY2U6c2VjcmV0", request.headers.Authorization)
        assert.are.equal(tostring(#([[{"query":"query Test { ok }"}]])), request.headers["Content-Length"])
        assert.are.equal(15, request.timeout)
        assert.are.equal("testOperation", events[1].operation)
        assert.are.equal("response", events[1].event)
    end)

    it("allows GraphQL callers to use a shorter request timeout", function()
        install_ltn12()
        local request = {}

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    request.timeout = options.timeout
                    options.sink([[{"data":{"ok":true}}]])
                    return 1, 200
                end,
            }
        end

        local result = transport.performGraphQLRequest(
            valid_credentials(),
            [[{"query":"query { __typename }"}]],
            "testConnection",
            nil,
            { timeout_seconds = 5 }
        )

        assert.is_true(result.ok)
        assert.are.equal(5, request.timeout)
    end)

    it("returns transport errors for missing URLs and non-200 GraphQL responses", function()
        forbid_ltn12()
        local missing = transport.performGraphQLRequest({}, "{}", "missing")
        assert.are.equal(false, missing.ok)
        assert.are.equal("Missing Suwayomi server URL.", missing.error)

        install_ltn12()
        package.preload["socket.http"] = function()
            return {
                request = function()
                    return nil, "connection refused"
                end,
            }
        end

        local failed = transport.performGraphQLRequest({ server_url = "http://suwayomi.example" }, "{}", "failure")
        assert.are.equal(false, failed.ok)
        assert.are.equal("Could not reach the Suwayomi server: connection refused", failed.error)
        assert.is_true(failed.retryable)
    end)

    it("maps transient TLS wait errors to a user-facing timeout", function()
        install_ltn12()
        package.preload["ssl.https"] = function()
            return {
                request = function()
                    return nil, "wantread"
                end,
            }
        end

        local result = transport.performGraphQLRequest(valid_credentials(), "{}", "failure")

        assert.are.equal(false, result.ok)
        assert.are.equal("Connection timed out while waiting for Suwayomi.", result.error)
    end)

    it("returns binary download errors for missing URLs before loading HTTP helpers", function()
        forbid_ltn12()
        local missing = transport.downloadBinary({}, "/api/v1/page/1")

        assert.are.equal(false, missing.ok)
        assert.are.equal("Missing Suwayomi server URL.", missing.error)
    end)

    it("rejects invalid binary page URLs before loading HTTP helpers", function()
        forbid_ltn12()
        local ok, invalid = pcall(transport.downloadBinary, valid_credentials(), { "/api/v1/page/1" })

        assert.are.equal(true, ok)
        assert.are.equal(false, invalid.ok)
        assert.are.equal("Invalid chapter page URL.", invalid.error)
    end)

    it("maps GraphQL HTTP statuses and non-numeric status strings", function()
        install_ltn12()
        local statuses = {
            { code = 400, error = "Could not reach the Suwayomi server.", retryable = false },
            { code = 401, error = "Authentication failed.", retryable = false },
            { code = 403, error = "Authentication failed.", retryable = false },
            { code = 404, error = "Suwayomi GraphQL endpoint not found.", retryable = false },
            { code = 408, error = "Could not reach the Suwayomi server.", retryable = true },
            { code = 429, error = "Could not reach the Suwayomi server.", retryable = true },
            { code = 500, error = "Could not reach the Suwayomi server.", retryable = true },
            { code = "closed", error = "Could not reach the Suwayomi server: closed", retryable = true },
        }

        for _, status in ipairs(statuses) do
            package.loaded["ssl.https"] = nil
            package.preload["ssl.https"] = function()
                return {
                    request = function()
                        return 1, status.code
                    end,
                }
            end

            local result = transport.performGraphQLRequest(valid_credentials(), "{}", "status")
            assert.are.equal(false, result.ok)
            assert.are.equal(status.error, result.error)
            assert.are.equal(status.retryable, result.retryable)
        end
    end)

    it("downloads binary bytes and only sends auth to same-origin URLs", function()
        install_ltn12()
        local requests = {}

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    table.insert(requests, options)
                    options.sink("PNG")
                    return 1, 200, { ["content-type"] = "image/png" }
                end,
            }
        end

        local relative = transport.downloadBinary(valid_credentials(), "/api/v1/page/1")
        assert.are.equal(true, relative.ok)
        assert.are.equal("PNG", relative.body)
        assert.are.equal("image/png", relative.content_type)
        assert.are.equal("Basic YWxpY2U6c2VjcmV0", requests[1].headers.Authorization)

        local absolute = transport.downloadBinary(valid_credentials(), "https://cdn.example/page.jpg")
        assert.are.equal(true, absolute.ok)
        assert.is_nil(requests[2].headers.Authorization)
    end)

    it("only sends auth to exact same bracketed IPv6 origins", function()
        install_ltn12()
        local requests = {}

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    table.insert(requests, options)
                    options.sink("PNG")
                    return 1, 200, { ["content-type"] = "image/png" }
                end,
            }
        end

        local credentials = valid_credentials()
        credentials.server_url = "https://[::1]:4567"

        local same_origin = transport.downloadBinary(credentials, "https://[::1]:4567/api/v1/page/1")
        assert.are.equal(true, same_origin.ok)
        assert.are.equal("Basic YWxpY2U6c2VjcmV0", requests[1].headers.Authorization)

        local different_origin = transport.downloadBinary(credentials, "https://[::2]:9999/api/v1/page/1")
        assert.are.equal(true, different_origin.ok)
        assert.is_nil(requests[2].headers.Authorization)
    end)

    it("stops binary downloads when the byte cap is exceeded", function()
        install_ltn12()
        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    local ok, err = options.sink("123456")
                    return ok, err
                end,
            }
        end

        local result = transport.downloadBinary(valid_credentials(), "/api/v1/page/1", {
            max_bytes = 5,
        })

        assert.are.equal(false, result.ok)
        assert.are.equal("Downloaded response was too large.", result.error)
        assert.is_false(result.retryable)
    end)

    it("stops GraphQL responses when the total response deadline is exceeded", function()
        install_ltn12()
        local times = { 0, 0, 31, 31 }
        package.loaded.socket = nil
        package.preload.socket = function()
            return {
                gettime = function()
                    return table.remove(times, 1) or 31
                end,
            }
        end
        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    local ok, err = options.sink([[{"data":{"ok":true}}]])
                    return ok, err
                end,
            }
        end

        local result = transport.performGraphQLRequest(valid_credentials(), "{}", "slowOperation")

        assert.are.equal(false, result.ok)
        assert.are.equal("Connection timed out while waiting for Suwayomi.", result.error)
    end)

    it("reports oversized GraphQL responses clearly", function()
        install_ltn12()
        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    local ok, err = options.sink(string.rep("x", 8 * 1024 * 1024 + 1))
                    return ok, err
                end,
            }
        end

        local result = transport.performGraphQLRequest(valid_credentials(), "{}", "hugeOperation")

        assert.are.equal(false, result.ok)
        assert.are.equal("Suwayomi response was too large.", result.error)
    end)

    it("uses socket.http for absolute http page URLs without rewriting them", function()
        install_ltn12()
        local requested_url
        local selected_client

        package.preload["ssl.https"] = function()
            return {
                request = function()
                    selected_client = "ssl.https"
                    return nil, "unexpected ssl client"
                end,
            }
        end

        package.preload["socket.http"] = function()
            return {
                request = function(options)
                    selected_client = "socket.http"
                    requested_url = options.url
                    options.sink("png-bytes")
                    return 1, 200, { ["content-type"] = "image/png" }
                end,
            }
        end

        local result = transport.downloadBinary(valid_credentials(), "http://cdn.example/assets/page-1.png")
        assert.are.equal(true, result.ok)
        assert.are.equal("socket.http", selected_client)
        assert.are.equal("http://cdn.example/assets/page-1.png", requested_url)
        assert.are.equal("png-bytes", result.body)
        assert.are.equal("image/png", result.content_type)
    end)

    it("reports binary download failure and not-found paths", function()
        install_ltn12()
        package.preload["socket.http"] = function()
            return {
                request = function()
                    return nil, "network timeout"
                end,
            }
        end

        local transport_error = transport.downloadBinary({
            server_url = "http://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "/api/v1/manga/85/chapter/1/page/0")
        assert.are.equal(false, transport_error.ok)
        assert.are.equal("Could not reach the Suwayomi server: network timeout", transport_error.error)
        assert.is_true(transport_error.retryable)

        package.loaded["socket.http"] = nil
        package.preload["socket.http"] = function()
            return {
                request = function()
                    return nil, "host or service not provided, or not known"
                end,
            }
        end
        local dns_error = transport.downloadBinary({
            server_url = "http://suwayomi.example",
        }, "/api/v1/manga/85/chapter/1/page/0")
        assert.is_true(dns_error.retryable)

        package.loaded["socket.http"] = nil
        package.preload["socket.http"] = function()
            return {
                request = function(options)
                    options.sink("missing")
                    return 1, 404, {}
                end,
            }
        end

        local not_found = transport.downloadBinary({
            server_url = "http://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "/api/v1/manga/85/chapter/1/page/0")
        assert.are.equal(false, not_found.ok)
        assert.are.equal("Chapter page not found.", not_found.error)
    end)

    for _, network_error in ipairs({
        "No address associated with hostname",
        "Software caused connection abort",
        "Software caused connection abor",
    }) do
        it("keeps Android connection loss retryable: " .. network_error, function()
            install_ltn12()
            package.preload["ssl.https"] = function()
                return { request = function() return nil, network_error end }
            end
            local result = transport.downloadBinary(valid_credentials(), "/page/1")
            assert.is_false(result.ok)
            assert.is_true(result.retryable)
        end)
    end

    it("marks only transient binary HTTP statuses as retryable", function()
        install_ltn12()
        local statuses = {
            { code = 400, retryable = false },
            { code = 408, retryable = true },
            { code = 429, retryable = true },
            { code = 500, retryable = true },
        }

        for _, status in ipairs(statuses) do
            package.loaded["socket.http"] = nil
            package.preload["socket.http"] = function()
                return {
                    request = function()
                        return 1, status.code, {}
                    end,
                }
            end

            local result = transport.downloadBinary({
                server_url = "http://suwayomi.example",
            }, "/api/v1/manga/85/chapter/1/page/0")

            assert.are.equal(false, result.ok)
            assert.are.equal(status.retryable, result.retryable)
            assert.are.equal(status.code, result.status_code)
        end
    end)

    it("downloads chapter archives to disk and removes failed partial files", function()
        local target_path = os.tmpname()
        os.remove(target_path)
        local request

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    request = options
                    options.sink("PK")
                    options.sink("\003\004archive")
                    return 1, 200, { ["content-length"] = "11", ["content-type"] = "application/vnd.comicbook+zip" }
                end,
            }
        end

        local result = transport.downloadChapterArchive(valid_credentials(), "398", target_path, nil, {
            total_timeout_seconds = 30,
            timeout_seconds = 42,
        })
        assert.are.equal(true, result.ok)
        assert.are.equal(target_path, result.path)
        assert.are.equal(11, result.bytes)
        assert.are.equal(11, result.content_length)
        assert.are.equal("PK\003\004", result.header_bytes)
        assert.are.equal("PK\003\004archive", result.head_bytes)
        assert.are.equal("PK\003\004archive", result.tail_bytes)
        assert.are.equal("https://suwayomi.example/api/v1/chapter/398/download?markAsRead=false", request.url)
        assert.are.equal("Basic YWxpY2U6c2VjcmV0", request.headers.Authorization)
        assert.are.equal(42, request.timeout)

        os.remove(target_path)
        package.loaded["ssl.https"] = nil

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    options.sink("missing")
                    return 1, 404
                end,
            }
        end

        local failed = transport.downloadChapterArchive(valid_credentials(), "404", target_path)
        assert.are.equal(false, failed.ok)
        assert.are.equal("Chapter archive not found.", failed.error)
        assert.is_nil(io.open(target_path, "rb"))
    end)

    it("uses a separate large response budget for chapter archives", function()
        assert.is_true(transport.MAX_CHAPTER_ARCHIVE_RESPONSE_BYTES > transport.MAX_BINARY_RESPONSE_BYTES)
    end)

    it("marks only transient archive HTTP statuses as retryable", function()
        local target_path = os.tmpname()
        os.remove(target_path)
        local statuses = {
            { code = 400, retryable = false },
            { code = 408, retryable = true },
            { code = 429, retryable = true },
            { code = 503, retryable = true },
        }

        for _, status in ipairs(statuses) do
            package.loaded["ssl.https"] = nil
            package.preload["ssl.https"] = function()
                return {
                    request = function()
                        return 1, status.code
                    end,
                }
            end

            local result = transport.downloadChapterArchive(valid_credentials(), "398", target_path)

            assert.are.equal(false, result.ok)
            assert.are.equal(status.retryable, result.retryable)
            assert.are.equal(status.code, result.status_code)
            assert.is_nil(io.open(target_path, "rb"))
        end
    end)

    it("rejects oversized chapter archives reported by Content-Length", function()
        local target_path = os.tmpname()
        os.remove(target_path)

        package.preload["ssl.https"] = function()
            return {
                request = function()
                    return 1, 200, { ["content-length"] = "9" }
                end,
            }
        end

        local result = transport.downloadChapterArchive(valid_credentials(), "398", target_path, nil, {
            max_bytes = 5,
        })

        assert.are.equal(false, result.ok)
        assert.are.equal("Downloaded response was too large.", result.error)
        assert.is_false(result.retryable)
        assert.is_nil(io.open(target_path, "rb"))
    end)

    it("stops oversized chapter archive streams and removes partial files", function()
        local target_path = os.tmpname()
        os.remove(target_path)

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    local ok, err = options.sink("123456")
                    return ok, err
                end,
            }
        end

        local result = transport.downloadChapterArchive(valid_credentials(), "398", target_path, nil, {
            max_bytes = 5,
        })

        assert.are.equal(false, result.ok)
        assert.are.equal("Downloaded response was too large.", result.error)
        assert.is_false(result.retryable)
        assert.is_nil(io.open(target_path, "rb"))
    end)

    it("reports archive stream timeouts as network timeouts", function()
        local target_path = os.tmpname()
        os.remove(target_path)
        local times = { 0, 31, 31 }
        package.loaded.socket = nil
        package.preload.socket = function()
            return {
                gettime = function()
                    return table.remove(times, 1) or 31
                end,
            }
        end

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    local ok, err = options.sink("PK\003\004archive")
                    return ok, err
                end,
            }
        end

        local result = transport.downloadChapterArchive(valid_credentials(), "398", target_path, nil, {
            total_timeout_seconds = 30,
        })

        assert.are.equal(false, result.ok)
        assert.are.equal("Connection timed out while downloading chapter archive.", result.error)
        assert.is_true(result.retryable)
        assert.is_nil(io.open(target_path, "rb"))
    end)

    it("does not inherit transport preload stubs from earlier examples", function()
        assert.is_nil(package.preload["ssl.https"])
        assert.is_nil(package.preload["socket.http"])
        assert.is_nil(package.preload.ltn12)
    end)
end)
