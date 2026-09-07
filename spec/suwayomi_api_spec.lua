package.path = "?.lua;" .. package.path

describe("suwayomi/api facade", function()
    local api

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
        package.loaded["suwayomi/api"] = nil
        package.loaded["suwayomi/api/queries"] = nil
        package.loaded["suwayomi/api/parsers"] = nil
        package.loaded["suwayomi/api/transport"] = nil
        clear_transport_stubs()
        api = require("suwayomi/api")
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

    local function install_graphql_sequence_stub(responses)
        local request = {
            bodies = {},
            urls = {},
            headers = {},
            count = 0,
        }
        package.loaded["ssl.https"] = nil
        package.loaded.ltn12 = nil

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    request.count = request.count + 1
                    request.urls[request.count] = options.url
                    request.headers[request.count] = options.headers
                    request.bodies[request.count] = options.source
                    local response = responses[request.count] or responses[#responses] or {}
                    if options.sink then
                        options.sink(response.body or "")
                    end
                    return response.ok or 1, response.code or 200
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
                            table.insert(target, chunk)
                        end
                    end,
                },
            }
        end

        return request
    end

    local function install_graphql_stub(response_body)
        return install_graphql_sequence_stub({
            { body = response_body },
        })
    end

    it("re-exports the legacy helper surface from focused API modules", function()
        local names = {
            "_buildSourcesQuery",
            "_buildLegacySourcesQuery",
            "_buildMangaQuery",
            "_buildLegacyMangaQuery",
            "_buildLibraryMangaQuery",
            "_buildLegacyLibraryMangaQuery",
            "_buildCategoryQuery",
            "_buildUpdateMangaLibraryMutation",
            "_buildRefreshMangaMutation",
            "_buildLegacyRefreshMangaMutation",
            "_buildChapterQuery",
            "_buildChapterPagesQuery",
            "_buildStoredChapterQuery",
            "_buildUpdateChapterReadMutation",
            "_buildUpdateChaptersReadMutation",
            "_buildMarkChapterReadMutation",
            "_buildMarkChapterUnreadMutation",
            "_buildFetchExtensionsMutation",
            "_buildLegacyFetchExtensionsMutation",
            "_buildUpdateExtensionMutation",
            "_buildLegacyUpdateExtensionMutation",
            "_buildSourceFiltersQuery",
            "_buildSourceMetadataQuery",
            "_buildSetSourceSavedSearchesMutation",
            "parseSourcesResponse",
            "parseExtensionsResponse",
            "parseUpdateExtensionResponse",
            "parseSourceFiltersResponse",
            "isSourceFiltersFieldError",
            "parseSourceMetadataResponse",
            "parseSetSourceMetasResponse",
            "isSourceMetadataFieldError",
            "isOptionalMangaMetadataFieldError",
            "parseMangaResponse",
            "parseLibraryMangaResponse",
            "parseCategoryResponse",
            "parseUpdateMangaLibraryResponse",
            "parseRefreshMangaResponse",
            "parseChapterResponse",
            "parseChapterPagesResponse",
            "parseStoredChapterResponse",
            "parseMarkChapterReadResponse",
            "parseMarkChaptersReadResponse",
            "buildBasicAuthHeader",
            "buildRequestHeaders",
            "buildGraphQLEndpoint",
            "buildRequestURL",
            "buildChapterArchiveDownloadURL",
            "downloadBinary",
            "downloadChapterArchive",
            "fetchSourceFilters",
            "fetchSourceMetadata",
            "setSourceSavedSearches",
        }

        for _, name in ipairs(names) do
            assert.are.equal("function", type(api[name]), name)
        end
    end)

    it("fetches sources and retries with the legacy query for optional metadata schema errors", function()
        local request = install_graphql_sequence_stub({
            {
                body = [[{"errors":[{"message":"Cannot query field \"isNsfw\" on type \"Source\""}]}]],
            },
            {
                body = [[{"data":{"sources":{"nodes":[{"id":"local","name":"Local Source","displayName":"Local Source","lang":"localsourcelang"}]}}}]],
            },
        })
        local events = {}
        api.setDebugLogger(function(event)
            table.insert(events, event)
        end)

        local result = api.fetchSources(valid_credentials())

        assert.are.equal(true, result.ok)
        assert.are.equal("local", result.sources[1].id)
        assert.are.equal(2, request.count)
        assert.truthy(request.bodies[1]:match("iconUrl"))
        assert.truthy(request.bodies[1]:match("isNsfw"))
        assert.is_nil(request.bodies[2]:match("iconUrl"))
        assert.is_nil(request.bodies[2]:match("isNsfw"))
        assert.are.equal("legacy_source_query_retry", events[2].event)
    end)

    it("retries manga operations with legacy fields for old schemas", function()
        local browse_request = install_graphql_sequence_stub({
            {
                body = [[{"errors":[{"message":"Cannot query field \"artist\" on type \"Manga\""}]}]],
            },
            {
                body = [[{"data":{"fetchSourceManga":{"hasNextPage":false,"mangas":[{"id":1,"title":"Cloud Lantern","thumbnailUrl":"/thumb/1"}]}}}]],
            },
        })

        local manga = api.fetchMangaForSource(valid_credentials(), { source_id = "local", page = 1 })

        assert.are.equal(true, manga.ok)
        assert.are.equal("Cloud Lantern", manga.manga[1].title)
        assert.are.equal(2, browse_request.count)
        assert.truthy(browse_request.bodies[1]:match("artist"))
        assert.is_nil(browse_request.bodies[2]:match("artist"))
        assert.truthy(browse_request.bodies[2]:match("thumbnailUrl"))

        local library_request = install_graphql_sequence_stub({
            {
                body = [[{"errors":[{"message":"FieldUndefined: description"}]}]],
            },
            {
                body = [[{"data":{"mangas":{"totalCount":1,"nodes":[{"id":17,"title":"Harbor Notes","inLibrary":true}]}}}]],
            },
        })

        local library = api.fetchLibraryManga(valid_credentials(), { first = 20, offset = 40 })

        assert.are.equal(true, library.ok)
        assert.are.equal(1, library.total_count)
        assert.are.equal(2, library_request.count)
        assert.truthy(library_request.bodies[1]:match("description"))
        assert.is_nil(library_request.bodies[2]:match("description"))

        local single_request = install_graphql_sequence_stub({
            {
                body = [[{"errors":[{"message":"Cannot query field \"artist\" on type \"Manga\""}]}]],
            },
            {
                body = [[{"data":{"mangas":{"totalCount":1,"nodes":[{"id":17,"title":"Paper Comet","inLibrary":true}]}}}]],
            },
        })

        local single_manga = api.fetchMangaById(valid_credentials(), "17")

        assert.are.equal(true, single_manga.ok)
        assert.are.equal("Paper Comet", single_manga.manga.title)
        assert.are.equal(2, single_request.count)
        assert.truthy(single_request.bodies[1]:match("artist"))
        assert.is_nil(single_request.bodies[2]:match("artist"))

        local refresh_request = install_graphql_sequence_stub({
            {
                body = [[{"errors":[{"message":"Cannot query field \"genre\" on type \"Manga\""}]}]],
            },
            {
                body = [[{"data":{"fetchManga":{"manga":{"id":17,"title":"Harbor Notes","initialized":true}},"fetchChapters":{"chapters":[{"id":398,"sourceOrder":1,"name":"Ch. 1","isRead":false}]}}}]],
            },
        })

        local refreshed = api.refreshManga(valid_credentials(), "17")

        assert.are.equal(true, refreshed.ok)
        assert.are.equal("Harbor Notes", refreshed.manga.title)
        assert.are.equal(2, refresh_request.count)
        assert.truthy(refresh_request.bodies[1]:match("genre"))
        assert.is_nil(refresh_request.bodies[2]:match("genre"))
    end)

    it("tests connection with a lightweight GraphQL request", function()
        local request = install_graphql_stub([[{"data":{"__typename":"Query"}}]])

        local result = api.testConnection(valid_credentials())

        assert.is_true(result.ok)
        assert.are.equal([[{"query":"query { __typename }"}]], request.bodies[1])
    end)

    it("fetches extensions and updates extension install state", function()
        local request = install_graphql_stub([[{"data":{"fetchExtensions":{"extensions":[{"pkgName":"pkg.mangadex","name":"MangaDex","lang":"all","versionName":"1.4.0","versionCode":140,"isNsfw":true,"isInstalled":false,"hasUpdate":false,"isObsolete":false,"iconUrl":"/icons/md.png","apkName":"mangadex.apk","repo":"https://repo.example"}]}}}]])

        local extensions = api.fetchExtensions(valid_credentials())

        assert.are.equal(true, extensions.ok)
        assert.are.equal("pkg.mangadex", extensions.extensions[1].pkg_name)
        assert.are.equal("MangaDex", extensions.extensions[1].name)
        assert.are.equal("all", extensions.extensions[1].lang)
        assert.are.equal("1.4.0", extensions.extensions[1].version_name)
        assert.are.equal(140, extensions.extensions[1].version_code)
        assert.is_true(extensions.extensions[1].is_nsfw)
        assert.is_false(extensions.extensions[1].is_installed)
        assert.is_false(extensions.extensions[1].has_update)
        assert.is_false(extensions.extensions[1].is_obsolete)
        assert.truthy(request.bodies[1]:match("fetchExtensions"))

        local update_request = install_graphql_stub([[{"data":{"updateExtension":{"extension":{"pkgName":"pkg.mangadex","name":"MangaDex","lang":"all","versionName":"1.4.0","versionCode":140,"isNsfw":true,"isInstalled":true,"hasUpdate":false,"isObsolete":false,"iconUrl":"/icons/md.png","apkName":"mangadex.apk","repo":"https://repo.example"}}}}]])
        local installed = api.updateExtension(valid_credentials(), "pkg.mangadex", "install")

        assert.are.equal(true, installed.ok)
        assert.are.equal("pkg.mangadex", installed.extension.pkg_name)
        assert.is_true(installed.extension.is_installed)
        assert.truthy(update_request.bodies[1]:match("updateExtension"))
        assert.truthy(update_request.bodies[1]:match("\"id\":\"pkg.mangadex\""))
        assert.truthy(update_request.bodies[1]:match("\"install\":true"))
    end)

    it("retries extension operations with legacy fields for old schemas", function()
        local request = install_graphql_sequence_stub({
            {
                body = [[{"errors":[{"message":"Cannot query field \"apkName\" on type \"Extension\""}]}]],
            },
            {
                body = [[{"data":{"fetchExtensions":{"extensions":[{"pkgName":"pkg.mangadex","name":"MangaDex","lang":"all","versionName":"1.4.0","versionCode":140,"isNsfw":false,"isInstalled":true,"hasUpdate":false,"isObsolete":false}]}}}]],
            },
        })

        local extensions = api.fetchExtensions(valid_credentials())

        assert.are.equal(true, extensions.ok)
        assert.are.equal("pkg.mangadex", extensions.extensions[1].pkg_name)
        assert.are.equal(2, request.count)
        assert.truthy(request.bodies[1]:match("apkName"))
        assert.is_nil(request.bodies[2]:match("apkName"))
        assert.is_nil(request.bodies[2]:match("iconUrl"))
        assert.is_nil(request.bodies[2]:match("repo"))

        local update_request = install_graphql_sequence_stub({
            {
                body = [[{"errors":[{"message":"Cannot query field \"repo\" on type \"Extension\""}]}]],
            },
            {
                body = [[{"data":{"updateExtension":{"extension":{"pkgName":"pkg.mangadex","name":"MangaDex","lang":"all","versionName":"1.4.0","versionCode":140,"isNsfw":false,"isInstalled":true,"hasUpdate":false,"isObsolete":false}}}}]],
            },
        })

        local installed = api.updateExtension(valid_credentials(), "pkg.mangadex", "install")

        assert.are.equal(true, installed.ok)
        assert.are.equal(2, update_request.count)
        assert.truthy(update_request.bodies[1]:match("repo"))
        assert.is_nil(update_request.bodies[2]:match("repo"))
        assert.truthy(update_request.bodies[2]:match("\"install\":true"))
    end)

    it("fetches source filters through the facade", function()
        local request = install_graphql_stub([[{"data":{"source":{"id":"s1","displayName":"MangaDex","name":"mangadex","filters":[]}}}]])

        local result = api.fetchSourceFilters(valid_credentials(), "s1")

        assert.is_true(result.ok)
        assert.are.equal("s1", result.source.id)
        assert.are.equal("MangaDex", result.source.display_name)
        assert.are.same({}, result.filters)
        assert.truthy(request.bodies[1]:match("GET_SOURCE_FILTERS"))
    end)

    it("returns unsupported source filters schema errors and logs parse errors", function()
        install_graphql_stub([[{"errors":[{"message":"Cannot query field \"filters\" on type \"SourceType\""}]}]])
        local unsupported = api.fetchSourceFilters(valid_credentials(), "s1")
        assert.is_false(unsupported.ok)
        assert.are.equal("Source filters are not supported by this server.", unsupported.error)

        local events = {}
        api.setDebugLogger(function(event)
            table.insert(events, event)
        end)
        install_graphql_stub("{")
        local malformed = api.fetchSourceFilters(valid_credentials(), "s1")
        assert.is_false(malformed.ok)
        assert.are.equal("Invalid response from Suwayomi server.", malformed.error)
        assert.are.equal("fetchSourceFilters", events[#events].operation)
        assert.are.equal("parse_error", events[#events].event)
    end)

    it("fetches and updates source saved-search metadata through the facade", function()
        local request = install_graphql_sequence_stub({
            {
                body = [[{"data":{"source":{"id":"s1","meta":[{"key":"webUI_savedSearches","value":"{\"One\":{\"query\":\"frieren\",\"filters\":[]}}"}]}}}]],
            },
            {
                body = [[{"data":{"setSourceMetas":{"metas":[{"key":"webUI_savedSearches","value":"{\"Two\":{}}","sourceId":"s1"}]}}}]],
            },
        })

        local fetched = api.fetchSourceMetadata(valid_credentials(), "s1")
        assert.is_true(fetched.ok)
        assert.are.equal("s1", fetched.source.id)
        assert.are.equal("webUI_savedSearches", fetched.meta[1].key)
        assert.truthy(request.bodies[1]:match("GET_SOURCE_METADATA"))

        local updated = api.setSourceSavedSearches(valid_credentials(), "s1", '{"Two":{}}')
        assert.is_true(updated.ok)
        assert.are.equal("s1", updated.meta[1].source_id)
        assert.truthy(request.bodies[2]:match("SET_SOURCE_METAS"))
        assert.truthy(request.bodies[2]:match("webUI_savedSearches"))
        assert.truthy(request.bodies[2]:match('\\"Two\\"'))
    end)

    it("reports unsupported source metadata without exposing raw schema dumps", function()
        install_graphql_stub([[{"errors":[{"message":"Cannot query field \"meta\" on type \"SourceType\""}]}]])
        local unsupported = api.fetchSourceMetadata(valid_credentials(), "s1")
        assert.is_false(unsupported.ok)
        assert.are.equal("Saved filters are not supported by this server.", unsupported.error)

        install_graphql_stub([[{"errors":[{"message":"Unknown field \"setSourceMetas\""}]}]])
        local update_unsupported = api.setSourceSavedSearches(valid_credentials(), "s1", "{}")
        assert.is_false(update_unsupported.ok)
        assert.are.equal("Saved filters are not supported by this server.", update_unsupported.error)
    end)

    it("fetches manga, library manga, categories, updates library state, and refreshes manga", function()
        install_graphql_stub([[{"data":{"fetchSourceManga":{"hasNextPage":true,"mangas":[{"id":1,"title":"One Piece"}]}}}]])
        local manga = api.fetchMangaForSource(valid_credentials(), { source_id = "local", page = 1 })
        assert.are.equal(true, manga.ok)
        assert.are.equal("One Piece", manga.manga[1].title)
        assert.are.equal(true, manga.has_next_page)

        install_graphql_stub([[{"data":{"mangas":{"totalCount":1,"nodes":[{"id":17,"title":"Frieren","inLibrary":true}]}}}]])
        local library = api.fetchLibraryManga(valid_credentials(), { first = 20, offset = 40 })
        assert.are.equal(true, library.ok)
        assert.are.equal(1, library.total_count)
        assert.are.equal("17", library.manga[1].id)

        install_graphql_stub([[{"data":{"mangas":{"totalCount":1,"nodes":[{"id":17,"title":"Paper Comet","inLibrary":true}]}}}]])
        local single_manga = api.fetchMangaById(valid_credentials(), "17")
        assert.are.equal(true, single_manga.ok)
        assert.are.equal("Paper Comet", single_manga.manga.title)
        assert.are.equal(true, single_manga.manga.in_library)

        install_graphql_stub([[{"data":{"categories":{"nodes":[{"id":2,"name":"Reading","order":1,"mangas":{"totalCount":7}}]}}}]])
        local categories = api.fetchCategories(valid_credentials())
        assert.are.equal(true, categories.ok)
        assert.are.equal("Reading", categories.categories[1].name)

        install_graphql_stub([[{"data":{"updateManga":{"manga":{"id":17,"inLibrary":true,"inLibraryAt":"2026-05-09T00:00:00Z"}}}}]])
        local updated = api.updateMangaLibraryState(valid_credentials(), "17", true)
        assert.are.equal(true, updated.ok)
        assert.are.equal(true, updated.manga.in_library)

        install_graphql_stub([[{"data":{"fetchManga":{"manga":{"id":17,"title":"Frieren","initialized":true}},"fetchChapters":{"chapters":[{"id":398,"sourceOrder":1,"name":"Ch. 1","isRead":false}]}}}]])
        local refreshed = api.refreshManga(valid_credentials(), "17")
        assert.are.equal(true, refreshed.ok)
        assert.are.equal("Frieren", refreshed.manga.title)
        assert.are.equal("398", refreshed.chapters[1].id)
    end)

    it("fetches chapter pages and chapter read state operations", function()
        install_graphql_stub([[{"data":{"fetchChapterPages":{"pages":["/api/v1/page/0"],"chapter":{"id":398,"name":"Official Ch. 1","manga":{"title":"Frieren"}}}}}]])
        local pages = api.fetchChapterPages(valid_credentials(), "398")
        assert.are.equal(true, pages.ok)
        assert.are.equal("398", pages.chapter.id)
        assert.are.equal("/api/v1/page/0", pages.pages[1])

        install_graphql_stub([[{"data":{"chapters":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[{"id":398,"sourceOrder":1,"name":"Ch. 1","isRead":false}]}}}]])
        local stored = api.queryChaptersForManga(valid_credentials(), "17")
        assert.are.equal(true, stored.ok)
        assert.are.equal("398", stored.chapters[1].id)

        install_graphql_stub([[{"data":{"updateChapter":{"chapter":{"id":398,"isRead":true}}}}]])
        local read = api.markChapterRead(valid_credentials(), "398")
        assert.are.equal(true, read.ok)
        assert.are.equal(true, read.chapter.is_read)

        install_graphql_stub([[{"data":{"updateChapter":{"chapter":{"id":398,"isRead":false}}}}]])
        local unread = api.markChapterUnread(valid_credentials(), "398")
        assert.are.equal(true, unread.ok)
        assert.are.equal(false, unread.chapter.is_read)

        install_graphql_stub([[{"data":{"updateChapters":{"chapters":[{"id":398,"isRead":true},{"id":399,"isRead":true}]}}}]])
        local bulk = api.markChaptersReadState(valid_credentials(), { "398", "399" }, true)
        assert.are.equal(true, bulk.ok)
        assert.are.equal("399", bulk.chapters[2].id)
    end)

    it("prefers stored chapters before falling back to fetched chapters", function()
        local stored_request = install_graphql_stub([[{"data":{"chapters":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[{"id":2,"sourceOrder":1,"name":"Stored Chapter"}]}}}]])
        local stored = api.fetchChaptersForManga(valid_credentials(), "17")
        assert.are.equal(true, stored.ok)
        assert.are.equal("Stored Chapter", stored.chapters[1].name)
        assert.are.equal(1, stored_request.count)

        local fetch_request = install_graphql_sequence_stub({
            { body = [[{"data":{"chapters":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}]] },
            { body = [[{"data":{"fetchChapters":{"chapters":[{"id":1,"sourceOrder":1,"name":"Fetched Chapter"}]}}}]] },
        })
        local fetched = api.fetchChaptersForManga(valid_credentials(), "17")
        assert.are.equal(true, fetched.ok)
        assert.are.equal("Fetched Chapter", fetched.chapters[1].name)
        assert.are.equal(2, fetch_request.count)
    end)

    it("returns credential, malformed response, and GraphQL errors from orchestration helpers", function()
        local missing_url = api.fetchSources({})
        assert.are.equal(false, missing_url.ok)
        assert.are.equal("Missing Suwayomi server URL.", missing_url.error)

        install_graphql_stub("{")
        local malformed = api.fetchMangaForSource(valid_credentials(), { source_id = "local" })
        assert.are.equal(false, malformed.ok)
        assert.are.equal("Invalid response from Suwayomi server.", malformed.error)

        install_graphql_stub([[{"data":{"fetchChapters":null},"errors":[{"message":"No chapters found"}]}]])
        local graph_error = api.fetchChaptersForManga(valid_credentials(), "17")
        assert.are.equal(false, graph_error.ok)
        assert.are.equal("Incomplete chapter load: No chapters found", graph_error.error)
        assert.are.equal("incomplete", graph_error.error_kind)
    end)

    it("delegates binary and archive downloads through the transport layer", function()
        local target_path = os.tmpname()
        os.remove(target_path)
        local requests = {}

        package.preload.ltn12 = function()
            return {
                sink = {
                    table = function(target)
                        return function(chunk)
                            table.insert(target, chunk)
                        end
                    end,
                },
            }
        end

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    table.insert(requests, options)
                    if options.sink then
                        options.sink(#requests == 1 and "PNG" or "CBZ")
                    end
                    return 1, 200, { ["content-type"] = #requests == 1 and "image/png" or "application/vnd.comicbook+zip" }
                end,
            }
        end

        local binary = api.downloadBinary(valid_credentials(), "/api/v1/page/1")
        assert.are.equal(true, binary.ok)
        assert.are.equal("PNG", binary.body)

        local archive = api.downloadChapterArchive(valid_credentials(), "398", target_path)
        assert.are.equal(true, archive.ok)
        assert.are.equal(target_path, archive.path)
        assert.are.equal("https://suwayomi.example/api/v1/chapter/398/download?markAsRead=false", requests[2].url)

        os.remove(target_path)
    end)

    it("does not inherit transport preload stubs from earlier examples", function()
        assert.is_nil(package.preload["ssl.https"])
        assert.is_nil(package.preload["socket.http"])
        assert.is_nil(package.preload.ltn12)
    end)
end)
