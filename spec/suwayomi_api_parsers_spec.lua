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
    end)

    it("parses manga, library manga, categories, and refresh responses", function()
        local manga, has_next_page = parsers.parseMangaResponse([[
            { "data": { "fetchSourceManga": { "hasNextPage": true, "mangas": [
                { "id": 17, "title": "Frieren", "inLibrary": true, "initialized": true,
                  "chapters": { "totalCount": 42 },
                  "source": { "id": "local", "displayName": "Local Source", "name": "Local Source", "lang": "localsourcelang" } }
            ] } } }
        ]])
        assert.are.equal(true, has_next_page)
        assert.are.equal("17", manga[1].id)
        assert.are.equal("Frieren", manga[1].title)
        assert.are.equal(true, manga[1].in_library)
        assert.are.equal(42, manga[1].chapter_count)
        assert.are.equal("local", manga[1].source.id)

        local library = assert(parsers.parseLibraryMangaResponse([[
            { "data": { "mangas": { "totalCount": 1, "nodes": [
                { "id": 17, "title": "Frieren", "unreadCount": 4, "downloadCount": 3,
                  "categories": { "nodes": [ { "id": 2, "name": "Reading", "order": 1 } ] },
                  "firstUnreadChapter": { "id": 398, "name": "Ch. 1", "chapterNumber": 1, "sourceOrder": 1, "scanlator": "Sense Scans", "isRead": false },
                  "latestFetchedChapter": { "id": 399, "name": "Ch. 2", "chapterNumber": 2, "sourceOrder": 2, "scanlator": "Flame Scans", "isRead": true } }
            ] } } }
        ]]))
        assert.are.equal(1, library.total_count)
        assert.are.equal(4, library.manga[1].unread_count)
        assert.are.equal(3, library.manga[1].download_count)
        assert.are.equal("Reading", library.manga[1].categories[1].name)
        assert.are.equal("398", library.manga[1].first_unread_chapter.id)
        assert.are.equal(true, library.manga[1].latest_fetched_chapter.is_read)

        local categories = assert(parsers.parseCategoryResponse([[
            { "data": { "categories": { "nodes": [
                { "id": 2, "name": "Reading", "order": 1, "mangas": { "totalCount": 7 } }
            ] } } }
        ]]))
        assert.are.equal("2", categories[1].id)
        assert.are.equal(7, categories[1].manga_count)

        local refreshed = assert(parsers.parseRefreshMangaResponse([[
            { "data": {
                "fetchManga": { "manga": { "id": 17, "title": "Frieren", "initialized": true } },
                "fetchChapters": { "chapters": [ { "id": 398, "name": "Ch. 1", "scanlator": "Sense Scans", "isRead": false } ] }
            } }
        ]]))
        assert.are.equal("17", refreshed.manga.id)
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
end)
