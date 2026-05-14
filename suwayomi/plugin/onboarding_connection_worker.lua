-- Boundary: Onboarding connection test worker.
--
-- Responsibility: verify Suwayomi credentials in a subprocess-friendly module.
-- Owned state: none.
-- Dependencies: Suwayomi API facade and shared subprocess result IO.
-- External data: credentials and API responses are normalized before callers see them.

local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")

local OnboardingConnectionWorker = {}

local function countSources(sources)
    local count = 0
    for _, _ in ipairs(sources or {}) do
        count = count + 1
    end
    return count
end

local function successMessage(source_count)
    if source_count == 1 then
        return "Connection test passed. Found 1 source."
    end
    return "Connection test passed. Found " .. tostring(source_count) .. " sources."
end

local function normalizeResult(result)
    result = type(result) == "table" and result or {}
    result.ok = result.ok == true
    result.source_count = tonumber(result.source_count) or 0
    result.error = result.error
    result.message = result.message
    return result
end

function OnboardingConnectionWorker:writeResult(result_path, result)
    return SubprocessJob.writeResult(result_path, normalizeResult(result))
end

function OnboardingConnectionWorker:readResult(result_path)
    return SubprocessJob.readResult(result_path, normalizeResult)
end

function OnboardingConnectionWorker:run(credentials, result_path)
    local result
    if not credentials or credentials.server_url == "" then
        result = {
            ok = false,
            error = "Enter a Suwayomi server URL first.",
        }
    else
        local response = SuwayomiAPI.fetchSources(credentials) or {}
        if response.ok == true then
            local source_count = countSources(response.sources)
            result = {
                ok = true,
                source_count = source_count,
                message = successMessage(source_count),
            }
        else
            result = {
                ok = false,
                error = response.error or "Could not connect to Suwayomi.",
            }
        end
    end

    self:writeResult(result_path, result)
    return normalizeResult(result)
end

return OnboardingConnectionWorker
