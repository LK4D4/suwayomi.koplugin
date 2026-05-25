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

local function normalizeExternalErrorMessage(error_message)
    if type(error_message) ~= "string" then
        return nil
    end
    if error_message:match("^%s*$") then
        return nil
    end
    return error_message
end

local function hasServerUrl(credentials)
    return type(credentials) == "table"
        and type(credentials.server_url) == "string"
        and credentials.server_url:match("^%s*$") == nil
end

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

local function successMessageId(attempt)
    if attempt and attempt > 1 then
        return "connection_test_passed_after_retry"
    end
    return "connection_test_passed"
end

local function normalizeResult(result)
    result = type(result) == "table" and result or {}
    return {
        ok = result.ok == true,
        source_count = tonumber(result.source_count) or 0,
        error = normalizeExternalErrorMessage(result.error),
        error_id = result.error_id,
        message_id = result.message_id,
    }
end

local function externalErrorMessage(response)
    if type(response) ~= "table" then
        return nil
    end
    return normalizeExternalErrorMessage(response.error)
end

function OnboardingConnectionWorker:writeResult(result_path, result)
    return SubprocessJob.writeResult(result_path, normalizeResult(result))
end

function OnboardingConnectionWorker:readResult(result_path)
    return SubprocessJob.readResult(result_path, normalizeResult)
end

function OnboardingConnectionWorker:run(credentials, result_path)
    local result
    if not hasServerUrl(credentials) then
        result = {
            ok = false,
            error_id = "missing_server_url",
        }
    else
        local response, attempt = runConnectionTest(credentials)
        if response.ok == true then
            result = {
                ok = true,
                source_count = 0,
                message_id = successMessageId(attempt),
            }
        else
            local external_error = externalErrorMessage(response)
            local error_id
            if external_error == nil then
                error_id = "could_not_connect"
            end
            result = {
                ok = false,
                error = external_error,
                error_id = error_id,
            }
        end
    end

    self:writeResult(result_path, result)
    return normalizeResult(result)
end

return OnboardingConnectionWorker
