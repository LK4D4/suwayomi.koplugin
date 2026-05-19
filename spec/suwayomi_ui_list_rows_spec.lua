describe("suwayomi/ui/list_rows", function()
    before_each(function()
        package.loaded["suwayomi/ui/list_rows"] = nil
        package.loaded["suwayomi/source_languages"] = nil
        package.preload["gettext"] = function()
            return function(text) return text end
        end
    end)

    after_each(function()
        package.preload["gettext"] = nil
        package.loaded["suwayomi/ui/list_rows"] = nil
        package.loaded["suwayomi/source_languages"] = nil
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
        assert.are.equal("English", row.subtitle)
        assert.are.equal("18+", row.mandatory)
        assert.are.equal("/icons/mangadex.png", row.thumbnail_url)
        assert.is_true(row.thumbnail_placeholder)
        assert.are.same(source, row.source)

        row.callback()
        assert.are.same(source, selected)
    end)

    it("uses language names for source row subtitles", function()
        local rows = require("suwayomi/ui/list_rows")

        assert.are.equal("Español", rows.getSourceSubtitle({
            lang = "es",
        }, {
            show_language = true,
        }))
        assert.are.equal("日本語", rows.getSourceSubtitle({
            lang = "ja",
        }, {
            show_language = true,
        }))
        assert.are.equal("All", rows.getSourceSubtitle({
            lang = "all",
        }, {
            show_language = true,
        }))
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
        assert.is_false(menu_table[2].select_enabled)
        assert.are.equal("More Source", menu_table[3].text)
        assert.are.equal("2+ results", menu_table[3].mandatory)

        menu_table[1].callback()
        menu_table[2].callback()
        menu_table[3].callback()
        assert.are.same({ "s1", "s3" }, selected)
    end)

    it("disables selection on non-openable global search summary rows", function()
        local rows = require("suwayomi/ui/list_rows")
        local summaries = {
            {
                source = { id = "s1", name = "Empty Source" },
                status = "empty",
            },
            {
                source = { id = "s2", name = "Searching Source" },
                status = "searching",
            },
            {
                source = { id = "s3", name = "Error Source" },
                status = "error",
                error = "Timed out",
            },
        }

        local menu_table = rows.buildGlobalSearchSummaryMenuTable(summaries, {
            on_select = function()
                error("non-openable summary rows must not navigate")
            end,
        })

        for _, row in ipairs(menu_table) do
            assert.is_false(row.select_enabled)
            row.callback()
        end
    end)

    it("wires retry callbacks for failed global search summary rows", function()
        local rows = require("suwayomi/ui/list_rows")
        local retried = {}
        local summaries = {
            {
                source = { id = "s1", name = "Error Source" },
                status = "error",
                error = "HTTP 403",
            },
            {
                source = { id = "s2", name = "Slow Source" },
                status = "timed_out",
            },
        }

        local menu_table = rows.buildGlobalSearchSummaryMenuTable(summaries, {
            on_retry = function(summary)
                table.insert(retried, summary.source.id)
            end,
        })

        assert.is_true(menu_table[1].select_enabled)
        assert.are.equal("Retry", menu_table[1].mandatory)
        assert.are.equal("HTTP 403", menu_table[1].subtitle)
        assert.is_true(menu_table[2].select_enabled)
        assert.are.equal("Retry", menu_table[2].mandatory)

        menu_table[1].callback()
        menu_table[2].callback()

        assert.are.same({ "s1", "s2" }, retried)
    end)

    it("groups extension rows with installed entries above available entries", function()
        local rows = require("suwayomi/ui/list_rows")
        local selected = {}
        local extensions = {
            {
                pkg_name = "pkg.available",
                name = "Available Source",
                is_installed = false,
            },
            {
                pkg_name = "pkg.installed",
                name = "Installed Source",
                is_installed = true,
            },
            {
                pkg_name = "pkg.update",
                name = "Update Source",
                is_installed = true,
                has_update = true,
            },
        }

        local menu_table = rows.buildExtensionMenuTable(extensions, {
            on_select = function(extension)
                table.insert(selected, extension.pkg_name)
            end,
        })

        assert.are.equal("Updates (1)", menu_table[1].text)
        assert.is_true(menu_table[1].is_section_header)
        assert.is_false(menu_table[1].select_enabled)
        assert.is_nil(menu_table[1].thumbnail_placeholder)

        assert.are.equal("Update Source", menu_table[2].text)
        assert.are.same(extensions[3], menu_table[2].extension)
        assert.is_true(menu_table[2].keep_menu_open)
        assert.are.equal("Installed (1)", menu_table[3].text)
        assert.is_true(menu_table[3].is_section_header)
        assert.are.equal("Installed Source", menu_table[4].text)
        assert.are.same(extensions[2], menu_table[4].extension)
        assert.is_true(menu_table[4].keep_menu_open)
        assert.are.equal("Available (1)", menu_table[5].text)
        assert.is_true(menu_table[5].is_section_header)
        assert.are.equal("Available Source", menu_table[6].text)
        assert.are.same(extensions[1], menu_table[6].extension)
        assert.is_true(menu_table[6].keep_menu_open)

        menu_table[2].callback()
        menu_table[4].callback()
        menu_table[6].callback()
        assert.are.same({ "pkg.update", "pkg.installed", "pkg.available" }, selected)
    end)

    it("keeps empty installed and available extension sections when requested", function()
        local rows = require("suwayomi/ui/list_rows")
        local menu_table = rows.buildExtensionMenuTable({
            {
                pkg_name = "pkg.installed",
                name = "Installed Source",
                is_installed = true,
            },
        }, {
            show_empty_sections = true,
        })

        assert.are.equal("Installed (1)", menu_table[1].text)
        assert.are.equal("Installed Source", menu_table[2].text)
        assert.are.equal("Available (0)", menu_table[3].text)
    end)

    it("keeps extension status on the first right-column line and markers on the second", function()
        local rows = require("suwayomi/ui/list_rows")

        assert.are.equal("Not installed\n18+ · v1.4.0", rows.getExtensionMandatory({
            is_installed = false,
            is_nsfw = true,
            version_name = "1.4.0",
        }))
        assert.are.equal("Update available\nv1.2.0", rows.getExtensionMandatory({
            is_installed = true,
            has_update = true,
            version_name = "1.2.0",
        }))
        assert.are.equal("Installed", rows.getExtensionMandatory({
            is_installed = true,
        }))
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
