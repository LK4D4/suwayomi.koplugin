-- Boundary: Browse source fetch worker process.
--
-- Responsibility: fetch sources in a subprocess-friendly module and write a
-- small JSON result file for the controller to poll.
-- Owned state: none.
-- Dependencies: dkjson, Suwayomi API facade, and Lua file IO.
-- External data: credentials, result paths, API responses, and filesystem
-- writes are normalized into an explicit result file.

local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")

local SourceFetchWorker = {}

function SourceFetchWorker:writeResult(result_path, result)
    return SubprocessJob.writeResult(result_path, result)
end

function SourceFetchWorker:readResult(result_path)
    return SubprocessJob.readResult(result_path, function(parsed)
        parsed.ok = parsed.ok == true
        parsed.sources = type(parsed.sources) == "table" and parsed.sources or {}
        return parsed
    end)
end

function SourceFetchWorker:run(credentials, result_path)
    local result
    if not credentials or credentials.server_url == "" then
        result = {
            ok = false,
            error = "Missing Suwayomi server URL.",
            sources = {},
        }
    else
        local ok, fetched = pcall(function()
            return SuwayomiAPI.fetchSources(credentials)
        end)
        if ok then
            result = fetched or {
                ok = false,
                error = "Could not fetch Suwayomi sources.",
                sources = {},
            }
        else
            result = {
                ok = false,
                error = tostring(fetched),
                sources = {},
            }
        end
        result.sources = type(result.sources) == "table" and result.sources or {}
    end

    self:writeResult(result_path, result)
    return result
end

return SourceFetchWorker
