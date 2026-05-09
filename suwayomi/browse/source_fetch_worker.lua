-- Boundary: Browse source fetch worker process.
--
-- Responsibility: fetch sources in a subprocess-friendly module and write a
-- small JSON result file for the controller to poll.
-- Owned state: none.
-- Dependencies: dkjson, Suwayomi API facade, and Lua file IO.
-- External data: credentials, result paths, API responses, and filesystem
-- writes are normalized into an explicit result file.

local json = require("dkjson")
local SuwayomiAPI = require("suwayomi/api")

local SourceFetchWorker = {}

function SourceFetchWorker:writeResult(result_path, result)
    if not result_path or result_path == "" then
        return false
    end

    local tmp_path = tostring(result_path) .. ".tmp"
    local handle = io.open(tmp_path, "w")
    if not handle then
        return false
    end

    handle:write(json.encode(result or {}))
    handle:close()
    if not os.rename(tmp_path, result_path) then
        os.remove(tmp_path)
        return false
    end
    return true
end

function SourceFetchWorker:readResult(result_path)
    local handle = result_path and io.open(result_path, "r")
    if not handle then
        return nil
    end

    local content = handle:read("*a") or ""
    handle:close()

    local parsed = json.decode(content)
    if type(parsed) ~= "table" then
        return nil
    end
    parsed.ok = parsed.ok == true
    parsed.sources = type(parsed.sources) == "table" and parsed.sources or {}
    return parsed
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
        result = SuwayomiAPI.fetchSources(credentials) or {
            ok = false,
            error = "Could not fetch Suwayomi sources.",
            sources = {},
        }
        result.sources = type(result.sources) == "table" and result.sources or {}
    end

    self:writeResult(result_path, result)
    return result
end

return SourceFetchWorker
