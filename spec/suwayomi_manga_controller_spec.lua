package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

local modules_to_clear = {
    "ffi/util",
    "gettext",
    "suwayomi/api",
    "suwayomi/settings",
    "suwayomi/ui",
    "suwayomi/debug",
    "suwayomi/manga/controller",
}

local function clearModules()
    for _, name in ipairs(modules_to_clear) do
        package.loaded[name] = nil
        package.preload[name] = nil
    end
end

local function installController(options)
    options = options or {}
    clearModules()
    local state = {
        messages = {},
        update_calls = {},
        refresh_calls = {},
        tracked_screens = {},
    }

    package.preload.gettext = function()
        return function(text)
            return text
        end
    end
    package.preload["ffi/util"] = function()
        return {
            template = function(template_string, ...)
                local result = template_string
                for index, value in ipairs({...}) do
                    result = result:gsub("%%" .. index, tostring(value))
                end
                return result
            end,
        }
    end
    package.preload["suwayomi/api"] = function()
        return {
            updateMangaLibraryState = function(_, manga_id, in_library)
                table.insert(state.update_calls, { manga_id = manga_id, in_library = in_library })
                return {
                    ok = options.library_update_ok ~= false,
                    error = "Library update failed.",
                    manga = { id = manga_id, in_library = in_library, title = "Updated " .. manga_id },
                }
            end,
            refreshManga = function(_, manga_id)
                table.insert(state.refresh_calls, manga_id)
                return options.refresh_result or {
                    ok = true,
                    manga = { id = manga_id, title = "Refreshed title" },
                    chapters = { { id = "c2", name = "Ch. 2", is_read = false } },
                }
            end,
            fetchChaptersForManga = function(_, manga_id)
                state.fetch_chapters_manga_id = manga_id
                return {
                    ok = true,
                    chapters = { { id = "c1", name = "Ch. 1", is_read = false } },
                }
            end,
        }
    end
    package.preload["suwayomi/settings"] = function()
        return {
            load = function()
                return { server_url = "https://suwayomi.example" }
            end,
        }
    end
    package.preload["suwayomi/ui"] = function()
        return {
            showMangaActionsMenu = function(menu_options, onSelect)
                state.manga_actions_options = menu_options
                state.manga_actions_callback = onSelect
                return { name = "manga-actions-menu" }
            end,
            showConfirm = function(confirm_options)
                state.confirm_options = confirm_options
            end,
            showChapterMenu = function(chapter_options)
                state.chapter_menu_options = chapter_options
                return { name = "chapter-menu", close_callback = chapter_options.close_callback }
            end,
        }
    end
    package.preload["suwayomi/debug"] = function()
        return {
            log = function() end,
            time = function(_, _, callback)
                return callback()
            end,
        }
    end

    local controller = require("suwayomi/manga/controller")
    local plugin = {
        messages = state.messages,
        opened_chapters = {},
        enqueued = {},
    }
    for name, method in pairs(controller.methods) do
        plugin[name] = method
    end
    function plugin:showMessage(message)
        table.insert(self.messages, message)
    end
    function plugin:withLoadingMessage(_, _, callback)
        return callback()
    end
    function plugin:getClient()
        return {
            attachSourceToManga = function(_, manga, source)
                manga.source = source
                return manga
            end,
        }
    end
    function plugin:isChapterDownloaded()
        return options.first_unread_downloaded == true
    end
    function plugin:getFirstUnreadChapterForManga()
        return options.first_unread_chapter
    end
    function plugin:openChapter(manga, chapter)
        table.insert(self.opened_chapters, { manga = manga, chapter = chapter })
        return true
    end
    function plugin:mergeChaptersWithReadLedger(_, chapters)
        return chapters
    end
    function plugin:setCurrentMangaChapterContext(manga, chapters)
        self.current_chapter_context = { manga = manga, chapters = chapters }
    end
    function plugin:buildChapterMenuOptions(manga, chapters)
        return { title = manga.title, chapters = chapters }
    end
    function plugin:handleChapterTap() end
    function plugin:toggleChapterSelection() end
    function plugin:ensureMangaChapterContext(manga)
        self.current_chapter_context = {
            manga = manga,
            chapters = options.context_chapters or {
                { id = "c1", name = "Ch. 1", is_read = true },
                { id = "c2", name = "Ch. 2", is_read = false },
            },
        }
        return true
    end
    function plugin:getDownloadDirectoryOrChoose(callback)
        if callback then
            return "/books"
        end
        return "/books"
    end
    function plugin:getNextUnreadChaptersForDownload(_, limit)
        local chapters = {}
        for _, chapter in ipairs(self.current_chapter_context.chapters) do
            if chapter.is_read ~= true then
                table.insert(chapters, chapter)
                if #chapters >= limit then
                    break
                end
            end
        end
        return chapters
    end
    function plugin:getUnreadDownloadBufferCandidates(_, limit)
        return self:getNextUnreadChaptersForDownload(nil, limit)
    end
    function plugin:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
        table.insert(self.enqueued, { manga = manga, chapters = chapters, download_directory = download_directory })
        return #chapters
    end
    function plugin:showBulkActionConfirmation(text, ok_text, callback)
        state.bulk_confirmation = { text = text, ok_text = ok_text, callback = callback }
        return true
    end
    function plugin:confirmDeleteReadChaptersFromDevice()
        state.confirm_delete_read = true
    end
    function plugin:pluralize(value, singular, plural)
        return value == 1 and singular or plural
    end
    function plugin:trackSuwayomiScreen(route_id, widget)
        table.insert(state.tracked_screens, { route_id = route_id, widget = widget })
    end
    return plugin, state
