local SuwayomiAPI = {}
local json = require("dkjson")

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local REQUEST_TIMEOUT_SECONDS = 15
local performGraphQLRequest
local debug_logger

local function logDebugEvent(event)
    if debug_logger then
        pcall(debug_logger, event)
    end
end

function SuwayomiAPI.setDebugLogger(logger)
    debug_logger = logger
end

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

function SuwayomiAPI._buildSourcesQuery()
    return json.encode({
        query = "query getSources { sources { nodes { id name displayName lang } } }",
    })
end

function SuwayomiAPI.buildBasicAuthHeader(username, password)
    return "Basic " .. base64Encode(string.format("%s:%s", username or "", password or ""))
end

function SuwayomiAPI.buildRequestHeaders(credentials)
    local headers = {
        ["Content-Type"] = "application/json",
    }

    if credentials and credentials.auth_method == "basic_auth" then
        headers.Authorization = SuwayomiAPI.buildBasicAuthHeader(credentials.username, credentials.password)
    end

    return headers
end

function SuwayomiAPI.buildGraphQLEndpoint(server_url)
    return (server_url or ""):gsub("/+$", "") .. "/api/graphql"
end

function SuwayomiAPI.buildRequestURL(server_url, path)
    if path:match("^https?://") then
        return path
    end

    return (server_url or ""):gsub("/+$", "") .. "/" .. tostring(path):gsub("^/+", "")
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

function SuwayomiAPI.parseSourcesResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local sources = payload
        and payload.data
        and payload.data.sources
        and payload.data.sources.nodes

    if type(sources) ~= "table" then
        return nil, "Suwayomi server did not return a sources list."
    end

    local parsed_sources = {}
    for _, source in ipairs(sources) do
        table.insert(parsed_sources, {
            id = tostring(source.id),
            name = source.displayName or ((source.name or tostring(source.id)) .. (source.lang and source.lang ~= "" and source.lang ~= "localsourcelang" and (" (" .. string.upper(source.lang) .. ")") or "")),
            raw_name = source.name,
            lang = source.lang,
        })
    end

    return parsed_sources
end

function SuwayomiAPI._buildMangaQuery(source_id)
    return json.encode({
        query = "mutation GET_SOURCE_MANGAS_FETCH($input: FetchSourceMangaInput!) { fetchSourceManga(input: $input) { hasNextPage mangas { id title } } }",
        variables = {
            input = {
                source = tostring(source_id),
                page = 1,
                type = "POPULAR",
            },
        },
    })
end

function SuwayomiAPI.parseMangaResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local manga_nodes = payload
        and payload.data
        and payload.data.fetchSourceManga
        and payload.data.fetchSourceManga.mangas

    if type(manga_nodes) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not return a manga list."
    end

    local manga = {}
    for _, entry in ipairs(manga_nodes) do
        table.insert(manga, {
            id = tostring(entry.id),
            title = entry.title or tostring(entry.id),
        })
    end

    return manga
end

function SuwayomiAPI._buildChapterQuery(manga_id)
    return json.encode({
        query = "mutation GET_MANGA_CHAPTERS_FETCH($input: FetchChaptersInput!) { fetchChapters(input: $input) { chapters { id name chapterNumber sourceOrder scanlator isRead } } }",
        variables = {
            input = {
                mangaId = tonumber(manga_id) or manga_id,
            },
        },
    })
end

function SuwayomiAPI._buildChapterPagesQuery(chapter_id)
    return json.encode({
        query = "mutation Pages($input: FetchChapterPagesInput!) { fetchChapterPages(input: $input) { pages chapter { id name manga { title } } } }",
        variables = {
            input = {
                chapterId = tonumber(chapter_id) or chapter_id,
            },
        },
    })
end

function SuwayomiAPI._buildStoredChapterQuery(manga_id)
    return json.encode({
        query = "query GET_CHAPTERS_MANGA($filter: ChapterFilterInput, $first: Int, $order: [ChapterOrderInput!]) { chapters(filter: $filter, first: $first, order: $order) { totalCount nodes { id name chapterNumber sourceOrder scanlator isRead } } }",
        variables = {
            filter = {
                mangaId = {
                    equalTo = tonumber(manga_id) or manga_id,
                },
            },
            first = 200,
            order = {
                {
                    by = "SOURCE_ORDER",
                },
            },
        },
    })
