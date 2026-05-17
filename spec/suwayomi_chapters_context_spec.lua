package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/chapters/context", function()
    local fake_settings

    before_each(function()
        fake_settings = {}
        package.loaded["suwayomi/chapters/context"] = nil
        package.loaded.gettext = nil
        package.loaded["ffi/util"] = nil
        package.loaded["suwayomi/settings"] = nil
        package.loaded["suwayomi/readsync/ledger"] = nil
        package.preload.gettext = function()
            return function(text) return text end
        end
        package.preload["ffi/util"] = function()
            return {
                template = function(template_string, ...)
                    local result = template_string
                    local values = {...}
                    for index, value in ipairs(values) do
                        result = result:gsub("%%" .. index, tostring(value))
                    end
                    return result
                end,
            }
        end
        package.preload["suwayomi/readsync/ledger"] = function()
            return { methods = { mergeChaptersWithReadLedger = function() end } }
        end
        package.preload["suwayomi/settings"] = function()
            return fake_settings
        end
    end)

    after_each(function()
        package.loaded["suwayomi/chapters/context"] = nil
        package.loaded.gettext = nil
        package.loaded["ffi/util"] = nil
        package.loaded["suwayomi/settings"] = nil
        package.loaded["suwayomi/readsync/ledger"] = nil
        package.preload.gettext = nil
        package.preload["ffi/util"] = nil
        package.preload["suwayomi/settings"] = nil
        package.preload["suwayomi/readsync/ledger"] = nil
    end)

    it("exports chapter context and selection methods", function()
        helper.assertControllerModule("suwayomi/chapters/context", {
            "getChapterSelectionKey",
            "getVisibleChapters",
            "mergeChaptersWithReadLedger",
            "toggleChapterSelection",
        })
    end)

    it("keeps chapter screen titles short while preserving detail titles", function()
        local controller = require("suwayomi/chapters/context")
        local manga = {
            id = "m1",
            title = "Very Long Manga Title That Would Truncate In Header",
            source = { displayName = "MangaDex" },
        }
        local plugin = {
            selected_chapters = {},
        }
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        assert.are.equal(
            "Chapters - Very Long Manga Title That Would Truncate In... - MangaDex",
            plugin:formatChapterListScreenTitle(manga)
        )
        assert.are.equal("Very Long Manga Title That Would Truncate In Header", plugin:formatChapterListTitle(manga))

        plugin.current_scanlator_filter = "Very Long Scanlator Name That Would Truncate In Header"
        assert.are.equal(
            "Chapters - Very Long Manga Title That Would Truncate In... - MangaDex",
            plugin:formatChapterListScreenTitle(manga)
        )
        assert.are.equal(
            "Very Long Manga Title That Would Truncate In Header - Very Long Scanlator Name That Would Truncate In Header",
            plugin:formatChapterListTitle(manga)
        )

        plugin.selection_mode = true
        plugin.selected_chapters = {
            ["m1:c1"] = true,
            ["m1:c2"] = true,
        }
        assert.are.equal("2 selected", plugin:formatChapterListScreenTitle(manga))
        assert.are.equal(
            "2 selected - Very Long Scanlator Name That Would Truncate In Header",
            plugin:formatChapterListTitle(manga)
        )
    end)

    it("builds previous ranges from visible scanlator-filtered chapters", function()
        local controller = require("suwayomi/chapters/context")
        local plugin = {
            current_scanlator_filter = "Team A",
            current_chapter_context = {
                chapters = {
                    { id = "1", name = "One", scanlator = "Team A" },
                    { id = "2", name = "Two", scanlator = "Team B" },
                    { id = "3", name = "Three", scanlator = "Team A" },
                },
            },
        }
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        assert.are.same({
            { id = "1", name = "One", scanlator = "Team A" },
        }, plugin:getChaptersBefore({ id = "3" }))
    end)

    it("scopes manga-level next unread downloads to the current scanlator filter", function()
        local controller = require("suwayomi/chapters/context")
        local manga = { id = "m1", title = "Manga" }
        local plugin = {
            current_scanlator_filter = "Team A",
            current_chapter_context = {
                manga = manga,
                chapters = {
                    { id = "1", name = "One", scanlator = "Team A", is_read = false },
                    { id = "2", name = "Two", scanlator = "Team B", is_read = false },
                    { id = "3", name = "Three", scanlator = "Team A", is_read = true },
                },
            },
            getDownloadQueue = function()
                return {
                    getStatus = function()
                        return nil
                    end,
                }
            end,
            isChapterDownloaded = function()
                return false
            end,
        }
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        assert.are.same({
            { id = "1", name = "One", scanlator = "Team A", is_read = false },
        }, plugin:getNextUnreadChaptersForDownload(manga, 2))
    end)

    it("scopes first unread lookup to the current scanlator filter", function()
        local controller = require("suwayomi/chapters/context")
        local manga = { id = "m1", title = "Manga" }
        local team_b = { id = "2", name = "Two", scanlator = "Team B", is_read = false }
        local plugin = {
            current_scanlator_filter = "Team B",
            current_chapter_context = {
                manga = manga,
                chapters = {
                    { id = "1", name = "One", scanlator = "Team A", is_read = false },
                    team_b,
                },
            },
        }
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        assert.are.same(team_b, plugin:getFirstUnreadChapterForManga(manga))
    end)

    it("prunes stale selected chapters when refreshing the same manga", function()
        local controller = require("suwayomi/chapters/context")
        local manga = { id = "m1", title = "Manga" }
        local visible = { id = "1", name = "One", scanlator = "Team A" }
        local hidden = { id = "2", name = "Two", scanlator = "Team B" }
        local plugin = {
            current_chapter_context = {
                manga = manga,
                chapters = {
                    visible,
                    hidden,
                    { id = "9", name = "Nine", scanlator = "Team A" },
                },
            },
            current_scanlator_filter = "Team A",
            selected_chapters = {
                ["m1:1"] = true,
                ["m1:2"] = true,
                ["m1:9"] = true,
            },
            selection_mode = true,
        }
        function fake_settings:loadMangaScanlatorFilter()
            return "Team A"
        end
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        plugin:setCurrentMangaChapterContext(manga, {
            visible,
            hidden,
        })

        assert.are.same({ ["m1:1"] = true }, plugin.selected_chapters)
        assert.are.equal(1, plugin:getSelectedChapterCount())
        assert.are.same({ visible }, plugin:getSelectedChapters(manga, plugin.current_chapter_context.chapters))
        assert.is_true(plugin.selection_mode)
        assert.are.equal("1 selected - Team A", plugin:formatChapterListTitle(manga))
    end)

    it("restores saved scanlator filter when setting chapter context", function()
        local controller = require("suwayomi/chapters/context")
        local manga = { id = "m1", title = "Manga" }
        local plugin = {
            selected_chapters = { ["old:1"] = true },
            current_chapter_context = {
                manga = { id = "old", title = "Old" },
                chapters = {},
            },
            clearChapterSelection = function(self)
                self.selected_chapters = {}
            end,
        }
        function fake_settings:loadMangaScanlatorFilter(target_manga)
            if target_manga == manga then
                return "Team B"
            end
        end
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        plugin:setCurrentMangaChapterContext(manga, {
            { id = "1", name = "One", scanlator = "Team A" },
            { id = "2", name = "Two", scanlator = "Team B" },
        })

        assert.are.equal("Team B", plugin.current_scanlator_filter)
        assert.are.same({
            { id = "2", name = "Two", scanlator = "Team B" },
        }, plugin:getVisibleChapters(plugin.current_chapter_context.chapters))
    end)

    it("drops a saved scanlator filter when refreshed chapters no longer contain it", function()
        local controller = require("suwayomi/chapters/context")
        local manga = { id = "m1", title = "Manga" }
        local plugin = {
            loadMangaScanlatorFilter = function()
                return "Missing Team"
            end,
        }
        function fake_settings:loadMangaScanlatorFilter()
            return "Missing Team"
        end
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        plugin:setCurrentMangaChapterContext(manga, {
            { id = "1", name = "One", scanlator = "Team A" },
            { id = "2", name = "Two", scanlator = "Team B" },
        })

        assert.is_nil(plugin.current_scanlator_filter)
    end)

    it("saves scanlator filter changes for the current manga", function()
        local controller = require("suwayomi/chapters/context")
        local manga = { id = "m1", title = "Manga" }
        local saved_filter
        local plugin = {
            current_chapter_context = {
                manga = manga,
                chapters = {},
            },
            clearChapterSelection = function() end,
            refreshChapterMenu = function() end,
        }
        function fake_settings:saveMangaScanlatorFilter(target_manga, scanlator)
            assert.are.same(manga, target_manga)
            saved_filter = scanlator
            return scanlator
        end
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        plugin:setScanlatorFilter("Team A")
        assert.are.equal("Team A", saved_filter)

        plugin:setScanlatorFilter(nil)
        assert.is_nil(saved_filter)
    end)
end)
