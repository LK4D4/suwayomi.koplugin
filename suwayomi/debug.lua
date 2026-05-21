-- Boundary: optional debug logging.
--
-- Responsibility: load debug settings, redact sensitive values, and send
-- structured Suwayomi-prefixed logs when enabled.
-- Owned state: cached logger, settings dir, and debug config.
-- Dependencies: KOReader logger/datastorage/luasettings when available.
-- External data: log payloads are redacted before leaving this module.

local Debug = {}

local logger
local settings_dir
local config

local function loadLogger()
    if logger ~= nil then
        return logger
    end

    local ok, loaded = pcall(require, "logger")
    if ok then
        logger = loaded
    else
        logger = false
    end
    return logger
end

local function loadSettingsDir()
    if settings_dir ~= nil then
        return settings_dir
    end

    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage and DataStorage.getSettingsDir then
        settings_dir = DataStorage:getSettingsDir()
    else
        settings_dir = false
    end
    return settings_dir
end

local function loadConfig()
    if config ~= nil then
        return config
    end

    local dir = loadSettingsDir()
    if not dir or dir == "" then
        config = false
        return config
    end

    local loader = loadfile(dir .. "/suwayomi_debug.lua")
    if not loader then
        config = false
        return config
    end

    local ok, loaded = pcall(loader)
    if ok and type(loaded) == "table" and loaded.enabled == true then
        config = loaded
    else
        config = false
    end
    return config
end

local function shouldLog(event)
    local loaded_config = loadConfig()
    if not loaded_config then
        return false
    end

    local threshold = tonumber(loaded_config.slow_threshold_ms)
    local elapsed_ms = event and tonumber(event.elapsed_ms)
    if threshold and elapsed_ms and elapsed_ms < threshold then
        return false
    end
    return true
end

local function now()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then
        return socket.gettime()
    end
    return os.time()
end

local safe_log_keys = {
    attempt = true,
    attempted = true,
    code = true,
    code_type = true,
    delay_seconds = true,
    elapsed_ms = true,
    event = true,
    ok = true,
    operation = true,
    plugin = true,
    request_bytes = true,
    response_bytes = true,
    same_origin = true,
    status = true,
    status_code = true,
    success = true,
}

local function isSafeLogKey(key)
    return safe_log_keys[key]
        or key:match("_count$") ~= nil
        or key:match("_ms$") ~= nil
        or key:match("_seconds$") ~= nil
end

local function isSensitiveLogKey(key)
    return key:match("password")
        or key:match("authorization")
        or key:match("credential")
        or key:match("username")
        or key:match("query")
        or key:match("title")
        or key:match("source")
        or key:match("path")
        or key:match("url")
        or key:match("token")
        or key:match("secret")
        or key:match("cookie")
end

local function sanitizeValue(key, value)
    key = tostring(key or ""):lower()
    if isSensitiveLogKey(key) then
        return "<redacted>"
    end
    if type(value) == "table" then
        return "<redacted>"
    end
    local scalar = tostring(value)
    if scalar:match("^https?://")
        or scalar:match("^/")
        or scalar:match("^%a:[/\\]")
        or scalar:match("[/\\][^/\\]+[/\\]")
    then
        return "<redacted>"
    end
    if not isSafeLogKey(key) then
        return "<redacted>"
    end
    return scalar
end

local function formatEvent(event)
    event = event or {}
    local keys = {}
    for key in pairs(event) do
        table.insert(keys, key)
    end
    table.sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)

    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, tostring(key) .. "=" .. sanitizeValue(key, event[key]))
    end
    return table.concat(parts, " ")
end

local function writeFileLine(line)
    local dir = loadSettingsDir()
    if not dir or dir == "" then
        return
    end

    local handle = io.open(dir .. "/suwayomi_debug.log", "a")
    if not handle then
        return
    end
    handle:write(os.date("!%Y-%m-%dT%H:%M:%SZ"), " ", line, "\n")
    handle:close()
end

function Debug.log(event)
    event = event or {}
    if not shouldLog(event) then
        return
    end

    event.plugin = event.plugin or "suwayomi"
    local line = formatEvent(event)
    local loaded_config = loadConfig() or {}

    local loaded_logger = loaded_config.log_to_koreader_log ~= false and loadLogger() or nil
    if loaded_logger and loaded_logger.info then
        pcall(loaded_logger.info, "Suwayomi " .. line)
    end
    if loaded_config.log_to_file ~= false then
        pcall(writeFileLine, line)
    end
end

function Debug.now()
    return now()
end

function Debug.elapsedMs(start_time)
    return math.floor(((now() - start_time) * 1000) + 0.5)
end

function Debug.time(operation, fields, callback)
    if type(fields) == "function" and callback == nil then
        callback = fields
        fields = {}
    end
    fields = fields or {}

    local start_time = now()
    if not loadConfig() then
        return callback()
    end

    local ok, result_a, result_b, result_c, result_d = pcall(callback)
    local event = {}
    for key, value in pairs(fields) do
        event[key] = value
    end
    event.operation = operation
    event.event = ok and "end" or "error"
    event.elapsed_ms = Debug.elapsedMs(start_time)
    if not ok then
        event.error = result_a
    end
    Debug.log(event)
    if not ok then
        error(result_a)
    end
    return result_a, result_b, result_c, result_d
end

function Debug._resetForTests()
    logger = nil
    settings_dir = nil
    config = nil
end

return Debug
