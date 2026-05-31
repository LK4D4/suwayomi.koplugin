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

local function parseExtensionNode(extension)
    if type(extension) ~= "table" then
        return nil
    end
    local pkg_name = extension.pkgName or extension.pkg_name
    if pkg_name == nil then
        return nil
    end
    return {
        pkg_name = tostring(pkg_name),
        name = extension.name or tostring(pkg_name),
        lang = extension.lang,
        version_name = extension.versionName,
        version_code = tonumber(extension.versionCode) or extension.versionCode,
        is_nsfw = extension.isNsfw == true,
        is_installed = extension.isInstalled == true,
        has_update = extension.hasUpdate == true,
        is_obsolete = extension.isObsolete == true,
        icon_url = extension.iconUrl,
        apk_name = extension.apkName,
        repo = extension.repo,
    }
end

local function normalizeFilterType(filter)
    local typename = filter.__typename or filter.type
    if typename then
        return tostring(typename)
    end
    return nil
end

local function parseFilterNode(filter)
    if type(filter) ~= "table" then
        return nil
    end

    local filter_type = normalizeFilterType(filter)
    if not filter_type then
        return nil
    end
    local name = filter.name ~= nil and tostring(filter.name) or ""
    local parsed = {
        type = filter_type,
        name = name,
    }
    if filter_type == "HeaderFilter" or filter_type == "SeparatorFilter" then
        return parsed
    elseif filter_type == "CheckBoxFilter" then
        local default = filter.checkBoxDefault
        if default == nil then
            default = filter.default
        end
        parsed.default = default == true
        return parsed
    elseif filter_type == "TriStateFilter" then
        local default = filter.triStateDefault
        if default == nil then
            default = filter.default
        end
        parsed.default = default or "IGNORE"
        return parsed
    elseif filter_type == "SelectFilter" then
        if type(filter.values) ~= "table" then
            return nil
        end
        parsed.values = filter.values
        local default = filter.selectDefault
        if default == nil then
            default = filter.default
        end
        parsed.default = tonumber(default) or 0
        return parsed
    elseif filter_type == "TextFilter" then
        local default = filter.textDefault
        if default == nil then
            default = filter.default
        end
        parsed.default = default ~= nil and tostring(default) or ""
        return parsed
    elseif filter_type == "SortFilter" then
        local default = filter.sortDefault
        if default == nil then
            default = filter.default
        end
        if type(filter.values) ~= "table" or type(default) ~= "table" then
            return nil
        end
        parsed.values = filter.values
        parsed.default = {
            index = tonumber(default.index) or 0,
            ascending = default.ascending == true,
        }
        return parsed
    elseif filter_type == "GroupFilter" then
        if type(filter.filters) ~= "table" then
            return nil
        end
        parsed.filters = {}
        for _, child in ipairs(filter.filters) do
            local parsed_child = parseFilterNode(child)
            if parsed_child then
                table.insert(parsed.filters, parsed_child)
            end
        end
        return parsed
    end
    parsed.unsupported = true
    return parsed
end

local function parseChapterNode(chapter)
    if type(chapter) ~= "table" or chapter.id == nil then
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

local function normalizeGenres(genre)
    if type(genre) == "table" then
        local genres = {}
        for _, value in ipairs(genre) do
            table.insert(genres, tostring(value))
        end
        return genres
    elseif genre ~= nil then
        return { tostring(genre) }
    end
    return nil
end

