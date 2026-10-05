package.path = "?.lua;" .. package.path

local json = require("dkjson")

describe("scanlator-scoped Library API", function()
    local api, requests, response
    local scopes = { { manga_id = 7, filter = "Team A" } }

    local function payload(count, total, nodes)
        return { data = { unread1 = { totalCount = count }, latest1 = { totalCount = total, nodes = nodes } } }
    end

    before_each(function()
        requests = {}
        response = payload(2, 3, { { fetchedAt = "1700000000" } })
        package.loaded["suwayomi/api"] = nil
        package.loaded["suwayomi/api/transport"] = nil
        package.preload["suwayomi/api/transport"] = function()
            return { performGraphQLRequest = function(_, body)
                requests[#requests + 1] = json.decode(body)
                return { ok = true, response_body = json.encode(response) }
            end }
        end
        api = require("suwayomi/api")
    end)

    after_each(function()
        package.loaded["suwayomi/api"] = nil
        package.loaded["suwayomi/api/transport"] = nil
        package.preload["suwayomi/api/transport"] = nil
    end)

    it("reads exact matching unread releases and the latest discovery including read chapters", function()
        local result = api.fetchLibraryScanlatorMetadata({}, scopes)
        assert.is_true(result.ok)
        assert.same({ manga_id = "7", filter = "Team A", unread_count = 2,
            latest_fetched_at = 1700000000 }, result.metadata["7"])
        assert.same({ mangaId = { equalTo = 7 }, scanlator = { equalTo = "Team A" },
            isRead = { equalTo = false } }, requests[1].variables.unread1)
        assert.same({ mangaId = { equalTo = 7 }, scanlator = { equalTo = "Team A" },
            fetchedAt = { greaterThan = "0", lessThanOrEqualTo = "9007199254740991" } },
            requests[1].variables.latest1)
        assert.matches("first: 0", requests[1].query, 1, true)
        assert.matches("first: 1", requests[1].query, 1, true)
        assert.matches("FETCHED_AT", requests[1].query, 1, true)
        assert.is_nil(requests[1].query:find("mutation", 1, true))
    end)

    it("distinguishes confirmed no matches from matching unread chapters with unknown discovery", function()
        for _, count in ipairs({ 0, 2 }) do
            response = payload(count, 0, {})
            local result = api.fetchLibraryScanlatorMetadata({}, scopes)
            assert.is_true(result.ok)
            assert.are.equal(count, result.metadata["7"].unread_count)
            assert.is_nil(result.metadata["7"].latest_fetched_at)
        end
    end)

    it("keeps manga identities distinct within a bounded batch", function()
        response.data.unread2 = { totalCount = 0 }
        response.data.latest2 = { totalCount = 1, nodes = { { fetchedAt = "1800000000" } } }
        local result = api.fetchLibraryScanlatorMetadata({}, { scopes[1], { manga_id = 8, filter = "Team B" } })
        assert.are.equal(2, result.metadata["7"].unread_count)
        assert.are.equal(0, result.metadata["8"].unread_count)
        assert.are.equal(1800000000, result.metadata["8"].latest_fetched_at)
        assert.are.equal("Team B", requests[1].variables.latest2.scanlator.equalTo)
    end)

    for name, body in pairs({
        missing = { data = {} },
        partial = { data = { unread1 = { totalCount = 0 } } },
        null = { data = json.null },
        negative = payload(-1, 0, {}),
        fractional = payload(1.5, 0, {}),
        absent_nodes = payload(0, 0, json.null),
        missing_latest = payload(0, 1, {}),
        unexpected_latest = payload(0, 0, { { fetchedAt = "1" } }),
        oversized_latest = payload(0, 2, { { fetchedAt = "1" }, { fetchedAt = "2" } }),
        unsupported = { errors = { { message = "Unknown filter field scanlator" } } },
        errors_with_data = { data = payload(0, 0, {}).data, errors = { { message = "Unauthorized" } } },
    }) do
        it("leaves " .. name .. " metadata unavailable without broadening the query", function()
            response = body
            assert.is_false(api.fetchLibraryScanlatorMetadata({}, scopes).ok)
            assert.are.equal(1, #requests)
        end)
    end

    it("rejects empty restrictions and oversized batches before networking", function()
        assert.is_false(api.fetchLibraryScanlatorMetadata({}, { { manga_id = 7, filter = "" } }).ok)
        local batch = {}
        for id = 1, 21 do batch[id] = { manga_id = id, filter = "A" } end
        assert.is_false(api.fetchLibraryScanlatorMetadata({}, batch).ok)
        assert.same({}, requests)
    end)
end)
