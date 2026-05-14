-- Boundary: Browse extension management worker process.
--
-- Responsibility: fetch/install/update/uninstall extensions in a subprocess-friendly
-- module and write compact JSON results for Browse controller polling.
-- Owned state: none.
-- Dependencies: Suwayomi API facade and shared subprocess result-file helpers.
-- External data: credentials, extension package names, API responses, and
-- result paths are normalized into explicit result records.

local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")

local ExtensionWorker = {}
local SOURCE_REFRESH_RETRY_DELAYS_SECONDS = { 0.5, 1, 2 }

local function normalizeRequest(request)
    request = type(request) == "table" and request or {}
    return {
        action = request.action or "fetch",
        pkg_name = request.pkg_name,
    }
end

local function normalizeResult(result)
    result = type(result) == "table" and result or {}
    result.ok = result.ok == true
    result.extensions = type(result.extensions) == "table" and result.extensions or {}
    result.sources = type(result.sources) == "table" and result.sources or {}
    return result
end

local function sourceCount(result)
    if result and result.ok and type(result.sources) == "table" then
        return #result.sources
    end
    return nil
end

local function sourceCatalogChanged(action, before_count, after_result)
    if before_count == nil then
        return true
    end
    local after_count = sourceCount(after_result)
    if after_count == nil then
        return true
    end
    if action == "install" then
        return after_count > before_count
    end
    if action == "uninstall" then
        return after_count < before_count
    end
    return true
end

local function sleep(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.sleep then
        socket.sleep(seconds)
    end
end

local function fetchSourcesAfterAction(credentials, action, before_count)
    local sources = SuwayomiAPI.fetchSources(credentials) or {}
    if action ~= "install" and action ~= "uninstall" then
        return sources
    end
    for _, delay in ipairs(SOURCE_REFRESH_RETRY_DELAYS_SECONDS) do
        if sourceCatalogChanged(action, before_count, sources) then
            return sources
        end
        sleep(delay)
        sources = SuwayomiAPI.fetchSources(credentials) or sources
    end
    return sources
end

local function fallbackExtensionList(extensions_result, updated_extension)
    if extensions_result and extensions_result.ok == true then
        return extensions_result.extensions
    end
    if type(updated_extension) == "table" then
        return { updated_extension }
    end
    return {}
end

function ExtensionWorker:writeResult(result_path, result)
    return SubprocessJob.writeResult(result_path, normalizeResult(result))
end

function ExtensionWorker:readResult(result_path)
    return SubprocessJob.readResult(result_path, normalizeResult)
end

function ExtensionWorker:run(credentials, request, result_path)
    request = normalizeRequest(request)
    local result

    if not credentials or credentials.server_url == "" then
        result = {
            ok = false,
            error = "Missing Suwayomi server URL.",
        }
    elseif request.action == "fetch" then
        result = SuwayomiAPI.fetchExtensions(credentials) or {
            ok = false,
            error = "Could not fetch Suwayomi extensions.",
        }
    elseif request.action == "install" or request.action == "update" or request.action == "uninstall" then
        local previous_sources
        if request.action == "install" or request.action == "uninstall" then
            previous_sources = SuwayomiAPI.fetchSources(credentials)
        end
        local updated = SuwayomiAPI.updateExtension(credentials, request.pkg_name, request.action) or {
            ok = false,
            error = "Could not update Suwayomi extension.",
        }
        if updated.ok then
            local extensions = SuwayomiAPI.fetchExtensions(credentials) or {}
            local sources = fetchSourcesAfterAction(credentials, request.action, sourceCount(previous_sources))
            local extensions_ok = extensions.ok == true
            result = {
                ok = true,
                action = request.action,
                updated_extension = updated.extension,
                extension_refresh_ok = extensions_ok,
                extension_refresh_error = not extensions_ok and extensions.error or nil,
                extensions = fallbackExtensionList(extensions, updated.extension),
                sources = sources.ok and sources.sources or {},
            }
        else
            result = updated
            result.action = request.action
        end
    else
        result = {
            ok = false,
            error = "Unsupported extension action.",
        }
    end

    result = normalizeResult(result)
    self:writeResult(result_path, result)
    return result
end

return ExtensionWorker
