local Transport = {}

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local REQUEST_TIMEOUT_SECONDS = 15

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
    local scheme, host, port = tostring(url or ""):match("^(https?)://([^/%?#:]+):?(%d*)")
    if not scheme or not host then
        return nil
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

function Transport.performGraphQLRequest(credentials, request_body, operation_name, log_debug_event)
    local ltn12 = require("ltn12")
    local server_url = credentials and credentials.server_url

    if not server_url or server_url == "" then
        return {
            ok = false,
            error = "Missing Suwayomi server URL.",
        }
    end

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
        sink = ltn12.sink.table(response_chunks),
        timeout = REQUEST_TIMEOUT_SECONDS,
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
            error = "Could not reach the Suwayomi server: " .. tostring(code),
        }
    end

    if type(code) ~= "number" then
        logDebugEvent(log_debug_event, { operation = operation_name, event = "non_numeric_status", code = code })
        return {
            ok = false,
            error = "Could not reach the Suwayomi server: " .. tostring(code),
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
    }
end

function Transport.downloadBinary(credentials, page_url, log_debug_event)
    local ltn12 = require("ltn12")
    local server_url = credentials and credentials.server_url
    if not server_url or server_url == "" then
        return {
            ok = false,
            error = "Missing Suwayomi server URL.",
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
        sink = ltn12.sink.table(response_chunks),
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

    if not ok then
        return {
            ok = false,
            error = "Could not reach the Suwayomi server: " .. tostring(code),
        }
    end

    if type(code) ~= "number" then
        return {
            ok = false,
            error = "Could not reach the Suwayomi server: " .. tostring(code),
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
    }
end

function Transport.downloadChapterArchive(credentials, chapter_id, target_path, log_debug_event)
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
    local write_error

    local started_at = now()
    local ok, code, response_headers = client.request{
        url = request_url,
        method = "GET",
        headers = headers,
        sink = function(chunk)
            if chunk then
                local written, err = handle:write(chunk)
                if not written then
                    write_error = err or "write failed"
                    return nil, write_error
                end
                response_bytes = response_bytes + #chunk
            end
            return 1
        end,
        timeout = REQUEST_TIMEOUT_SECONDS,
    }
    handle:close()

    response_headers = response_headers or {}
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

    if code == 200 and not write_error then
        return {
            ok = true,
            path = target_path,
            bytes = response_bytes,
            content_type = response_headers["content-type"] or response_headers["Content-Type"],
            content_length = tonumber(response_headers["content-length"] or response_headers["Content-Length"]),
        }
    end

    os.remove(target_path)
    if write_error then
        return {
            ok = false,
            error = "Could not write chapter archive.",
            detail = write_error,
        }
    end
    if not ok then
        return {
            ok = false,
            error = "Could not reach the Suwayomi server: " .. tostring(code),
        }
    end
    if type(code) ~= "number" then
        return {
            ok = false,
            error = "Could not reach the Suwayomi server: " .. tostring(code),
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
    }
end

return Transport
