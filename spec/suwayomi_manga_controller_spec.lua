package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

local modules_to_clear = {
    "ffi/util",
    "gettext",
    "suwayomi/api",
    "suwayomi/settings",
    "suwayomi/ui",
    "suwayomi/debug",
    "suwayomi/network/request_job",
    "suwayomi/manga/action_menu",
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
        update_requests = {},
        refresh_calls = {},
        network_requests = {},
        canceled_requests = {},
        tracked_screens = {},
        keep_next_saves = {},
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
            loadMangaKeepNextUnreadDownloads = function(_, target_manga)
                return (options.keep_next_limits or {})[tostring(target_manga and target_manga.id)]
                    or 0
            end,
            normalizeMangaKeepNextUnreadDownloads = function(_, limit)
                local normalized = tonumber(limit) or 0
                if normalized == 5 or normalized == 10 or normalized == 50 then
                    return normalized
                end
                return 0
            end,
            saveMangaKeepNextUnreadDownloads = function(_, target_manga, limit)
                table.insert(state.keep_next_saves, { manga = target_manga, limit = limit })
                return limit
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
    package.preload["suwayomi/network/request_job"] = function()
        return {
            cancel = function(active)
                table.insert(state.canceled_requests, active)
                active.canceled = true
                if active.on_cancel then
                    active.on_cancel()
                end
            end,
            start = function(request_options)
                table.insert(state.network_requests, request_options)
                local request = request_options.request or {}
                local active = {
                    pid = 4321,
                    on_cancel = request_options.on_cancel,
                }
                if options.defer_network_finish then
                    return active
                end
                local result
                if request.action == "refresh_manga" then
                    table.insert(state.refresh_calls, request.manga_id)
                    result = options.refresh_result or {
                        ok = true,
                        manga = { id = request.manga_id, title = "Refreshed title" },
                        chapters = { { id = "c2", name = "Ch. 2", is_read = false } },
                    }
                elseif request.action == "update_manga_library_state" then
                    table.insert(state.update_requests, {
                        manga_id = request.manga_id,
                        in_library = request.in_library,
                    })
                    result = {
                        ok = options.library_update_ok ~= false,
                        error = "Library update failed.",
                        manga = {
                            id = request.manga_id,
                            in_library = request.in_library,
                            title = "Updated " .. request.manga_id,
                        },
                    }
                else
                    result = {
                        ok = true,
                        chapters = options.context_chapters or {
                            { id = "c1", name = "Ch. 1", is_read = true },
                            { id = "c2", name = "Ch. 2", is_read = false },
                        },
                    }
                end
                if request_options.on_finish then
                    request_options.on_finish(result)
                end
                return active
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
        if self.current_chapter_context then
            for _, chapter in ipairs(self.current_chapter_context.chapters or {}) do
                if chapter.is_read ~= true then
                    return chapter
                end
            end
        end
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
        if self.current_chapter_context and self.current_chapter_context.manga == manga then
            return self.current_chapter_context
        end
        return nil
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

local function hasAction(actions, action_id)
    for _, action in ipairs(actions or {}) do
        if action.id == action_id then
            return true
        end
    end
    return false
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
        assert.are.equal("Bulk downloads", state.manga_actions_options.actions[4].text)
        assert.is_true(state.manga_actions_options.actions[4].submenu)
        assert.are.equal("Download ahead", state.manga_actions_options.actions[5].text)
        assert.is_true(state.manga_actions_options.actions[5].submenu)
        assert.are.equal("Remove from library", state.manga_actions_options.actions[#state.manga_actions_options.actions].text)
        assert.is_true(state.manga_actions_options.actions[#state.manga_actions_options.actions].destructive)
        assert.are.equal("manga-actions", state.tracked_screens[1].route_id)
        assert.are.equal("manga-actions-menu", state.tracked_screens[1].widget.name)

        state.manga_actions_callback({ id = "bulk_downloads" })
        assert.are.equal("Bulk downloads", state.manga_actions_options.title)
        assert.are.equal("Download first unread", state.manga_actions_options.actions[1].text)
        assert.are.equal("Download next 5", state.manga_actions_options.actions[2].text)
        assert.are.equal("Download all chapters", state.manga_actions_options.actions[6].text)
        assert.is_function(state.manga_actions_options.on_back)

        state.manga_actions_options.on_back()
        assert.are.equal("Frieren", state.manga_actions_options.title)
        assert.are.equal("bulk_downloads", state.manga_actions_options.actions[4].id)

        state.manga_actions_callback({ id = "keep_downloaded" })
        assert.are.equal("Download ahead", state.manga_actions_options.title)
        assert.are.equal("Keep next 50 downloaded", state.manga_actions_options.actions[3].text)
        assert.are.equal("Stop download ahead", state.manga_actions_options.actions[4].text)
        assert.is_function(state.manga_actions_options.on_back)

        state.manga_actions_options.on_back()
        assert.are.equal("Frieren", state.manga_actions_options.title)
        assert.are.equal("Download ahead", state.manga_actions_options.actions[5].text)
    end)

    it("builds manga actions without loading missing chapter context", function()
        local plugin, state = installController({
            first_unread_downloaded = true,
        })
        plugin.getFirstUnreadChapterForManga = function()
            error("should not load chapter context while building actions")
        end
        local manga = {
            id = "m1",
            title = "Frieren",
            first_unread_chapter = { id = "c2", name = "Ch. 2" },
        }

        plugin:showMangaActions(manga)

        assert.are.equal("Open first unread", state.manga_actions_options.actions[2].text)
    end)

    it("builds first-unread action from visible scanlator-filtered chapters only", function()
        local plugin, state = installController()
        local manga = { id = "m1", title = "Frieren" }
        local team_a = { id = "c1", name = "Ch. 1", scanlator = "Team A", is_read = false }
        local team_b = { id = "c2", name = "Ch. 2", scanlator = "Team B", is_read = false }
        plugin.current_scanlator_filter = "Team B"
        plugin.current_chapter_context = {
            manga = manga,
            chapters = {
                team_a,
                team_b,
            },
        }
        function plugin:getVisibleChapters(chapters)
            local visible = {}
            for _, chapter in ipairs(chapters or {}) do
                if chapter.scanlator == self.current_scanlator_filter then
                    table.insert(visible, chapter)
                end
            end
            return visible
        end
        function plugin:isChapterDownloaded(_, chapter)
            return chapter == team_b
        end

        plugin:showMangaActions(manga)

        assert.is_true(hasAction(state.manga_actions_options.actions, "open_first_unread"))
    end)

    it("hides first-unread action when filtered context has no unread visible chapters", function()
        local plugin, state = installController()
        local hidden = { id = "c1", name = "Ch. 1", scanlator = "Team A", is_read = false }
        local manga = {
            id = "m1",
            title = "Frieren",
            first_unread_chapter = hidden,
        }
        plugin.current_scanlator_filter = "Team B"
        plugin.current_chapter_context = {
            manga = manga,
            chapters = {
                hidden,
                { id = "c2", name = "Ch. 2", scanlator = "Team B", is_read = true },
            },
        }
        function plugin:getVisibleChapters(chapters)
            local visible = {}
            for _, chapter in ipairs(chapters or {}) do
                if chapter.scanlator == self.current_scanlator_filter then
                    table.insert(visible, chapter)
                end
            end
            return visible
        end
        function plugin:isChapterDownloaded(_, chapter)
            return chapter == hidden
        end

        plugin:showMangaActions(manga)

        assert.is_false(hasAction(state.manga_actions_options.actions, "open_first_unread"))
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
        assert.are.same({}, state.update_calls)
        assert.are.same({ { manga_id = "m1", in_library = true } }, state.update_requests)
        assert.is_true(manga.in_library)
        assert.is_nil(manga.menu_text)
        assert.are.equal(manga, updated_manga)
        assert.are.same({}, state.messages)

        assert.is_true(plugin:performMangaAction(manga, "remove_from_library"))
        assert.are.equal("Remove Updated m1 from your Suwayomi library?", state.confirm_options.text)
        state.confirm_options.ok_callback()

        assert.are.same({
            { manga_id = "m1", in_library = true },
            { manga_id = "m1", in_library = false },
        }, state.update_requests)
        assert.is_false(manga.in_library)
        assert.is_nil(manga.menu_text)
        assert.are.same({}, state.messages)
    end)

    it("refreshes the open manga action menu after library state changes", function()
        local plugin, state = installController()
        local manga = { id = "m1", title = "Frieren", in_library = false }

        plugin:showMangaActions(manga)
        assert.is_true(hasAction(state.manga_actions_options.actions, "add_to_library"))

        state.manga_actions_callback({ id = "add_to_library" })

        assert.is_true(hasAction(state.manga_actions_options.actions, "remove_from_library"))
        assert.is_false(hasAction(state.manga_actions_options.actions, "add_to_library"))

        state.manga_actions_callback({ id = "remove_from_library" })
        state.confirm_options.ok_callback()

        assert.is_true(hasAction(state.manga_actions_options.actions, "add_to_library"))
        assert.is_false(hasAction(state.manga_actions_options.actions, "remove_from_library"))
    end)

    it("opens first unread and downloads the next unread chapter from manga actions", function()
        local plugin, state = installController({
            first_unread_chapter = { id = "c2", name = "Ch. 2" },
        })
        local manga = { id = "m1", title = "Frieren" }

        assert.is_true(plugin:performMangaAction(manga, "open_first_unread"))
        assert.are.equal("c2", plugin.opened_chapters[1].chapter.id)

        assert.is_true(plugin:performMangaAction(manga, "download_first_unread"))
        assert.are.equal("fetch_chapters_for_manga", state.network_requests[#state.network_requests].request.action)
        assert.are.equal("c2", plugin.enqueued[1].chapters[1].id)
        assert.are.equal("/books", plugin.enqueued[1].download_directory)
    end)

    it("opens first unread from loaded context before using stale row cache", function()
        local plugin = installController({
            first_unread_chapter = { id = "stale", name = "Stale row chapter" },
        })
        local manga = { id = "m1", title = "Frieren", first_unread_chapter = { id = "stale" } }
        plugin.current_chapter_context = {
            manga = manga,
            chapters = {
                { id = "c1", name = "Ch. 1", is_read = true },
                { id = "c2", name = "Ch. 2", is_read = false },
            },
        }

        assert.is_true(plugin:performMangaAction(manga, "open_first_unread"))

        assert.are.equal("c2", plugin.opened_chapters[1].chapter.id)
    end)

    it("does not warn about missing chapter context before loading first unread", function()
        local plugin, state = installController({
            defer_network_finish = true,
        })
        local manga = { id = "m1", title = "Frieren" }
        plugin.ensureMangaChapterContext = function(owner, target_manga)
            if owner.current_chapter_context and owner.current_chapter_context.manga == target_manga then
                return owner.current_chapter_context
            end
            owner:showMessage("This manga has no chapters loaded.")
            return nil
        end

        assert.is_true(plugin:performMangaAction(manga, "open_first_unread"))

        assert.are.same({}, plugin.messages)
        assert.are.equal("fetch_chapters_for_manga", state.network_requests[1].request.action)
    end)

    it("ignores stale chapter loads when a newer manga request wins", function()
        local plugin, state = installController({
            defer_network_finish = true,
        })
        local first = { id = "m1", title = "First" }
        local second = { id = "m2", title = "Second" }

        assert.is_true(plugin:showChaptersForManga(first))
        assert.is_true(plugin:showChaptersForManga(second))
        assert.are.equal(2, #state.network_requests)
        assert.are.equal(1, #state.canceled_requests)

        state.network_requests[1].on_finish({
            ok = true,
            chapters = { { id = "old", name = "Old", is_read = false } },
        })

        assert.is_nil(plugin.current_chapter_context)

        state.network_requests[2].on_finish({
            ok = true,
            chapters = { { id = "new", name = "New", is_read = false } },
        })

        assert.are.equal("m2", plugin.current_chapter_context.manga.id)
        assert.are.equal("new", plugin.current_chapter_context.chapters[1].id)
    end)

    it("refreshes manga and shows returned chapters", function()
        local plugin, state = installController()
        local manga = { id = "m1", title = "Frieren" }
        local updated_manga

        assert.is_true(plugin:performMangaAction(manga, "refresh_chapters", {
            onMangaUpdated = function(value)
                updated_manga = value
            end,
        }))

        assert.are.same({ "m1" }, state.refresh_calls)
        assert.are.equal("Refreshed title", manga.title)
        assert.are.equal(manga, updated_manga)
        assert.are.equal("Refreshed title", state.chapter_menu_options.title)
        assert.are.equal("c2", plugin.current_chapter_context.chapters[1].id)
        assert.are.equal("chapters", state.tracked_screens[1].route_id)
        assert.are.equal("chapter-menu", state.tracked_screens[1].widget.name)

        state.chapter_menu_options.close_callback()

        assert.is_nil(plugin.current_chapter_menu)
    end)

    it("loads chapters through an async request instead of calling the API inline", function()
        local plugin, state = installController()
        local manga = { id = "m1", title = "Frieren" }

        assert.is_true(plugin:showChaptersForManga(manga))

        assert.are.equal(1, #state.network_requests)
        assert.are.equal("fetch_chapters_for_manga", state.network_requests[1].request.action)
        assert.are.equal("m1", state.network_requests[1].request.manga_id)
        assert.is_nil(state.fetch_chapters_manga_id)
        assert.are.equal("Frieren", state.chapter_menu_options.title)
        assert.are.equal("c1", plugin.current_chapter_context.chapters[1].id)
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

    it("saves per-manga keep-next policy and queues the current buffer", function()
        local plugin, state = installController({
            context_chapters = {
                { id = "c1", name = "Ch. 1", is_read = false },
                { id = "c2", name = "Ch. 2", is_read = false },
            },
        })
        local manga = { id = "m1", title = "Frieren" }

        assert.is_true(plugin:performMangaAction(manga, "keep_next_5_unread"))
        assert.are.equal(2, #plugin.enqueued[1].chapters)
        assert.are.same({ { manga = manga, limit = 5 } }, state.keep_next_saves)

        assert.is_true(plugin:performMangaAction(manga, "keep_next_50_unread"))
        assert.are.equal("Queue", state.bulk_confirmation.ok_text)
        assert.is_nil(state.keep_next_saves[2])
        state.bulk_confirmation.callback()
        assert.are.equal(50, state.keep_next_saves[2].limit)
        assert.are.equal(2, #plugin.enqueued[2].chapters)

        assert.is_true(plugin:performMangaAction(manga, "delete_read_downloaded"))
        assert.is_true(state.confirm_delete_read)
    end)

    it("clears a per-manga keep-next policy without loading chapters", function()
        local plugin, state = installController()
        local manga = { id = "m1", title = "Frieren" }
        function plugin:ensureMangaChapterContext()
            error("stop action should not load chapters")
        end

        assert.is_true(plugin:performMangaAction(manga, "keep_next_0_unread"))

        assert.are.same({ { manga = manga, limit = 0 } }, state.keep_next_saves)
        assert.are.same({}, state.messages)
    end)
end)