end

describe("suwayomi/manga/controller", function()
    after_each(clearModules)

    it("exports manga/library action methods", function()
        helper.assertControllerModule("suwayomi/manga/controller", {
            "showMangaActions",
            "setMangaLibraryState",
            "refreshMangaChapters",
            "performMangaAction",
        })
    end)

    it("builds manga action menus including first-unread and nested groups", function()
        local plugin, state = installController({
            first_unread_downloaded = true,
            first_unread_chapter = { id = "c2", name = "Ch. 2" },
        })
        local manga = {
            id = "m1",
            title = "Frieren",
            in_library = true,
            first_unread_chapter = { id = "c2", name = "Ch. 2" },
        }

        plugin:showMangaActions(manga)
        assert.are.equal("Open chapters", state.manga_actions_options.actions[1].text)
        assert.are.equal("Open first unread", state.manga_actions_options.actions[2].text)
        assert.are.equal("Refresh chapters", state.manga_actions_options.actions[3].text)
        assert.are.equal("Remove from library", state.manga_actions_options.actions[#state.manga_actions_options.actions].text)
        assert.is_true(state.manga_actions_options.actions[#state.manga_actions_options.actions].destructive)
        assert.are.equal("more", state.manga_actions_options.actions[#state.manga_actions_options.actions - 1].id)
        assert.is_true(state.manga_actions_options.actions[#state.manga_actions_options.actions - 1].submenu)
        assert.are.equal("manga-actions", state.tracked_screens[1].route_id)
        assert.are.equal("manga-actions-menu", state.tracked_screens[1].widget.name)

        state.manga_actions_callback({ id = "more" })
        assert.are.equal("More...", state.manga_actions_options.title)
        assert.are.equal("Download next 5 unread", state.manga_actions_options.actions[1].text)
        assert.are.equal("Keep downloaded", state.manga_actions_options.actions[5].text)
        assert.is_true(state.manga_actions_options.actions[5].submenu)
        assert.are.equal("Delete read downloads", state.manga_actions_options.actions[#state.manga_actions_options.actions].text)
        assert.is_true(state.manga_actions_options.actions[#state.manga_actions_options.actions].destructive)
        assert.is_function(state.manga_actions_options.on_back)

        state.manga_actions_options.on_back()
        assert.are.equal("Frieren", state.manga_actions_options.title)
        assert.are.equal("more", state.manga_actions_options.actions[#state.manga_actions_options.actions - 1].id)

        state.manga_actions_callback({ id = "more" })

        state.manga_actions_callback({ id = "keep_downloaded" })
        assert.are.equal("Keep downloaded", state.manga_actions_options.title)
        assert.are.equal("Keep next 50 unread", state.manga_actions_options.actions[3].text)
        assert.is_function(state.manga_actions_options.on_back)

        state.manga_actions_options.on_back()
        assert.are.equal("More...", state.manga_actions_options.title)
        assert.are.equal("Keep downloaded", state.manga_actions_options.actions[5].text)
    end)

    it("adds and removes library manga through API and confirmation wiring", function()
        local plugin, state = installController()
        local manga = { id = "m1", title = "Frieren", in_library = false }
        local updated_manga

        assert.is_true(plugin:performMangaAction(manga, "add_to_library", {
            onMangaUpdated = function(value)
                updated_manga = value
            end,
        }))
        assert.are.same({ { manga_id = "m1", in_library = true } }, state.update_calls)
        assert.is_true(manga.in_library)
        assert.is_nil(manga.menu_text)
        assert.are.equal(manga, updated_manga)
        assert.are.equal("Added to library.", state.messages[#state.messages])

        assert.is_true(plugin:performMangaAction(manga, "remove_from_library"))
        assert.are.equal("Remove Updated m1 from your Suwayomi library?", state.confirm_options.text)
        state.confirm_options.ok_callback()

        assert.are.same({
            { manga_id = "m1", in_library = true },
            { manga_id = "m1", in_library = false },
        }, state.update_calls)
        assert.is_false(manga.in_library)
        assert.is_nil(manga.menu_text)
        assert.are.equal("Removed from library.", state.messages[#state.messages])
    end)

    it("opens first unread and downloads the next unread chapter from manga actions", function()
        local plugin = installController({
            first_unread_chapter = { id = "c2", name = "Ch. 2" },
        })
        local manga = { id = "m1", title = "Frieren" }

        assert.is_true(plugin:performMangaAction(manga, "open_first_unread"))
        assert.are.equal("c2", plugin.opened_chapters[1].chapter.id)

        assert.is_true(plugin:performMangaAction(manga, "download_first_unread"))
        assert.are.equal("c2", plugin.enqueued[1].chapters[1].id)
        assert.are.equal("/books", plugin.enqueued[1].download_directory)
    end)

    it("refreshes manga and shows returned chapters", function()
        local plugin, state = installController()
        local manga = { id = "m1", title = "Frieren" }

        assert.is_true(plugin:performMangaAction(manga, "refresh_chapters"))

        assert.are.same({ "m1" }, state.refresh_calls)
        assert.are.equal("Refreshed title", manga.title)
        assert.are.equal("Refreshed title", state.chapter_menu_options.title)
        assert.are.equal("c2", plugin.current_chapter_context.chapters[1].id)
        assert.are.equal("chapters", state.tracked_screens[1].route_id)
        assert.are.equal("chapter-menu", state.tracked_screens[1].widget.name)

        state.chapter_menu_options.close_callback()

        assert.is_nil(plugin.current_chapter_menu)
    end)

    it("focuses the returned chapter when showing chapters from reader return", function()
        local plugin, state = installController()
        local manga = { id = "m1", title = "Frieren" }

        assert.is_true(plugin:showChapterResultForManga(manga, {
            ok = true,
            chapters = {
                { id = "c1", name = "Ch. 1" },
                { id = "c2", name = "Ch. 2" },
                { id = "c3", name = "Ch. 3" },
            },
        }, {
            return_context = {
                chapter_id = "c2",
                chapter_name = "Ch. 2",
            },
        }))

        assert.are.equal(2, state.chapter_menu_options.itemnumber)
    end)

    it("falls back to returned chapter name when the context has no chapter id", function()
        local plugin, state = installController()
        local manga = { id = "m1", title = "Frieren" }

        assert.is_true(plugin:showChapterResultForManga(manga, {
            ok = true,
            chapters = {
                { id = "c1", name = "Ch. 1" },
                { id = "c2", name = "Ch. 2" },
            },
        }, {
            return_context = {
                chapter_name = "Ch. 2",
            },
        }))

        assert.are.equal(2, state.chapter_menu_options.itemnumber)
    end)

    it("queues keep-next downloads without persisting a background policy", function()
        local plugin, state = installController({
            context_chapters = {
                { id = "c1", name = "Ch. 1", is_read = false },
                { id = "c2", name = "Ch. 2", is_read = false },
            },
        })
        local manga = { id = "m1", title = "Frieren" }

        assert.is_true(plugin:performMangaAction(manga, "keep_next_5_unread"))
        assert.are.equal(2, #plugin.enqueued[1].chapters)

        assert.is_true(plugin:performMangaAction(manga, "keep_next_50_unread"))
        assert.are.equal("Queue", state.bulk_confirmation.ok_text)
        state.bulk_confirmation.callback()
        assert.are.equal(2, #plugin.enqueued[2].chapters)

        assert.is_true(plugin:performMangaAction(manga, "delete_read_downloaded"))
        assert.is_true(state.confirm_delete_read)
    end)
end)
