package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")
local Marker = require("spec/support/i18n_marker")

describe("suwayomi/chapters/menu", function()
    after_each(function()
        Marker.uninstall()
        package.loaded["suwayomi/chapters/menu"] = nil
        package.loaded["suwayomi/chapters/context"] = nil
        package.loaded["suwayomi/i18n"] = nil
        package.loaded["suwayomi/ui"] = nil
        package.preload["suwayomi/ui"] = nil
    end)

    it("exports chapter menu construction methods", function()
        helper.assertControllerModule("suwayomi/chapters/menu", {
            "buildChapterMenuItems",
            "buildChapterMenuOptions",
            "buildQuickChapterMenuItems",
            "showChapterActions",
        })
    end)

    it("labels one-shot downloads separately from download-ahead buffers", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local plugin = {}
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end

        local actions = plugin:getBulkDownloadActions()

        assert.are.equal("Download first unread", actions[1].text)
        assert.are.equal("Download next 5", actions[2].text)
        assert.are.equal("Download next 10", actions[3].text)
        assert.are.equal("Download next 50", actions[4].text)
        assert.are.equal("Download all unread (up to 50 new)", actions[5].text)
        assert.are.equal("Download all chapters (up to 50 new)", actions[6].text)
    end)

    it("builds chapter title actions through the shared title menu", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local captured_title_options
        local performed_action
        local performed_menu_context
        local plugin = { getMangaRefillRequest = function() end }
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end
        function plugin:getVisibleChapters(chapters)
            return chapters
        end
        function plugin:formatChapterListTitle()
            return "Frieren"
        end
        function plugin:buildChapterMenuItems()
            return { { name = "Chapter 1" } }
        end
        function plugin:isChapterDownloaded()
            return true
        end
        function plugin:getSelectedChapterCount()
            return 0
        end
        function plugin:getChapterScanlatorChoices()
            return {}
        end
        function plugin:getFirstUnreadChapterForManga()
            return { id = "c1", name = "Chapter 1", is_read = false }
        end
        function plugin:getBulkChapterActions()
            return ChapterMenu.methods.getBulkChapterActions(plugin)
        end
        function plugin:performBulkChapterAction(action_id, menu_context)
            performed_action = action_id
            performed_menu_context = menu_context
        end
        function plugin:getTitleBarMenuOptions(options)
            captured_title_options = options
            return {
                title_bar_left_icon = "appbar.menu",
                on_title_bar_left_tap = function()
                    return true
                end,
            }
        end

        local manga = { id = "m1", title = "Frieren", in_library = true }
        plugin.current_chapter_context = {
            manga = manga,
            chapters = { { id = "c1", name = "Chapter 1", is_read = false } },
        }

        local options = plugin:buildChapterMenuOptions(manga, { { name = "Chapter 1" } }, {})

        assert.are.equal("Chapters", options.title)
        assert.are.equal("appbar.menu", options.title_bar_left_icon)
        assert.are.equal("Frieren", captured_title_options.title)
        assert.are.equal("select_all", captured_title_options.actions[1].id)
        assert.are.equal("manga_information", captured_title_options.actions[2].id)
        assert.are.equal("open_first_unread", captured_title_options.actions[3].id)
        assert.are.equal("refresh_chapters", captured_title_options.actions[4].id)
        assert.are.equal("bulk_downloads", captured_title_options.actions[5].id)
        assert.are.equal("keep_downloaded", captured_title_options.actions[6].id)
        assert.are.equal("delete_read_downloaded", captured_title_options.actions[7].id)
        assert.are.equal("remove_from_library", captured_title_options.actions[8].id)
        assert.is_true(captured_title_options.vertical)
        assert.is_true(captured_title_options.destructive_actions_at_bottom)

        local anchor = function()
            return { x = 3, y = 4, w = 32, h = 32 }
        end
        captured_title_options.onSelect({ id = "manga_information" }, nil, { anchor = anchor })
        assert.are.equal("manga_information", performed_action)
        assert.are.equal(anchor, performed_menu_context and performed_menu_context.anchor)

        captured_title_options.onSelect({ id = "bulk_downloads" }, nil, { anchor = anchor })
        assert.are.equal("bulk_downloads", performed_action)
        assert.are.equal(anchor, performed_menu_context and performed_menu_context.anchor)
    end)

    it("anchors burger-descended chapter submenus to the title action origin", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        package.loaded["suwayomi/ui"] = nil
        local shown_menus = {}
        package.preload["suwayomi/ui"] = function()
            return {
                showChapterActionsMenu = function(options)
                    table.insert(shown_menus, options)
                    return options
                end,
            }
        end
        local ChapterMenu = require("suwayomi/chapters/menu")
        local anchor = function()
            return { x = 3, y = 4, w = 32, h = 32 }
        end
        local plugin = {
            getMangaRefillRequest = function() end,
            current_chapter_context = {
                chapters = {
                    { id = "c1", name = "Chapter 1" },
                },
            },
            getSelectedChapterCount = function()
                return 0
            end,
            getVisibleChapters = function(_, chapters)
                return chapters
            end,
            getChapterScanlatorChoices = function()
                return { "Official" }
            end,
            getScanlatorFilterActions = function()
                return { { id = "scanlator_filter_all", text = "All" } }
            end,
            getBulkDownloadActions = function()
                return { { id = "download_next_5_unread", text = "Download next 5" } }
            end,
        }
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end

        plugin:showScanlatorFilterActions({ anchor = anchor })
        plugin:showBulkDownloadActions({ anchor = anchor })

        assert.are.equal(anchor, shown_menus[1].anchor)
        assert.are.equal(anchor, shown_menus[2].anchor)
        assert.is_function(shown_menus[1].on_back)
        assert.is_function(shown_menus[2].on_back)

        shown_menus[2].on_back()

        assert.are.equal("Chapter downloads", shown_menus[3].title)
        assert.are.equal(anchor, shown_menus[3].anchor)
        assert.are.equal("bulk_downloads", shown_menus[3].actions[4].id)

        package.preload["suwayomi/ui"] = nil
        package.loaded["suwayomi/ui"] = nil
    end)

    it("builds quick-refresh title actions through the shared title menu", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local captured_title_options
        local plugin = {}
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end
        function plugin:getVisibleChapters(chapters)
            return chapters
        end
        function plugin:formatChapterListTitle()
            return "Frieren"
        end
        function plugin:buildQuickChapterMenuItems()
            return { { name = "Chapter 1" } }
        end
        function plugin:getBulkChapterActions()
            return { { id = "select_all", text = "Select all" } }
        end
        function plugin:performBulkChapterAction()
            return true
        end
        function plugin:getTitleBarMenuOptions(options)
            captured_title_options = options
            return { title_bar_left_icon = "appbar.menu" }
        end

        local options = plugin:buildQuickChapterMenuOptions({ title = "Frieren" }, { { name = "Chapter 1" } })

        assert.are.equal("appbar.menu", options.title_bar_left_icon)
        assert.are.equal("Chapters", options.title)
        assert.are.equal("Frieren", captured_title_options.title)
        assert.are.equal("select_all", captured_title_options.actions[1].id)
    end)

    it("marks destructive chapter actions so action menus can separate them", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local plugin = {
            getMangaRefillRequest = function() end,
            current_chapter_context = {
                chapters = {
                    { id = "c1", name = "Chapter 1", is_read = true },
                },
            },
        }
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end
        function plugin:isChapterDownloaded()
            return true
        end
        function plugin:getSelectedChapterCount()
            return 1
        end
        function plugin:getChapterScanlatorChoices()
            return { "Official" }
        end

        local chapter_actions = plugin:getChapterActions({ id = "m1" }, {
            id = "c1",
            name = "Chapter 1",
            is_read = true,
        })
        assert.are.equal("Delete from device", chapter_actions[#chapter_actions].text)
        assert.is_true(chapter_actions[#chapter_actions].destructive)

        local bulk_actions = plugin:getBulkChapterActions()
        assert.are.equal("Delete downloads", bulk_actions[#bulk_actions].text)
        assert.is_true(bulk_actions[#bulk_actions].destructive)
    end)

    it("offers mark previous read without the ambiguous mark-through action", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local plugin = {}
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end
        function plugin:isChapterDownloaded()
            return false
        end

        local actions = plugin:getChapterActions({ id = "m1" }, {
            id = "c1",
            name = "Chapter 1",
            is_read = false,
        })
        local action_ids = {}
        for _, action in ipairs(actions) do
            action_ids[action.id] = true
        end

        assert.is_true(action_ids.mark_previous_read)
        assert.is_nil(action_ids.mark_through_read)
    end)

    it("keeps damaged and unverified local archives visible with distinct recovery actions", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local status = { state = "failed", archive_state = "damaged" }
        local plugin = {
            isChapterDownloaded = function() return true end,
            getChapterDownloadStatus = function() return status end,
        }
        local function actionSet()
            local result = {}
            for _, action in ipairs(ChapterMenu.methods.getChapterActions(plugin, {}, { is_read = true })) do
                result[action.id] = true
            end
            return result
        end
        local damaged = actionSet()
        assert.is_true(damaged.redownload)
        assert.is_true(damaged.verify_download)
        assert.is_true(damaged.delete)
        assert.is_true(damaged.mark_unread)
        assert.is_nil(damaged.open)
        assert.is_nil(damaged.retry_download)
        status.archive_state = "unverified"
        local unverified = actionSet()
        assert.is_true(unverified.verify_download)
        assert.is_nil(unverified.redownload)
        assert.is_nil(unverified.open)
        assert.is_nil(unverified.retry_download)
    end)

    it("offers cancel download for queued and active chapter rows", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local plugin = {}
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end
        function plugin:isChapterDownloaded()
            return false
        end
        function plugin:getChapterDownloadStatus(_, chapter)
            return { state = chapter.id == "active" and "downloading" or "queued" }
        end

        local queued_actions = plugin:getChapterActions({ id = "m1" }, {
            id = "queued",
            name = "Queued chapter",
        })
        local active_actions = plugin:getChapterActions({ id = "m1" }, {
            id = "active",
            name = "Active chapter",
        })

        assert.are.equal("cancel_download", queued_actions[1].id)
        assert.are.equal("Cancel download", queued_actions[1].text)
        assert.is_true(queued_actions[1].destructive)
        assert.are.equal("cancel_download", active_actions[1].id)
        assert.are.equal("Cancel download", active_actions[1].text)
        assert.is_true(active_actions[1].destructive)
    end)

    it("offers translated download errors for failures and waiting retries while preserving chapter actions", function()
        helper.stubControllerDependencies()
        Marker.install()
        package.loaded["suwayomi/chapters/menu"] = nil
        package.loaded["suwayomi/i18n"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local plugin = {
            isChapterDownloaded = function()
                return false
            end,
            getChapterDownloadStatus = function(_, _, chapter)
                return chapter.download_status
            end,
        }
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end

        for _, case in ipairs({
            { status = { state = "failed", error = "Page request failed" }, primary = "retry_download", has_error = true },
            { status = { state = "failed" }, primary = "retry_download", has_error = true },
            { status = { state = "queued", retry_at = 123, error = "Connection failed" }, primary = "cancel_download", has_error = true },
            { status = { state = "queued", retry_at = 123 }, primary = "cancel_download", has_error = true },
            { status = { state = "queued" }, primary = "cancel_download", has_error = false },
            { status = { state = "downloading", error = "Old failure" }, primary = "cancel_download", has_error = false },
            { primary = "download", has_error = false },
        }) do
            local actions = plugin:getChapterActions({ id = "m1" }, {
                id = "c1",
                name = "Chapter 1",
                download_status = case.status,
            })
            local actions_by_id = {}
            for _, action in ipairs(actions) do
                actions_by_id[action.id] = action
            end

            assert.is_table(actions_by_id[case.primary])
            if case.primary == "retry_download" then
                assert.are.equal("tx:Retry", actions_by_id.retry_download.text)
                assert.is_nil(actions_by_id.download)
            end
            assert.is_table(actions_by_id.mark_read)
            assert.is_table(actions_by_id.mark_previous_read)
            if case.has_error then
                assert.is_table(actions_by_id.download_error)
                assert.are.equal("tx:Download error", actions_by_id.download_error.text)
                assert.is_nil(actions_by_id.download_error.destructive)
            else
                assert.is_nil(actions_by_id.download_error)
            end
        end
    end)

    it("marks bulk chapter actions that open submenus", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local plugin = {
            getMangaRefillRequest = function() end,
            current_chapter_context = {
                chapters = {
                    { id = "c1", name = "Chapter 1" },
                },
            },
        }
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end
        function plugin:getSelectedChapterCount()
            return 0
        end
        function plugin:getVisibleChapters(chapters)
            return chapters
        end
        function plugin:getChapterScanlatorChoices()
            return { "Official" }
        end

        local bulk_actions = plugin:getBulkChapterActions()

        assert.are.equal("select_all", bulk_actions[1].id)
        assert.is_nil(bulk_actions[1].submenu)
        assert.are.equal("bulk_downloads", bulk_actions[4].id)
        assert.is_true(bulk_actions[4].submenu)
        assert.are.equal("keep_downloaded", bulk_actions[5].id)
        assert.is_true(bulk_actions[5].submenu)
        assert.are.equal("scanlator_filter", bulk_actions[7].id)
        assert.is_true(bulk_actions[7].submenu)
    end)

    it("offers cancel all downloads from the chapter title menu", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local plugin = {
            getMangaRefillRequest = function() end,
            current_chapter_context = {
                chapters = {
                    { id = "c1", name = "Chapter 1" },
                },
            },
        }
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end
        function plugin:getSelectedChapterCount()
            return 0
        end
        function plugin:getVisibleChapters(chapters)
            return chapters
        end
        function plugin:getChapterScanlatorChoices()
            return {}
        end
        function plugin:getDownloadQueue()
            return {
                getSnapshot = function()
                    return {
                        active = { { key = "active" } },
                        queued = { { key = "queued" } },
                        failed = {},
                    }
                end,
            }
        end

        local actions = plugin:getBulkChapterActions()

        assert.are.equal("cancel_all_downloads", actions[#actions].id)
        assert.are.equal("Cancel all downloads", actions[#actions].text)
        assert.is_true(actions[#actions].destructive)
    end)

    it("routes chapter action labels through i18n while keeping chapter titles raw", function()
        helper.stubControllerDependencies()
        Marker.install()
        package.loaded["suwayomi/chapters/menu"] = nil
        package.loaded["suwayomi/i18n"] = nil
        local shown_options
        package.preload["suwayomi/ui"] = function()
            return {
                showChapterActionsMenu = function(options)
                    shown_options = options
                    return options
                end,
            }
        end
        package.loaded["suwayomi/ui"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local plugin = {}
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end
        function plugin:isChapterDownloaded()
            return false
        end
        function plugin:performChapterAction()
            return true
        end

        local manga = { id = "m1", title = "Frieren" }
        local chapter = { id = "c1", name = "Chapter 1", is_read = false }

        local actions = plugin:getChapterActions(manga, chapter)

        assert.are.equal("ctx:chapter action:Download", actions[1].text)
        assert.are.equal("tx:Mark as read", actions[2].text)
        assert.are.equal("tx:Mark previous as read", actions[3].text)

        plugin:showChapterActions(manga, chapter)

        assert.are.equal("Chapter 1", shown_options.title)
    end)

    it("translates chapter bulk menu chrome and scanlator menu labels", function()
        helper.stubControllerDependencies()
        Marker.install()
        package.loaded["suwayomi/chapters/menu"] = nil
        package.loaded["suwayomi/chapters/context"] = nil
        package.loaded["suwayomi/i18n"] = nil
        local shown_menus = {}
        package.preload["suwayomi/ui"] = function()
            return {
                showChapterActionsMenu = function(options)
                    table.insert(shown_menus, options)
                    return options
                end,
            }
        end
        package.loaded["suwayomi/ui"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local plugin = {
            getMangaRefillRequest = function() end,
            current_chapter_context = {
                manga = { id = "m1", title = "Frieren" },
                chapters = {
                    { id = "c1", name = "Chapter 1", scanlator = "Alpha" },
                    { id = "c2", name = "Chapter 2", scanlator = "Beta" },
                },
            },
        }
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end
        function plugin:getSelectedChapterCount()
            return 2
        end
        function plugin:getVisibleChapters(chapters)
            return chapters
        end
        function plugin:getChapterScanlatorChoices()
            return { "Alpha", "Beta" }
        end
        function plugin:getScanlatorFilterActions()
            return {
                { id = "scanlator_filter_all", text = "tx:All scanlators" },
                { id = "scanlator_filter_value", text = "Alpha", scanlator = "Alpha" },
                { id = "scanlator_filter_value", text = "Beta", scanlator = "Beta" },
            }
        end
        function plugin:pluralize(count, singular, plural)
            if count == 1 then
                return singular
            end
            return plural
        end
        function plugin:setScanlatorFilter()
            return true
        end

        plugin:showBulkChapterActions()
        plugin:showScanlatorFilterActions()

        assert.are.equal("tx:2 selected chapters", shown_menus[1].title)
        assert.are.equal("tx:Download selected", shown_menus[1].actions[1].text)
        assert.are.equal("tx:Scanlator filter", shown_menus[1].actions[5].text)
        assert.are.equal("tx:Scanlator filter", shown_menus[2].title)
        assert.are.equal("tx:All scanlators", shown_menus[2].actions[1].text)
        assert.are.equal("Alpha", shown_menus[2].actions[2].text)
    end)

end)
