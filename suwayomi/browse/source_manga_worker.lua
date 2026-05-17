-- Boundary: Browse source manga worker process.
--
-- Responsibility: fetch one source browse/search page in a subprocess-friendly
-- module and write a compact JSON result for the UI process to poll.
-- Owned state: none.
-- Dependencies: Suwayomi API facade and shared subprocess result-file helper.
-- External data: credentials, source rows, browse options, and API responses
-- are normalized into explicit source manga result records.

local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")

local SourceMangaWorker = {}

function SourceMangaWorker:writeResult(result_path, result)
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

local function normalizeBrowseOptions(options)
    options = type(options) == "table" and options or {}
    local browse_options = {
        type = options.type or "POPULAR",
        page = tonumber(options.page) or 1,
    }
    if browse_options.type == "SEARCH" then
        browse_options.query = tostring(options.query or "")
        if type(options.filters) == "table" then
            browse_options.filters = options.filters
        end
    end
    return browse_options
end

local function buildRequestOptions(source, browse_options)
    local request_options = {
        source_id = source.id,
        page = browse_options.page,
        type = browse_options.type,
    }
    if request_options.type == "SEARCH" then
        request_options.query = browse_options.query
        request_options.filters = browse_options.filters
    end
    return request_options
end

function SourceMangaWorker:readResult(result_path)
    return SubprocessJob.readResult(result_path, function(parsed)
        parsed.ok = parsed.ok == true
        parsed.source = normalizeSource(parsed.source)
        parsed.browse_options = normalizeBrowseOptions(parsed.browse_options)
        parsed.manga = type(parsed.manga) == "table" and parsed.manga or {}
        parsed.has_next_page = parsed.has_next_page == true
        if not parsed.ok then
            parsed.error = parsed.error or "Could not load manga."
        end
        return parsed
    end)
end

function SourceMangaWorker:run(credentials, source, browse_options, result_path)
    source = normalizeSource(source)
    browse_options = normalizeBrowseOptions(browse_options)
    local ok, api_result = pcall(function()
        return SuwayomiAPI.fetchMangaForSource(credentials, buildRequestOptions(source, browse_options))
    end)

    local result
    if not ok then
        result = {
            ok = false,
            source = source,
            browse_options = browse_options,
            error = tostring(api_result),
            manga = {},
            has_next_page = false,
        }
    elseif not api_result or not api_result.ok then
        result = {
            ok = false,
            source = source,
            browse_options = browse_options,
            error = api_result and api_result.error or "Could not load manga.",
            manga = {},
            has_next_page = false,
        }
    else
        result = {
            ok = true,
            source = source,
            browse_options = browse_options,
            manga = type(api_result.manga) == "table" and api_result.manga or {},
            has_next_page = api_result.has_next_page == true,
        }
    end

    self:writeResult(result_path, result)
    return result
end

return SourceMangaWorker
