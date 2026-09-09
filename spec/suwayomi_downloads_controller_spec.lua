package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")
local Marker = require("spec/support/i18n_marker")

local modules_to_clear = {
    "ffi/util",
    "gettext",
    "suwayomi/settings",
    "suwayomi/ui",
    "suwayomi/downloads/controller",
    "suwayomi/downloads/queue",
    "suwayomi/downloads/active_jobs",
    "suwayomi/downloads/status_formatter",
}

local function clearModules()
    for _, name in ipairs(modules_to_clear) do
        package.loaded[name] = nil
        package.preload[name] = nil
    end
    package.loaded["suwayomi/i18n"] = nil
end

local function installController(options)
    options = options or {}
    clearModules()
    local state = {
        messages = {},
        closed_menus = {},
        home_count = 0,
        downloads_count = 0,
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
            loadMangaKeepNextUnreadDownloads = function(_, manga)
                return (options.keep_next_limits or {})[tostring(manga and manga.id)] or 0
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
            updateDownloadsMenu = function(menu, snapshot, callbacks, menu_options)
                state.updated_downloads_menu = menu
                state.updated_downloads_menu_snapshot = snapshot
                state.updated_downloads_menu_callbacks = callbacks
                state.updated_downloads_menu_options = menu_options
            end,
            showChapterActionsMenu = function(menu_options, onSelect)
                state.actions_menu_options = menu_options
                state.actions_menu_callback = onSelect
                return { name = "actions-menu" }
            end,
            showConfirm = function(confirm_options)
                state.confirm_options = confirm_options
                return { name = "confirm-dialog" }
            end,
            showDownloadErrorDetails = function(job, details_options)
                state.error_details_job = job
                state.error_details = job.progress and job.progress.error
                state.error_details_options = details_options
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
    function queue:cancelAll()
        self.cancel_all_count = (self.cancel_all_count or 0) + 1
    end
    function queue:clearFailed()
        self.clear_failed_count = (self.clear_failed_count or 0) + 1
        return options.cleared_failed or 2
    end
    function queue:retryFailed(key)
        self.retried_key = key
        return options.retry_ok ~= false
    end
    function queue:findPersistentJob(key)
        for _, state_name in ipairs({ "failed", "queued", "active" }) do
            for _, job in ipairs(self.snapshot[state_name]) do
                if job.key == key then
                    job.state = state_name == "active" and "downloading" or state_name
                    return job
                end
            end
        end
    end
    function queue:copySnapshotJob(job, job_state)
        return require("suwayomi/downloads/job_store"):copySnapshotJob(job, job_state)
    end
    function queue:cancelPending(manga, chapter)
        self.cancelled = { manga = manga, chapter = chapter }
        return options.cancel_pending_ok ~= false, options.cancel_pending_state
    end
    function queue:getStatus(manga, chapter)
        self.status = self.status or {}
        return self.status[tostring(manga.id) .. ":" .. tostring(chapter.id)]
    end
    function queue:enqueueBatch(manga, chapters)
        self.enqueued = { manga = manga, chapters = chapters }
        self.status = self.status or {}
        for _, chapter in ipairs(chapters or {}) do
            self.status[tostring(manga.id) .. ":" .. tostring(chapter.id)] = { state = "queued" }
        end
        return #(chapters or {})
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
        if options.visible_chapters then
            return options.visible_chapters
        end
        return chapters
    end
    function plugin:isChapterDownloadAvailable(_, chapter)
        return chapter.downloaded == true
    end
    function plugin:isChapterDownloaded(_, chapter)
        return chapter.downloaded == true
    end
    function plugin:enqueueSelectedChapterDownloads(_, chapters)
        state.interactive_enqueue_count = (state.interactive_enqueue_count or 0) + 1
        state.enqueued_chapters = chapters
        return #chapters
    end
    function plugin:loadChapterLedger()
        return options.ledger or {}
    end
    function plugin:isChapterPathFinishedInKoreader(path)
        return options.finished_paths and options.finished_paths[path] == true
    end
    function plugin:markCurrentContextChapterReadFromLedger(entry)
        state.marked_entry = entry
        local context_manga = self.current_chapter_context and self.current_chapter_context.manga
        if entry.manga_id and tostring(context_manga and context_manga.id or "") ~= tostring(entry.manga_id) then
            return false
        end
        for _, chapter in ipairs((self.current_chapter_context and self.current_chapter_context.chapters) or {}) do
            if tostring(chapter.id or "") == tostring(entry.chapter_id or "") then
                chapter.is_read = true
                return true
            end
        end
        return false
    end
    function plugin:saveChapterLedger(ledger)
        state.saved_ledger = ledger
    end
    function plugin:withChapterMenuRefreshSuppressed(callback)
        return callback()
    end
    function plugin:refreshChapterMenu(refresh_options)
        state.refresh_options = refresh_options
    end
    return plugin, state
end

describe("suwayomi/downloads/controller", function()
    local marker_installed = false
    local archive_path

    local function installMarker()
        if not marker_installed then
            Marker.install()
            marker_installed = true
        end
    end

    after_each(function()
        if archive_path then
            os.remove(archive_path)
            archive_path = nil
        end
        if marker_installed then
            Marker.uninstall()
            marker_installed = false
        end
        clearModules()
    end)

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
        assert.are.equal("cancel_all", state.title_menu_options.actions[1].id)
        assert.are.equal("Cancel all downloads", state.title_menu_options.actions[1].text)
        assert.is_true(state.title_menu_options.actions[1].destructive)
        assert.is_nil(state.title_menu_options.actions[2])

        state.downloads_menu_options.on_title_bar_left_tap(menu)
        assert.are.equal(menu, state.title_menu_tapped)

        state.title_menu_options.onSelect(state.title_menu_options.actions[1], menu)
        assert.is_nil(queue.cancel_all_count)
        assert.are.equal("Cancel all downloads?", state.confirm_options.text)
        assert.are.equal(1, state.downloads_count)

        state.confirm_options.ok_callback()
        assert.are.equal(1, queue.cancel_all_count)
        assert.are.equal(menu, state.closed_menus[1])
        assert.are.equal(2, state.downloads_count)
    end)

    it("translates downloads hub actions and summaries while keeping active job titles raw", function()
        installMarker()
        local queue = {
            snapshot = {
                active = {
                    { key = "m1:c1", manga = { id = "m1", title = "Frieren" }, chapter = { id = "c1", name = "Chapter 1" } },
                },
                queued = {},
                failed = {
                    { key = "m1:c9", manga = { id = "m1", title = "Frieren" }, chapter = { id = "c9", name = "Chapter 9" } },
                },
            },
        }
        local plugin, state = installController({ queue = queue, download_directory = "" })
        plugin.getDownloadDirectorySummary = nil
        local menu = plugin:showDownloads()
        local job = queue.snapshot.active[1]

        assert.are.equal("tx:Downloads", state.title_menu_options.title)
        assert.are.equal("tx:Cancel all downloads", state.title_menu_options.actions[1].text)
        assert.are.equal("tx:Clear failed", state.title_menu_options.actions[2].text)
        assert.are.equal("tx:not set", state.downloads_menu_options.download_directory_summary)

        state.title_menu_options.onSelect(state.title_menu_options.actions[1], menu)
        assert.are.equal("tx:Cancel all downloads?", state.confirm_options.text)
        assert.are.equal("tx:Cancel downloads", state.confirm_options.ok_text)
        assert.are.equal("tx:Keep downloads", state.confirm_options.cancel_text)

        plugin:showActiveDownloadActions(job, menu)
        assert.are.equal("Frieren / Chapter 1", state.actions_menu_options.title)
        assert.are.equal("tx:Open chapter list", state.actions_menu_options.actions[1].text)
        assert.are.equal("tx:Cancel download", state.actions_menu_options.actions[2].text)

    end)

    it("refreshes the active downloads hub in place when queue status changes", function()
        local queue = {
            snapshot = {
                active = {
                    { key = "m1:c1", manga = { id = "m1", title = "Frieren" }, chapter = { id = "c1", name = "Ch. 1" } },
                },
                queued = {},
                failed = {},
            },
        }
        local plugin, state = installController({ queue = queue })
        local menu = plugin:showDownloads()

        queue.snapshot = {
            active = {
                {
                    key = "m1:c2",
                    manga = { id = "m1", title = "Frieren" },
                    chapter = { id = "c2", name = "Ch. 2" },
                    progress = { current = 2, total = 5 },
                },
            },
            queued = {},
            failed = {},
        }

        assert.is_true(plugin:refreshDownloadsMenu())

        assert.are.equal(menu, state.updated_downloads_menu)
        assert.are.equal("m1:c2", state.updated_downloads_menu_snapshot.active[1].key)
        assert.are.equal("Downloads", state.title_menu_options.title)
        assert.are.equal("cancel_all", state.title_menu_options.actions[1].id)
        assert.is_function(state.updated_downloads_menu_callbacks.onSelectActive)
    end)

    it("drops the tracked downloads menu when the downloads route is no longer active", function()
        local plugin, state = installController({ inactive_downloads_menu = true })

        plugin:showDownloads()

        assert.is_false(plugin:refreshDownloadsMenu())
        assert.is_nil(plugin.current_downloads_menu)
        assert.is_nil(state.updated_downloads_menu)
    end)

    it("opens failed download details directly and retries without closing Downloads", function()
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

        state.downloads_menu_callbacks.onSelectFailed(queue.snapshot.failed[1], menu)
        assert.is_nil(state.actions_menu_options)
        assert.are.equal("Frieren / Ch. 1", state.error_details_options.context)
        assert.is_nil(queue.retried_key)

        state.error_details_options.onRetry()
        assert.are.equal("m1:c1", queue.retried_key)
        assert.are.same({}, state.closed_menus)
        assert.are.equal(1, state.downloads_count)
        assert.are.equal(menu, state.updated_downloads_menu)
        assert.are.same({}, state.messages)

        state.downloads_menu_callbacks.onClearFailed(menu)
        assert.are.equal(1, queue.clear_failed_count)
        assert.are.same({}, state.messages)
    end)

    it("translates retry failure feedback while keeping job context raw", function()
        installMarker()
        local job = {
            key = "m1:c1",
            manga = { id = "m1", title = "Frieren" },
            chapter = { id = "c1", name = "Chapter 1" },
        }
        local plugin, state = installController({
            queue = {
                snapshot = {
                    active = {},
                    queued = {},
                    failed = { job },
                },
            },
            retry_ok = false,
        })

        plugin:showFailedDownloadActions(job, plugin:showDownloads())

        assert.are.equal("Frieren / Chapter 1", state.error_details_options.context)

        state.error_details_options.onRetry()
        assert.are.equal("tx:Could not retry download.", state.messages[#state.messages])
    end)

    it("opens the complete stored error only when the failed row is selected", function()
        local error_message = string.rep("A long download error with more detail.\n", 200) .. "final detail"
        local job = { key = "m1:c1", progress = { error = error_message } }
        local plugin, state = installController({
            queue = { snapshot = { active = {}, queued = {}, failed = { job } } },
        })
        local menu = plugin:showDownloads()
        assert.is_nil(state.error_details)
        state.downloads_menu_callbacks.onSelectFailed(job, menu)

        assert.are.equal(error_message, state.error_details)
        assert.is_nil(plugin.queue.retried_key)
        assert.are.same({}, state.closed_menus)
        assert.are.same({}, state.messages)
        assert.are.equal(1, state.downloads_count)
    end)

    it("retries verification from Downloads without chapter context and offers repair only for damage", function()
        local job = {
            key = "m1:c1", download_directory = "/original",
            manga = { id = "m1", title = "Manga" }, chapter = { id = "c1", name = "Chapter" },
            progress = { archive_state = "unverified", path = "/original/chapter.cbz" },
        }
        local callback, guard, repaired
        local queue = {
            snapshot = { active = {}, queued = {}, failed = { job } },
            verifyArchive = function(_, _, _, path, on_done, options)
                assert.are.equal("/original/chapter.cbz", path)
                callback, guard = on_done, options.is_current
                return true
            end,
            redownload = function(_, _, _, directory)
                repaired = directory
                return true
            end,
        }
        local plugin, state = installController({ queue = queue, download_directory = "/changed" })
        local menu = plugin:showDownloads()
        state.downloads_menu_callbacks.onSelectFailed(job, menu)
        assert.is_nil(state.error_details_options.onRetry)
        assert.is_nil(state.error_details_options.onRedownload)
        assert.is_true(state.error_details_options.onVerify())
        assert.is_true(guard())
        callback({ state = "unverified" })
        assert.is_true(state.error_details_options.onVerify())
        assert.is_true(guard())
        job.progress.archive_state = "damaged"
        callback({ state = "damaged" })
        assert.is_true(state.error_details_options.onRedownload())
        assert.are.equal("/original", repaired)
        assert.is_nil(plugin.current_chapter_context)
    end)

    it("discards replaced archive damage in details and rejects retained recovery callbacks", function()
        local plugin, state = installController()
        local Archive = require("suwayomi/downloads/archive")
        local DownloadQueue = require("suwayomi/downloads/queue")
        archive_path = os.tmpname()
        local file = assert(io.open(archive_path, "wb"))
        assert(file:write("damaged"))
        assert(file:close())
        local job = {
            key = "m1:c1", state = "failed", download_directory = "/books",
            manga = { id = "m1", title = "Manga" }, chapter = { id = "c1", name = "Chapter" },
            progress = {
                state = "failed", archive_state = "damaged", path = archive_path,
                identity = assert(Archive.identity(archive_path)), error = "Archive checksum failed.",
            },
        }
        local queue = DownloadQueue:new{
            settings = { loadDownloadQueue = function() return { job } end },
        }
        queue.redownload = function() error("stale damage authorized forced repair") end
        queue.verifyArchive = function() error("stale details started verification") end
        plugin.queue = queue
        local menu = plugin:showDownloads()
        state.downloads_menu_callbacks.onSelectFailed(job, menu)
        assert.are.equal("damaged", state.error_details_job.progress.archive_state)
        local retained = state.error_details_options
        assert.is_function(retained.onRedownload)
        assert.is_function(retained.onVerify)

        -- Row rendering and retained dialogs must both follow the current bytes,
        -- even though the persisted observation still describes the old file.
        file = assert(io.open(archive_path, "wb"))
        assert(file:write("replacement archive with a different identity"))
        assert(file:close())
        assert.are_not.equal(job.progress.identity, Archive.identity(archive_path))
        plugin:refreshDownloadsMenu()
        assert.is_nil(state.updated_downloads_menu_snapshot.failed[1].progress.archive_state)
        state.downloads_menu_callbacks.onSelectFailed(job, menu)
        assert.is_nil(state.error_details_job.progress.archive_state)
        assert.is_nil(state.error_details_options.onRedownload)
        assert.is_nil(state.error_details_options.onVerify)
        assert.is_false(retained.onRedownload())
        assert.is_false(retained.onVerify())
        assert.are.equal("damaged", job.progress.archive_state)
    end)

    it("keeps authorized repair retries available without fresh damage evidence", function()
        local job = {
            key = "m1:c1", repair = true,
            manga = { id = "m1" }, chapter = { id = "c1" },
            progress = { archive_state = "unverified", path = "/books/chapter.cbz" },
        }
        local plugin, state = installController({
            queue = { snapshot = { active = {}, queued = {}, failed = { job } } },
        })
        plugin:showFailedDownloadActions(job, plugin:showDownloads())
        local retry = state.error_details_options.onRetry
        job.progress.archive_state = nil
        assert.is_true(retry())
        assert.are.equal(job.key, plugin.queue.retried_key)
    end)

    it("rejects retained recovery actions after the failed job is removed or requeued", function()
        local job = {
            key = "m1:c1", manga = { id = "m1" }, chapter = { id = "c1" },
            progress = { archive_state = "damaged", path = "/books/chapter.cbz" },
        }
        local queue = {
            snapshot = { active = {}, queued = {}, failed = { job } },
            redownload = function() error("obsolete failure authorized repair") end,
            verifyArchive = function() error("obsolete failure started verification") end,
        }
        local plugin, state = installController({ queue = queue })
        plugin:showFailedDownloadActions(job, plugin:showDownloads())
        local retained = state.error_details_options
        queue.snapshot.failed = {}
        assert.is_false(retained.onRedownload())
        assert.is_false(retained.onVerify())
        queue.snapshot.queued = { job }
        assert.is_false(retained.onRedownload())
        assert.is_false(retained.onVerify())
    end)

    it("does not act on recovery details after Downloads closes or the host retires", function()
        local job = {
            key = "m1:c1", manga = { id = "m1" }, chapter = { id = "c1" },
            progress = { archive_state = "damaged", path = "/books/chapter.cbz" },
        }
        local queue = {
            snapshot = { active = {}, queued = {}, failed = { job } },
            redownload = function() error("stale repair") end,
            verifyArchive = function() error("stale verification") end,
        }
        local plugin, state = installController({ queue = queue })
        local menu = plugin:showDownloads()
        state.downloads_menu_callbacks.onSelectFailed(job, menu)
        state.downloads_menu_options.close_callback()
        assert.is_false(state.error_details_options.onVerify())
        assert.is_false(state.error_details_options.onRedownload())
        menu = plugin:showDownloads()
        state.downloads_menu_callbacks.onSelectFailed(job, menu)
        plugin.suwayomi_host_retired = true
        assert.is_false(state.error_details_options.onVerify())
        assert.is_false(state.error_details_options.onRedownload())
    end)


    it("wires queued and active cancellation actions to the queue", function()
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

        assert.are.equal("Cancel download", state.actions_menu_options.actions[2].text)
        assert.is_true(state.actions_menu_options.actions[2].destructive)
        state.actions_menu_callback(state.actions_menu_options.actions[2])
        assert.are.equal(job.chapter, plugin.queue.cancelled.chapter)
        assert.are.equal(menu, state.closed_menus[#state.closed_menus])
        assert.are.equal(2, state.downloads_count)
    end)

    it("translates missing queued and active cancel messages", function()
        installMarker()
        local plugin, state = installController({
            cancel_pending_ok = false,
            cancel_pending_state = "missing",
        })
        local menu = { name = "downloads-menu" }
        local job = {
            manga = { id = "m1", title = "Dandadan" },
            chapter = { id = "c1", name = "Ch. 1" },
        }

        plugin:showQueuedDownloadActions(job, menu)
        state.actions_menu_callback(state.actions_menu_options.actions[1])
        assert.are.equal("tx:Download is no longer queued.", state.messages[#state.messages])

        plugin:showActiveDownloadActions(job, menu)
        state.actions_menu_callback(state.actions_menu_options.actions[2])
        assert.are.equal("tx:Download is no longer active.", state.messages[#state.messages])
    end)

    it("translates queued action labels while keeping queued job titles raw", function()
        installMarker()
        local plugin, state = installController()
        local menu = { name = "downloads-menu" }
        local job = {
            manga = { id = "m1", title = "Dandadan" },
            chapter = { id = "c1", name = "Ch. 1" },
        }

        plugin:showQueuedDownloadActions(job, menu)

        assert.are.equal("Dandadan / Ch. 1", state.actions_menu_options.title)
        assert.are.equal("tx:Cancel queued download", state.actions_menu_options.actions[1].text)
        assert.are.equal("tx:Open chapter list", state.actions_menu_options.actions[2].text)
    end)

    it("translates already-downloading queued cancel message", function()
        installMarker()
        local plugin, state = installController({
            cancel_pending_ok = false,
            cancel_pending_state = "downloading",
        })
        local job = {
            manga = { id = "m1", title = "Dandadan" },
            chapter = { id = "c1", name = "Ch. 1" },
        }

        plugin:showQueuedDownloadActions(job, { name = "downloads-menu" })
        state.actions_menu_callback(state.actions_menu_options.actions[1])

        assert.are.equal("tx:Download is already downloading.", state.messages[#state.messages])
    end)

end)
