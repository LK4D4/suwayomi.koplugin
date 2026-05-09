-- Boundary: Browse global search worker process.
--
-- Responsibility: fetch one source search page in a subprocess-friendly module
-- and write a compact JSON result for the client to poll.
-- Owned state: none.
-- Dependencies: Suwayomi API facade and shared subprocess result-file helper.
-- External data: credentials, source rows, query text, and API responses are
-- normalized into explicit per-source result records.

local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")

local GlobalSearchWorker = {}

function GlobalSearchWorker:writeResult(result_path, result)
    return SubprocessJob.writeResult(result_path, result)
end

local function normalizeSource(source)
    source = type(source) == "table" and source or {}
    return {
        id = source.id ~= nil and tostring(source.id) or nil,
        name = source.name,
        display_name = source.display_name,
        displayName = source.displayName,
        raw_name = source.raw_name,
        lang = source.lang,
        supports_latest = source.supports_latest,
        is_nsfw = source.is_nsfw,
    }
end

function GlobalSearchWorker:readResult(result_path)
    return SubprocessJob.readResult(result_path, function(parsed)
        parsed.ok = parsed.ok == true
        parsed.source = normalizeSource(parsed.source)
        parsed.query = tostring(parsed.query or "")
        parsed.manga = type(parsed.manga) == "table" and parsed.manga or {}
        parsed.has_next_page = parsed.has_next_page == true
        if not parsed.ok then
            parsed.error = parsed.error or "Could not load manga."
        end
        return parsed
    end)
end

function GlobalSearchWorker:run(credentials, source, query, result_path)
    source = normalizeSource(source)
    local ok, api_result = pcall(function()
        return SuwayomiAPI.fetchMangaForSource(credentials, {
            source_id = source.id,
            page = 1,
            type = "SEARCH",
            query = query,
        })
    end)

    local result
    if not ok then
        result = {
            ok = false,
            source = source,
            query = query,
            error = tostring(api_result),
            manga = {},
            has_next_page = false,
        }
    elseif not api_result or not api_result.ok then
        result = {
            ok = false,
            source = source,
            query = query,
            error = api_result and api_result.error or "Could not load manga.",
            manga = {},
            has_next_page = false,
        }
    else
        result = {
            ok = true,
            source = source,
            query = query,
            manga = type(api_result.manga) == "table" and api_result.manga or {},
            has_next_page = api_result.has_next_page == true,
        }
    end

    self:writeResult(result_path, result)
    return result
end

return GlobalSearchWorker
