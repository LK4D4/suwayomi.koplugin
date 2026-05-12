package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

local modules_to_clear = {
    "ffi/util",
    "gettext",
    "suwayomi/settings",
    "suwayomi/ui",
    "suwayomi/downloads/controller",
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
        closed_menus = {},
        home_count = 0,
        downloads_count = 0,
        manga_actions = {},
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
    package.preload["suwayomi/settings"] = function()
        return {
            loadDownloadDirectory = function()
                return options.download_directory or "/books"
            end,
        }
    end
    package.preload["suwayomi/ui"] = function()
        return {
            showDownloadsMenu = function(snapshot, callbacks, menu_options)
                state.downloads_menu_snapshot = snapshot
                state.downloads_menu_callbacks = callbacks
                state.downloads_menu_options = menu_options
                return { name = "downloads-menu" }
            end,
            showChapterActionsMenu = function(menu_options, onSelect)
                state.actions_menu_options = menu_options
                state.actions_menu_callback = onSelect
                return { name = "actions-menu" }
            end,
        }
    end

    local controller = require("suwayomi/downloads/controller")
    local queue = options.queue or {}
    queue.snapshot = queue.snapshot or { active = {}, queued = {}, failed = {} }
    function queue:getSnapshot()
        return self.snapshot
    end
    function queue:cancelQueued()
        self.cancel_queued_count = (self.cancel_queued_count or 0) + 1
    end
    function queue:clearFailed()
        self.clear_failed_count = (self.clear_failed_count or 0) + 1
        return options.cleared_failed or 2
    end
    function queue:retryFailed(key)
        self.retried_key = key
        return options.retry_ok ~= false
    end
    function queue:cancelPending(manga, chapter)
        self.cancelled = { manga = manga, chapter = chapter }
        return options.cancel_pending_ok ~= false, options.cancel_pending_state
    end

    local plugin = {
        queue = queue,
        messages = state.messages,
        current_chapter_context = options.current_chapter_context,
    }
    for name, method in pairs(controller.methods) do
        plugin[name] = method
    end
    function plugin:getDownloadQueue()
        return self.queue
    end
    function plugin:showMessage(message)
        table.insert(self.messages, message)
    end
    function plugin:getDownloadDirectorySummary()
        return options.download_directory_summary or "Books/Manga"
    end
    function plugin:closeMenu(menu)
        table.insert(state.closed_menus, menu)
    end
    function plugin:showHome()
        state.home_count = state.home_count + 1
    end
    function plugin:getTitleBarMenuOptions(menu_options)
        state.title_menu_options = menu_options
        return {
            title_bar_left_icon = "appbar.menu",
            on_title_bar_left_tap = function(menu)
                state.title_menu_tapped = menu
                return true
            end,
        }
    end
    function plugin:showDownloads()
        state.downloads_count = state.downloads_count + 1
        return controller.methods.showDownloads(self)
    end
    function plugin:showMangaActions(manga, manga_options)
        table.insert(state.manga_actions, { manga = manga, options = manga_options })
    end
    function plugin:trackSuwayomiScreen(route_id, widget)
        table.insert(state.tracked_screens, { route_id = route_id, widget = widget })
    end
    function plugin:isSuwayomiScreenActive(widget)
        if options.inactive_downloads_menu == true and widget and widget.name == "downloads-menu" then
            return false
        end
        return true
    end
    function plugin:getVisibleChapters(chapters)
        return chapters
    end
    function plugin:isChapterDownloadAvailable(_, chapter)
        return chapter.downloaded == true
    end
    function plugin:enqueueSelectedChapterDownloads(_, chapters)
        state.enqueued_chapters = chapters
        return #chapters
    end
    function plugin:loadChapterLedger()
        return options.ledger or {}
    end
    function plugin:loadKoreaderHistoryPaths()
        return options.history_paths or {}
    end
    function plugin:isChapterPathFinishedInKoreader(path)
        return options.finished_paths and options.finished_paths[path] == true
    end
    function plugin:markCurrentContextChapterReadFromLedger(entry)
        state.marked_entry = entry
    end
    function plugin:saveChapterLedger(ledger)
        state.saved_ledger = ledger
    end
    return plugin, state
end

describe("suwayomi/downloads/controller", function()
    after_each(clearModules)

    it("exports downloads hub and ledger reconciliation methods", function()
        helper.assertControllerModule("suwayomi/downloads/controller", {
            "showDownloads",
            "getDownloadJobTitle",
            "reconcileDownloadedChapterLedger",
        })
    end)

    it("opens the downloads hub with empty-state folder context", function()
        local plugin, state = installController({ download_directory_summary = "Books/Manga" })

        local menu = plugin:showDownloads()

        assert.are.equal(menu, state.tracked_screens[1].widget)
        assert.are.same({ active = {}, queued = {}, failed = {} }, state.downloads_menu_snapshot)
        assert.are.equal("Books/Manga", state.downloads_menu_options.download_directory_summary)
        assert.are.equal(0, #state.messages)
    end)

    it("opens the downloads hub and wires title-bar actions", function()
        local queue = {
            snapshot = {
                active = {},
                queued = {
                    { key = "m1:c1", manga = { id = "m1", title = "Frieren" }, chapter = { id = "c1", name = "Ch. 1" } },
                },
                failed = {},
            },
        }
        local plugin, state = installController({ queue = queue })
        local menu = plugin:showDownloads()

        assert.are.equal("m1:c1", state.downloads_menu_snapshot.queued[1].key)
        assert.are.equal("appbar.menu", state.downloads_menu_options.title_bar_left_icon)
        assert.are.equal("downloads", state.tracked_screens[1].route_id)
        assert.are.equal("downloads-menu", state.tracked_screens[1].widget.name)
        assert.are.equal("Downloads", state.title_menu_options.title)
        assert.are.equal("cancel_queued", state.title_menu_options.actions[1].id)
        assert.is_nil(state.title_menu_options.actions[2])

        state.downloads_menu_options.on_title_bar_left_tap(menu)
        assert.are.equal(menu, state.title_menu_tapped)

        state.title_menu_options.onSelect(state.title_menu_options.actions[1], menu)
        assert.are.equal(1, queue.cancel_queued_count)
        assert.are.equal(menu, state.closed_menus[1])
        assert.are.equal(2, state.downloads_count)
    end)

    it("delegates retry and clear callbacks from the downloads hub", function()
        local queue = {
            snapshot = {
                active = {},
                queued = {},
                failed = {
                    { key = "m1:c1", manga = { id = "m1", title = "Frieren" }, chapter = { id = "c1", name = "Ch. 1" } },
                },
            },
        }
        local plugin, state = installController({ queue = queue, cleared_failed = 1 })
        local menu = plugin:showDownloads()

        state.downloads_menu_callbacks.onRetryFailed(queue.snapshot.failed[1], menu)
        assert.are.equal("m1:c1", queue.retried_key)
        assert.are.equal("Download queued.", state.messages[#state.messages])

        state.downloads_menu_callbacks.onClearFailed(menu)
        assert.are.equal(1, queue.clear_failed_count)
        assert.are.equal("Cleared 1 failed downloads.", state.messages[#state.messages])
    end)

    it("wires queued and active row actions to queue and manga callbacks", function()
        local plugin, state = installController()
        local menu = { name = "downloads-menu" }
        local job = {
            manga = { id = "m1", title = "Dandadan" },
            chapter = { id = "c1", name = "Ch. 1" },
        }

        plugin:showQueuedDownloadActions(job, menu)
        assert.are.equal("Dandadan / Ch. 1", state.actions_menu_options.title)
        assert.are.equal("Cancel queued download", state.actions_menu_options.actions[1].text)
        assert.are.equal("Open chapter list", state.actions_menu_options.actions[2].text)

        state.actions_menu_callback(state.actions_menu_options.actions[1])
        assert.are.equal(job.manga, plugin.queue.cancelled.manga)
        assert.are.equal(menu, state.closed_menus[#state.closed_menus])

        plugin:showActiveDownloadActions(job, menu)
        state.actions_menu_callback(state.actions_menu_options.actions[1])
        assert.are.equal(job.manga, state.manga_actions[1].manga)
        state.manga_actions[1].options.onMangaUpdated()
        assert.are.equal(2, state.downloads_count)
    end)

    it("does not reopen downloads after manga actions if the downloads route is gone", function()
        local plugin, state = installController({ inactive_downloads_menu = true })
        local menu = { name = "downloads-menu" }
        local job = {
            manga = { id = "m1", title = "Dandadan" },
            chapter = { id = "c1", name = "Ch. 1" },
        }

        plugin:showActiveDownloadActions(job, menu)
        state.actions_menu_callback(state.actions_menu_options.actions[1])
        state.manga_actions[1].options.onMangaUpdated()

        assert.are.equal(0, state.downloads_count)
    end)

    it("reconciles read ledger entries without queueing downloads", function()
        local ledger = {
            ["m1:c1"] = {
                chapter_id = "c1",
                path = "/books/Frieren/Ch. 1.cbz",
                read = false,
            },
        }
        local plugin, state = installController({
            ledger = ledger,
            finished_paths = {
                ["/books/Frieren/Ch. 1.cbz"] = true,
            },
            current_chapter_context = {
                manga = { id = "m1", title = "Frieren" },
                chapters = {
                    { id = "c1", name = "Ch. 1", downloaded = true },
                    { id = "c2", name = "Ch. 2", downloaded = false },
                },
            },
        })

        assert.are.equal(1, plugin:reconcileDownloadedChapterLedger(ledger))

        assert.is_true(ledger["m1:c1"].read)
        assert.is_true(ledger["m1:c1"].pending_read_sync)
        assert.are.equal(ledger, state.saved_ledger)
        assert.is_nil(state.enqueued_chapters)
    end)
end)
