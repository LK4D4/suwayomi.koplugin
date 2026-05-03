package.path = "?.lua;" .. package.path

describe("suwayomi_api", function()
    local api

    before_each(function()
        package.loaded.suwayomi_api = nil
        package.loaded["socket.http"] = nil
        package.loaded["ssl.https"] = nil
        package.loaded.ltn12 = nil
        api = require("suwayomi_api")
    end)

    it("should build correct GraphQL query for sources", function()
        local query = api._buildSourcesQuery()
        assert.truthy(query:match("query getSources"))
        assert.truthy(query:match("sources { nodes { id name displayName lang } }"))
    end)

    it("builds the manga query for a source", function()
        local query = api._buildMangaQuery("2499283573021220255")
        assert.truthy(query:match("mutation GET_SOURCE_MANGAS_FETCH"))
        assert.truthy(query:match('"source":"2499283573021220255"'))
        assert.truthy(query:match('"page":1'))
        assert.truthy(query:match('"type":"POPULAR"'))
    end)

    it("builds a basic auth header from credentials", function()
        local header = api.buildBasicAuthHeader("alice", "s3cret")
        assert.are.equal("Basic YWxpY2U6czNjcmV0", header)
    end)

    it("builds a basic auth header for longer credentials", function()
        local header = api.buildBasicAuthHeader("suwayomi", "EfQDeSAHD8NktUWX6nb9")
        assert.are.equal("Basic c3V3YXlvbWk6RWZRRGVTQUhEOE5rdFVXWDZuYjk=", header)
    end)

    it("builds request headers for basic auth settings", function()
        local headers = api.buildRequestHeaders({
            username = "alice",
            password = "s3cret",
            auth_method = "basic_auth",
        })

        assert.are.equal("application/json", headers["Content-Type"])
        assert.are.equal("Basic YWxpY2U6czNjcmV0", headers.Authorization)
    end)

    it("parses sources from a GraphQL response body", function()
        local response = [[
            {
                "data": {
                    "sources": {
                        "nodes": [
                            {"id": "1", "name": "MangaDex", "displayName": "MangaDex (EN)", "lang": "en"},
                            {"id": "2", "name": "ComicK", "lang": "fr"}
                        ]
                    }
                }
            }
        ]]

        local sources = api.parseSourcesResponse(response)

        assert.are.same({
            { id = "1", name = "MangaDex (EN)", raw_name = "MangaDex", lang = "en" },
            { id = "2", name = "ComicK (FR)", raw_name = "ComicK", lang = "fr" },
        }, sources)
    end)

    it("parses manga from a source response body", function()
        local response = [[
            {
                "data": {
                    "fetchSourceManga": {
                        "mangas": [
                            { "id": 1, "title": "One Piece" },
                            { "id": 2, "title": "Frieren" }
                        ]
                    }
                }
            }
        ]]

        local manga = api.parseMangaResponse(response)

        assert.are.same({
            { id = "1", title = "One Piece" },
            { id = "2", title = "Frieren" },
        }, manga)
    end)

    it("fetches manga for a source and parses the response", function()
        local requested_body
        local requested_timeout

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    requested_body = options.source
                    requested_timeout = options.timeout
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(_chunk)
                            table.insert(target, [[{"data":{"fetchSourceManga":{"mangas":[{"id":1,"title":"One Piece"}]}}}]])
                        end
                    end,
                },
            }
        end

        local result = api.fetchMangaForSource({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "source-1")

        assert.is_true(result.ok)
        assert.truthy(requested_body:match("GET_SOURCE_MANGAS_FETCH"))
        assert.truthy(requested_body:match('"source":"source%-1"'))
        assert.are.equal(15, requested_timeout)
        assert.are.same({ { id = "1", title = "One Piece" } }, result.manga)
    end)

    it("returns a missing URL error when source fetch credentials omit server_url", function()
        local result = api.fetchMangaForSource({
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "source-1")

        assert.is_false(result.ok)
        assert.are.equal("Missing Suwayomi server URL.", result.error)
    end)

    it("reports malformed manga responses from the server", function()
        local logs = {}
        local original_io_open = io.open

        io.open = function(path, mode)
            if path ~= "/storage/emulated/0/koreader/settings/suwayomi_debug.log" then
                return original_io_open(path, mode)
            end

            return {
                write = function(_, message)
                    table.insert(logs, message)
                end,
                close = function() end,
            }
        end

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(_chunk)
                            table.insert(target, "{not-json")
                        end
                    end,
                },
            }
        end

        local result = api.fetchMangaForSource({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "source-1")

        io.open = original_io_open

        assert.is_false(result.ok)
        assert.are.equal("Invalid response from Suwayomi server.", result.error)
        assert.are.same({}, logs)
    end)

    it("reports manga schema mismatches from the server", function()
        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(_chunk)
                            table.insert(target, [[{"data":{"fetchSourceManga":null},"errors":[{"message":"No manga found"}]}]])
                        end
                    end,
                },
            }
        end

        local result = api.fetchMangaForSource({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "source-1")

        assert.is_false(result.ok)
        assert.are.equal("No manga found", result.error)
    end)

    it("builds the chapter query for a manga", function()
        local query = api._buildChapterQuery("17")
        assert.truthy(query:match("mutation GET_MANGA_CHAPTERS_FETCH"))
        assert.truthy(query:match('"mangaId":17'))
        assert.truthy(query:match("fetchChapters"))
    end)

    it("builds the chapter pages mutation for a chapter", function()
        local query = api._buildChapterPagesQuery("398")
        assert.truthy(query:match("mutation Pages"))
        assert.truthy(query:match("fetchChapterPages"))
        assert.truthy(query:match('"chapterId":398'))
    end)

    it("builds the stored chapter query for a manga", function()
        local query = api._buildStoredChapterQuery("17")
        assert.truthy(query:match("query GET_CHAPTERS_MANGA"))
        assert.truthy(query:match('"equalTo":17'))
        assert.truthy(query:match('"first":200'))
        assert.truthy(query:match("chapters"))
        assert.truthy(query:match("isRead"))
    end)

    it("builds the mark chapter read mutation", function()
        local query = api._buildMarkChapterReadMutation("398")

        assert.truthy(query:match("mutation UPDATE_CHAPTER_READ"))
        assert.truthy(query:match('"id":398'))
        assert.truthy(query:match('"isRead":true'))
    end)

    it("builds the mark chapter unread mutation", function()
        local query = api._buildMarkChapterUnreadMutation("398")

        assert.truthy(query:match("mutation UPDATE_CHAPTER_READ"))
        assert.truthy(query:match('"id":398'))
        assert.truthy(query:match('"isRead":false'))
    end)

    it("parses chapters from a manga response body", function()
        local response = [[
            {
                "data": {
                    "fetchChapters": {
                        "chapters": [
                            { "id": 1, "name": "Chapter 1" },
                            { "id": 2, "name": "", "chapterNumber": 7 },
                            { "id": 3, "chapterNumber": 8 },
                            { "id": 4, "name": "" }
                        ]
                    }
                }
            }
        ]]

        local chapters = api.parseChapterResponse(response)

        assert.are.same({
            { id = "1", name = "Chapter 1", is_read = false },
            { id = "2", name = "Chapter 7", is_read = false },
            { id = "3", name = "Chapter 8", is_read = false },
            { id = "4", name = "4", is_read = false },
        }, chapters)
    end)

    it("parses chapter pages using the exact URLs returned by Suwayomi", function()
        local response = [[
            {
                "data": {
                    "fetchChapterPages": {
                        "pages": [
                            "/api/v1/manga/85/chapter/1/page/0",
                            "/api/v1/manga/85/chapter/1/page/1"
                        ],
                        "chapter": {
                            "id": 398,
                            "name": "Official_Vol. 1 Ch. 1",
                            "manga": { "title": "Sousou no Frieren" }
                        }
                    }
                }
            }
        ]]

        local result = api.parseChapterPagesResponse(response)

        assert.are.same({
            chapter = {
                id = "398",
                name = "Official_Vol. 1 Ch. 1",
                manga_title = "Sousou no Frieren",
            },
            pages = {
                "/api/v1/manga/85/chapter/1/page/0",
                "/api/v1/manga/85/chapter/1/page/1",
            },
        }, result)
    end)

    it("fetches chapter pages and preserves the returned page URLs", function()
        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value) return value end,
                },
                sink = {
                    table = function(target)
                        return function()
                            table.insert(target, [[{"data":{"fetchChapterPages":{"pages":["/api/v1/manga/85/chapter/1/page/0"],"chapter":{"id":398,"name":"Official_Vol. 1 Ch. 1","manga":{"title":"Sousou no Frieren"}}}}}]])
                        end
                    end,
                },
            }
        end

        local result = api.fetchChapterPages({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "398")

        assert.is_true(result.ok)
        assert.are.same({ "/api/v1/manga/85/chapter/1/page/0" }, result.pages)
        assert.are.equal("Sousou no Frieren", result.chapter.manga_title)
    end)

    it("reports malformed chapter page responses from the server", function()
        local logs = {}
        local original_io_open = io.open

        io.open = function(path, mode)
            if path ~= "/storage/emulated/0/koreader/settings/suwayomi_debug.log" then
                return original_io_open(path, mode)
            end

            return {
                write = function(_, message)
                    table.insert(logs, message)
                end,
                close = function() end,
            }
        end

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value) return value end,
                },
                sink = {
                    table = function(target)
                        return function()
                            table.insert(target, "{not-json")
                        end
                    end,
                },
            }
        end

        local result = api.fetchChapterPages({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "398")

        io.open = original_io_open

        assert.is_false(result.ok)
        assert.are.equal("Invalid response from Suwayomi server.", result.error)
        assert.are.same({}, logs)
    end)

    it("downloads binary page bytes from a relative URL", function()
        local requested_url
        local requested_timeout

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    requested_url = options.url
                    requested_timeout = options.timeout
                    options.sink("ignored")
                    return 1, 200, {
                        ["content-type"] = "image/jpeg",
                    }
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value) return value end,
                },
                sink = {
                    table = function(target)
                        return function()
                            table.insert(target, "jpeg-bytes")
                        end
                    end,
                },
            }
        end

        local result = api.downloadBinary({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "/api/v1/manga/85/chapter/1/page/0")

        assert.is_true(result.ok)
        assert.are.equal("https://suwayomi.example/api/v1/manga/85/chapter/1/page/0", requested_url)
        assert.are.equal(15, requested_timeout)
        assert.are.equal("jpeg-bytes", result.body)
        assert.are.equal("image/jpeg", result.content_type)
    end)

    it("uses socket.http for absolute http page URLs without rewriting them", function()
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
                    options.sink("ignored")
                    return 1, 200, {
                        ["content-type"] = "image/png",
                    }
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value) return value end,
                },
                sink = {
                    table = function(target)
                        return function()
                            table.insert(target, "png-bytes")
                        end
                    end,
                },
            }
        end

        local result = api.downloadBinary({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "http://cdn.example/assets/page-1.png")

        assert.is_true(result.ok)
        assert.are.equal("socket.http", selected_client)
        assert.are.equal("http://cdn.example/assets/page-1.png", requested_url)
        assert.are.equal("png-bytes", result.body)
        assert.are.equal("image/png", result.content_type)
    end)

    it("does not send Suwayomi auth headers to off-origin absolute page URLs", function()
        local requested_headers

        package.preload["socket.http"] = function()
            return {
                request = function(options)
                    requested_headers = options.headers
                    options.sink("ignored")
                    return 1, 200, {
                        ["content-type"] = "image/png",
                    }
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value) return value end,
                },
                sink = {
                    table = function(target)
                        return function()
                            table.insert(target, "png-bytes")
                        end
                    end,
                },
            }
        end

        local result = api.downloadBinary({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "http://cdn.example/assets/page-2.png")

        assert.is_true(result.ok)
        assert.is_nil(requested_headers.Authorization)
    end)

    it("reports download failures when the HTTP client returns a non-200 status", function()
        package.preload["socket.http"] = function()
            return {
                request = function(options)
                    options.sink("ignored")
                    return 1, 500, {}
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value) return value end,
                },
                sink = {
                    table = function(_target)
                        return function() end
                    end,
                },
            }
        end

        local result = api.downloadBinary({
            server_url = "http://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "/api/v1/manga/85/chapter/1/page/0")

        assert.is_false(result.ok)
        assert.are.equal("Could not download chapter page.", result.error)
    end)

    it("surfaces transport errors when downloading binary page bytes", function()
        package.preload["socket.http"] = function()
            return {
                request = function(_options)
                    return nil, "network timeout"
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value) return value end,
                },
                sink = {
                    table = function(_target)
                        return function() end
                    end,
                },
            }
        end

        local result = api.downloadBinary({
            server_url = "http://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "/api/v1/manga/85/chapter/1/page/0")

        assert.is_false(result.ok)
        assert.are.equal("Could not reach the Suwayomi server: network timeout", result.error)
    end)

    it("reports not-found responses when downloading binary page bytes", function()
        package.preload["socket.http"] = function()
            return {
                request = function(options)
                    options.sink("ignored")
                    return 1, 404, {}
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value) return value end,
                },
                sink = {
                    table = function(_target)
                        return function() end
                    end,
                },
            }
        end

        local result = api.downloadBinary({
            server_url = "http://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "/api/v1/manga/85/chapter/1/page/0")

        assert.is_false(result.ok)
        assert.are.equal("Chapter page not found.", result.error)
    end)

    it("falls back to the chapter id when chapter pages return an empty chapter name", function()
        local response = [[
            {
                "data": {
                    "fetchChapterPages": {
                        "pages": [
                            "/api/v1/manga/85/chapter/1/page/0"
                        ],
                        "chapter": {
                            "id": 398,
                            "name": "",
                            "manga": { "title": "Sousou no Frieren" }
                        }
                    }
                }
            }
        ]]

        local result = api.parseChapterPagesResponse(response)

        assert.are.same({
            chapter = {
                id = "398",
                name = "398",
                manga_title = "Sousou no Frieren",
            },
            pages = {
                "/api/v1/manga/85/chapter/1/page/0",
            },
        }, result)
    end)

    it("parses stored chapters from a chapter query response body", function()
        local response = [[
            {
                "data": {
                    "chapters": {
                        "nodes": [
                            { "id": 1, "name": "Chapter 1", "isRead": true },
                            { "id": 2, "name": "", "chapterNumber": 7, "isRead": false },
                            { "id": 3, "chapterNumber": 8 }
                        ]
                    }
                }
            }
        ]]

        local chapters = api.parseStoredChapterResponse(response)

        assert.are.same({
            { id = "1", name = "Chapter 1", is_read = true },
            { id = "2", name = "Chapter 7", is_read = false },
            { id = "3", name = "Chapter 8", is_read = false },
        }, chapters)
    end)

    it("queries stored chapters for a manga and parses the response", function()
        local requested_body

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    requested_body = options.source
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(_chunk)
                            table.insert(target, [[{"data":{"chapters":{"totalCount":1,"nodes":[{"id":1,"name":"Chapter 1","isRead":true}]}}}]])
                        end
                    end,
                },
            }
        end

        local result = api.queryChaptersForManga({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "17")

        assert.is_true(result.ok)
        assert.truthy(requested_body:match("GET_CHAPTERS_MANGA"))
        assert.truthy(requested_body:match('"equalTo":17'))
        assert.are.same({ { id = "1", name = "Chapter 1", is_read = true } }, result.chapters)
    end)

    it("marks a chapter read through Suwayomi", function()
        local requested_body

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    requested_body = options.source
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(_chunk)
                            table.insert(target, [[{"data":{"updateChapter":{"chapter":{"id":398,"isRead":true}}}}]])
                        end
                    end,
                },
            }
        end

        local result = api.markChapterRead({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "398")

        assert.is_true(result.ok)
        assert.truthy(requested_body:match("UPDATE_CHAPTER_READ"))
        assert.truthy(requested_body:match('"isRead":true'))
    end)

    it("marks a chapter unread through Suwayomi", function()
        local requested_body

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    requested_body = options.source
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(_chunk)
                            table.insert(target, [[{"data":{"updateChapter":{"chapter":{"id":398,"isRead":false}}}}]])
                        end
                    end,
                },
            }
        end

        local result = api.markChapterUnread({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "398")

        assert.is_true(result.ok)
        assert.is_false(result.chapter.is_read)
        assert.truthy(requested_body:match("UPDATE_CHAPTER_READ"))
        assert.truthy(requested_body:match('"isRead":false'))
    end)

    it("fetches chapters for a manga and parses the response", function()
        local requested_body

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    requested_body = options.source
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(_chunk)
                            table.insert(target, [[{"data":{"fetchChapters":{"chapters":[{"id":1,"name":"Chapter 1"}]}}}]])
                        end
                    end,
                },
            }
        end

        local result = api.fetchChaptersForManga({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "m1")

        assert.is_true(result.ok)
        assert.truthy(requested_body:match("GET_MANGA_CHAPTERS_FETCH"))
        assert.truthy(requested_body:match('"mangaId":"m1"'))
        assert.are.same({ { id = "1", name = "Chapter 1", is_read = false } }, result.chapters)
    end)

    it("prefers stored chapters before falling back to fetch", function()
        local requests = {}

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    table.insert(requests, options.source)
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(_chunk)
                            if #requests == 1 then
                                table.insert(target, [[{"data":{"chapters":{"totalCount":1,"nodes":[{"id":1,"name":"Chapter 1"}]}}}]])
                            else
                                table.insert(target, [[{"data":{"fetchChapters":{"chapters":[{"id":2,"name":"Fetched Chapter"}]}}}]])
                            end
                        end
                    end,
                },
            }
        end

        local result = api.fetchChaptersForManga({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "17")

        assert.is_true(result.ok)
        assert.are.equal(1, #requests)
        assert.truthy(requests[1]:match("GET_CHAPTERS_MANGA"))
        assert.are.same({ { id = "1", name = "Chapter 1", is_read = false } }, result.chapters)
    end)

    it("falls back to fetch when stored chapters are empty", function()
        local requests = {}

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    table.insert(requests, options.source)
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(_chunk)
                            if #requests == 1 then
                                table.insert(target, [[{"data":{"chapters":{"totalCount":0,"nodes":[]}}}]])
                            else
                                table.insert(target, [[{"data":{"fetchChapters":{"chapters":[{"id":1,"name":"Fetched Chapter"}]}}}]])
                            end
                        end
                    end,
                },
            }
        end

        local result = api.fetchChaptersForManga({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "17")

        assert.is_true(result.ok)
        assert.are.equal(2, #requests)
        assert.truthy(requests[1]:match("GET_CHAPTERS_MANGA"))
        assert.truthy(requests[2]:match("GET_MANGA_CHAPTERS_FETCH"))
        assert.are.same({ { id = "1", name = "Fetched Chapter", is_read = false } }, result.chapters)
    end)

    it("returns a missing URL error when chapter fetch credentials omit server_url", function()
        local result = api.fetchChaptersForManga({
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "m1")

        assert.is_false(result.ok)
        assert.are.equal("Missing Suwayomi server URL.", result.error)
    end)

    it("reports malformed chapter responses from the server", function()
        local logs = {}
        local original_io_open = io.open

        io.open = function(path, mode)
            if path ~= "/storage/emulated/0/koreader/settings/suwayomi_debug.log" then
                return original_io_open(path, mode)
            end

            return {
                write = function(_, message)
                    table.insert(logs, message)
                end,
                close = function() end,
            }
        end

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(_chunk)
                            table.insert(target, "{not-json")
                        end
                    end,
                },
            }
        end

        local result = api.fetchChaptersForManga({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "m1")

        io.open = original_io_open

        assert.is_false(result.ok)
        assert.are.equal("Invalid response from Suwayomi server.", result.error)
        assert.are.same({}, logs)
    end)

    it("reports chapter schema mismatches from the server", function()
        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(_chunk)
                            table.insert(target, [[{"data":{"fetchChapters":null},"errors":[{"message":"No chapters found"}]}]])
                        end
                    end,
                },
            }
        end

        local result = api.fetchChaptersForManga({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "m1")

        assert.is_false(result.ok)
        assert.are.equal("No chapters found", result.error)
    end)

    it("uses ssl.https for https servers", function()
        local requested_url

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    requested_url = options.url
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

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
                            table.insert(target, [[{"data":{"sources":{"nodes":[]}}}]])
                        end
                    end,
                },
            }
        end

        local result = api.fetchSources({
            server_url = "https://suwayomi.example/",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.is_true(result.ok)
        assert.are.equal("https://suwayomi.example/api/graphql", requested_url)
    end)

    it("returns a missing URL error when source browse credentials omit server_url", function()
        local result = api.fetchSources({
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.is_false(result.ok)
        assert.are.equal("Missing Suwayomi server URL.", result.error)
    end)

    it("reports malformed source responses from the server", function()
        local logs = {}
        local original_io_open = io.open

        io.open = function(path, mode)
            if path ~= "/storage/emulated/0/koreader/settings/suwayomi_debug.log" then
                return original_io_open(path, mode)
            end

            return {
                write = function(_, message)
                    table.insert(logs, message)
                end,
                close = function() end,
            }
        end

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(_chunk)
                            table.insert(target, "{not-json")
                        end
                    end,
                },
            }
        end

        local result = api.fetchSources({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        io.open = original_io_open

        assert.is_false(result.ok)
        assert.are.equal("Invalid response from Suwayomi server.", result.error)
        assert.are.same({}, logs)
    end)

    it("reports source schema mismatches from the server", function()
        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(_chunk)
                            table.insert(target, [[{"data":{"sources":{"edges":[]}}}]])
                        end
                    end,
                },
            }
        end

        local result = api.fetchSources({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.is_false(result.ok)
        assert.are.equal("Suwayomi server did not return a sources list.", result.error)
    end)

    it("sends redacted metadata to an injected debug logger", function()
        local events = {}
        api.setDebugLogger(function(event)
            table.insert(events, event)
        end)

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    options.sink("ignored")
                    return 1, 500
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function()
                            table.insert(target, [[{"errors":[{"message":"secret body"}]}]])
                        end
                    end,
                },
            }
        end

        local result = api.fetchSources({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.is_false(result.ok)
        assert.are.equal("response", events[1].event)
        assert.are.equal("fetchSources", events[1].operation)
        assert.are.equal(500, events[1].code)
        assert.is_nil(events[1].response_body)
    end)

    it("uses socket.http for http servers", function()
        local requested_url

        package.preload["socket.http"] = function()
            return {
                request = function(options)
                    requested_url = options.url
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

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
                            table.insert(target, [[{"data":{"sources":{"nodes":[]}}}]])
                        end
                    end,
                },
            }
        end

        local result = api.fetchSources({
            server_url = "http://suwayomi.example/",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.is_true(result.ok)
        assert.are.equal("http://suwayomi.example/api/graphql", requested_url)
    end)

    it("surfaces transport errors from the HTTP client", function()
        package.preload["ssl.https"] = function()
            return {
                request = function(_)
                    return nil, "certificate verify failed"
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(_target)
                        return function(_chunk) end
                    end,
                },
            }
        end

        local result = api.fetchSources({
            server_url = "https://suwayomi.example/",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.is_false(result.ok)
        assert.are.equal("Could not reach the Suwayomi server: certificate verify failed", result.error)
    end)

    it("surfaces non-http status strings from the HTTP client", function()
        package.preload["ssl.https"] = function()
            return {
                request = function(_)
                    return 1, "closed"
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(_target)
                        return function(_chunk) end
                    end,
                },
            }
        end

        local result = api.fetchSources({
            server_url = "https://suwayomi.example/",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.is_false(result.ok)
        assert.are.equal("Could not reach the Suwayomi server: closed", result.error)
    end)
end)
