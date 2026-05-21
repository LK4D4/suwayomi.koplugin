-- Boundary: device-local progress file paths and parsing.
--
-- Responsibility: keep the hidden progress filename contract, parse downloader
-- progress files, and provide the fallback writer used by legacy downloader
-- flows.
-- Owned state: none.
-- Injected dependencies: Lua io/os.
-- External data: filesystem paths and line-oriented progress files, treated as
-- untrusted because polling may observe files produced by a worker process.

local ProgressFile = {}

local function buildLegacyName(key)
    local sanitized_key = tostring(key or ""):gsub("[^%w%-_%.]", "_")
    return sanitized_key
end

local function encodeKey(key)
    local encoded = {}
    for index = 1, #key do
        encoded[#encoded + 1] = string.format("%02x", key:byte(index))
    end
    return table.concat(encoded)
end

local function lineSafe(value)
    return tostring(value or ""):gsub("%c+", " ")
end

function ProgressFile.lineSafe(value)
    return lineSafe(value)
end

function ProgressFile.buildPath(key, download_directory)
    local encoded_key = encodeKey(tostring(key or ""))
    if encoded_key == "" then
        encoded_key = "empty"
    end
    return (download_directory or ""):gsub("/+$", "") .. "/.suwayomi_progress_" .. encoded_key .. ".txt"
end

function ProgressFile.buildLegacyPath(key, download_directory)
    local sanitized_key = buildLegacyName(key)
    return (download_directory or ""):gsub("/+$", "") .. "/.suwayomi_progress_" .. sanitized_key .. ".txt"
end

function ProgressFile.read(progress_path)
    local handle = io.open(progress_path, "r")
    if not handle then
        return nil
    end

    local status = {}
    for line in handle:lines() do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then
            status[key] = value
        end
    end
    handle:close()

    if status.current then
        status.current = tonumber(status.current)
    end
    if status.total then
        status.total = tonumber(status.total)
    end
    return status
end

function ProgressFile.writeFallback(progress_path, state, current, total, path, error_message)
    -- Polling reads this file from another code path, so write a full temp file
    -- before renaming it into place to avoid observing partial key/value state.
    local tmp_path = tostring(progress_path or "") .. ".tmp"
    local handle = io.open(tmp_path, "w")
    if not handle then
        return
    end
    handle:write("state=", lineSafe(state), "\n")
    handle:write("current=", lineSafe(current or 0), "\n")
    handle:write("total=", lineSafe(total or 0), "\n")
    handle:write("path=", lineSafe(path), "\n")
    if error_message then
        handle:write("error=", lineSafe(error_message), "\n")
    end
    handle:close()
    if not os.rename(tmp_path, progress_path) then
        os.remove(tmp_path)
    end
end

return ProgressFile
