-- Boundary: Suwayomi GraphQL response parsers.
--
-- Responsibility: decode server JSON and normalize source, manga, category, and
-- chapter records into the plugin's small local data shapes.
-- Owned state: none.
-- Dependencies: dkjson only.
-- External data: every response body is treated as untrusted and converted into
-- either a normalized value or a user-facing parse error.

local Parsers = {}
local json = require("dkjson")

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
    if type(entry.chapters) == "table" and entry.chapters.totalCount ~= nil then
        manga.chapter_count = tonumber(entry.chapters.totalCount) or 0
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

function Parsers.parseSourcesResponse(response_body)
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

function Parsers.isOptionalSourceMetadataFieldError(response_body)
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

function Parsers.parseMangaResponse(response_body)
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

function Parsers.parseLibraryMangaResponse(response_body)
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

function Parsers.parseCategoryResponse(response_body)
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

function Parsers.parseUpdateMangaLibraryResponse(response_body)
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

function Parsers.parseRefreshMangaResponse(response_body)
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
            chapter_number = parsed_chapter.chapter_number,
            source_order = parsed_chapter.source_order,
            scanlator = parsed_chapter.scanlator,
            is_read = parsed_chapter.is_read,
        })
    end
    return {
        manga = parseMangaNode(manga),
        chapters = chapters,
    }
end

function Parsers.parseChapterResponse(response_body)
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
        table.insert(chapters, parseChapterNode(entry))
    end

    return chapters
end

function Parsers.parseChapterPagesResponse(response_body)
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
            chapter_number = chapter.chapterNumber,
            source_order = chapter.sourceOrder,
            manga_title = chapter.manga and chapter.manga.title or "",
        },
        pages = pages,
    }
end

function Parsers.parseStoredChapterResponse(response_body)
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
        table.insert(chapters, parseChapterNode(entry))
    end

    return chapters
end

function Parsers.parseMarkChapterReadResponse(response_body)
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

function Parsers.parseMarkChaptersReadResponse(response_body)
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

return Parsers