end

function SuwayomiAPI._buildUpdateChapterReadMutation(chapter_id, is_read)
    return json.encode({
        query = "mutation UPDATE_CHAPTER_READ($input: UpdateChapterInput!) { updateChapter(input: $input) { chapter { id isRead } } }",
        variables = {
            input = {
                id = tonumber(chapter_id) or chapter_id,
                patch = {
                    isRead = is_read == true,
                },
            },
        },
    })
end

function SuwayomiAPI._buildMarkChapterReadMutation(chapter_id)
    return SuwayomiAPI._buildUpdateChapterReadMutation(chapter_id, true)
end

function SuwayomiAPI._buildMarkChapterUnreadMutation(chapter_id)
    return SuwayomiAPI._buildUpdateChapterReadMutation(chapter_id, false)
end

function SuwayomiAPI.parseChapterResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local chapter_nodes = payload
        and payload.data
        and payload.data.fetchChapters
        and payload.data.fetchChapters.chapters

    if type(chapter_nodes) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not return a chapter list."
    end

    local chapters = {}
    for _, entry in ipairs(chapter_nodes) do
        local chapter_name = entry.name
        if not chapter_name or chapter_name == "" then
            chapter_name = entry.chapterNumber and ("Chapter " .. tostring(entry.chapterNumber)) or tostring(entry.id)
        end

        table.insert(chapters, {
            id = tostring(entry.id),
            name = chapter_name,
            is_read = entry.isRead == true,
        })
    end

    return chapters
end

function SuwayomiAPI.parseChapterPagesResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local data = payload and payload.data and payload.data.fetchChapterPages
    local pages = data and data.pages
    local chapter = data and data.chapter

    if type(pages) ~= "table" or type(chapter) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not return chapter pages."
    end

    local chapter_name = chapter.name
    if not chapter_name or chapter_name == "" then
        chapter_name = tostring(chapter.id)
    end

    return {
        chapter = {
            id = tostring(chapter.id),
            name = chapter_name,
            manga_title = chapter.manga and chapter.manga.title or "",
        },
        pages = pages,
    }
end

