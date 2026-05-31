package.path = "?.lua;" .. package.path

-- Pure parser coverage: these specs keep malformed server responses and
-- normalized plugin table shapes separate from transport/facade behavior.
describe("suwayomi/api/parsers", function()
    local parsers

    before_each(function()
        package.loaded["suwayomi/api/parsers"] = nil
        parsers = require("suwayomi/api/parsers")
    end)

    it("parses sources and detects optional metadata schema errors", function()
        local sources = assert(parsers.parseSourcesResponse([[
            { "data": { "sources": { "nodes": [
                { "id": "local", "name": "Local Source", "displayName": "Local Source", "lang": "localsourcelang", "iconUrl": "/icons/local.png", "isNsfw": false, "supportsLatest": true },
                { "id": 42, "name": "MangaDex", "lang": "en" }
            ] } } }
        ]]))

        assert.are.equal("local", sources[1].id)
        assert.are.equal("Local Source", sources[1].name)
        assert.are.equal("/icons/local.png", sources[1].icon_url)
        assert.are.equal(false, sources[1].is_nsfw)
        assert.are.equal(true, sources[1].supports_latest)
        assert.are.equal("42", sources[2].id)
        assert.are.equal("MangaDex (EN)", sources[2].name)

        assert.is_true(parsers.isOptionalSourceMetadataFieldError([[
            { "errors": [ { "message": "Cannot query field \"isNsfw\" on type \"Source\"" } ] }
        ]]))
        assert.is_true(parsers.isOptionalSourceMetadataFieldError([[
            { "errors": [ { "message": "Cannot query field \"iconUrl\" on type \"Source\"" } ] }
        ]]))
        assert.is_false(parsers.isOptionalSourceMetadataFieldError([[
            { "errors": [ { "message": "Authentication failed" } ] }
        ]]))

        assert.is_true(parsers.isOptionalExtensionMetadataFieldError([[
            { "errors": [ { "message": "Cannot query field \"apkName\" on type \"Extension\"" } ] }
        ]]))
        assert.is_true(parsers.isOptionalExtensionMetadataFieldError([[
            { "errors": [ { "message": "Cannot query field \"repo\" on type \"Extension\"" } ] }
        ]]))
        assert.is_false(parsers.isOptionalExtensionMetadataFieldError([[
            { "errors": [ { "message": "Authentication failed" } ] }
        ]]))

        assert.is_true(parsers.isOptionalMangaMetadataFieldError([[
            { "errors": [ { "message": "Cannot query field \"artist\" on type \"Manga\"" } ] }
        ]]))
        assert.is_true(parsers.isOptionalMangaMetadataFieldError([[
            { "errors": [ { "message": "FieldUndefined: description" } ] }
        ]]))
        assert.is_false(parsers.isOptionalMangaMetadataFieldError([[
            { "errors": [ { "message": "Cannot query field \"chapters\" on type \"Manga\"" } ] }
        ]]))
    end)

    it("parses source filter schema responses", function()
        local parsed = assert(parsers.parseSourceFiltersResponse([[
            { "data": { "source": {
                "id": "s1",
                "displayName": "MangaDex",
                "name": "mangadex",
                "filters": [
                    { "__typename": "HeaderFilter", "name": "Tags" },
                    { "__typename": "CheckBoxFilter", "name": "Completed", "default": false },
                    { "__typename": "TriStateFilter", "name": "Official", "default": "IGNORE" },
                    { "__typename": "SelectFilter", "name": "Demographic", "values": ["Any", "Shounen"], "default": 0 },
                    { "__typename": "TextFilter", "name": "Author", "default": "" },
                    { "__typename": "SortFilter", "name": "Sort", "values": ["Relevance"], "default": { "index": 0, "ascending": false } },
                    { "__typename": "GroupFilter", "name": "Genres", "filters": [
                        { "__typename": "CheckBoxFilter", "name": "Fantasy", "default": false },
                        { "__typename": "UnknownNestedFilter", "name": "Nested unknown" }
                    ] },
                    { "__typename": "UnknownFilter", "name": "Show read-only" },
                    { "__typename": "SelectFilter", "name": "Bad select" },
                    { "__typename": "SortFilter", "name": "Bad sort", "values": ["Relevance"] },
                    { "__typename": "GroupFilter", "name": "Bad group" },
                    "bad"
                ]
            } } }
        ]]))

        assert.are.equal("s1", parsed.source.id)
        assert.are.equal("MangaDex", parsed.source.display_name)
        assert.are.equal("mangadex", parsed.source.name)
        assert.are.equal(8, #parsed.filters)
        assert.are.equal("HeaderFilter", parsed.filters[1].type)
        assert.are.equal("CheckBoxFilter", parsed.filters[2].type)
        assert.are.equal(false, parsed.filters[2].default)
        assert.are.equal("TriStateFilter", parsed.filters[3].type)
        assert.are.equal("IGNORE", parsed.filters[3].default)
        assert.are.same({ "Any", "Shounen" }, parsed.filters[4].values)
        assert.are.equal(0, parsed.filters[4].default)
        assert.are.equal("", parsed.filters[5].default)
        assert.are.same({ index = 0, ascending = false }, parsed.filters[6].default)
        assert.are.equal("GroupFilter", parsed.filters[7].type)
        assert.are.equal("Fantasy", parsed.filters[7].filters[1].name)
        assert.are.equal("UnknownNestedFilter", parsed.filters[7].filters[2].type)
        assert.is_true(parsed.filters[7].filters[2].unsupported)
        assert.are.equal("UnknownFilter", parsed.filters[8].type)
        assert.is_true(parsed.filters[8].unsupported)
    end)

    it("parses aliased source filter defaults", function()
        local parsed = assert(parsers.parseSourceFiltersResponse([[
            { "data": { "source": {
                "id": "s1",
                "filters": [
                    { "__typename": "CheckBoxFilter", "name": "Completed", "checkBoxDefault": true },
                    { "__typename": "TriStateFilter", "name": "Official", "triStateDefault": "EXCLUDE" },
                    { "__typename": "SelectFilter", "name": "Demographic", "values": ["Any", "Shounen"], "selectDefault": 1 },
                    { "__typename": "TextFilter", "name": "Author", "textDefault": "Ada" },
                    { "__typename": "SortFilter", "name": "Sort", "values": ["Relevance"], "sortDefault": { "index": 0, "ascending": true } }
                ]
            } } }
        ]]))

        assert.are.equal(true, parsed.filters[1].default)
        assert.are.equal("EXCLUDE", parsed.filters[2].default)
        assert.are.equal(1, parsed.filters[3].default)
        assert.are.equal("Ada", parsed.filters[4].default)
        assert.are.same({ index = 0, ascending = true }, parsed.filters[5].default)
    end)

    it("reports source filter parser and schema errors", function()
        local invalid, invalid_error = parsers.parseSourceFiltersResponse("{")
        assert.is_nil(invalid)
        assert.are.equal("Invalid response from Suwayomi server.", invalid_error)

        local missing, missing_error = parsers.parseSourceFiltersResponse([[{ "data": { "source": null } }]])
        assert.is_nil(missing)
        assert.are.equal("Suwayomi server did not return source filters.", missing_error)

        local graph, graph_error = parsers.parseSourceFiltersResponse([[{"errors":[{"message":"No source found"}]}]])
        assert.is_nil(graph)
        assert.are.equal("No source found", graph_error)

        assert.is_true(parsers.isSourceFiltersFieldError([[
            { "errors": [ { "message": "Cannot query field \"filters\" on type \"SourceType\"" } ] }
        ]]))
        assert.is_true(parsers.isSourceFiltersFieldError([[
            { "errors": [ { "message": "FieldUndefined: filters" } ] }
        ]]))
        assert.is_false(parsers.isSourceFiltersFieldError([[
            { "errors": [ { "message": "Authentication failed" } ] }
        ]]))
    end)

    it("parses source metadata and detects unsupported metadata fields", function()
        local parsed = assert(parsers.parseSourceMetadataResponse([[
            { "data": { "source": {
                "id": "s1",
                "meta": [
                    { "key": "savedSearches", "value": "{\"Frieren\":{\"query\":\"frieren\",\"filters\":[]}}" },
                    { "key": "other", "value": "kept raw" },
                    { "key": 99, "value": 123 },
                    "bad"
                ]
            } } }
        ]]))

        assert.are.equal("s1", parsed.source.id)
        assert.are.same({
            { key = "savedSearches", value = "{\"Frieren\":{\"query\":\"frieren\",\"filters\":[]}}" },
            { key = "other", value = "kept raw" },
            { key = "99", value = "123" },
        }, parsed.meta)

        local malformed, malformed_error = parsers.parseSourceMetadataResponse("{")
        assert.is_nil(malformed)
        assert.are.equal("Invalid response from Suwayomi server.", malformed_error)

        local missing, missing_error = parsers.parseSourceMetadataResponse([[{ "data": { "source": null } }]])
        assert.is_nil(missing)
        assert.are.equal("Suwayomi server did not return source metadata.", missing_error)

        assert.is_true(parsers.isSourceMetadataFieldError([[
            { "errors": [ { "message": "Cannot query field \"meta\" on type \"Source\"" } ] }
        ]]))
        assert.is_true(parsers.isSourceMetadataFieldError([[
            { "errors": [ { "message": "Unknown field \"setSourceMetas\"" } ] }
        ]]))
        assert.is_false(parsers.isSourceMetadataFieldError([[
            { "errors": [ { "message": "Authentication failed" } ] }
        ]]))
    end)

    it("parses setSourceMetas responses", function()
        local parsed = assert(parsers.parseSetSourceMetasResponse([[
            { "data": { "setSourceMetas": {
                "metas": [
                    { "key": "savedSearches", "value": "{\"One\":{}}", "sourceId": "s1" }
                ]
            } } }
        ]]))

        assert.are.same({
            { key = "savedSearches", value = "{\"One\":{}}", source_id = "s1" },
        }, parsed.meta)

        local invalid, invalid_error = parsers.parseSetSourceMetasResponse([[{ "data": { "setSourceMetas": {} } }]])
        assert.is_nil(invalid)
        assert.are.equal("Suwayomi server did not update source metadata.", invalid_error)
    end)

    it("parses manga, library manga, categories, and refresh responses", function()
        local manga, has_next_page = parsers.parseMangaResponse([[
            { "data": { "fetchSourceManga": { "hasNextPage": true, "mangas": [
                { "id": 17, "title": "Cloud Lantern", "inLibrary": true, "initialized": true,
                  "author": "Rina Vale", "artist": "Mako Reed",
                  "description": "Archive notes cross the harbor.", "genre": ["Quest", "Ink"], "status": "ONGOING",
                  "thumbnailUrl": "/api/v1/manga/17/thumbnail",
                  "chapters": { "totalCount": 42 },
                  "source": { "id": "source-z", "displayName": "Source Z", "name": "Source Z", "lang": "zz" } }
            ] } } }
        ]])
        assert.are.equal(true, has_next_page)
        assert.are.equal("17", manga[1].id)
        assert.are.equal("Cloud Lantern", manga[1].title)
        assert.are.equal(true, manga[1].in_library)
        assert.are.equal("Rina Vale", manga[1].author)
        assert.are.equal("Mako Reed", manga[1].artist)
        assert.are.equal("Archive notes cross the harbor.", manga[1].description)
        assert.are.same({ "Quest", "Ink" }, manga[1].genres)
        assert.are.equal("ONGOING", manga[1].status)
        assert.are.equal("/api/v1/manga/17/thumbnail", manga[1].thumbnail_url)
        assert.are.equal(42, manga[1].chapter_count)
        assert.are.equal("source-z", manga[1].source.id)

        local library = assert(parsers.parseLibraryMangaResponse([[
            { "data": { "mangas": { "totalCount": 1, "nodes": [
                { "id": 17, "title": "Cloud Lantern", "unreadCount": 4, "downloadCount": 3,
                  "author": "Rina Vale", "artist": "Mako Reed",
                  "description": "Archive notes cross the harbor.", "genre": ["Quest", "Ink"], "status": "ONGOING",
                  "categories": { "nodes": [ { "id": 2, "name": "Reading", "order": 1 } ] },
                  "firstUnreadChapter": { "id": 398, "name": "Ch. 1", "chapterNumber": 1, "sourceOrder": 1, "scanlator": "Crew One", "isRead": false },
                  "latestFetchedChapter": { "id": 399, "name": "Ch. 2", "chapterNumber": 2, "sourceOrder": 2, "scanlator": "Crew Two", "isRead": true } }
            ] } } }
        ]]))
        assert.are.equal(1, library.total_count)
        assert.are.equal("Rina Vale", library.manga[1].author)
        assert.are.equal("Mako Reed", library.manga[1].artist)
        assert.are.equal("Archive notes cross the harbor.", library.manga[1].description)
        assert.are.same({ "Quest", "Ink" }, library.manga[1].genres)
        assert.are.equal("ONGOING", library.manga[1].status)
        assert.are.equal(4, library.manga[1].unread_count)
        assert.are.equal(3, library.manga[1].download_count)
        assert.are.equal("Reading", library.manga[1].categories[1].name)
        assert.are.equal("398", library.manga[1].first_unread_chapter.id)
        assert.is_nil(library.manga[1].latest_fetched_chapter)

        local single_manga = assert(parsers.parseMangaByIdResponse([[
            { "data": { "mangas": { "nodes": [
                {
                    "id": 17,
                    "title": "Paper Comet",
                    "inLibrary": true,
                    "source": { "id": "local", "displayName": "Local source", "name": "Local", "lang": "en" }
                }
            ] } } }
        ]]))
        assert.are.equal("17", single_manga.id)
        assert.are.equal("Paper Comet", single_manga.title)
        assert.are.equal(true, single_manga.in_library)
        assert.are.equal("local", single_manga.source.id)

        local categories = assert(parsers.parseCategoryResponse([[
            { "data": { "categories": { "nodes": [
                { "id": 2, "name": "Reading", "order": 1, "mangas": { "totalCount": 7 } }
            ] } } }
        ]]))
        assert.are.equal("2", categories[1].id)
        assert.are.equal(7, categories[1].manga_count)

        local refreshed = assert(parsers.parseRefreshMangaResponse([[
            { "data": {
                "fetchManga": { "manga": { "id": 17, "title": "Cloud Lantern", "initialized": true,
                    "author": "Rina Vale", "artist": "Mako Reed",
                    "description": "Archive notes cross the harbor.", "genre": ["Quest", "Ink"], "status": "ONGOING",
                    "thumbnailUrl": "/api/v1/manga/17/thumbnail" } },
                "fetchChapters": { "chapters": [ { "id": 398, "name": "Ch. 1", "scanlator": "Crew One", "isRead": false } ] }
            } }
        ]]))
        assert.are.equal("17", refreshed.manga.id)
        assert.are.equal("Rina Vale", refreshed.manga.author)
        assert.are.equal("Mako Reed", refreshed.manga.artist)
        assert.are.equal("Archive notes cross the harbor.", refreshed.manga.description)
        assert.are.same({ "Quest", "Ink" }, refreshed.manga.genres)
        assert.are.equal("ONGOING", refreshed.manga.status)
        assert.are.equal("/api/v1/manga/17/thumbnail", refreshed.manga.thumbnail_url)
        assert.are.equal("398", refreshed.chapters[1].id)
        assert.are.equal(false, refreshed.chapters[1].is_read)
    end)

    it("parses chapter lists, pages, and read-state mutation responses", function()
        local chapters = assert(parsers.parseChapterResponse([[
            { "data": { "fetchChapters": { "chapters": [
                { "id": 398, "name": "", "chapterNumber": 1, "sourceOrder": 2, "scanlator": "Sense Scans", "isRead": false }
            ] } } }
        ]]))
        assert.are.equal("398", chapters[1].id)
        assert.are.equal("Chapter 1", chapters[1].name)
        assert.are.equal(2, chapters[1].source_order)

        local pages = assert(parsers.parseChapterPagesResponse([[
            { "data": { "fetchChapterPages": {
                "pages": [ "/api/v1/manga/85/chapter/1/page/0" ],
                "chapter": { "id": 398, "name": "", "chapterNumber": 1, "sourceOrder": 2, "manga": { "title": "Sousou no Frieren" } }
            } } }
        ]]))
        assert.are.equal("398", pages.chapter.id)
        assert.are.equal("398", pages.chapter.name)
        assert.are.equal("Sousou no Frieren", pages.chapter.manga_title)
        assert.are.equal("/api/v1/manga/85/chapter/1/page/0", pages.pages[1])

        local invalid_pages, invalid_pages_error = parsers.parseChapterPagesResponse([[
            { "data": { "fetchChapterPages": {
                "pages": [ "/api/v1/page/0", "" ],
                "chapter": { "id": 398, "name": "Chapter 1" }
            } } }
        ]])
        assert.is_nil(invalid_pages)
        assert.are.equal("Suwayomi server returned invalid chapter page URLs.", invalid_pages_error)

        local stored = assert(parsers.parseStoredChapterResponse([[
            { "data": { "chapters": { "nodes": [
                { "id": 399, "name": "Ch. 2", "isRead": true }
            ] } } }
        ]]))
        assert.are.equal("399", stored[1].id)
        assert.are.equal(true, stored[1].is_read)

        local read = assert(parsers.parseMarkChapterReadResponse([[
            { "data": { "updateChapter": { "chapter": { "id": 398, "isRead": true } } } }
        ]]))
        assert.are.equal("398", read.id)
        assert.are.equal(true, read.is_read)

        local bulk = assert(parsers.parseMarkChaptersReadResponse([[
            { "data": { "updateChapters": { "chapters": [
                { "id": 398, "isRead": false }, { "id": 399, "isRead": false }
            ] } } }
        ]]))
        assert.are.equal("399", bulk[2].id)
        assert.are.equal(false, bulk[2].is_read)
    end)

    it("surfaces malformed JSON and GraphQL parser errors", function()
        local sources, sources_error = parsers.parseSourcesResponse("{")
        assert.is_nil(sources)
        assert.are.equal("Invalid response from Suwayomi server.", sources_error)

        local manga, manga_error = parsers.parseMangaResponse([[{ "errors": [ { "message": "No manga found" } ] }]])
        assert.is_nil(manga)
        assert.are.equal("No manga found", manga_error)

        local chapters, chapters_error = parsers.parseChapterResponse([[{ "data": { "fetchChapters": null } }]])
        assert.is_nil(chapters)
        assert.are.equal("Suwayomi server did not return a chapter list.", chapters_error)
    end)

    it("rejects malformed manga nodes with an explicit parser error", function()
        local source_manga, source_error = parsers.parseMangaResponse([[
            { "data": { "fetchSourceManga": { "hasNextPage": false, "mangas": [
                { "title": "Missing id" }
            ] } } }
        ]])
        assert.is_nil(source_manga)
        assert.are.equal("Suwayomi server returned invalid manga data.", source_error)

        local library_manga, library_error = parsers.parseLibraryMangaResponse([[
            { "data": { "mangas": { "totalCount": 1, "nodes": [
                { "title": "Missing id" }
            ] } } }
        ]])
        assert.is_nil(library_manga)
        assert.are.equal("Suwayomi server returned invalid manga data.", library_error)

        local refreshed, refresh_error = parsers.parseRefreshMangaResponse([[
            { "data": {
                "fetchManga": { "manga": { "title": "Missing id" } },
                "fetchChapters": { "chapters": [ { "id": 398, "name": "Ch. 1" } ] }
            } }
        ]])
        assert.is_nil(refreshed)
        assert.are.equal("Suwayomi server returned invalid manga data.", refresh_error)
    end)

    it("rejects malformed nested manga metadata explicitly", function()
        local library_manga, library_error = parsers.parseLibraryMangaResponse([[
            { "data": { "mangas": { "totalCount": 1, "nodes": [
                { "id": 17, "title": "Frieren",
                  "categories": { "nodes": [ { "name": "Missing id" } ] } }
            ] } } }
        ]])
        assert.is_nil(library_manga)
        assert.are.equal("Suwayomi server returned invalid manga data.", library_error)

        local source_manga, source_error = parsers.parseMangaResponse([[
            { "data": { "fetchSourceManga": { "hasNextPage": false, "mangas": [
                { "id": 17, "title": "Frieren",
                  "firstUnreadChapter": { "name": "Missing id" } }
            ] } } }
        ]])
        assert.is_nil(source_manga)
        assert.are.equal("Suwayomi server returned invalid manga data.", source_error)

        local refreshed, refresh_error = parsers.parseRefreshMangaResponse([[
            { "data": {
                "fetchManga": { "manga": { "id": 17, "title": "Frieren" } },
                "fetchChapters": { "chapters": [ { "name": "Missing id" } ] }
            } }
        ]])
        assert.is_nil(refreshed)
        assert.are.equal("Suwayomi server returned invalid chapter data.", refresh_error)

        local categories, category_error = parsers.parseCategoryResponse([[
            { "data": { "categories": { "nodes": [
                { "name": "Missing id" }
            ] } } }
        ]])
        assert.is_nil(categories)
        assert.are.equal("Suwayomi server returned invalid category data.", category_error)
    end)

    it("rejects malformed source, update, page, and bulk-read nodes explicitly", function()
        local sources, sources_error = parsers.parseSourcesResponse([[
            { "data": { "sources": { "nodes": [
                { "name": "Missing id" }
            ] } } }
        ]])
        assert.is_nil(sources)
        assert.are.equal("Suwayomi server returned invalid source data.", sources_error)

        local scalar_sources, scalar_sources_error = parsers.parseSourcesResponse([[
            { "data": { "sources": { "nodes": [
                "not a source"
            ] } } }
        ]])
        assert.is_nil(scalar_sources)
        assert.are.equal("Suwayomi server returned invalid source data.", scalar_sources_error)

        local updated, update_error = parsers.parseUpdateMangaLibraryResponse([[
            { "data": { "updateManga": { "manga": { "title": "Missing id" } } } }
        ]])
        assert.is_nil(updated)
        assert.are.equal("Suwayomi server returned invalid manga data.", update_error)

        local pages, pages_error = parsers.parseChapterPagesResponse([[
            { "data": { "fetchChapterPages": {
                "pages": [ "/api/v1/page/0" ],
                "chapter": { "name": "Missing id" }
            } } }
        ]])
        assert.is_nil(pages)
        assert.are.equal("Suwayomi server returned invalid chapter data.", pages_error)

        local bulk, bulk_error = parsers.parseMarkChaptersReadResponse([[
            { "data": { "updateChapters": { "chapters": [
                { "isRead": true }
            ] } } }
        ]])
        assert.is_nil(bulk)
        assert.are.equal("Suwayomi server returned invalid chapter data.", bulk_error)

        local scalar_bulk, scalar_bulk_error = parsers.parseMarkChaptersReadResponse([[
            { "data": { "updateChapters": { "chapters": [
                "not a chapter"
            ] } } }
        ]])
        assert.is_nil(scalar_bulk)
        assert.are.equal("Suwayomi server returned invalid chapter data.", scalar_bulk_error)
    end)
end)
