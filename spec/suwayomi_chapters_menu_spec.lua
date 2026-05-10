package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/chapters/menu", function()
    it("exports chapter menu construction methods", function()
        helper.assertControllerModule("suwayomi/chapters/menu", {
            "buildChapterMenuItems",
            "buildChapterMenuOptions",
            "buildQuickChapterMenuItems",
            "showChapterActions",
        })
    end)

    it("builds chapter title actions through the shared title menu", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local captured_title_options
        local performed_action
        local performed_menu_context
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
        function plugin:buildChapterMenuItems()
            return { { name = "Chapter 1" } }
        end
        function plugin:getBulkChapterActions()
            return { { id = "bulk_downloads", text = "Bulk downloads" } }
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

        local options = plugin:buildChapterMenuOptions({ title = "Frieren" }, { { name = "Chapter 1" } }, {})

        assert.are.equal("Frieren", options.title)
        assert.are.equal("appbar.menu", options.title_bar_left_icon)
        assert.are.equal("Chapter downloads", captured_title_options.title)
        assert.are.equal("bulk_downloads", captured_title_options.actions[1].id)
        assert.is_true(captured_title_options.vertical)
        assert.is_true(captured_title_options.destructive_actions_at_bottom)

        local anchor = function()
            return { x = 3, y = 4, w = 32, h = 32 }
        end
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
            current_chapter_context = { chapters = {} },
            getScanlatorFilterActions = function()
                return { { id = "scanlator_filter_all", text = "All" } }
            end,
            getBulkDownloadActions = function()
                return { { id = "download_next_5_unread", text = "Download 5 unread" } }
            end,
        }
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end

        plugin:showScanlatorFilterActions({ anchor = anchor })
        plugin:showBulkDownloadActions({ anchor = anchor })

        assert.are.equal(anchor, shown_menus[1].anchor)
        assert.are.equal(anchor, shown_menus[2].anchor)

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
        assert.are.equal("Chapter downloads", captured_title_options.title)
        assert.are.equal("select_all", captured_title_options.actions[1].id)
    end)

    it("marks destructive chapter actions so action menus can separate them", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local plugin = {
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

    it("quick refresh reflects updated read state instead of stale cached row status", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local plugin = {
            current_chapter_context = {
                manga = { id = "m1", title = "Manga" },
                chapters = {},
            },
            current_chapter_options = {
                chapters = {
                    { id = "c1", name = "Chapter 1", menu_text = "Chapter 1" },
                },
            },
            getChapterDownloadKey = function(_, manga, chapter)
                return tostring(manga.id) .. ":" .. tostring(chapter.id)
            end,
            getChapterDownloadStatus = function()
                return nil
            end,
            stripChapterSelectionStatus = function(_, menu_status)
                return menu_status
            end,
            isChapterSelected = function()
                return false
            end,
            getDownloadQueue = function()
                return {
                    formatChapterMenuStatus = function(_, chapter, status)
                        if chapter.is_read == true or status.state == "read" then
                            return "Read"
                        end
                        return status.state
                    end,
                }
            end,
        }
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end

        local items = plugin:buildQuickChapterMenuItems(
            plugin.current_chapter_context.manga,
            { { id = "c1", name = "Chapter 1", is_read = true } }
        )

        assert.are.equal("Read", items[1].menu_status)
    end)

    it("quick refresh preserves cached downloaded state while applying current read state", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local plugin = {
            current_chapter_context = {
                manga = { id = "m1", title = "Manga" },
                chapters = {},
            },
            current_chapter_options = {
                chapters = {
                    {
                        id = "c1",
                        name = "Chapter 1",
                        menu_text = "Chapter 1",
                        menu_status = "Read · Downloaded",
                        _suwayomi_download_status = { state = "downloaded" },
                    },
                },
            },
            getChapterDownloadKey = function(_, manga, chapter)
                return tostring(manga.id) .. ":" .. tostring(chapter.id)
            end,
            getChapterDownloadStatus = function()
                return nil
            end,
            stripChapterSelectionStatus = function(_, menu_status)
                return menu_status
            end,
            isChapterSelected = function()
                return false
            end,
            getDownloadQueue = function()
                return {
                    formatChapterMenuStatus = function(_, chapter, status)
                        if status and status.state == "downloaded" then
                            return chapter.is_read == true and "Read · Downloaded" or "Downloaded"
                        end
                        if chapter.is_read == true or (status and status.state == "read") then
                            return "Read"
                        end
                        return status and status.state or nil
                    end,
                }
            end,
        }
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end

        local unread_items = plugin:buildQuickChapterMenuItems(
            plugin.current_chapter_context.manga,
            { { id = "c1", name = "Chapter 1", is_read = false } }
        )
        local read_items = plugin:buildQuickChapterMenuItems(
            plugin.current_chapter_context.manga,
            { { id = "c1", name = "Chapter 1", is_read = true } }
        )

        assert.are.equal("Downloaded", unread_items[1].menu_status)
        assert.are.equal("Read · Downloaded", read_items[1].menu_status)
    end)

    it("builds chapter rows without deleting unrelated read downloads", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        package.loaded["suwayomi/settings"] = nil
        package.loaded["suwayomi/downloads/downloader"] = nil
        local previous_settings_preload = package.preload["suwayomi/settings"]
        local previous_downloader_preload = package.preload["suwayomi/downloads/downloader"]
        package.preload["suwayomi/settings"] = function()
            return {
                loadDownloadDirectory = function()
                    return "/downloads"
                end,
            }
        end
        package.preload["suwayomi/downloads/downloader"] = function()
            return {
                getTargetPath = function(_, download_directory, _, chapter)
                    return nil, download_directory .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return true
                end,
            }
        end

        local ChapterMenu = require("suwayomi/chapters/menu")
        local delete_count = 0
        local plugin = {
            loadKoreaderHistoryPaths = function()
                return {}
            end,
            isChapterPathFinishedInKoreader = function()
                return false
            end,
            setKoreaderChapterReadState = function() end,
            upsertChapterLedgerEntry = function() end,
            autoDeleteReadLocalDownload = function()
                delete_count = delete_count + 1
                return false
            end,
            getChapterDownloadStatus = function()
                return nil
            end,
            isChapterSelected = function()
                return false
            end,
            getDownloadQueue = function()
                return {
                    formatChapterMenuStatus = function(_, chapter, status)
                        if status and status.state == "downloaded" then
                            return chapter.is_read == true and "Read · Downloaded" or "Downloaded"
                        end
                        if chapter.is_read == true or (status and status.state == "read") then
                            return "Read"
                        end
                        return status and status.state or nil
                    end,
                }
            end,
        }
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end

        local items = plugin:buildChapterMenuItems({ id = "m1" }, {
            { id = "c1", name = "Chapter 1", is_read = true },
            { id = "c2", name = "Chapter 2", is_read = true },
        })
        package.preload["suwayomi/settings"] = previous_settings_preload
        package.preload["suwayomi/downloads/downloader"] = previous_downloader_preload
        package.loaded["suwayomi/settings"] = nil
        package.loaded["suwayomi/downloads/downloader"] = nil

        assert.are.equal(0, delete_count)
        assert.are.equal("Read · Downloaded", items[1].menu_status)
        assert.are.equal("Read · Downloaded", items[2].menu_status)
    end)
end)
