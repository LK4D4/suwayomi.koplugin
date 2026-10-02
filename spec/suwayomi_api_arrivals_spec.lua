package.path = "?.lua;" .. package.path

local json = require("dkjson")

describe("Library arrivals API", function()
    local api, requests, responses

    local function library(timestamp)
        local node = { id = 1, title = "Fixture", latestFetchedChapter = timestamp }
        return json.encode({ data = { mangas = {
            nodes = { node }, totalCount = 1, pageInfo = { hasNextPage = false },
        } } })
    end

    local function errors(...)
        local entries = {}
        for _, message in ipairs({ ... }) do entries[#entries + 1] = { message = message } end
        return json.encode({ errors = entries })
    end

    before_each(function()
        requests, responses = {}, {}
        package.loaded["suwayomi/api"] = nil
        package.loaded["suwayomi/api/transport"] = nil
        package.preload["suwayomi/api/transport"] = function()
            return { performGraphQLRequest = function(_, body)
                requests[#requests + 1] = json.decode(body)
                return responses[#requests] or { ok = true, response_body = library() }
            end }
        end
        api = require("suwayomi/api")
    end)

    after_each(function()
        package.loaded["suwayomi/api"] = nil
        package.loaded["suwayomi/api/transport"] = nil
        package.preload["suwayomi/api/transport"] = nil
    end)

    it("requests discovery only in Library and retains completion metadata", function()
        local query = json.decode(api._buildLibraryMangaQuery({ require_complete = true })).query
        assert.truthy(query:find("latestFetchedChapter { fetchedAt }", 1, true))
        assert.truthy(query:find("pageInfo { hasNextPage }", 1, true))
        assert.is_nil(json.decode(api._buildMangaQuery({})).query:find("latestFetchedChapter", 1, true))
        assert.is_nil(json.decode(api._buildRefreshMangaMutation(1)).query:find("latestFetchedChapter", 1, true))
    end)

    it("normalizes numeric and string Unix seconds at the Library parser boundary", function()
        for _, timestamp in ipairs({ 1700000000, "1700000000" }) do
            local parsed = assert(api.parseLibraryMangaResponse(library({ fetchedAt = timestamp }), true))
            assert.are.equal(1700000000, parsed.manga[1].latest_fetched_at)
        end
    end)

    it("leaves absent, malformed and unrenderable timestamps unknown", function()
        for _, timestamp in ipairs({ json.null, {}, { fetchedAt = json.null },
            { fetchedAt = 0 }, { fetchedAt = -1 }, { fetchedAt = 1.5 },
            { fetchedAt = "no date" }, { fetchedAt = true }, { fetchedAt = {} },
            { fetchedAt = "nan" }, { fetchedAt = "inf" }, { fetchedAt = "1e300" } }) do
            local parsed = assert(api.parseLibraryMangaResponse(library(timestamp), true))
            assert.is_nil(parsed.manga[1].latest_fetched_at)
        end
        assert.is_nil(assert(api.parseLibraryMangaResponse(library(), true)).manga[1].latest_fetched_at)
    end)

    it("reports support even when every timestamp is unknown", function()
        local result = api.fetchLibraryManga({}, { require_complete = true })
        assert.is_true(result.ok)
        assert.is_true(result.arrivals_supported)
        assert.is_nil(result.manga[1].latest_fetched_at)
    end)

    it("keeps unavailable server unread counts unknown and preserves valid zero", function()
        for _, count in ipairs({ json.null, "bad", false, {}, -1, 1.5, "inf" }) do
            local body = json.decode(library())
            body.data.mangas.nodes[1].unreadCount = count
            local parsed = assert(api.parseLibraryMangaResponse(json.encode(body), true))
            assert.is_nil(parsed.manga[1].unread_count)
        end
        for _, count in ipairs({ 0, "0", 12, "12" }) do
            local body = json.decode(library())
            body.data.mangas.nodes[1].unreadCount = count
            local parsed = assert(api.parseLibraryMangaResponse(json.encode(body), true))
            assert.are.equal(tonumber(count), parsed.manga[1].unread_count)
        end
    end)

    it("leaves timestamps unknown when the platform cannot render them", function()
        local date = os.date
        os.date = function() error("out of range") end
        local ok, parsed = pcall(api.parseLibraryMangaResponse, library({ fetchedAt = 1700000000 }), true)
        os.date = date
        assert.is_true(ok)
        assert.is_nil(parsed.manga[1].latest_fetched_at)
    end)

    it("retries discovery schema rejection without losing manga metadata", function()
        for _, field in ipairs({ "latestFetchedChapter", "fetchedAt" }) do
            requests = {}
            responses = { { ok = true, response_body = errors('Cannot query field "' .. field .. '" on type "Manga".') } }
            local result = api.fetchLibraryManga({}, { require_complete = true, first = 17, offset = 34 })
            assert.is_true(result.ok)
            assert.is_false(result.arrivals_supported)
            assert.are.equal(2, #requests)
            assert.is_nil(requests[2].query:find("latestFetchedChapter", 1, true))
            assert.truthy(requests[2].query:find("author", 1, true))
            assert.are.equal(17, requests[2].variables.first)
            assert.are.equal(34, requests[2].variables.offset)
        end
    end)

    it("preserves metadata fallback independently in either rejection order", function()
        for _, order in ipairs({ { "author", "latestFetchedChapter" }, { "latestFetchedChapter", "author" } }) do
            requests, responses = {}, {}
            for _, field in ipairs(order) do responses[#responses + 1] = {
                ok = true, response_body = errors('Cannot query field "' .. field .. '" on type "Manga".'),
            } end
            local result = api.fetchLibraryManga({}, { require_complete = true })
            assert.is_true(result.ok)
            assert.is_false(result.arrivals_supported)
            assert.are.equal(3, #requests)
            assert.is_nil(requests[3].query:find("author", 1, true))
            assert.is_nil(requests[3].query:find("latestFetchedChapter", 1, true))
        end
        requests = {}
        responses = { { ok = true, response_body = errors('Cannot query field "author" on type "Manga".') } }
        assert.is_true(api.fetchLibraryManga({}, { require_complete = true }).arrivals_supported)
        assert.truthy(requests[2].query:find("latestFetchedChapter", 1, true))
    end)

    it("handles simultaneous rejection and GraphQL Java schema error wording", function()
        responses = { { ok = true, response_body = errors(
            "Validation error (FieldUndefined@[mangas/nodes/latestFetchedChapter]) : Field 'latestFetchedChapter' in type 'MangaType' is undefined",
            'Unknown field "author" on type "Manga".') } }
        local result = api.fetchLibraryManga({}, { require_complete = true })
        assert.is_true(result.ok)
        assert.is_false(result.arrivals_supported)
        assert.are.equal(2, #requests)
        assert.is_nil(requests[2].query:find("author", 1, true))
        assert.is_nil(requests[2].query:find("latestFetchedChapter", 1, true))
    end)

    it("rejects partial GraphQL data rather than publishing supported capability", function()
        local payload = json.decode(library())
        payload.errors = { { message = "Unauthorized" } }
        responses = { { ok = true, response_body = json.encode(payload) } }
        local result = api.fetchLibraryManga({})
        assert.is_false(result.ok)
        assert.is_nil(result.arrivals_supported)
        assert.are.equal(1, #requests)
    end)

    it("does not retry authentication, transport or unrelated GraphQL failures", function()
        for _, response in ipairs({ { ok = false, error = "Network error" },
            { ok = false, error = "Unauthorized" },
            { ok = true, response_body = errors("Unauthorized latestFetchedChapter") },
            { ok = true, response_body = errors('Cannot query field "unrelated" on type "Manga".') },
            { ok = true, response_body = errors('Cannot query field "latestFetchedChapter" on type "Manga".', "Unauthorized") },
        }) do
            requests, responses = {}, { response }
            local result = api.fetchLibraryManga({}, { require_complete = true })
            assert.is_false(result.ok)
            assert.is_nil(result.arrivals_supported)
            assert.are.equal(1, #requests)
        end
    end)
end)
