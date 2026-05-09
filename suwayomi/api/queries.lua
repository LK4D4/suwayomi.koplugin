-- Boundary: pure Suwayomi GraphQL request builders.
--
-- Responsibility: build JSON-encoded GraphQL queries and mutations without
-- knowing how they are transported or parsed.
-- Owned state: none.
-- Dependencies: dkjson only.
-- External data: caller-provided IDs, pagination, and filter values are coerced
-- into query variables before leaving the plugin.

local Queries = {}
local json = require("dkjson")

local function normalizeNumber(value, fallback)
    local number = tonumber(value)
    if number then
        return number
    end
    return fallback
end

function Queries._buildSourcesQuery()
    return json.encode({
        query = "query getSources { sources { nodes { id name displayName lang isNsfw supportsLatest } } }",
    })
end

function Queries._buildLegacySourcesQuery()
    return json.encode({
        query = "query getSources { sources { nodes { id name displayName lang } } }",
    })
end

function Queries._buildMangaQuery(options)
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

function Queries._buildLibraryMangaQuery(options)
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

function Queries._buildCategoryQuery()
    return json.encode({
        query = "query GET_LIBRARY_CATEGORIES { categories { nodes { id name order mangas { totalCount } } } }",
    })
end

function Queries._buildUpdateMangaLibraryMutation(manga_id, in_library)
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

function Queries._buildRefreshMangaMutation(manga_id)
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

function Queries._buildChapterQuery(manga_id)
    return json.encode({
        query = "mutation GET_MANGA_CHAPTERS_FETCH($input: FetchChaptersInput!) { fetchChapters(input: $input) { chapters { id name chapterNumber sourceOrder scanlator isRead } } }",
        variables = {
            input = {
                mangaId = tonumber(manga_id) or manga_id,
            },
        },
    })
end

function Queries._buildChapterPagesQuery(chapter_id)
    return json.encode({
        query = "mutation Pages($input: FetchChapterPagesInput!) { fetchChapterPages(input: $input) { pages chapter { id name chapterNumber sourceOrder manga { title } } } }",
        variables = {
            input = {
                chapterId = tonumber(chapter_id) or chapter_id,
            },
        },
    })
end

function Queries._buildStoredChapterQuery(manga_id)
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

function Queries._buildUpdateChapterReadMutation(chapter_id, is_read)
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

function Queries._buildUpdateChaptersReadMutation(chapter_ids, is_read)
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

function Queries._buildMarkChapterReadMutation(chapter_id)
    return Queries._buildUpdateChapterReadMutation(chapter_id, true)
end

function Queries._buildMarkChapterUnreadMutation(chapter_id)
    return Queries._buildUpdateChapterReadMutation(chapter_id, false)
end

return Queries
