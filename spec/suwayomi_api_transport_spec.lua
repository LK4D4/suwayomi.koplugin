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
