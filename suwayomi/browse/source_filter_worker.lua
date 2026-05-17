-- Boundary: Browse source filter worker process.
--
-- Responsibility: fetch one source filter schema in a subprocess-friendly module
-- and write a compact JSON result for the UI process to poll.
-- Owned state: none.
-- Dependencies: Suwayomi API facade and shared subprocess result-file helper.
-- External data: credentials, source rows, and API responses are normalized into
-- explicit source filter result records.

local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")

local SourceFilterWorker = {}

function SourceFilterWorker:writeResult(result_path, result)
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

function SourceFilterWorker:readResult(result_path)
    return SubprocessJob.readResult(result_path, function(parsed)
        parsed.ok = parsed.ok == true
        parsed.source = normalizeSource(parsed.source)
        parsed.filters = type(parsed.filters) == "table" and parsed.filters or {}
        if not parsed.ok then
            parsed.error = parsed.error or "Could not load source filters."
        end
        return parsed
    end)
end

function SourceFilterWorker:run(credentials, source, result_path)
    source = normalizeSource(source)
    local ok, api_result = pcall(function()
        return SuwayomiAPI.fetchSourceFilters(credentials, source.id)
    end)

    local result
    if not ok then
        result = {
            ok = false,
            source = source,
            error = tostring(api_result),
            filters = {},
        }
    elseif not api_result or not api_result.ok then
        result = {
            ok = false,
            source = source,
            error = api_result and api_result.error or "Could not load source filters.",
            filters = {},
        }
    else
        result = {
            ok = true,
            source = normalizeSource(api_result.source or source),
            filters = type(api_result.filters) == "table" and api_result.filters or {},
        }
    end

    self:writeResult(result_path, result)
    return result
end

return SourceFilterWorker
