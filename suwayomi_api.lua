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
        query = "query getSources { sources { nodes { id name displayName lang isNsfw supportsLatest } } }",
    })
end

function SuwayomiAPI._buildLegacySourcesQuery()
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
            display_name = source.displayName,
            raw_name = source.name,
            lang = source.lang,
            is_nsfw = source.isNsfw,
            supports_latest = source.supportsLatest,
        })
    end

    return parsed_sources
end

local function isOptionalSourceMetadataFieldError(response_body)
    local payload = json.decode(response_body, 1, nil)
    if type(payload) ~= "table" or type(payload.errors) ~= "table" then
        return false
    end

    for _, graph_error in ipairs(payload.errors) do
        local message = tostring(graph_error and graph_error.message or "")
        local mentions_optional_field = message:match("isNsfw") or message:match("supportsLatest")
        local looks_like_schema_error = message:match("Cannot query field")
            or message:match("Unknown field")
            or message:match("FieldUndefined")
        if mentions_optional_field and looks_like_schema_error then
            return true
        end
    end
    return false
end

local function normalizeNumber(value, fallback)
    local number = tonumber(value)
    if number then
        return number
    end
    return fallback
end

local function parseSource(source)
    if type(source) ~= "table" then
        return nil
    end
    return {
        id = source.id ~= nil and tostring(source.id) or nil,
        displayName = source.displayName,
        name = source.name,
        lang = source.lang,
    }
end

local function parseChapterNode(chapter)
    if type(chapter) ~= "table" then
        return nil
    end

    local chapter_name = chapter.name
    if not chapter_name or chapter_name == "" then
        chapter_name = chapter.chapterNumber and ("Chapter " .. tostring(chapter.chapterNumber)) or tostring(chapter.id)
    end

    return {
        id = tostring(chapter.id),
        name = chapter_name,
        chapter_number = chapter.chapterNumber,
        source_order = chapter.sourceOrder,
        scanlator = chapter.scanlator,
        is_read = chapter.isRead == true,
    }
end

local function parseMangaNode(entry)
    local manga = {
        id = tostring(entry.id),
        title = entry.title or tostring(entry.id),
    }
    if entry.inLibrary ~= nil then
        manga.in_library = entry.inLibrary == true
    end
    if entry.unreadCount ~= nil then
        manga.unread_count = tonumber(entry.unreadCount) or 0
    end
    if entry.downloadCount ~= nil then
        manga.download_count = tonumber(entry.downloadCount) or 0
    end
    if entry.initialized ~= nil then
        manga.initialized = entry.initialized == true
    end
    if entry.thumbnailUrl ~= nil then
        manga.thumbnail_url = entry.thumbnailUrl
    end

    local source = parseSource(entry.source)
    if source then
        manga.source = source
    end

    if entry.categories and type(entry.categories.nodes) == "table" then
        manga.categories = {}
        for _, category in ipairs(entry.categories.nodes) do
            table.insert(manga.categories, {
                id = tostring(category.id),
                name = category.name or tostring(category.id),
                order = category.order,
            })
        end
    end

    manga.first_unread_chapter = parseChapterNode(entry.firstUnreadChapter)
    manga.latest_fetched_chapter = parseChapterNode(entry.latestFetchedChapter)
    return manga
end

function SuwayomiAPI._buildMangaQuery(options)
    options = options or {}
    local input = {
        source = tostring(options.source_id),
        page = normalizeNumber(options.page, 1),
        type = options.type or "POPULAR",
    }
    if options.query and options.query ~= "" then
        input.query = options.query
    end
    if options.filters then
        input.filters = options.filters
    end

    return json.encode({
        query = "mutation GET_SOURCE_MANGAS_FETCH($input: FetchSourceMangaInput!) { fetchSourceManga(input: $input) { hasNextPage mangas { id title inLibrary initialized thumbnailUrl source { id displayName name lang } } } }",
        variables = {
            input = input,
        },
    })
end

function SuwayomiAPI._buildLibraryMangaQuery(options)
    options = options or {}
    local variables = {
        filter = {
            inLibrary = {
                equalTo = true,
            },
        },
        first = normalizeNumber(options.first, 100),
        offset = normalizeNumber(options.offset, 0),
    }
    if options.order then
        variables.order = options.order
    end

    return json.encode({
        query = "query GET_LIBRARY_MANGAS($filter: MangaFilterInput, $first: Int, $offset: Int, $order: [MangaOrderInput!]) { mangas(filter: $filter, first: $first, offset: $offset, order: $order) { totalCount nodes { id title inLibrary unreadCount downloadCount initialized thumbnailUrl source { id displayName name lang } categories { nodes { id name order } } firstUnreadChapter { id name chapterNumber sourceOrder scanlator isRead } latestFetchedChapter { id name chapterNumber sourceOrder scanlator isRead } } } }",
        variables = variables,
    })
