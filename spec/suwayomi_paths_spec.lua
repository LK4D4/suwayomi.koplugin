package.path = "?.lua;" .. package.path

describe("suwayomi/paths", function()
    after_each(function()
        package.loaded["suwayomi/paths"] = nil
        package.loaded["ffi/util"] = nil
        package.preload["ffi/util"] = nil
    end)

    local function load_paths()
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end
        return require("suwayomi/paths")
    end

    it("sanitizes unsafe and empty path segments", function()
        local paths = load_paths()

        assert.are.equal("Frieren_ Beyond Journey's End", paths.sanitizePathSegment(" Frieren: Beyond Journey's End "))
        assert.are.equal("untitled", paths.sanitizePathSegment(".."))
        assert.are.equal("untitled", paths.sanitizePathSegment(""))
    end)

    it("strips control characters from path segments", function()
        local paths = load_paths()

        assert.are.equal("Manga state=failed path=x", paths.sanitizePathSegment("Manga\nstate=failed\rpath=x"))
        assert.are.equal("Chapter  01", paths.sanitizePathSegment("\tChapter\000 01\n"))
        assert.are.equal("untitled", paths.sanitizePathSegment("\n\r\t"))
    end)

    it("selects the source label from display name first", function()
        local paths = load_paths()

        local label = paths.getSourceLabel({
            source = {
                id = "mangadex",
                displayName = "MangaDex (EN)",
                name = "MangaDex",
                lang = "en",
            },
        })

        assert.are.equal("MangaDex (EN)", label)
    end)

    it("falls back to source name with language before source id", function()
        local paths = load_paths()

        local label = paths.getSourceLabel({
            source = {
                id = "2499283573021220255",
                name = "Comick",
                lang = "en",
            },
        })

        assert.are.equal("Comick (EN)", label)
    end)

    it("does not append language when the source name already includes it", function()
        local paths = load_paths()

        local label = paths.getSourceLabel({
            source = {
                id = "mangadex",
                name = "MangaDex (EN)",
                lang = "en",
            },
        })

        assert.are.equal("MangaDex (EN)", label)
    end)

    it("uses source id before the unknown source fallback", function()
        local paths = load_paths()

        assert.are.equal("2499283573021220255", paths.getSourceLabel({
            source = { id = "2499283573021220255" },
        }))
        assert.are.equal("Unknown source", paths.getSourceLabel({}))
    end)

    it("ignores corrupt non-table source metadata", function()
        local paths = load_paths()

        assert.are.equal("Unknown source", paths.getSourceLabel({
            source = "MangaDex",
        }))
    end)

    it("builds source-scoped target paths", function()
        local paths = load_paths()

        local manga_dir, chapter_path = paths.getTargetPath("/books", {
            title = "Frieren: Beyond Journey's End",
            source = {
                displayName = "MangaDex (EN)",
                name = "MangaDex",
                lang = "en",
            },
        }, {
            name = "Vol. 1 / Ch. 1",
        })

        assert.are.equal("/books/MangaDex (EN)/Frieren_ Beyond Journey's End", manga_dir)
        assert.are.equal("/books/MangaDex (EN)/Frieren_ Beyond Journey's End/Vol. 1 _ Ch. 1.cbz", chapter_path)
    end)

    it("treats non-string download directory bases as unset before joining paths", function()
        local paths = load_paths()

        local manga_dir, chapter_path = paths.getTargetPath({ path = "/books" }, {
            title = "Frieren",
            source = { displayName = "MangaDex (EN)" },
        }, {
            name = "Chapter 1",
        })

        assert.is_nil(manga_dir)
        assert.is_nil(chapter_path)
    end)

    it("keeps duplicate chapter names collision-safe with stable ids", function()
        local paths = load_paths()
        local manga = {
            title = "Frieren",
            source = { displayName = "MangaDex (EN)" },
        }

        local first = paths.getChapterPath("/books", manga, {
            id = "398",
            name = "Chapter 1",
        })
        local second = paths.getChapterPath("/books", manga, {
            id = "399",
            name = "Chapter 1",
        })
        local no_id = paths.getChapterPath("/books", manga, {
            name = "Chapter 1",
            source_order = 3,
        })

        assert.are.equal("/books/MangaDex (EN)/Frieren/Chapter 1 [id-398].cbz", first)
        assert.are.equal("/books/MangaDex (EN)/Frieren/Chapter 1 [id-399].cbz", second)
        assert.are.equal("/books/MangaDex (EN)/Frieren/Chapter 1 [order-3].cbz", no_id)
    end)
end)
