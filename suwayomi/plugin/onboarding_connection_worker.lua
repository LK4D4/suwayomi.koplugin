-- Boundary: Onboarding connection test worker.
--
-- Responsibility: verify Suwayomi credentials in a subprocess-friendly module.
-- Owned state: none.
-- Dependencies: Suwayomi API facade and shared subprocess result IO.
-- External data: credentials and API responses are normalized before callers see them.

local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")

local OnboardingConnectionWorker = {}
local CONNECTION_TEST_ATTEMPTS = 3
local CONNECTION_TEST_TIMEOUT_SECONDS = 5

local function isTransientConnectionError(error_message)
    error_message = tostring(error_message or ""):lower()
    return error_message:match("timed out") ~= nil
        or error_message:match("could not reach") ~= nil
end

local function runConnectionTest(credentials)
    local last_response
    for attempt = 1, CONNECTION_TEST_ATTEMPTS do
        local response
        if SuwayomiAPI.testConnection then
            response = SuwayomiAPI.testConnection(credentials, {
                timeout_seconds = CONNECTION_TEST_TIMEOUT_SECONDS,
            })
        else
            response = SuwayomiAPI.fetchSources(credentials)
        end
        response = response or {}
        if response.ok == true then
            return response, attempt
        end
        last_response = response
        if not isTransientConnectionError(response.error) then
            break
        end
    end
    return last_response or { ok = false, error = "Could not connect to Suwayomi." }, CONNECTION_TEST_ATTEMPTS
end

local function successMessage(attempt)
    if attempt and attempt > 1 then
        return "Connection test passed after retry."
    end
    return "Connection test passed."
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
        local response, attempt = runConnectionTest(credentials)
        if response.ok == true then
            result = {
                ok = true,
                source_count = 0,
                message = successMessage(attempt),
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
