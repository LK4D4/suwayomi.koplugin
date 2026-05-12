describe("suwayomi/ui/list_rows", function()
    before_each(function()
        package.loaded["suwayomi/ui/list_rows"] = nil
        package.preload["gettext"] = function()
            return function(text) return text end
        end
    end)

    after_each(function()
        package.preload["gettext"] = nil
        package.loaded["suwayomi/ui/list_rows"] = nil
    end)

    it("uses manga title, id, then an empty title fallback", function()
        local rows = require("suwayomi/ui/list_rows")

        assert.are.equal("Frieren", rows.getMangaTitle({ title = "Frieren", id = "m1" }))
        assert.are.equal("m2", rows.getMangaTitle({ id = "m2" }))
        assert.are.equal("", rows.getMangaTitle(nil))
    end)

    it("shows manga in-library state only when requested and true", function()
        local rows = require("suwayomi/ui/list_rows")

        assert.are.equal("In Library", rows.getMangaMandatory({ in_library = true }, {
            show_in_library = true,
        }))
        assert.is_nil(rows.getMangaMandatory({ in_library = false }, {
            show_in_library = true,
        }))
        assert.is_nil(rows.getMangaMandatory({ in_library = true }, {
            show_in_library = false,
        }))
    end)

    it("shows manga chapter count in the status column", function()
        local rows = require("suwayomi/ui/list_rows")

        assert.are.equal("12 chapters", rows.getMangaMandatory({ chapter_count = 12 }))
        assert.are.equal("1 chapter", rows.getMangaMandatory({ chapter_count = 1 }))
        assert.is_nil(rows.getMangaMandatory({ chapter_count = 0 }))
        assert.are.equal("Checking chapters", rows.getMangaMandatory({ chapter_count_loading = true }))
        assert.are.equal("0 chapters", rows.getMangaMandatory({
            chapter_count = 0,
            chapter_count_verified = true,
        }))
        assert.are.equal("In Library · 12 chapters", rows.getMangaMandatory({
            in_library = true,
            chapter_count = 12,
        }, {
            show_in_library = true,
        }))
    end)

    it("uses source names as manga secondary row text", function()
        local rows = require("suwayomi/ui/list_rows")

        assert.are.equal("MangaDex", rows.getMangaSubtitle({
            source = { displayName = "MangaDex", name = "mangadex" },
        }))
        assert.are.equal("Local Source", rows.getMangaSubtitle({
            source = { name = "Local Source" },
        }))
        assert.is_nil(rows.getMangaSubtitle({}))
    end)

    it("builds manga rows without mutating manga tables", function()
        local rows = require("suwayomi/ui/list_rows")
        local manga = {
            id = "m1",
            title = "Frieren",
            in_library = true,
            thumbnail_url = "/covers/frieren.jpg",
            source = { displayName = "MangaDex" },
        }
        local selected

        local row = rows.buildMangaRow(manga, {
            show_in_library = true,
            on_select = function(value)
                selected = value
            end,
        })

        assert.are.equal("Frieren", row.text)
        assert.are.equal("MangaDex", row.subtitle)
        assert.are.equal("In Library", row.mandatory)
        assert.are.equal("/covers/frieren.jpg", row.thumbnail_url)
        assert.is_true(row.thumbnail_placeholder)
        assert.are.same(manga, row.manga)
        assert.is_nil(manga.menu_text)

        row.callback()
        assert.are.same(manga, selected)
    end)

    it("builds manga menu tables in source order", function()
        local rows = require("suwayomi/ui/list_rows")
        local selected = {}
        local manga = {
            { id = "m1", title = "Added", in_library = true },
            { id = "m2", title = "New", in_library = false },
        }

        local menu_table = rows.buildMangaMenuTable(manga, {
            show_in_library = true,
            on_select = function(value)
                table.insert(selected, value.id)
            end,
        })

        assert.are.equal("Added", menu_table[1].text)
        assert.are.equal("In Library", menu_table[1].mandatory)
        assert.are.equal("New", menu_table[2].text)
        assert.is_nil(menu_table[2].mandatory)

        menu_table[1].callback()
        menu_table[2].callback()
        assert.are.same({ "m1", "m2" }, selected)
    end)

    it("builds source rows with icon, language subtitle, and adult marker", function()
        local rows = require("suwayomi/ui/list_rows")
        local source = {
            id = "s1",
            name = "MangaDex",
            lang = "en",
            icon_url = "/icons/mangadex.png",
            is_nsfw = true,
        }
        local selected

        local row = rows.buildSourceRow(source, {
            show_language = true,
            on_select = function(value)
                selected = value
            end,
        })

        assert.are.equal("MangaDex", row.text)
        assert.are.equal("EN", row.subtitle)
        assert.are.equal("18+", row.mandatory)
        assert.are.equal("/icons/mangadex.png", row.thumbnail_url)
        assert.is_true(row.thumbnail_placeholder)
        assert.are.same(source, row.source)

        row.callback()
        assert.are.same(source, selected)
    end)

    it("hides local source language and absent adult markers", function()
        local rows = require("suwayomi/ui/list_rows")

        local row = rows.buildSourceRow({
            id = "local",
            name = "Local Source",
            lang = "localsourcelang",
            is_nsfw = false,
        }, {
            show_language = true,
        })

        assert.are.equal("Local Source", row.text)
        assert.is_nil(row.subtitle)
        assert.is_nil(row.mandatory)
        assert.is_true(row.thumbnail_placeholder)
    end)

    it("builds global search summary rows with source columns and result status", function()
        local rows = require("suwayomi/ui/list_rows")
        local selected = {}
        local summaries = {
            {
                source = { id = "s1", name = "MangaDex", icon_url = "/icons/md.png" },
                status = "ok",
                result_count = 1,
            },
            {
                source = { id = "s2", name = "Slow Source" },
                status = "error",
                error = "Timed out",
            },
            {
                source = { id = "s3", name = "More Source" },
                status = "pageable_empty",
                result_count = 2,
                has_next_page = true,
            },
        }

        local menu_table = rows.buildGlobalSearchSummaryMenuTable(summaries, {
            on_select = function(summary)
                table.insert(selected, summary.source.id)
            end,
        })

        assert.are.equal("MangaDex", menu_table[1].text)
        assert.are.equal("1 result", menu_table[1].mandatory)
        assert.are.equal("/icons/md.png", menu_table[1].thumbnail_url)
        assert.is_true(menu_table[1].thumbnail_placeholder)
        assert.are.equal("Slow Source", menu_table[2].text)
        assert.are.equal("Error", menu_table[2].mandatory)
        assert.are.equal("Timed out", menu_table[2].subtitle)
        assert.are.equal("More Source", menu_table[3].text)
        assert.are.equal("2+ results", menu_table[3].mandatory)

        menu_table[1].callback()
        menu_table[2].callback()
        menu_table[3].callback()
        assert.are.same({ "s1", "s3" }, selected)
    end)

    it("builds library category rows with manga counts in the status column", function()
        local rows = require("suwayomi/ui/list_rows")
        local selected
        local row = rows.buildLibraryCategoryRow({
            id = 7,
            name = "Favorites",
            manga_count = 2,
        }, {
            on_select = function(category)
                selected = category
            end,
        })

        assert.are.equal("Favorites", row.text)
        assert.are.equal("2 manga", row.mandatory)
        row.callback()
        assert.are.same({ id = 7, name = "Favorites", manga_count = 2 }, selected)
    end)

    it("builds chapter rows with shared text columns and no thumbnail slot", function()
        local rows = require("suwayomi/ui/list_rows")
        local chapter = {
            id = "c1",
            name = "Chapter 1",
            menu_text = "Chapter 1",
            menu_status = "Read · Downloaded",
            scanlator = "Official",
        }
        local selected

        local row = rows.buildChapterRow(chapter, {
            on_select = function(value)
                selected = value
            end,
        })

        assert.are.equal("Chapter 1", row.text)
        assert.are.equal("Official", row.subtitle)
        assert.are.equal("Read · Downloaded", row.mandatory)
        assert.is_nil(row.thumbnail_url)
        assert.is_nil(row.thumbnail_placeholder)
        assert.are.same(chapter, row.chapter)

        row.callback()
        assert.are.same(chapter, selected)
    end)

    it("builds chapter menu tables in source order", function()
        local rows = require("suwayomi/ui/list_rows")
        local selected = {}
        local chapters = {
            { id = "c1", name = "Chapter 1", scanlator = "Official" },
            { id = "c2", name = "Chapter 2" },
        }

        local menu_table = rows.buildChapterMenuTable(chapters, {
            on_select = function(value)
                table.insert(selected, value.id)
            end,
        })

        assert.are.equal("Chapter 1", menu_table[1].text)
        assert.are.equal("Official", menu_table[1].subtitle)
        assert.are.equal("Chapter 2", menu_table[2].text)
        assert.is_nil(menu_table[2].subtitle)

        menu_table[1].callback()
        menu_table[2].callback()
        assert.are.same({ "c1", "c2" }, selected)
    end)
end)
