-- Boundary: HTTP transport for Suwayomi GraphQL and binary downloads.
--
-- Responsibility: build request headers/URLs, choose the right HTTP client, map
-- transport failures to plugin errors, and stream downloaded bytes to files.
-- Owned state: none.
-- Dependencies: socket/http, ssl.https, ltn12, and Lua file IO at call time.
-- External data: credentials, URLs, HTTP status codes, and downloaded bytes are
-- normalized here before the API facade parses or returns them.

local Transport = {}

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local REQUEST_TIMEOUT_SECONDS = 15
local RESPONSE_TOTAL_TIMEOUT_SECONDS = 30
local MAX_GRAPHQL_RESPONSE_BYTES = 8 * 1024 * 1024
local MAX_BINARY_RESPONSE_BYTES = 32 * 1024 * 1024
local MAX_CHAPTER_ARCHIVE_RESPONSE_BYTES = 512 * 1024 * 1024
local CHAPTER_ARCHIVE_TOTAL_TIMEOUT_SECONDS = 10 * 60
local RESPONSE_TIMEOUT_ERROR = "response timeout"
local RESPONSE_TOO_LARGE_ERROR = "response too large"

Transport.MAX_BINARY_RESPONSE_BYTES = MAX_BINARY_RESPONSE_BYTES
Transport.MAX_CHAPTER_ARCHIVE_RESPONSE_BYTES = MAX_CHAPTER_ARCHIVE_RESPONSE_BYTES

