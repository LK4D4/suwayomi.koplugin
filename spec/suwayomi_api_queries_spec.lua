package.path = "?.lua;" .. package.path

-- Pure query-builder coverage: these specs pin the JSON/GraphQL contracts
-- without installing HTTP or parser stubs.
describe("suwayomi/api/queries", function()
    local json = require("dkjson")
    local queries

    before_each(function()
        package.loaded["suwayomi/api/queries"] = nil
        queries = require("suwayomi/api/queries")
    end)

    local function decode_request(request_body)
        local payload = json.decode(request_body)
        assert.is_table(payload)
        return payload
    end

    it("builds the sources queries", function()
        local query = queries._buildSourcesQuery()
        assert.truthy(query:match("query getSources"))
        assert.truthy(query:match("sources { nodes { id name displayName lang isNsfw supportsLatest } }"))

        local legacy_query = queries._buildLegacySourcesQuery()
        assert.truthy(legacy_query:match("query getSources"))
        assert.truthy(legacy_query:match("sources { nodes { id name displayName lang } }"))
        assert.is_nil(legacy_query:match("isNsfw"))
        assert.is_nil(legacy_query:match("supportsLatest"))
    end)

    it("builds manga browse queries with normalized input", function()
        local payload = decode_request(queries._buildMangaQuery({
            source_id = "2499283573021220255",
            page = "2",
            type = "SEARCH",
            query = "frieren",
            filters = { genre = "fantasy" },
        }))

        assert.truthy(payload.query:match("fetchSourceManga"))
        assert.are.equal("2499283573021220255", payload.variables.input.source)
        assert.are.equal(2, payload.variables.input.page)
        assert.are.equal("SEARCH", payload.variables.input.type)
        assert.are.equal("frieren", payload.variables.input.query)
        assert.are.equal("fantasy", payload.variables.input.filters.genre)
    end)

    it("builds library and category queries", function()
        local library = decode_request(queries._buildLibraryMangaQuery({ first = "50", offset = "10", order = { { by = "TITLE" } } }))
        assert.truthy(library.query:match("GET_LIBRARY_MANGAS"))
        assert.are.equal(true, library.variables.filter.inLibrary.equalTo)
        assert.are.equal(50, library.variables.first)
        assert.are.equal(10, library.variables.offset)
        assert.are.equal("TITLE", library.variables.order[1].by)

        local categories = queries._buildCategoryQuery()
        assert.truthy(categories:match("GET_LIBRARY_CATEGORIES"))
        assert.truthy(categories:match("mangas { totalCount }"))
    end)

    it("builds manga update and refresh mutations", function()
        local update = decode_request(queries._buildUpdateMangaLibraryMutation("17", true))
        assert.truthy(update.query:match("UPDATE_MANGA_LIBRARY"))
        assert.are.equal(17, update.variables.input.id)
        assert.are.equal(true, update.variables.input.patch.inLibrary)

        local refresh = decode_request(queries._buildRefreshMangaMutation("17"))
        assert.truthy(refresh.query:match("REFRESH_MANGA"))
        assert.truthy(refresh.query:match("fetchManga"))
        assert.truthy(refresh.query:match("fetchChapters"))
        assert.are.equal(17, refresh.variables.manga.id)
        assert.are.equal(17, refresh.variables.chapters.mangaId)
    end)

    it("builds chapter queries and read-state mutations", function()
        local fetched = decode_request(queries._buildChapterQuery("17"))
        assert.truthy(fetched.query:match("GET_MANGA_CHAPTERS_FETCH"))
        assert.are.equal(17, fetched.variables.input.mangaId)

        local pages = decode_request(queries._buildChapterPagesQuery("398"))
        assert.truthy(pages.query:match("fetchChapterPages"))
        assert.are.equal(398, pages.variables.input.chapterId)

        local stored = decode_request(queries._buildStoredChapterQuery("17"))
        assert.truthy(stored.query:match("GET_CHAPTERS_MANGA"))
        assert.are.equal(17, stored.variables.filter.mangaId.equalTo)
        assert.are.equal(200, stored.variables.first)

        local read = decode_request(queries._buildUpdateChapterReadMutation("398", true))
        assert.truthy(read.query:match("UPDATE_CHAPTER_READ"))
        assert.are.equal(398, read.variables.input.id)
        assert.are.equal(true, read.variables.input.patch.isRead)

        local bulk = decode_request(queries._buildUpdateChaptersReadMutation({ "398", "399" }, false))
        assert.truthy(bulk.query:match("UPDATE_CHAPTERS_READ"))
        assert.are.same({ 398, 399 }, bulk.variables.input.ids)
        assert.are.equal(false, bulk.variables.input.patch.isRead)

        assert.are.equal(queries._buildUpdateChapterReadMutation("398", true), queries._buildMarkChapterReadMutation("398"))
        assert.are.equal(queries._buildUpdateChapterReadMutation("398", false), queries._buildMarkChapterUnreadMutation("398"))
    end)
end)