local function parseMangaNode(entry)
    if type(entry) ~= "table" or entry.id == nil then
        return nil
    end

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
    if entry.author ~= nil then
        manga.author = entry.author
    end
    if entry.artist ~= nil then
        manga.artist = entry.artist
    end
    if entry.description ~= nil then
        manga.description = entry.description
    end
    if entry.genre ~= nil then
        manga.genres = normalizeGenres(entry.genre)
    end
    if entry.status ~= nil then
        manga.status = entry.status
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
            if type(category) ~= "table" or category.id == nil then
                return nil
            end
            table.insert(manga.categories, {
                id = tostring(category.id),
                name = category.name or tostring(category.id),
                order = category.order,
            })
        end
    end

    manga.first_unread_chapter = parseChapterNode(entry.firstUnreadChapter)
    if entry.firstUnreadChapter ~= nil and not manga.first_unread_chapter then
        return nil
    end
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
        if type(source) ~= "table" or source.id == nil then
            return nil, "Suwayomi server returned invalid source data."
        end
        table.insert(parsed_sources, {
            id = tostring(source.id),
            name = source.displayName or ((source.name or tostring(source.id)) .. (source.lang and source.lang ~= "" and source.lang ~= "localsourcelang" and (" (" .. string.upper(source.lang) .. ")") or "")),
            display_name = source.displayName,
            raw_name = source.name,
            lang = source.lang,
            icon_url = source.iconUrl,
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
        local mentions_optional_field = message:match("iconUrl")
            or message:match("isNsfw")
            or message:match("supportsLatest")
        local looks_like_schema_error = message:match("Cannot query field")
            or message:match("Unknown field")
            or message:match("FieldUndefined")
        if mentions_optional_field and looks_like_schema_error then
            return true
        end
    end
    return false
end

function Parsers.isOptionalExtensionMetadataFieldError(response_body)
    local payload = json.decode(response_body, 1, nil)
    if type(payload) ~= "table" or type(payload.errors) ~= "table" then
        return false
    end

    for _, graph_error in ipairs(payload.errors) do
        local message = tostring(graph_error and graph_error.message or "")
        local mentions_optional_field = message:match("iconUrl")
            or message:match("apkName")
            or message:match("repo")
        local looks_like_schema_error = message:match("Cannot query field")
            or message:match("Unknown field")
            or message:match("FieldUndefined")
        if mentions_optional_field and looks_like_schema_error then
            return true
        end
    end
    return false
end

function Parsers.isOptionalMangaMetadataFieldError(response_body)
    local payload = json.decode(response_body, 1, nil)
    if type(payload) ~= "table" or type(payload.errors) ~= "table" then
        return false
    end

    for _, graph_error in ipairs(payload.errors) do
        local message = tostring(graph_error and graph_error.message or "")
        local mentions_optional_field = message:match("author")
            or message:match("artist")
            or message:match("description")
            or message:match("genre")
            or message:match("status")
        local looks_like_schema_error = message:match("Cannot query field")
            or message:match("Unknown field")
            or message:match("FieldUndefined")
        if mentions_optional_field and looks_like_schema_error then
            return true
        end
    end
    return false
end

function Parsers.parseSourceFiltersResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local source = payload and payload.data and payload.data.source
    if type(source) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not return source filters."
    end

    local filters = {}
    for _, filter in ipairs(type(source.filters) == "table" and source.filters or {}) do
        local parsed = parseFilterNode(filter)
        if parsed then
            table.insert(filters, parsed)
        end
    end

    return {
        source = {
            id = source.id ~= nil and tostring(source.id) or nil,
            display_name = source.displayName,
            name = source.name,
        },
        filters = filters,
    }
end

function Parsers.isSourceFiltersFieldError(response_body)
    local payload = json.decode(response_body, 1, nil)
    if type(payload) ~= "table" or type(payload.errors) ~= "table" then
        return false
    end

    for _, graph_error in ipairs(payload.errors) do
        local message = tostring(graph_error and graph_error.message or "")
        local mentions_filters = message:match("filters")
        local looks_like_schema_error = message:match("Cannot query field")
            or message:match("Unknown field")
            or message:match("FieldUndefined")
        if mentions_filters and looks_like_schema_error then
            return true
        end
    end
    return false
end

local function parseMetaNode(meta)
    if type(meta) ~= "table" or meta.key == nil or meta.value == nil then
        return nil
    end
    return {
        key = tostring(meta.key),
        value = tostring(meta.value),
        source_id = meta.sourceId ~= nil and tostring(meta.sourceId) or nil,
    }
end

function Parsers.parseSourceMetadataResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local source = payload and payload.data and payload.data.source
    if type(source) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not return source metadata."
    end

    local meta = {}
    for _, raw_meta in ipairs(type(source.meta) == "table" and source.meta or {}) do
        local parsed = parseMetaNode(raw_meta)
        if parsed then
            parsed.source_id = nil
            table.insert(meta, parsed)
        end
    end

    return {
        source = {
            id = source.id ~= nil and tostring(source.id) or nil,
        },
        meta = meta,
    }
end

function Parsers.parseSetSourceMetasResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local meta_nodes = payload and payload.data and payload.data.setSourceMetas and payload.data.setSourceMetas.metas
    if type(meta_nodes) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not update source metadata."
    end

    local meta = {}
    for _, raw_meta in ipairs(meta_nodes) do
        local parsed = parseMetaNode(raw_meta)
        if parsed then
            table.insert(meta, parsed)
        end
    end

    return {
        meta = meta,
    }
end

function Parsers.isSourceMetadataFieldError(response_body)
    local payload = json.decode(response_body, 1, nil)
    if type(payload) ~= "table" or type(payload.errors) ~= "table" then
        return false
    end

    for _, graph_error in ipairs(payload.errors) do
        local message = tostring(graph_error and graph_error.message or "")
        local mentions_metadata = message:match("meta") or message:match("setSourceMetas")
        local looks_like_schema_error = message:match("Cannot query field")
            or message:match("Unknown field")
            or message:match("FieldUndefined")
        if mentions_metadata and looks_like_schema_error then
            return true
        end
    end
    return false
end

function Parsers.parseExtensionsResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local extension_nodes = payload
        and payload.data
        and payload.data.fetchExtensions
        and payload.data.fetchExtensions.extensions
    if type(extension_nodes) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not return an extension list."
    end

    local extensions = {}
    for _, extension in ipairs(extension_nodes) do
        local parsed = parseExtensionNode(extension)
        if parsed then
            table.insert(extensions, parsed)
        end
    end
    return extensions
end

function Parsers.parseUpdateExtensionResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local extension = payload
        and payload.data
        and payload.data.updateExtension
        and payload.data.updateExtension.extension
    if type(extension) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not update extension."
    end

    local parsed = parseExtensionNode(extension)
    if not parsed then
        return nil, "Suwayomi server returned an invalid extension."
    end
    return parsed
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
        local parsed = parseMangaNode(entry)
        if not parsed then
            return nil, "Suwayomi server returned invalid manga data."
        end
        table.insert(manga, parsed)
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
        local manga = parseMangaNode(entry)
        if not manga then
            return nil, "Suwayomi server returned invalid manga data."
        end
        table.insert(parsed, manga)
    end
    return {
        total_count = tonumber(mangas.totalCount) or #parsed,
        manga = parsed,
    }
end

function Parsers.parseMangaByIdResponse(response_body)
    local parsed, parse_error = Parsers.parseLibraryMangaResponse(response_body)
    if not parsed then
        return nil, parse_error
    end
    if type(parsed.manga) ~= "table" or #parsed.manga == 0 then
        return nil, "Suwayomi server did not return manga data."
    end
    return parsed.manga[1]
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
        if type(category) ~= "table" or category.id == nil then
            return nil, "Suwayomi server returned invalid category data."
        end
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
    if manga.id == nil then
        return nil, "Suwayomi server returned invalid manga data."
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
        if not parsed_chapter then
            return nil, "Suwayomi server returned invalid chapter data."
        end
        table.insert(chapters, {
            id = parsed_chapter.id,
            name = parsed_chapter.name,
            chapter_number = parsed_chapter.chapter_number,
            source_order = parsed_chapter.source_order,
            scanlator = parsed_chapter.scanlator,
            is_read = parsed_chapter.is_read,
        })
    end
    local parsed_manga = parseMangaNode(manga)
    if not parsed_manga then
        return nil, "Suwayomi server returned invalid manga data."
    end

    return {
        manga = parsed_manga,
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
        local chapter = parseChapterNode(entry)
        if not chapter then
            return nil, "Suwayomi server returned invalid chapter data."
        end
        table.insert(chapters, chapter)
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
    if chapter.id == nil then
        return nil, "Suwayomi server returned invalid chapter data."
    end
    for _, page_url in ipairs(pages) do
        if type(page_url) ~= "string" or page_url == "" then
            return nil, "Suwayomi server returned invalid chapter page URLs."
        end
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
        local chapter = parseChapterNode(entry)
        if not chapter then
            return nil, "Suwayomi server returned invalid chapter data."
        end
        table.insert(chapters, chapter)
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
    if chapter.id == nil then
        return nil, "Suwayomi server returned invalid chapter data."
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
        if type(chapter) ~= "table" or chapter.id == nil then
            return nil, "Suwayomi server returned invalid chapter data."
        end
        table.insert(chapters, {
            id = tostring(chapter.id),
            is_read = chapter.isRead == true,
        })
    end
    return chapters
end

return Parsers
