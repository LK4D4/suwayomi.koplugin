-- Boundary: public Suwayomi GraphQL/API facade.
--
-- Responsibility: preserve the historical require("suwayomi/api") surface while
-- delegating query building, response parsing, and transport concerns to focused
-- internal modules. Stored chapter loading validates complete sequential pages
-- and bounds their aggregate result before publishing success.
-- Owned state: optional debug logger only.
-- Dependencies: suwayomi/api/* modules; callers should not need to require
-- those internal modules directly.
-- External data: server responses and credentials stay normalized by the
-- delegated parser/transport boundaries before callers receive results.

local SuwayomiAPI = {}

local queries = require("suwayomi/api/queries")
local parsers = require("suwayomi/api/parsers")
local transport = require("suwayomi/api/transport")
local json = require("dkjson")

local MAX_CHAPTER_RESULT_BYTES = 4 * 1024 * 1024

local debug_logger

-- These lists intentionally define the compatibility surface exported by the
-- facade. Add new helpers here only when they are meant to be public API.
local query_exports = {
    "_buildConnectionTestQuery",
    "_buildSourcesQuery",
    "_buildLegacySourcesQuery",
    "_buildSourceFiltersQuery",
    "_buildMangaQuery",
    "_buildLegacyMangaQuery",
    "_buildLibraryMangaQuery",
    "_buildLegacyLibraryMangaQuery",
    "_buildMangaByIdQuery",
    "_buildLegacyMangaByIdQuery",
    "_buildCategoryQuery",
    "_buildUpdateMangaLibraryMutation",
    "_buildRefreshMangaMutation",
    "_buildLegacyRefreshMangaMutation",
    "_buildChapterQuery",
    "_buildChapterPagesQuery",
    "_buildStoredChapterQuery",
    "_buildUpdateChapterReadMutation",
    "_buildUpdateChaptersReadMutation",
    "_buildMarkChapterReadMutation",
    "_buildMarkChapterUnreadMutation",
    "_buildFetchExtensionsMutation",
    "_buildLegacyFetchExtensionsMutation",
    "_buildUpdateExtensionMutation",
    "_buildLegacyUpdateExtensionMutation",
    "_buildSourceMetadataQuery",
    "_buildSetSourceSavedSearchesMutation",
}

local parser_exports = {
    "parseSourcesResponse",
    "parseSourceFiltersResponse",
    "isSourceFiltersFieldError",
    "parseSourceMetadataResponse",
    "parseSetSourceMetasResponse",
    "isSourceMetadataFieldError",
    "isOptionalMangaMetadataFieldError",
    "parseExtensionsResponse",
    "parseUpdateExtensionResponse",
    "parseMangaResponse",
    "parseLibraryMangaResponse",
    "parseMangaByIdResponse",
    "parseCategoryResponse",
    "parseUpdateMangaLibraryResponse",
    "parseRefreshMangaResponse",
    "parseChapterResponse",
    "parseChapterPagesResponse",
    "parseStoredChapterResponse",
    "parseMarkChapterReadResponse",
    "parseMarkChaptersReadResponse",
}

local transport_exports = {
    "buildBasicAuthHeader",
    "buildRequestHeaders",
    "buildGraphQLEndpoint",
    "buildRequestURL",
    "buildChapterArchiveDownloadURL",
}

for _, name in ipairs(query_exports) do
    SuwayomiAPI[name] = queries[name]
end

for _, name in ipairs(parser_exports) do
    SuwayomiAPI[name] = parsers[name]
end

for _, name in ipairs(transport_exports) do
    SuwayomiAPI[name] = transport[name]
end

local function logDebugEvent(event)
    if debug_logger then
        pcall(debug_logger, event)
    end
end

local function performGraphQLRequest(credentials, request_body, operation_name, options)
    return transport.performGraphQLRequest(credentials, request_body, operation_name, logDebugEvent, options)
end

function SuwayomiAPI.setDebugLogger(logger)
    debug_logger = logger
end

function SuwayomiAPI.testConnection(credentials, options)
    local result = performGraphQLRequest(
        credentials,
        SuwayomiAPI._buildConnectionTestQuery(),
        "testConnection",
        options
    )
    if not result.ok then
        return result
    end
    local categories, parse_error = parsers.parseCategoryResponse(result.response_body)
    if not categories then
        return { ok = false, error = parse_error, retryable = false }
    end
    return {
        ok = true,
    }
end

function SuwayomiAPI.fetchSources(credentials)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildSourcesQuery(), "fetchSources")
    if not result.ok then
        return result
    end
    if parsers.isOptionalSourceMetadataFieldError(result.response_body) then
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

function SuwayomiAPI.fetchExtensions(credentials)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildFetchExtensionsMutation(), "fetchExtensions")
    if not result.ok then
        return result
    end
    if parsers.isOptionalExtensionMetadataFieldError(result.response_body) then
        logDebugEvent({ operation = "fetchExtensions", event = "legacy_extension_query_retry" })
        result = performGraphQLRequest(credentials, SuwayomiAPI._buildLegacyFetchExtensionsMutation(), "fetchExtensions")
        if not result.ok then
            return result
        end
    end

    local extensions, parse_error = SuwayomiAPI.parseExtensionsResponse(result.response_body)
    if not extensions then
        logDebugEvent({ operation = "fetchExtensions", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        extensions = extensions,
    }
end

function SuwayomiAPI.updateExtension(credentials, pkg_name, action)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildUpdateExtensionMutation(pkg_name, action), "updateExtension")
    if not result.ok then
        return result
    end
    if parsers.isOptionalExtensionMetadataFieldError(result.response_body) then
        logDebugEvent({ operation = "updateExtension", event = "legacy_extension_query_retry" })
        result = performGraphQLRequest(credentials, SuwayomiAPI._buildLegacyUpdateExtensionMutation(pkg_name, action), "updateExtension")
        if not result.ok then
            return result
        end
    end

    local extension, parse_error = SuwayomiAPI.parseUpdateExtensionResponse(result.response_body)
    if not extension then
        logDebugEvent({ operation = "updateExtension", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        extension = extension,
    }
end

function SuwayomiAPI.fetchSourceFilters(credentials, source_id)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildSourceFiltersQuery(source_id), "fetchSourceFilters")
    if not result.ok then
        return result
    end
    if parsers.isSourceFiltersFieldError(result.response_body) then
        return {
            ok = false,
            error = "Source filters are not supported by this server.",
        }
    end

    local parsed, parse_error = SuwayomiAPI.parseSourceFiltersResponse(result.response_body)
    if not parsed then
        logDebugEvent({ operation = "fetchSourceFilters", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        source = parsed.source,
        filters = parsed.filters,
    }
end

function SuwayomiAPI.fetchSourceMetadata(credentials, source_id)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildSourceMetadataQuery(source_id), "fetchSourceMetadata")
    if not result.ok then
        return result
    end
    if parsers.isSourceMetadataFieldError(result.response_body) then
        return {
            ok = false,
            error = "Saved filters are not supported by this server.",
        }
    end

    local parsed, parse_error = SuwayomiAPI.parseSourceMetadataResponse(result.response_body)
    if not parsed then
        logDebugEvent({ operation = "fetchSourceMetadata", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        source = parsed.source,
        meta = parsed.meta,
    }
end

function SuwayomiAPI.setSourceSavedSearches(credentials, source_id, saved_searches_json)
    local result = performGraphQLRequest(
        credentials,
        SuwayomiAPI._buildSetSourceSavedSearchesMutation(source_id, saved_searches_json),
        "setSourceSavedSearches"
    )
    if not result.ok then
        return result
    end
    if parsers.isSourceMetadataFieldError(result.response_body) then
        return {
            ok = false,
            error = "Saved filters are not supported by this server.",
        }
    end

    local parsed, parse_error = SuwayomiAPI.parseSetSourceMetasResponse(result.response_body)
    if not parsed then
        logDebugEvent({ operation = "setSourceSavedSearches", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        meta = parsed.meta,
    }
end

function SuwayomiAPI.fetchMangaForSource(credentials, options)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildMangaQuery(options), "fetchMangaForSource")
    if not result.ok then
        return result
    end
    if parsers.isOptionalMangaMetadataFieldError(result.response_body) then
        logDebugEvent({ operation = "fetchMangaForSource", event = "legacy_manga_query_retry" })
        result = performGraphQLRequest(credentials, SuwayomiAPI._buildLegacyMangaQuery(options), "fetchMangaForSource")
        if not result.ok then
            return result
        end
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
    if parsers.isOptionalMangaMetadataFieldError(result.response_body) then
        logDebugEvent({ operation = "fetchLibraryManga", event = "legacy_manga_query_retry" })
        result = performGraphQLRequest(credentials, SuwayomiAPI._buildLegacyLibraryMangaQuery(options), "fetchLibraryManga")
        if not result.ok then
            return result
        end
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

function SuwayomiAPI.fetchMangaById(credentials, manga_id)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildMangaByIdQuery(manga_id), "fetchMangaById")
    if not result.ok then
        return result
    end
    if parsers.isOptionalMangaMetadataFieldError(result.response_body) then
        logDebugEvent({ operation = "fetchMangaById", event = "legacy_manga_query_retry" })
        result = performGraphQLRequest(credentials, SuwayomiAPI._buildLegacyMangaByIdQuery(manga_id), "fetchMangaById")
        if not result.ok then
            return result
        end
    end

    local manga, parse_error = SuwayomiAPI.parseMangaByIdResponse(result.response_body)
    if not manga then
        logDebugEvent({ operation = "fetchMangaById", event = "parse_error", error = parse_error })
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
    if parsers.isOptionalMangaMetadataFieldError(result.response_body) then
        logDebugEvent({ operation = "refreshManga", event = "legacy_manga_query_retry" })
        result = performGraphQLRequest(credentials, SuwayomiAPI._buildLegacyRefreshMangaMutation(manga_id), "refreshManga")
        if not result.ok then
            return result
        end
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

function SuwayomiAPI.downloadBinary(credentials, page_url, options)
    return transport.downloadBinary(credentials, page_url, logDebugEvent, options)
end

function SuwayomiAPI.downloadChapterArchive(credentials, chapter_id, target_path, options)
    return transport.downloadChapterArchive(credentials, chapter_id, target_path, logDebugEvent, options)
end

local function incompleteChapterLoad(reason)
    return { ok = false, error_kind = "incomplete", error = "Incomplete chapter load: " .. tostring(reason) }
end

function SuwayomiAPI.queryChaptersForManga(credentials, manga_id, options)
    options = options or {}
    local max_result_bytes = tonumber(options.max_result_bytes) or MAX_CHAPTER_RESULT_BYTES
    local chapters = {}
    local seen = {}
    local total_count
    local previous
    local result_bytes
    while true do
        local result = performGraphQLRequest(credentials,
            SuwayomiAPI._buildStoredChapterQuery(manga_id, #chapters), "queryChaptersForManga")
        if not result.ok then
            local failure = incompleteChapterLoad(result.error)
            failure.retryable = result.retryable
            failure.status_code = result.status_code
            return failure
        end
        local page, parse_error = SuwayomiAPI.parseStoredChapterResponse(result.response_body)
        if not page then
            logDebugEvent({ operation = "queryChaptersForManga", event = "parse_error", error = parse_error })
            return incompleteChapterLoad(parse_error)
        end
        if total_count ~= nil and page.total_count ~= total_count then
            return incompleteChapterLoad("The chapter total changed during loading.")
        end
        total_count = page.total_count
        if not result_bytes then
            result_bytes = #json.encode({ ok = true, chapters = {}, total_count = total_count, has_next_page = false })
        end
        if #page.chapters > 200 or #chapters + #page.chapters > total_count then
            return incompleteChapterLoad("The chapter count exceeds the reported page or total size.")
        end
        for _, chapter in ipairs(page.chapters) do
            if seen[chapter.id] then
                return incompleteChapterLoad("The server returned duplicate chapter IDs.")
            end
            if previous and (chapter.source_order < previous.source_order
                or (chapter.source_order == previous.source_order and tonumber(chapter.id) <= tonumber(previous.id)))
            then
                return incompleteChapterLoad("The server returned chapters out of order.")
            end
            seen[chapter.id] = true
            previous = chapter
            result_bytes = result_bytes + #json.encode(chapter) + (#chapters > 0 and 1 or 0)
            if result_bytes > max_result_bytes then
                return { ok = false, error_kind = "too_large", error = "Chapter list is too large to load completely." }
            end
            chapters[#chapters + 1] = chapter
        end
        if #chapters == total_count and page.has_next_page == false then break end
        if #page.chapters == 0 or #chapters == total_count or page.has_next_page == false then
            return incompleteChapterLoad("The chapter count and continuation do not agree.")
        end
    end

    return {
        ok = true,
        chapters = chapters,
        total_count = total_count,
        has_next_page = false,
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

function SuwayomiAPI.fetchChaptersForManga(credentials, manga_id, options)
    local stored_result = SuwayomiAPI.queryChaptersForManga(credentials, manga_id, options)
    if not stored_result.ok or #stored_result.chapters > 0 then
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