-- LuaJIT on KOReader does not guarantee a standalone base64 helper, so this
-- tiny encoder keeps Basic Auth construction self-contained and testable.
local function base64Encode(input)
    local result = {}
    local index = 1

    while index <= #input do
        local a = input:byte(index) or 0
        local b = input:byte(index + 1) or 0
        local c = input:byte(index + 2) or 0
        local chunk_length = math.min(3, #input - index + 1)
        local value = a * 65536 + b * 256 + c

        local char1 = math.floor(value / 262144) % 64 + 1
        local char2 = math.floor(value / 4096) % 64 + 1
        local char3 = math.floor(value / 64) % 64 + 1
        local char4 = value % 64 + 1

        table.insert(result, BASE64_ALPHABET:sub(char1, char1))
        table.insert(result, BASE64_ALPHABET:sub(char2, char2))
        table.insert(result, chunk_length < 2 and "=" or BASE64_ALPHABET:sub(char3, char3))
        table.insert(result, chunk_length < 3 and "=" or BASE64_ALPHABET:sub(char4, char4))

        index = index + 3
    end

    return table.concat(result)
end

local function parseOrigin(url)
    local scheme, authority = tostring(url or ""):match("^(https?)://([^/%?#]*)")
    if not scheme or not authority or authority == "" then
        return nil
    end

    local host, port
    if authority:sub(1, 1) == "[" then
        local bracketed_host, rest = authority:match("^%[([^%]]+)%](.*)$")
        if not bracketed_host then
            return nil
        end
        host = bracketed_host
        if rest == "" then
            port = ""
        else
            port = rest:match("^:(%d+)$")
            if not port then
                return nil
            end
        end
    else
        host, port = authority:match("^([^:]+):?(%d*)$")
        if not host or host == "" then
            return nil
        end
    end
    if port == "" then
        port = scheme == "https" and "443" or "80"
    end

    return {
        scheme = scheme,
        host = host:lower(),
        port = port,
    }
end

local function isSameOrigin(url_a, url_b)
    local origin_a = parseOrigin(url_a)
    local origin_b = parseOrigin(url_b)

    return origin_a
        and origin_b
        and origin_a.scheme == origin_b.scheme
        and origin_a.host == origin_b.host
        and origin_a.port == origin_b.port
end

local function now()
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket and socket.gettime then
        return socket.gettime()
    end
    return os.time()
end

local function logDebugEvent(log_debug_event, event)
    if log_debug_event then
        log_debug_event(event)
    end
end

local function formatReachabilityError(code)
    if code == "wantread" or code == "wantwrite" or code == "timeout" or code == RESPONSE_TIMEOUT_ERROR then
        return "Connection timed out while waiting for Suwayomi."
    end
    if code == RESPONSE_TOO_LARGE_ERROR then
        return "Suwayomi response was too large."
    end
    return "Could not reach the Suwayomi server: " .. tostring(code)
end

local function isRetryableTransportCode(code)
    local normalized = tostring(code or ""):lower()
    return normalized == "wantread"
        or normalized == "wantwrite"
        or normalized == "timeout"
        or normalized == "closed"
        or normalized == RESPONSE_TIMEOUT_ERROR
        or normalized:match("timed? ?out") ~= nil
        or normalized:match("connection.*reset") ~= nil
        or normalized:match("connection.*refused") ~= nil
        or normalized:match("network.*unreachable") ~= nil
        or normalized:match("network.*down") ~= nil
        or normalized:match("no route to host") ~= nil
        or normalized:match("host.*not.*found") ~= nil
        or normalized:match("name or service not known") ~= nil
        or normalized:match("host or service not provided") ~= nil
end

local function isRetryableHttpStatus(code)
    return code == 408 or code == 429 or (type(code) == "number" and code >= 500 and code <= 599)
end

local function buildGuardedTableSink(target, options)
    options = options or {}
    target = target or {}
    local started_at = now()
    local total_bytes = 0
    local total_timeout_seconds = options.total_timeout_seconds or RESPONSE_TOTAL_TIMEOUT_SECONDS
    local max_bytes = options.max_bytes

    return function(chunk)
        if chunk then
            if total_timeout_seconds
                and total_timeout_seconds >= 0
                and now() - started_at > total_timeout_seconds
            then
                return nil, RESPONSE_TIMEOUT_ERROR
            end
            total_bytes = total_bytes + #chunk
            if max_bytes and total_bytes > max_bytes then
                return nil, RESPONSE_TOO_LARGE_ERROR
            end
            table.insert(target, chunk)
        end
        return 1
    end
end

local function normalizeBinaryCallOptions(log_debug_event, request_options)
    if type(log_debug_event) == "table" and request_options == nil then
        return nil, log_debug_event
    end
    return log_debug_event, request_options or {}
end

function Transport.buildBasicAuthHeader(username, password)
    return "Basic " .. base64Encode(string.format("%s:%s", username or "", password or ""))
end

function Transport.buildRequestHeaders(credentials)
    local headers = {
        ["Content-Type"] = "application/json",
    }

    if credentials and credentials.auth_method == "basic_auth" then
        headers.Authorization = Transport.buildBasicAuthHeader(credentials.username, credentials.password)
    end

    return headers
end

function Transport.buildGraphQLEndpoint(server_url)
    return (server_url or ""):gsub("/+$", "") .. "/api/graphql"
end

function Transport.buildRequestURL(server_url, path)
    if path:match("^https?://") then
        return path
    end

    return (server_url or ""):gsub("/+$", "") .. "/" .. tostring(path):gsub("^/+", "")
end

function Transport.buildChapterArchiveDownloadURL(server_url, chapter_id)
    return Transport.buildRequestURL(
        server_url,
        "/api/v1/chapter/" .. tostring(chapter_id) .. "/download?markAsRead=false"
    )
end

function Transport.performGraphQLRequest(credentials, request_body, operation_name, log_debug_event, options)
    local server_url = credentials and credentials.server_url
    options = options or {}

    if not server_url or server_url == "" then
        return {
            ok = false,
            error = "Missing Suwayomi server URL.",
        }
    end

    local ltn12 = require("ltn12")
    local client
    if server_url:match("^https://") then
        client = require("ssl.https")
    else
        client = require("socket.http")
    end

    local response_chunks = {}
    local headers = Transport.buildRequestHeaders(credentials)
    headers["Content-Length"] = tostring(#request_body)

    local started_at = now()
    local ok, code = client.request{
        url = Transport.buildGraphQLEndpoint(server_url),
        method = "POST",
        headers = headers,
        source = ltn12.source.string(request_body),
        sink = buildGuardedTableSink(response_chunks, {
            max_bytes = MAX_GRAPHQL_RESPONSE_BYTES,
        }),
        timeout = options.timeout_seconds or REQUEST_TIMEOUT_SECONDS,
    }

    local response_body = table.concat(response_chunks)
    local finished_at = now()
    logDebugEvent(log_debug_event, {
        operation = operation_name,
        event = "response",
        ok = ok,
        code = code,
        code_type = type(code),
        elapsed_ms = math.floor(((finished_at - started_at) * 1000) + 0.5),
        request_bytes = #request_body,
        response_bytes = #response_body,
    })
    if code == 200 then
        return {
            ok = true,
            response_body = response_body,
        }
    end

    if not ok then
        logDebugEvent(log_debug_event, { operation = operation_name, event = "transport_failure", error = code })
        return {
            ok = false,
            error = formatReachabilityError(code),
            retryable = isRetryableTransportCode(code),
        }
    end

    if type(code) ~= "number" then
        logDebugEvent(log_debug_event, { operation = operation_name, event = "non_numeric_status", code = code })
        return {
            ok = false,
            error = formatReachabilityError(code),
            retryable = isRetryableTransportCode(code),
        }
    end

    local error_message = {
        [401] = "Authentication failed.",
        [403] = "Authentication failed.",
        [404] = "Suwayomi GraphQL endpoint not found.",
    }

    logDebugEvent(log_debug_event, { operation = operation_name, event = "http_status", code = code })
    return {
        ok = false,
        error = error_message[code] or "Could not reach the Suwayomi server.",
        retryable = isRetryableHttpStatus(code),
        status_code = code,
    }
end

function Transport.downloadBinary(credentials, page_url, log_debug_event, request_options)
    log_debug_event, request_options = normalizeBinaryCallOptions(log_debug_event, request_options)
    local server_url = credentials and credentials.server_url
    if not server_url or server_url == "" then
        return {
            ok = false,
            error = "Missing Suwayomi server URL.",
        }
    end
    if type(page_url) ~= "string" or page_url == "" then
        return {
            ok = false,
            error = "Invalid chapter page URL.",
        }
    end

    local request_url = Transport.buildRequestURL(server_url, page_url)
    local client = request_url:match("^https://") and require("ssl.https") or require("socket.http")
    local response_chunks = {}
    local headers = {}

    if not page_url:match("^https?://") or isSameOrigin(server_url, request_url) then
        headers = Transport.buildRequestHeaders(credentials)
    end

    local started_at = now()
    local ok, code, response_headers = client.request{
        url = request_url,
        method = "GET",
        headers = headers,
        sink = buildGuardedTableSink(response_chunks, {
            max_bytes = request_options.max_bytes or MAX_BINARY_RESPONSE_BYTES,
            total_timeout_seconds = request_options.total_timeout_seconds,
        }),
        timeout = REQUEST_TIMEOUT_SECONDS,
    }

    response_headers = response_headers or {}
    local body = table.concat(response_chunks)
    local finished_at = now()
    logDebugEvent(log_debug_event, {
        operation = "downloadBinary",
        event = "response",
        ok = ok,
        code = code,
        code_type = type(code),
        elapsed_ms = math.floor(((finished_at - started_at) * 1000) + 0.5),
        response_bytes = #body,
        same_origin = (not page_url:match("^https?://") or isSameOrigin(server_url, request_url)) == true,
    })
    if code == 200 then
        return {
            ok = true,
            body = body,
            content_type = response_headers["content-type"] or response_headers["Content-Type"],
        }
    end

    if not ok and code == RESPONSE_TOO_LARGE_ERROR then
        return {
            ok = false,
            error = "Downloaded response was too large.",
            retryable = false,
        }
    end

    if not ok then
        return {
            ok = false,
            error = formatReachabilityError(code),
            retryable = isRetryableTransportCode(code),
        }
    end

    if type(code) ~= "number" then
        return {
            ok = false,
            error = formatReachabilityError(code),
            retryable = isRetryableTransportCode(code),
        }
    end

    local error_message = {
        [401] = "Authentication failed.",
        [403] = "Authentication failed.",
        [404] = "Chapter page not found.",
    }

    return {
        ok = false,
        error = error_message[code] or "Could not download chapter page.",
        retryable = isRetryableHttpStatus(code),
        status_code = code,
    }
end

function Transport.downloadChapterArchive(credentials, chapter_id, target_path, log_debug_event, request_options)
    request_options = request_options or {}
    local server_url = credentials and credentials.server_url
    if not server_url or server_url == "" then
        return {
            ok = false,
            error = "Missing Suwayomi server URL.",
        }
    end
    if not target_path or target_path == "" then
        return {
            ok = false,
            error = "Missing chapter archive target path.",
        }
    end

    local handle, open_error = io.open(target_path, "wb")
    if not handle then
        return {
            ok = false,
            error = "Could not create chapter archive.",
            detail = open_error,
        }
    end

    local request_url = Transport.buildChapterArchiveDownloadURL(server_url, chapter_id)
    local client = request_url:match("^https://") and require("ssl.https") or require("socket.http")
    local headers = Transport.buildRequestHeaders(credentials)
    local response_bytes = 0
    local header_chunks = {}
    local header_bytes_count = 0
    local head_chunks = {}
    local head_bytes_count = 0
    local tail_bytes = ""
    local write_error
    local started_at = now()
    local max_bytes = request_options.max_bytes or MAX_CHAPTER_ARCHIVE_RESPONSE_BYTES
    local total_timeout_seconds = request_options.total_timeout_seconds or CHAPTER_ARCHIVE_TOTAL_TIMEOUT_SECONDS

    local ok, code, response_headers = client.request{
        url = request_url,
        method = "GET",
        headers = headers,
        sink = function(chunk)
            if chunk then
                if now() - started_at > total_timeout_seconds then
                    write_error = RESPONSE_TIMEOUT_ERROR
                    return nil, write_error
                end
                if response_bytes + #chunk > max_bytes then
                    write_error = RESPONSE_TOO_LARGE_ERROR
                    return nil, write_error
                end
                local written, err = handle:write(chunk)
                if not written then
                    write_error = err or "write failed"
                    return nil, write_error
                end
                if header_bytes_count < 4 then
                    local header_piece = chunk:sub(1, 4 - header_bytes_count)
                    table.insert(header_chunks, header_piece)
                    header_bytes_count = header_bytes_count + #header_piece
                end
                if head_bytes_count < 4096 then
                    local head_piece = chunk:sub(1, 4096 - head_bytes_count)
                    table.insert(head_chunks, head_piece)
                    head_bytes_count = head_bytes_count + #head_piece
                end
                tail_bytes = (tail_bytes .. chunk):sub(-65557)
                response_bytes = response_bytes + #chunk
            end
            return 1
        end,
        timeout = request_options.timeout_seconds or REQUEST_TIMEOUT_SECONDS,
    }
    handle:close()

    response_headers = response_headers or {}
    local content_length = tonumber(response_headers["content-length"] or response_headers["Content-Length"])
    local finished_at = now()
    logDebugEvent(log_debug_event, {
        operation = "downloadChapterArchive",
        event = "response",
        ok = ok,
        code = code,
        code_type = type(code),
        elapsed_ms = math.floor(((finished_at - started_at) * 1000) + 0.5),
        response_bytes = response_bytes,
    })

    if code == 200 and not write_error and content_length and content_length > max_bytes then
        os.remove(target_path)
        return {
            ok = false,
            error = "Downloaded response was too large.",
            retryable = false,
        }
    end

    if code == 200 and not write_error then
        return {
            ok = true,
            path = target_path,
            bytes = response_bytes,
            content_type = response_headers["content-type"] or response_headers["Content-Type"],
            content_length = content_length,
            header_bytes = table.concat(header_chunks),
            head_bytes = table.concat(head_chunks),
            tail_bytes = tail_bytes,
        }
    end

    os.remove(target_path)
    if write_error == RESPONSE_TOO_LARGE_ERROR then
        return {
            ok = false,
            error = "Downloaded response was too large.",
            retryable = false,
        }
    end
    if write_error == RESPONSE_TIMEOUT_ERROR then
        return {
            ok = false,
            error = "Connection timed out while downloading chapter archive.",
            detail = write_error,
            retryable = true,
        }
    end
    if write_error then
        return {
            ok = false,
            error = "Could not write chapter archive.",
            detail = write_error,
            retryable = write_error == RESPONSE_TIMEOUT_ERROR,
        }
    end
    if not ok then
        return {
            ok = false,
            error = formatReachabilityError(code),
            retryable = isRetryableTransportCode(code),
        }
    end
    if type(code) ~= "number" then
        return {
            ok = false,
            error = formatReachabilityError(code),
            retryable = isRetryableTransportCode(code),
        }
    end

    local error_message = {
        [401] = "Authentication failed.",
        [403] = "Authentication failed.",
        [404] = "Chapter archive not found.",
    }
    return {
        ok = false,
        error = error_message[code] or "Could not download chapter archive.",
        retryable = isRetryableHttpStatus(code),
        status_code = code,
    }
end

return Transport