end

function SuwayomiAPI._buildCategoryQuery()
    return json.encode({
        query = "query GET_LIBRARY_CATEGORIES { categories { nodes { id name order mangas { totalCount } } } }",
    })
end

function SuwayomiAPI._buildUpdateMangaLibraryMutation(manga_id, in_library)
    return json.encode({
        query = "mutation UPDATE_MANGA_LIBRARY($input: UpdateMangaInput!) { updateManga(input: $input) { manga { id inLibrary inLibraryAt } } }",
        variables = {
            input = {
                id = tonumber(manga_id) or manga_id,
                patch = {
                    inLibrary = in_library == true,
                },
            },
        },
    })
end

function SuwayomiAPI._buildRefreshMangaMutation(manga_id)
    return json.encode({
        query = "mutation REFRESH_MANGA($manga: FetchMangaInput!, $chapters: FetchChaptersInput!) { fetchManga(input: $manga) { manga { id title initialized thumbnailUrl source { id displayName name lang } } } fetchChapters(input: $chapters) { chapters { id name chapterNumber sourceOrder scanlator isRead } } }",
        variables = {
            manga = {
                id = tonumber(manga_id) or manga_id,
            },
            chapters = {
                mangaId = tonumber(manga_id) or manga_id,
            },
        },
    })
end

function SuwayomiAPI.parseMangaResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local source_manga = payload
        and payload.data
        and payload.data.fetchSourceManga
    local manga_nodes = source_manga
        and source_manga.mangas

    if type(manga_nodes) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not return a manga list."
    end

    local manga = {}
    for _, entry in ipairs(manga_nodes) do
        table.insert(manga, parseMangaNode(entry))
    end

    return manga, source_manga.hasNextPage == true
end

function SuwayomiAPI.parseLibraryMangaResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local mangas = payload and payload.data and payload.data.mangas
    local manga_nodes = mangas and mangas.nodes
    if type(manga_nodes) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not return a library manga list."
    end

    local parsed = {}
    for _, entry in ipairs(manga_nodes) do
        table.insert(parsed, parseMangaNode(entry))
    end
    return {
        total_count = tonumber(mangas.totalCount) or #parsed,
        manga = parsed,
    }
end

function SuwayomiAPI.parseCategoryResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local category_nodes = payload
        and payload.data
        and payload.data.categories
        and payload.data.categories.nodes
    if type(category_nodes) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not return categories."
    end

    local categories = {}
    for _, category in ipairs(category_nodes) do
        table.insert(categories, {
            id = tostring(category.id),
            name = category.name or tostring(category.id),
            order = category.order,
            manga_count = category.mangas and tonumber(category.mangas.totalCount) or 0,
        })
    end
    return categories
end

function SuwayomiAPI.parseUpdateMangaLibraryResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local manga = payload
        and payload.data
        and payload.data.updateManga
        and payload.data.updateManga.manga
    if type(manga) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not update manga library state."
    end

    return {
        id = tostring(manga.id),
        in_library = manga.inLibrary == true,
        in_library_at = manga.inLibraryAt,
    }
end

function SuwayomiAPI.parseRefreshMangaResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local manga = payload
        and payload.data
        and payload.data.fetchManga
        and payload.data.fetchManga.manga
    local chapter_nodes = payload
        and payload.data
        and payload.data.fetchChapters
        and payload.data.fetchChapters.chapters
    if type(manga) ~= "table" or type(chapter_nodes) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not refresh manga."
    end

    local chapters = {}
    for _, chapter in ipairs(chapter_nodes) do
        local parsed_chapter = parseChapterNode(chapter)
        table.insert(chapters, {
            id = parsed_chapter.id,
            name = parsed_chapter.name,
            scanlator = parsed_chapter.scanlator,
            is_read = parsed_chapter.is_read,
        })
    end
    return {
        manga = parseMangaNode(manga),
        chapters = chapters,
    }
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

