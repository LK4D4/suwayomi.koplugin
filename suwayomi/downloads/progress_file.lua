-- Boundary: device-local progress file paths and parsing.
--
-- Responsibility: keep attempt-private progress paths and atomic line-oriented
-- progress IO shared by the downloader and its owner.
-- Owned state: none.
-- Injected dependencies: Lua io/os.
-- External data: filesystem paths and line-oriented progress files, treated as
-- untrusted because polling may observe files produced by a worker process.

local ProgressFile = {}


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

function ProgressFile.buildPath(key, download_directory, attempt_id)
    assert(type(attempt_id) == "string" and #attempt_id == 32 and attempt_id:match("^[0-9a-f]+$"), "Invalid download attempt ID")
    local encoded_key = encodeKey(tostring(key or ""))
    if encoded_key == "" then
        encoded_key = "empty"
    end
    return (download_directory or ""):gsub("/+$", "") .. "/.suwayomi_progress_" .. encoded_key .. "_" .. attempt_id .. ".txt"
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
    if status.retryable ~= nil then
        status.retryable = status.retryable == "true"
    end
    return status
end

function ProgressFile.writeFallback(progress_path, state, current, total, path, error_message, retryable, details)
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
    if retryable ~= nil then
        handle:write("retryable=", retryable == true and "true" or "false", "\n")
    end
    if type(details) == "table" then
        if details.archive_state then handle:write("archive_state=", lineSafe(details.archive_state), "\n") end
        if details.identity then handle:write("identity=", lineSafe(details.identity), "\n") end
    end
    local closed = handle:close()
    if not closed then
        os.remove(tmp_path)
        return
    end
    if not os.rename(tmp_path, progress_path) then
        os.remove(tmp_path)
    end
end

return ProgressFile