function SuwayomiAPI.fetchChapterPages(credentials, chapter_id)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildChapterPagesQuery(chapter_id), "fetchChapterPages")
    if not result.ok then
        return result
    end

    local parsed, parse_error = SuwayomiAPI.parseChapterPagesResponse(result.response_body)
    if not parsed then
        logDebugEvent({ operation = "fetchChapterPages", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        chapter = parsed.chapter,
        pages = parsed.pages,
    }
end

function SuwayomiAPI.downloadBinary(credentials, page_url)
    local ltn12 = require("ltn12")
    local server_url = credentials and credentials.server_url
    if not server_url or server_url == "" then
        return {
            ok = false,
            error = "Missing Suwayomi server URL.",
        }
    end

    local request_url = SuwayomiAPI.buildRequestURL(server_url, page_url)
    local client = request_url:match("^https://") and require("ssl.https") or require("socket.http")
    local response_chunks = {}
    local headers = {}

    if not page_url:match("^https?://") or isSameOrigin(server_url, request_url) then
        headers = SuwayomiAPI.buildRequestHeaders(credentials)
    end

    local ok, code, headers = client.request{
        url = request_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_chunks),
        timeout = REQUEST_TIMEOUT_SECONDS,
    }

    headers = headers or {}
    if code == 200 then
        return {
            ok = true,
            body = table.concat(response_chunks),
            content_type = headers["content-type"] or headers["Content-Type"],
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

function SuwayomiAPI.parseStoredChapterResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local chapter_nodes = payload
        and payload.data
        and payload.data.chapters
        and payload.data.chapters.nodes

    if type(chapter_nodes) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not return a chapter list."
    end

    local chapters = {}
    for _, entry in ipairs(chapter_nodes) do
        local chapter_name = entry.name
        if not chapter_name or chapter_name == "" then
            chapter_name = entry.chapterNumber and ("Chapter " .. tostring(entry.chapterNumber)) or tostring(entry.id)
        end

        table.insert(chapters, {
            id = tostring(entry.id),
            name = chapter_name,
            is_read = entry.isRead == true,
        })
    end

    return chapters
end

function SuwayomiAPI.parseMarkChapterReadResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local chapter = payload
        and payload.data
        and payload.data.updateChapter
        and payload.data.updateChapter.chapter

    if type(chapter) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not update chapter read state."
    end

    return {
        id = tostring(chapter.id),
        is_read = chapter.isRead == true,
    }
end

performGraphQLRequest = function(credentials, request_body, operation_name)
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
    local headers = SuwayomiAPI.buildRequestHeaders(credentials)
    headers["Content-Length"] = tostring(#request_body)

    local ok, code = client.request{
        url = SuwayomiAPI.buildGraphQLEndpoint(server_url),
        method = "POST",
        headers = headers,
        source = ltn12.source.string(request_body),
        sink = ltn12.sink.table(response_chunks),
        timeout = REQUEST_TIMEOUT_SECONDS,
    }

    logDebugEvent({ operation = operation_name, event = "response", ok = ok, code = code, code_type = type(code) })

    local response_body = table.concat(response_chunks)
    if code == 200 then
        return {
            ok = true,
            response_body = response_body,
        }
    end

    if not ok then
        logDebugEvent({ operation = operation_name, event = "transport_failure", error = code })
        return {
            ok = false,
            error = "Could not reach the Suwayomi server: " .. tostring(code),
        }
    end

    if type(code) ~= "number" then
        logDebugEvent({ operation = operation_name, event = "non_numeric_status", code = code })
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

    logDebugEvent({ operation = operation_name, event = "http_status", code = code })
    return {
        ok = false,
        error = error_message[code] or "Could not reach the Suwayomi server.",
    }
end

function SuwayomiAPI.fetchSources(credentials)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildSourcesQuery(), "fetchSources")
    if not result.ok then
        return result
    end

    local sources, parse_error = SuwayomiAPI.parseSourcesResponse(result.response_body)
    if not sources then
        logDebugEvent({ operation = "fetchSources", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        sources = sources,
    }
end

function SuwayomiAPI.fetchMangaForSource(credentials, source_id)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildMangaQuery(source_id), "fetchMangaForSource")
    if not result.ok then
        return result
    end

    local manga, parse_error = SuwayomiAPI.parseMangaResponse(result.response_body)
    if not manga then
        logDebugEvent({ operation = "fetchMangaForSource", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        manga = manga,
    }
end

function SuwayomiAPI.queryChaptersForManga(credentials, manga_id)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildStoredChapterQuery(manga_id), "queryChaptersForManga")
    if not result.ok then
        return result
    end

    local chapters, parse_error = SuwayomiAPI.parseStoredChapterResponse(result.response_body)
    if not chapters then
        logDebugEvent({ operation = "queryChaptersForManga", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        chapters = chapters,
    }
end

function SuwayomiAPI.markChapterRead(credentials, chapter_id)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildMarkChapterReadMutation(chapter_id), "markChapterRead")
    if not result.ok then
        return result
    end

    local chapter, parse_error = SuwayomiAPI.parseMarkChapterReadResponse(result.response_body)
    if not chapter then
        logDebugEvent({ operation = "markChapterRead", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        chapter = chapter,
    }
end

function SuwayomiAPI.markChapterUnread(credentials, chapter_id)
    local result = performGraphQLRequest(
        credentials,
        SuwayomiAPI._buildMarkChapterUnreadMutation(chapter_id),
        "markChapterUnread"
    )
    if not result.ok then
        return result
    end

    local chapter, parse_error = SuwayomiAPI.parseMarkChapterReadResponse(result.response_body)
    if not chapter then
        logDebugEvent({ operation = "markChapterUnread", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        chapter = chapter,
    }
end

function SuwayomiAPI.fetchChaptersForManga(credentials, manga_id)
    local stored_result = SuwayomiAPI.queryChaptersForManga(credentials, manga_id)
    if stored_result.ok and stored_result.chapters and #stored_result.chapters > 0 then
        return stored_result
    end

    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildChapterQuery(manga_id), "fetchChaptersForManga")
    if not result.ok then
        return result
    end

    local chapters, parse_error = SuwayomiAPI.parseChapterResponse(result.response_body)
    if not chapters then
        logDebugEvent({ operation = "fetchChaptersForManga", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        chapters = chapters,
    }
end

return SuwayomiAPI