function SuwayomiAPI._buildUpdateChaptersReadMutation(chapter_ids, is_read)
    local ids = {}
    for _, chapter_id in ipairs(chapter_ids or {}) do
        table.insert(ids, tonumber(chapter_id) or chapter_id)
    end

    return json.encode({
        query = "mutation UPDATE_CHAPTERS_READ($input: UpdateChaptersInput!) { updateChapters(input: $input) { chapters { id isRead } } }",
        variables = {
            input = {
                ids = ids,
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
            scanlator = entry.scanlator,
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

    local started_at = os.time()
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket and socket.gettime then
        started_at = socket.gettime()
    end
    local ok, code, headers = client.request{
        url = request_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_chunks),
        timeout = REQUEST_TIMEOUT_SECONDS,
    }

    headers = headers or {}
    local body = table.concat(response_chunks)
    local finished_at = os.time()
    if ok_socket and socket and socket.gettime then
        finished_at = socket.gettime()
    end
    logDebugEvent({
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
            scanlator = entry.scanlator,
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

function SuwayomiAPI.parseMarkChaptersReadResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local chapter_nodes = payload
        and payload.data
        and payload.data.updateChapters
        and payload.data.updateChapters.chapters

    if type(chapter_nodes) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not update chapter read states."
    end

    local chapters = {}
    for _, chapter in ipairs(chapter_nodes) do
        table.insert(chapters, {
            id = tostring(chapter.id),
            is_read = chapter.isRead == true,
        })
    end
    return chapters
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

    local started_at = os.time()
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket and socket.gettime then
        started_at = socket.gettime()
    end
    local ok, code = client.request{
        url = SuwayomiAPI.buildGraphQLEndpoint(server_url),
        method = "POST",
        headers = headers,
        source = ltn12.source.string(request_body),
        sink = ltn12.sink.table(response_chunks),
        timeout = REQUEST_TIMEOUT_SECONDS,
    }

    local response_body = table.concat(response_chunks)
    local finished_at = os.time()
    if ok_socket and socket and socket.gettime then
        finished_at = socket.gettime()
    end
    logDebugEvent({
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
    if isOptionalSourceMetadataFieldError(result.response_body) then
        logDebugEvent({ operation = "fetchSources", event = "legacy_source_query_retry" })
        result = performGraphQLRequest(credentials, SuwayomiAPI._buildLegacySourcesQuery(), "fetchSources")
        if not result.ok then
            return result
        end
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

function SuwayomiAPI.fetchMangaForSource(credentials, options)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildMangaQuery(options), "fetchMangaForSource")
    if not result.ok then
        return result
    end

    local manga, parse_result = SuwayomiAPI.parseMangaResponse(result.response_body)
    if not manga then
        local parse_error = parse_result
        logDebugEvent({ operation = "fetchMangaForSource", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        manga = manga,
        has_next_page = parse_result == true,
    }
end

function SuwayomiAPI.fetchLibraryManga(credentials, options)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildLibraryMangaQuery(options), "fetchLibraryManga")
    if not result.ok then
        return result
    end

    local parsed, parse_error = SuwayomiAPI.parseLibraryMangaResponse(result.response_body)
    if not parsed then
        logDebugEvent({ operation = "fetchLibraryManga", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        manga = parsed.manga,
        total_count = parsed.total_count,
    }
end

function SuwayomiAPI.fetchCategories(credentials)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildCategoryQuery(), "fetchCategories")
    if not result.ok then
        return result
    end

    local categories, parse_error = SuwayomiAPI.parseCategoryResponse(result.response_body)
    if not categories then
        logDebugEvent({ operation = "fetchCategories", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        categories = categories,
    }
end

function SuwayomiAPI.updateMangaLibraryState(credentials, manga_id, in_library)
    local result = performGraphQLRequest(
        credentials,
        SuwayomiAPI._buildUpdateMangaLibraryMutation(manga_id, in_library),
        "updateMangaLibraryState"
    )
    if not result.ok then
        return result
    end

    local manga, parse_error = SuwayomiAPI.parseUpdateMangaLibraryResponse(result.response_body)
    if not manga then
        logDebugEvent({ operation = "updateMangaLibraryState", event = "parse_error", error = parse_error })
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

function SuwayomiAPI.refreshManga(credentials, manga_id)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildRefreshMangaMutation(manga_id), "refreshManga")
    if not result.ok then
        return result
    end

    local parsed, parse_error = SuwayomiAPI.parseRefreshMangaResponse(result.response_body)
    if not parsed then
        logDebugEvent({ operation = "refreshManga", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        manga = parsed.manga,
        chapters = parsed.chapters,
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

function SuwayomiAPI.markChaptersReadState(credentials, chapter_ids, is_read)
    local result = performGraphQLRequest(
        credentials,
        SuwayomiAPI._buildUpdateChaptersReadMutation(chapter_ids, is_read),
        "markChaptersReadState"
    )
    if not result.ok then
        return result
    end

    local chapters, parse_error = SuwayomiAPI.parseMarkChaptersReadResponse(result.response_body)
    if not chapters then
        logDebugEvent({ operation = "markChaptersReadState", event = "parse_error", error = parse_error })
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
