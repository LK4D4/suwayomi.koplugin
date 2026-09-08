package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")
local Marker = require("spec/support/i18n_marker")

describe("suwayomi/chapters/actions", function()
    local original_os_remove
    local removed_paths
    local settings
    local downloader
    local debug_events

    local manga = { id = "m1", title = "Manga" }
    local chapter = { id = "c1", name = "Chapter 1" }

    local function reset_modules()
        for _, name in ipairs({
            "suwayomi/chapters/actions",
            "suwayomi/chapters/context",
            "suwayomi/chapters/local_downloads",
            "suwayomi/chapters/delete_actions",
            "suwayomi/chapters/read_actions",
            "suwayomi/chapters/manual_deletion",
            "suwayomi/chapters/archive_identity",
            "suwayomi/fs",
            "apps/reader/readerui",
            "suwayomi/i18n",
            "suwayomi/settings",
            "suwayomi/downloads/downloader",
            "suwayomi/ui",
            "suwayomi/debug",
            "suwayomi/api",
            "suwayomi/readsync/worker",
            "suwayomi/readsync/ledger",
            "suwayomi/browse/source_fetch_worker",
        }) do
            package.loaded[name] = nil
        end
    end

    local function install_runtime_stubs(options)
        options = options or {}
        helper.stubControllerDependencies()
        reset_modules()

        removed_paths = {}
        debug_events = {}
        os.remove = function(path)
            table.insert(removed_paths, path)
            local result = options.remove_results and options.remove_results[path]
            if result == false then
                return false
            end
            if downloader and downloader.existing then
                downloader.existing[path] = nil
            end
            return true
        end

        settings = {
            download_directory = options.download_directory == nil and "/downloads" or options.download_directory,
            delete_chapters_settings = options.delete_chapters_settings or {
                delete_after_mark_read = false,
                delete_finished_while_reading = 0,
            },
            loadDownloadDirectory = function(self)
                return self.download_directory
            end,
            saveDownloadDirectory = function(self, path)
                self.download_directory = path
                return path
            end,
            loadDeleteChaptersSettings = function(self)
                return self.delete_chapters_settings
            end,
        }
        local checked = require("spec/support/checked_queue_settings")()
        settings.getStore = checked.getStore
        settings.isBlocked = checked.isBlocked
        settings.reconcile = checked.reconcile
        downloader = {
            existing = options.existing or {},
            getTargetPath = function(_, download_directory, target_manga, target_chapter)
                if options.get_target_path then
                    return options.get_target_path(download_directory, target_manga, target_chapter)
                end
                return download_directory .. "/" .. target_manga.title,
                    download_directory .. "/" .. target_manga.title .. "/" .. target_chapter.name .. ".cbz"
            end,
            findExistingChapterPath = options.find_existing_chapter_path,
            chapterExists = function(self, path)
                return self.existing[path] == true
            end,
        }
        package.preload["suwayomi/fs"] = function()
            local function attributes(path)
                if path == settings.download_directory then return { mode = "directory" } end
                if downloader.existing[path] then
                    return { mode = "file", dev = 1, ino = 1, size = 1, change = 1, modification = 1 }
                end
                return nil, "missing", 2
            end
            return { attributes = attributes, symlinkattributes = attributes }
        end
        package.preload["apps/reader/readerui"] = package.preload["apps/reader/readerui"] or function() return {} end
        require("ffi/util").realpath = function(path) return path end

        package.preload["suwayomi/settings"] = function()
            return settings
        end
        package.preload["suwayomi/downloads/downloader"] = function()
            return downloader
        end
        package.preload["suwayomi/debug"] = function()
            return {
                now = function()
                    return 100
                end,
                elapsedMs = function()
                    return 0
                end,
                log = function(event)
                    table.insert(debug_events, event)
                end,
            }
        end
        package.preload["suwayomi/ui"] = function()
            return {
                showDirectoryChooser = function(callback)
                    if callback then
                        callback("/chosen")
                    end
                end,
            }
        end
        package.preload["suwayomi/api"] = function()
            return {}
        end
        package.preload["suwayomi/readsync/worker"] = function()
            return {}
        end
        package.preload["suwayomi/readsync/ledger"] = function()
            return { methods = { mergeChaptersWithReadLedger = function() end } }
        end
        package.preload["suwayomi/browse/source_fetch_worker"] = function()
            return {}
        end
    end

    local function build_plugin(options)
        options = options or {}
        install_runtime_stubs(options)

        local queue = options.queue or {}
        queue.status = queue.status or {}
        queue.cleared = {}
        queue.getStatus = queue.getStatus or function(_, target_manga, target_chapter)
            return queue.status[tostring(target_manga.id) .. ":" .. tostring(target_chapter.id)]
        end
        queue.cancelPending = queue.cancelPending or function()
            return options.cancelled == true, options.queue_state
        end
        queue.clearStatus = queue.clearStatus or function(_, target_manga, target_chapter, clear_options)
            table.insert(queue.cleared, { manga = target_manga, chapter = target_chapter, options = clear_options })
            return true
        end

        local ledger = options.ledger or {}
        local plugin = {
            current_chapter_context = options.current_chapter_context,
            queue = queue,
            ledger = ledger,
            reader_return_contexts = {},
            messages = {},
            refreshes = {},
            saved_ledgers = {},
            metadata_updates = {},
            cleanup_cancellations = {},
            scheduled_count = 0,
            getDownloadQueue = function(self)
                return self.queue
            end,
            getKoreaderMetadataPathForDocument = function(_, chapter_path)
                return chapter_path .. ".sdr/metadata.lua"
            end,
            loadChapterLedger = function(self)
                return self.ledger
            end,
            saveChapterLedger = function(self, saved)
                table.insert(self.saved_ledgers, saved)
                self.ledger = saved
                return saved
            end,
            getChapterLedgerKey = function(_, target_manga, target_chapter)
                return tostring(target_manga.id or "") .. ":" .. tostring(target_chapter.id or "")
            end,
            upsertChapterLedgerEntryInLedger = function(self, target_ledger, target_manga, target_chapter, updates)
                local key = self:getChapterLedgerKey(target_manga, target_chapter)
                target_ledger[key] = target_ledger[key] or {
                    manga_id = target_manga.id,
                    manga_title = target_manga.title,
                    chapter_id = target_chapter.id,
                    chapter_name = target_chapter.name,
                }
                for update_key, value in pairs(updates or {}) do
                    target_ledger[key][update_key] = value
                end
            end,
            upsertChapterLedgerEntry = function(self, target_manga, target_chapter, updates)
                self:upsertChapterLedgerEntryInLedger(self.ledger, target_manga, target_chapter, updates)
            end,
            setKoreaderChapterReadState = function(self, chapter_path, read_state)
                table.insert(self.metadata_updates, { path = chapter_path, read = read_state })
                return true
            end,
            showMessage = function(self, message)
                table.insert(self.messages, message)
            end,
            formatBulkDeleteMessage = function(_, deleted, _, missing, active)
                return "bulk deleted=" .. tostring(deleted)
                    .. " missing=" .. tostring(missing)
                    .. " active=" .. tostring(active)
            end,
            refreshChapterMenu = function(self, refresh_options)
                table.insert(self.refreshes, refresh_options or true)
            end,
            withChapterMenuRefreshSuppressed = function(_, callback)
                return callback()
            end,
            getVisibleChapters = function(_, chapters)
                return chapters or {}
            end,
            pluralize = function(_, count, singular, plural)
                if count == 1 then
                    return singular
                end
                return plural
            end,
            getReadChaptersFromCurrentContext = function(self)
                local read_chapters = {}
                for _, target_chapter in ipairs(self:getVisibleChapters((self.current_chapter_context and self.current_chapter_context.chapters) or {})) do
                    if target_chapter.is_read == true then
                        table.insert(read_chapters, target_chapter)
                    end
                end
                return read_chapters
            end,
            schedulePendingReadSync = function(self)
                self.scheduled_count = self.scheduled_count + 1
            end,
            cancelFinishedChapter = function(self, manga_id, chapter_id)
                table.insert(self.cleanup_cancellations, {
                    manga_id = manga_id,
                    chapter_id = chapter_id,
                })
            end,
            applyMangaKeepNextUnreadDownloadsPolicy = function(self, target_manga)
                self.keep_next_policy_manga = target_manga
                return options.keep_next_queued or 0
            end,
            saveReaderReturnContext = function(self, target_manga, target_chapter, chapter_path)
                table.insert(self.reader_return_contexts, {
                    manga = target_manga,
                    chapter = target_chapter,
                    path = chapter_path,
                })
            end,
            getChaptersBefore = function(_, selected)
                return options.chapters_before or { selected }
            end,
        }
        queue.statuses = queue.status
        queue.getKey = plugin.getChapterLedgerKey
        queue.isChapterBusy = queue.isChapterBusy or function() return false end
        local store = settings:getStore()
        assert(store:saveKey("chapter_ledger", ledger))
        local save_document = store.saveDocument
        store.saveDocument = function(subject, mutate)
            local ok, result = save_document(subject, mutate)
            if ok then plugin.ledger = store:readKey("chapter_ledger", {}) end
            return ok, result
        end
        queue.manual_deletion = require("suwayomi/chapters/manual_deletion"):new{
            settings = settings, queue = queue,
            ui_manager = { scheduleIn = function() end, unschedule = function() end },
        }

        local Actions = require("suwayomi/chapters/actions")
        for name, method in pairs(Actions.methods) do
            plugin[name] = method
        end
        return plugin, queue
    end

    local function install_bulk_admission(plugin)
        plugin.max_batch_queue_chapters = 50
        plugin.queue = require("suwayomi/downloads/queue"):new{ downloader = downloader }
        local context = require("suwayomi/chapters/context").methods
        for _, name in ipairs({ "loadMangaScanlatorFilter", "getChapterScanlator" }) do
            plugin[name] = context[name]
        end
    end

    before_each(function()
        original_os_remove = os.remove
    end)

    after_each(function()
        if original_os_remove then
            os.remove = original_os_remove
        end
        reset_modules()
        package.preload["suwayomi/settings"] = nil
        package.preload["suwayomi/downloads/downloader"] = nil
        package.preload["suwayomi/debug"] = nil
        package.preload["suwayomi/ui"] = nil
        package.preload["suwayomi/api"] = nil
        package.preload["suwayomi/readsync/worker"] = nil
        package.preload["suwayomi/readsync/ledger"] = nil
        package.preload["suwayomi/browse/source_fetch_worker"] = nil
        package.preload["suwayomi/fs"] = nil
        package.preload["apps/reader/readerui"] = nil
        Marker.uninstall()
    end)

    it("exports chapter and bulk action methods", function()
        helper.assertControllerModule("suwayomi/chapters/actions", {
            "openChapter",
            "markChapterRead",
            "downloadSelectedChapters",
            "confirmDeleteChapterFromDevice",
            "performBulkChapterAction",
        })
    end)

    it("resolves local chapter paths through the saved download directory", function()
        local plugin = build_plugin()

        assert.are.equal("/downloads/Manga/Chapter 1.cbz", plugin:getChapterPath(manga, chapter))

        settings.download_directory = ""
        assert.is_nil(plugin:getChapterPath(manga, chapter))
    end)

    it("reports downloaded chapters only when the target archive exists", function()
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
        })

        local downloaded, chapter_path = plugin:isChapterDownloaded(manga, chapter)

        assert.is_true(downloaded)
        assert.are.equal("/downloads/Manga/Chapter 1.cbz", chapter_path)
    end)

    it("reports downloaded chapters when only a legacy unsuffixed archive exists", function()
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
            get_target_path = function(download_directory)
                return download_directory .. "/Manga", download_directory .. "/Manga/Chapter 1 [id-c1].cbz"
            end,
            find_existing_chapter_path = function()
                return "/downloads/Manga/Chapter 1.cbz"
            end,
        })

        local downloaded, chapter_path = plugin:isChapterDownloaded(manga, chapter)

        assert.is_true(downloaded)
        assert.are.equal("/downloads/Manga/Chapter 1.cbz", chapter_path)
    end)

    it("removes KOReader sidecars before the archive so interrupted cleanup can retry", function()
        local plugin = build_plugin()

        plugin:removeChapterArchiveAndSidecars(
            "/downloads/Manga/Chapter 1.cbz",
            "/downloads/Manga/Chapter 1.sdr/metadata.lua"
        )

        assert.are.same({
            "/downloads/Manga/Chapter 1.sdr/metadata.lua",
            "/downloads/Manga/Chapter 1.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 1.sdr",
            "/downloads/Manga/Chapter 1.cbz",
        }, removed_paths)
    end)

    for _, suffix in ipairs({ "", ".old" }) do
        it("keeps the archive and ledger until sidecar " .. suffix .. " removal succeeds", function()
            local path = "/downloads/Manga/Chapter 1.cbz"
            local metadata_path = path .. ".sdr/metadata.lua"
            local options = { existing = { [path] = true },
                remove_results = { [metadata_path .. suffix] = false },
                ledger = { ["m1:c1"] = { manga_id = "m1", chapter_id = "c1", read = true, path = path } } }
            local plugin, queue = build_plugin(options)
            local ok, state = plugin:deleteChapterFromDeviceWithOptions(manga, chapter)
            assert.is_false(ok)
            assert.are.equal("delete_failed", state)
            assert.is_true(downloader.existing[path])
            assert.are.equal(path, plugin.ledger["m1:c1"].path)
            assert.are.equal(0, #queue.cleared)
            options.remove_results[metadata_path .. suffix] = nil
            assert.is_true(plugin:deleteChapterFromDeviceWithOptions(manga, chapter))
            assert.is_nil(downloader.existing[path])
            assert.is_nil(plugin.ledger["m1:c1"].path)
        end)
    end

    it("refuses to delete a chapter that is currently downloading", function()
        local plugin = build_plugin({
            queue = {
                status = {
                    ["m1:c1"] = { state = "downloading" },
                },
            },
        })

        local ok, state = plugin:deleteChapterFromDeviceWithOptions(manga, chapter)

        assert.is_false(ok)
        assert.are.equal("downloading", state)
        assert.are.same({ "This chapter is downloading. Wait for it to finish before deleting it." }, plugin.messages)
        assert.are.same({}, removed_paths)
    end)

    it("does not report missing when the deletion boundary cannot inspect the archive", function()
        local plugin = build_plugin()
        plugin.chapterArchiveExists = function() return nil, "stat_failed" end
        local ok, state = plugin:deleteChapterFromDeviceWithOptions(manga, chapter, {
            chapter_path = "/downloads/Manga/Chapter 1.cbz",
        })
        assert.is_false(ok)
        assert.are.equal("delete_failed", state)
        assert.are.equal(0, #removed_paths)
    end)

    it("leaves the archive intact when metadata path resolution fails", function()
        local path = "/downloads/Manga/Chapter 1.cbz"
        local plugin = build_plugin({ existing = { [path] = true } })
        plugin.getKoreaderMetadataPathForDocument = function() error("temporary IO failure") end
        local ok, state = plugin:deleteChapterFromDeviceWithOptions(manga, chapter)
        assert.is_false(ok)
        assert.are.equal("delete_failed", state)
        assert.is_true(downloader.existing[path])
        assert.are.equal(0, #removed_paths)
    end)

    it("accepts absent sidecars while preserving unrelated files in their directory", function()
        local plugin = build_plugin()
        local path = "/downloads/Manga/Chapter 1.cbz"
        local metadata_path = "/downloads/Manga/Chapter 1.sdr/metadata.cbz.lua"
        local remove = os.remove
        os.remove = function(candidate)
            if candidate == metadata_path or candidate == metadata_path .. ".old" then
                return nil, "No such file or directory", 2
            elseif candidate == "/downloads/Manga/Chapter 1.sdr" then
                return nil, "Directory not empty", 39
            end
            return remove(candidate)
        end
        assert.is_true(plugin:removeChapterArchiveAndSidecars(path, metadata_path))
        assert.are.same({ path }, removed_paths)
    end)

    it("keeps the archive until metadata in every KOReader location is removed", function()
        local path = "/downloads/Manga/Chapter 1.cbz"
        local primary = "/downloads/Manga/Chapter 1.sdr/metadata.cbz.lua"
        local alternate = "/settings/Chapter 1.sdr/metadata.cbz.lua"
        local options = { existing = { [path] = true }, remove_results = { [alternate] = false } }
        local plugin = build_plugin(options)
        plugin.getKoreaderMetadataPathForDocument = function() return primary, { primary, alternate } end
        local ok, state = plugin:deleteChapterFromDeviceWithOptions(manga, chapter)
        assert.is_false(ok)
        assert.are.equal("delete_failed", state)
        assert.is_true(downloader.existing[path])
        options.remove_results[alternate] = nil
        assert.is_true(plugin:deleteChapterFromDeviceWithOptions(manga, chapter))
        assert.is_nil(downloader.existing[path])
        assert.are.equal(path, removed_paths[#removed_paths])
    end)

    it("cancels a pending queue entry before reporting a missing archive", function()
        local plugin = build_plugin({ cancelled = true })

        local ok, state = plugin:deleteChapterFromDeviceWithOptions(manga, chapter)

        assert.is_false(ok)
        assert.are.equal("queued", state)
        assert.are.same({ "This chapter is not downloaded." }, plugin.messages)
    end)

    it("opens only after verification and preserves existing reading metadata", function()
        local opened_paths = {}
        local complete
        package.preload["apps/reader/readerui"] = function()
            return {
                showReader = function(_, path)
                    table.insert(opened_paths, path)
                end,
            }
        end
        local plugin = build_plugin({
            queue = {
                verifyArchive = function(_, _, _, _, callback)
                    complete = callback
                    return true
                end,
            },
            ledger = { ["m1:c1"] = { read = true, last_page = 7 } },
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
        })

        assert.is_true(plugin:openChapter(manga, chapter))
        assert.are.same({}, opened_paths)
        assert.are.same({}, plugin.reader_return_contexts)
        complete({ state = "valid" })

        assert.are.same({ "/downloads/Manga/Chapter 1.cbz" }, opened_paths)
        assert.are.equal(1, #plugin.reader_return_contexts)
        assert.are.equal(manga, plugin.reader_return_contexts[1].manga)
        assert.are.equal(chapter, plugin.reader_return_contexts[1].chapter)
        assert.are.equal("/downloads/Manga/Chapter 1.cbz", plugin.reader_return_contexts[1].path)
        assert.are.equal("/downloads/Manga/Chapter 1.cbz", plugin.ledger["m1:c1"].path)
        assert.is_true(plugin.ledger["m1:c1"].read)
        assert.are.equal(7, plugin.ledger["m1:c1"].last_page)
        package.preload["apps/reader/readerui"] = nil
        package.loaded["apps/reader/readerui"] = nil
    end)

    it("never opens or writes reader metadata for an inconclusive or damaged inspection", function()
        local complete
        local plugin = build_plugin({
            existing = { ["/downloads/Manga/Chapter 1.cbz"] = true },
            queue = { verifyArchive = function(_, _, _, _, callback)
                complete = callback
                return true
            end },
        })
        local failures = 0
        plugin.showChapterDownloadError = function() failures = failures + 1 end
        for _, state in ipairs({ "unverified", "damaged" }) do
            assert.is_true(plugin:openChapter(manga, chapter))
            complete({ state = state })
        end
        assert.are.equal(2, failures)
        assert.are.same({}, plugin.reader_return_contexts)
        assert.are.same({}, plugin.ledger)
        assert.are.same({}, plugin.metadata_updates)
    end)

    it("drops verification after a newer open request, context change, path change, or host retirement", function()
        local callbacks = {}
        local plugin = build_plugin({
            existing = { ["/downloads/Manga/Chapter 1.cbz"] = true },
            queue = { verifyArchive = function(_, _, _, _, callback)
                callbacks[#callbacks + 1] = callback
                return true
            end },
        })
        local Context = require("suwayomi/chapters/context")
        plugin.captureChapterActionGuard = Context.methods.captureChapterActionGuard
        assert.is_true(plugin:openChapter(manga, chapter))
        assert.is_true(plugin:openChapter(manga, chapter))
        callbacks[1]({ state = "valid" })
        plugin.current_chapter_context = { manga = manga, chapters = { chapter } }
        callbacks[2]({ state = "valid" })
        assert.is_true(plugin:openChapter(manga, chapter))
        settings.download_directory = "/other"
        callbacks[3]({ state = "valid" })
        settings.download_directory = "/downloads"
        assert.is_true(plugin:openChapter(manga, chapter))
        plugin.suwayomi_host_retired = true
        callbacks[4]({ state = "valid" })
        assert.are.same({}, plugin.reader_return_contexts)
        assert.are.same({}, plugin.ledger)
    end)

    it("translates chapter action refusal and confirmation messages", function()
        Marker.install()
        reset_modules()

        local plugin = build_plugin({
            existing = {},
        })
        function plugin:showBulkActionConfirmation(text, ok_text, callback)
            self.confirmation = {
                text = text,
                ok_text = ok_text,
                callback = callback,
            }
            return true
        end

        plugin:openChapter(manga, chapter)
        assert.are.equal("tx:Download the chapter first.", plugin.messages[#plugin.messages])

        plugin:confirmDeleteChapterFromDevice(manga, chapter)
        assert.are.equal("tx:Delete downloaded file for Chapter 1 from this device?", plugin.confirmation.text)
        assert.are.equal("tx:Delete", plugin.confirmation.ok_text)
    end)

    it("translates chapter delete refusal and failure messages", function()
        Marker.install()
        reset_modules()

        local downloading_plugin = build_plugin({
            queue = {
                status = {
                    ["m1:c1"] = { state = "downloading" },
                },
            },
        })

        local ok, state = downloading_plugin:deleteChapterFromDeviceWithOptions(manga, chapter)

        assert.is_false(ok)
        assert.are.equal("downloading", state)
        assert.are.equal(
            "tx:This chapter is downloading. Wait for it to finish before deleting it.",
            downloading_plugin.messages[#downloading_plugin.messages]
        )

        local missing_plugin = build_plugin()

        ok, state = missing_plugin:deleteChapterFromDeviceWithOptions(manga, chapter)

        assert.is_false(ok)
        assert.are.equal("missing", state)
        assert.are.equal("tx:This chapter is not downloaded.", missing_plugin.messages[#missing_plugin.messages])

        local failing_plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
            remove_results = {
                ["/downloads/Manga/Chapter 1.cbz"] = false,
            },
        })

        ok, state = failing_plugin:deleteChapterFromDeviceWithOptions(manga, chapter)

        assert.is_false(ok)
        assert.are.equal("delete_failed", state)
        assert.are.equal(
            "tx:Could not delete this chapter from device.",
            failing_plugin.messages[#failing_plugin.messages]
        )
    end)

    it("deletes archives while preserving the saved unread choice", function()
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
            ledger = {
                ["m1:c1"] = {
                    manga_id = "m1",
                    chapter_id = "c1",
                    path = "/downloads/Manga/Chapter 1.cbz",
                    read = false,
                    pending_read_sync = false,
                },
            },
        })

        local ok, state = plugin:deleteChapterFromDeviceWithOptions(manga, chapter)

        assert.is_true(ok)
        assert.are.equal("deleted", state)
        assert.is_nil(plugin.ledger["m1:c1"].path)
        assert.is_false(plugin.ledger["m1:c1"].read)
        assert.are.same({
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 1.cbz.sdr",
            "/downloads/Manga/Chapter 1.cbz",
        }, removed_paths)
    end)

    it("confirms before deleting a single chapter from device actions", function()
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
            ledger = {
                ["m1:c1"] = {
                    manga_id = "m1",
                    chapter_id = "c1",
                    path = "/downloads/Manga/Chapter 1.cbz",
                    read = false,
                },
            },
        })
        function plugin:showBulkActionConfirmation(text, ok_text, callback)
            self.confirmation = {
                text = text,
                ok_text = ok_text,
                callback = callback,
            }
            return true
        end

        assert.is_true(plugin:performChapterAction(manga, chapter, "delete"))

        assert.are.equal("Delete downloaded file for Chapter 1 from this device?", plugin.confirmation.text)
        assert.are.equal("Delete", plugin.confirmation.ok_text)
        assert.are.same({}, removed_paths)
        assert.is_table(plugin.ledger["m1:c1"])

        plugin.confirmation.callback()

        assert.is_nil(plugin.ledger["m1:c1"].path)
        assert.are.same({
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 1.cbz.sdr",
            "/downloads/Manga/Chapter 1.cbz",
        }, removed_paths)
    end)

    it("does not dispatch the removed mark-through chapter action", function()
        local plugin = build_plugin()
        local called = false
        function plugin:markChaptersReadThrough()
            called = true
            return true
        end

        assert.is_false(plugin:performChapterAction(manga, chapter, "mark_through_read"))
        assert.is_false(called)
    end)

    it("routes chapter download errors to the shared details controller", function()
        local plugin = build_plugin()
        local shown
        local dialog = {}
        function plugin:showChapterDownloadError(target_manga, target_chapter)
            shown = { manga = target_manga, chapter = target_chapter }
            return dialog
        end

        assert.are.equal(dialog, plugin:performChapterAction(manga, chapter, "download_error"))

        assert.are.equal(manga, shown.manga)
        assert.are.equal(chapter, shown.chapter)
        assert.are.same({}, plugin.refreshes)
        assert.are.same({}, removed_paths)
    end)

    it("reports chapter cancellation storage failures without refreshing away the current state", function()
        local plugin = build_plugin({ queue = {
            cancelPending = function() return false, "write_failed: injected" end,
        } })
        assert.is_false(plugin:performChapterAction(manga, chapter, "cancel_download"))
        assert.are.same({ "Could not cancel download: write_failed: injected" }, plugin.messages)
        assert.are.same({}, plugin.refreshes)
    end)

    it("cancels chapter downloads from the chapter action menu", function()
        local cancelled
        local plugin = build_plugin({
            queue = {
                status = {
                    ["m1:c1"] = { state = "downloading" },
                },
                cancelPending = function(_, target_manga, target_chapter)
                    cancelled = { manga = target_manga, chapter = target_chapter }
                    return true, "downloading"
                end,
            },
        })

        assert.is_true(plugin:performChapterAction(manga, chapter, "cancel_download"))

        assert.are.equal(manga, cancelled.manga)
        assert.are.equal(chapter, cancelled.chapter)
        assert.are.same({ { quick = true } }, plugin.refreshes)
        assert.are.same({}, plugin.messages)
    end)

    it("confirms selected download deletion before removing local files", function()
        local chapter2 = { id = "c2", name = "Chapter 2" }
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
                ["/downloads/Manga/Chapter 2.cbz"] = true,
            },
            current_chapter_context = {
                manga = manga,
                chapters = {
                    chapter,
                    chapter2,
                },
            },
            ledger = {
                ["m1:c1"] = {
                    manga_id = "m1",
                    chapter_id = "c1",
                    path = "/downloads/Manga/Chapter 1.cbz",
                    read = false,
                },
                ["m1:c2"] = {
                    manga_id = "m1",
                    chapter_id = "c2",
                    path = "/downloads/Manga/Chapter 2.cbz",
                    read = false,
                },
            },
        })
        function plugin:getSelectedChapters()
            return { chapter, chapter2 }
        end
        function plugin:clearChapterSelection(skip_refresh)
            self.selection_cleared = skip_refresh
        end
        function plugin:showBulkActionConfirmation(text, ok_text, callback)
            self.confirmation = {
                text = text,
                ok_text = ok_text,
                callback = callback,
            }
            return true
        end

        assert.is_true(plugin:performBulkChapterAction("delete_selected"))

        assert.are.equal("Delete 2 selected downloads from device?", plugin.confirmation.text)
        assert.are.equal("Delete", plugin.confirmation.ok_text)
        assert.are.same({}, removed_paths)
        assert.is_table(plugin.ledger["m1:c1"])
        assert.is_table(plugin.ledger["m1:c2"])

        plugin.confirmation.callback()

        assert.is_nil(plugin.ledger["m1:c1"].path)
        assert.is_nil(plugin.ledger["m1:c2"].path)
        assert.are.equal(true, plugin.selection_cleared)
        assert.are.same({ "bulk deleted=2 missing=0 active=0" }, plugin.messages)
        assert.are.same({
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 1.cbz.sdr",
            "/downloads/Manga/Chapter 1.cbz",
            "/downloads/Manga/Chapter 2.cbz.sdr/metadata.lua",
            "/downloads/Manga/Chapter 2.cbz.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 2.cbz.sdr",
            "/downloads/Manga/Chapter 2.cbz",
        }, removed_paths)
    end)

    it("translates selected chapter bulk confirmations", function()
        Marker.install()
        reset_modules()

        local chapter2 = { id = "c2", name = "Chapter 2" }
        local plugin = build_plugin({
            current_chapter_context = {
                manga = manga,
                chapters = {
                    chapter,
                    chapter2,
                },
            },
        })
        function plugin:getSelectedChapters()
            return { chapter, chapter2 }
        end
        function plugin:showBulkActionConfirmation(text, ok_text, callback)
            self.confirmation = {
                text = text,
                ok_text = ok_text,
                callback = callback,
            }
            return true
        end

        plugin:confirmDeleteSelectedChapters()

        assert.are.equal("tx:Delete 2 selected downloads from device?", plugin.confirmation.text)
        assert.are.equal("tx:Delete", plugin.confirmation.ok_text)
    end)

    it("preserves read ledger entries while clearing their local path", function()
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
            ledger = {
                ["m1:c1"] = {
                    manga_id = "m1",
                    chapter_id = "c1",
                    path = "/downloads/Manga/Chapter 1.cbz",
                    read = true,
                    pending_read_sync = false,
                },
            },
        })

        local ok, state = plugin:deleteChapterFromDeviceWithOptions(manga, chapter)

        assert.is_true(ok)
        assert.are.equal("deleted", state)
        assert.is_nil(plugin.ledger["m1:c1"].path)
        assert.is_true(plugin.ledger["m1:c1"].read)
    end)

    it("preserves unproved historical ledger associations during an explicit archive delete", function()
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
            ledger = {
                legacy = {
                    manga_id = "m1",
                    chapter_id = "c1",
                    path = "/downloads/Manga/Chapter 1.cbz",
                    read = false,
                },
            },
        })

        local ok = plugin:deleteChapterFromDeviceWithOptions(manga, chapter)

        assert.is_true(ok)
        assert.are.equal("/downloads/Manga/Chapter 1.cbz", plugin.ledger.legacy.path)
        assert.is_false(plugin.ledger.legacy.read)
        assert.is_nil(downloader.existing["/downloads/Manga/Chapter 1.cbz"])
    end)

    it("deletes only read downloaded chapters and reports the deleted count", function()
        local chapters = {
            { id = "c1", name = "Chapter 1", is_read = true },
            { id = "c2", name = "Chapter 2", is_read = true },
            { id = "c3", name = "Chapter 3", is_read = false },
        }
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
                ["/downloads/Manga/Chapter 3.cbz"] = true,
            },
            current_chapter_context = {
                manga = manga,
                chapters = chapters,
            },
            ledger = {
                ["m1:c1"] = {
                    manga_id = "m1",
                    chapter_id = "c1",
                    path = "/downloads/Manga/Chapter 1.cbz",
                    read = true,
                },
                ["m1:c3"] = {
                    manga_id = "m1",
                    chapter_id = "c3",
                    path = "/downloads/Manga/Chapter 3.cbz",
                    read = false,
                },
            },
        })

        local deleted = plugin:deleteReadChaptersFromDevice()

        assert.are.equal(1, deleted)
        assert.are.same({ "Deleted 1 chapter from device." }, plugin.messages)
        assert.is_nil(plugin.ledger["m1:c1"].path)
        assert.are.equal("/downloads/Manga/Chapter 3.cbz", plugin.ledger["m1:c3"].path)
        assert.are.same({
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 1.cbz.sdr",
            "/downloads/Manga/Chapter 1.cbz",
        }, removed_paths)
        assert.are.equal(1, #plugin.refreshes)
    end)

    it("reports zero deleted chapters when no read downloads exist", function()
        local plugin = build_plugin({
            current_chapter_context = {
                manga = manga,
                chapters = {
                    { id = "c1", name = "Chapter 1", is_read = true },
                    { id = "c2", name = "Chapter 2", is_read = false },
                },
            },
        })

        local deleted = plugin:deleteReadChaptersFromDevice()

        assert.are.equal(0, deleted)
        assert.are.same({ "Deleted 0 chapters from device." }, plugin.messages)
        assert.are.same({}, removed_paths)
    end)

    it("keeps ledger and status when archive deletion races and the file remains", function()
        local plugin, queue = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
            remove_results = {
                ["/downloads/Manga/Chapter 1.cbz"] = false,
            },
            current_chapter_context = {
                manga = manga,
                chapters = {
                    { id = "c1", name = "Chapter 1", is_read = true },
                },
            },
            ledger = {
                ["m1:c1"] = {
                    manga_id = "m1",
                    chapter_id = "c1",
                    path = "/downloads/Manga/Chapter 1.cbz",
                    read = true,
                },
            },
        })

        local deleted = plugin:deleteReadChaptersFromDevice()

        assert.are.equal(0, deleted)
        assert.are.same({ "Deleted 0 chapters from device. Skipped 1 download. Failed to delete 1 download." }, plugin.messages)
        assert.are.equal("/downloads/Manga/Chapter 1.cbz", plugin.ledger["m1:c1"].path)
        assert.are.equal(0, #queue.cleared)
    end)

    it("reports partial delete-read outcomes in the result text", function()
        local chapters = {
            { id = "c1", name = "Chapter 1", is_read = true },
            { id = "c2", name = "Chapter 2", is_read = true },
            { id = "c3", name = "Chapter 3", is_read = true },
            { id = "c4", name = "Chapter 4", is_read = true },
        }
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
                ["/downloads/Manga/Chapter 4.cbz"] = true,
            },
            remove_results = {
                ["/downloads/Manga/Chapter 4.cbz"] = false,
            },
            queue = {
                status = {
                    ["m1:c2"] = { state = "downloading" },
                },
            },
            current_chapter_context = {
                manga = manga,
                chapters = chapters,
            },
        })
        function plugin:getReadDownloadedChaptersFromCurrentContext()
            return chapters
        end

        local deleted = plugin:deleteReadChaptersFromDevice()

        assert.are.equal(1, deleted)
        assert.are.same({
            "Deleted 1 chapter from device. Skipped 3 downloads. 1 active download. 1 missing download. Failed to delete 1 download.",
        }, plugin.messages)
    end)

    it("translates chapter delete result summaries", function()
        Marker.install()
        reset_modules()

        local plugin = build_plugin()

        assert.are.equal(
            "tx:Deleted 2 chapters from device. tx:Skipped 1 download. tx:1 active download. tx:3 missing downloads. tx:Failed to delete 1 download.",
            plugin:formatReadDownloadDeleteMessage(2, {
                skipped = 1,
                active = 1,
                missing = 3,
                failed = 1,
            })
        )
    end)

    local manual_delete_contract_cases = {
        {
            name = "downloading",
            options = { queue = { status = { ["m1:c1"] = { state = "downloading" } } } },
            expected_ok = false,
            expected_state = "downloading",
        },
        {
            name = "queued",
            options = { cancelled = true },
            expected_ok = false,
            expected_state = "queued",
        },
        {
            name = "missing",
            options = {},
            expected_ok = false,
            expected_state = "missing",
        },
        {
            name = "deleted",
            options = { existing = { ["/downloads/Manga/Chapter 1.cbz"] = true } },
            expected_ok = true,
            expected_state = "deleted",
        },
        {
            name = "delete_failed",
            options = {
                existing = { ["/downloads/Manga/Chapter 1.cbz"] = true },
                remove_results = { ["/downloads/Manga/Chapter 1.cbz"] = false },
            },
            expected_ok = false,
            expected_state = "delete_failed",
        },
    }
    for _, case in ipairs(manual_delete_contract_cases) do
        it("preserves the manual " .. case.name .. " result state", function()
            local plugin = build_plugin(case.options)
            local ok, state = plugin:deleteChapterFromDeviceWithOptions(manga, chapter)
            assert.are.equal(case.expected_ok, ok)
            assert.are.equal(case.expected_state, state)
        end)
    end


    it("scopes manga-level next unread download confirmation to the current scanlator filter", function()
        local team_a = { id = "c1", name = "Chapter 1", scanlator = "Team A", is_read = false }
        local team_b = { id = "c2", name = "Chapter 2", scanlator = "Team B", is_read = false }
        local plugin = build_plugin({
            current_chapter_context = {
                manga = manga,
                chapters = {
                    team_a,
                    team_b,
                },
            },
        })
        plugin.current_scanlator_filter = "Team A"
        install_bulk_admission(plugin)
        function plugin:getDownloadDirectoryOrChoose()
            return "/downloads"
        end
        function plugin:showBulkActionConfirmation(text, ok_text, callback)
            self.confirmation = {
                text = text,
                ok_text = ok_text,
                callback = callback,
            }
            return true
        end
        function plugin:enqueueSelectedChapterDownloads(target_manga, chapters)
            self.enqueued = { manga = target_manga, chapters = chapters }
            return #chapters
        end
        local context = require("suwayomi/chapters/context")
        plugin.getChapterScanlator = context.methods.getChapterScanlator
        plugin.getVisibleChapters = context.methods.getVisibleChapters
        plugin.canQueueChapterDownload = context.methods.canQueueChapterDownload
        plugin.getNextUnreadChaptersForDownload = context.methods.getNextUnreadChaptersForDownload

        assert.is_true(plugin:confirmNextUnreadChapterDownloads(2))
        plugin.confirmation.callback()

        assert.are.equal(1, #plugin.enqueued.chapters)
        assert.are.equal(team_a.id, plugin.enqueued.chapters[1].id)
    end)

    it("translates next unread chapter bulk confirmations", function()
        Marker.install()
        reset_modules()

        local chapter2 = { id = "c2", name = "Chapter 2", is_read = false }
        local plugin = build_plugin({
            current_chapter_context = {
                manga = manga,
                chapters = {
                    chapter,
                    chapter2,
                },
            },
        })
        function plugin:getDownloadDirectoryOrChoose()
            return "/downloads"
        end
        function plugin:getNextUnreadChaptersForDownload()
            return { chapter, chapter2 }
        end
        function plugin:showBulkActionConfirmation(text, ok_text, callback)
            self.confirmation = {
                text = text,
                ok_text = ok_text,
                callback = callback,
            }
            return true
        end

        install_bulk_admission(plugin)
        plugin:confirmNextUnreadChapterDownloads(2)

        assert.is_truthy(plugin.confirmation.text:find("tx:Queue up to 2 new chapter downloads?", 1, true))
        assert.is_truthy(plugin.confirmation.text:find("tx:Download next 2 (up to 50 new)", 1, true))
        assert.are.equal("tx:Queue", plugin.confirmation.ok_text)
    end)

    it("keeps burger action origin when opening nested bulk action menus", function()
        local plugin = build_plugin()
        local anchor = function()
            return { x = 3, y = 4, w = 32, h = 32 }
        end
        local bulk_download_options
        local scanlator_options
        function plugin:showBulkDownloadActions(options)
            bulk_download_options = options
        end
        function plugin:showScanlatorFilterActions(options)
            scanlator_options = options
        end

        plugin:performBulkChapterAction("bulk_downloads", { anchor = anchor })
        plugin:performBulkChapterAction("scanlator_filter", { anchor = anchor })

        assert.are.equal(anchor, bulk_download_options and bulk_download_options.anchor)
        assert.are.equal(anchor, scanlator_options and scanlator_options.anchor)
    end)

    it("cancels all downloads from the chapter bulk menu", function()
        local queue = {
            cancelAll = function(self)
                self.cancel_all_count = (self.cancel_all_count or 0) + 1
                return 2
            end,
        }
        local plugin = build_plugin({ queue = queue })

        assert.is_true(plugin:performBulkChapterAction("cancel_all_downloads"))

        assert.are.equal(1, queue.cancel_all_count)
        assert.are.same({ { quick = true } }, plugin.refreshes)
    end)

end)
