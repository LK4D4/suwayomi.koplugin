package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

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
        original_os_remove = os.remove
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
        downloader = {
            existing = options.existing or {},
            getTargetPath = function(_, download_directory, target_manga, target_chapter)
                return download_directory .. "/" .. target_manga.title,
                    download_directory .. "/" .. target_manga.title .. "/" .. target_chapter.name .. ".cbz"
            end,
            chapterExists = function(self, path)
                return self.existing[path] == true
            end,
        }

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
            getChaptersThrough = function(_, selected)
                return options.chapters_through or { selected }
            end,
        }

        local Actions = require("suwayomi/chapters/actions")
        for name, method in pairs(Actions.methods) do
            plugin[name] = method
        end
        return plugin, queue
    end

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

    it("removes a chapter archive and KOReader sidecars in the current order", function()
        local plugin = build_plugin()

        plugin:removeChapterArchiveAndSidecars(
            "/downloads/Manga/Chapter 1.cbz",
            "/downloads/Manga/Chapter 1.sdr/metadata.lua"
        )

        assert.are.same({
            "/downloads/Manga/Chapter 1.cbz",
            "/downloads/Manga/Chapter 1.sdr/metadata.lua",
            "/downloads/Manga/Chapter 1.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 1.sdr",
        }, removed_paths)
    end)

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

    it("cancels a pending queue entry before reporting a missing archive", function()
        local plugin = build_plugin({ cancelled = true })

        local ok, state = plugin:deleteChapterFromDeviceWithOptions(manga, chapter)

        assert.is_false(ok)
        assert.are.equal("queued", state)
        assert.are.same({ "This chapter is not downloaded." }, plugin.messages)
    end)

    it("saves reader return context before opening a downloaded chapter", function()
        local opened_paths = {}
        package.preload["apps/reader/readerui"] = function()
            return {
                showReader = function(_, path)
                    table.insert(opened_paths, path)
                end,
            }
        end
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
        })

        assert.is_true(plugin:openChapter(manga, chapter))

        assert.are.same({ "/downloads/Manga/Chapter 1.cbz" }, opened_paths)
        assert.are.equal(1, #plugin.reader_return_contexts)
        assert.are.equal(manga, plugin.reader_return_contexts[1].manga)
        assert.are.equal(chapter, plugin.reader_return_contexts[1].chapter)
        assert.are.equal("/downloads/Manga/Chapter 1.cbz", plugin.reader_return_contexts[1].path)
        assert.are.equal("/downloads/Manga/Chapter 1.cbz", plugin.ledger["m1:c1"].path)
        package.preload["apps/reader/readerui"] = nil
        package.loaded["apps/reader/readerui"] = nil
    end)

    it("deletes archives, clears queue status, and removes unread ledger entries", function()
        local plugin, queue = build_plugin({
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
        assert.is_nil(plugin.ledger["m1:c1"])
        assert.are.equal(1, #plugin.saved_ledgers)
        assert.are.equal(1, #queue.cleared)
        assert.are.same({
            "/downloads/Manga/Chapter 1.cbz",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 1.cbz.sdr",
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

        assert.is_nil(plugin.ledger["m1:c1"])
        assert.are.same({
            "/downloads/Manga/Chapter 1.cbz",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 1.cbz.sdr",
        }, removed_paths)
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

        assert.is_nil(plugin.ledger["m1:c1"])
        assert.is_nil(plugin.ledger["m1:c2"])
        assert.are.equal(true, plugin.selection_cleared)
        assert.are.same({
            "/downloads/Manga/Chapter 1.cbz",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 1.cbz.sdr",
            "/downloads/Manga/Chapter 2.cbz",
            "/downloads/Manga/Chapter 2.cbz.sdr/metadata.lua",
            "/downloads/Manga/Chapter 2.cbz.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 2.cbz.sdr",
        }, removed_paths)
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

    it("uses legacy manga/chapter id lookup when deleting ledger paths", function()
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
        assert.is_nil(plugin.ledger.legacy)
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
            "/downloads/Manga/Chapter 1.cbz",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 1.cbz.sdr",
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
        assert.are.same({ "Deleted 0 chapters from device. Failed to delete 1 download." }, plugin.messages)
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
            "Deleted 1 chapter from device. Skipped 1 active download. Missing 1 download. Failed to delete 1 download.",
        }, plugin.messages)
    end)

    it("deletes the configured finished chapter offset while reading", function()
        local chapters = {
            { id = "c1", name = "Chapter 1", is_read = true },
            { id = "c2", name = "Chapter 2", is_read = true },
            { id = "c3", name = "Chapter 3", is_read = true },
        }
        local plugin = build_plugin({
            delete_chapters_settings = {
                delete_after_mark_read = false,
                delete_finished_while_reading = 2,
            },
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
                ["/downloads/Manga/Chapter 2.cbz"] = true,
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
                ["m1:c2"] = {
                    manga_id = "m1",
                    chapter_id = "c2",
                    path = "/downloads/Manga/Chapter 2.cbz",
                    read = true,
                },
                ["m1:c3"] = {
                    manga_id = "m1",
                    chapter_id = "c3",
                    path = "/downloads/Manga/Chapter 3.cbz",
                    read = true,
                },
            },
        })

        assert.are.equal(1, plugin:deleteFinishedChaptersWhileReading(manga, chapters[3]))

        assert.are.equal("/downloads/Manga/Chapter 1.cbz", plugin.ledger["m1:c1"].path)
        assert.is_nil(plugin.ledger["m1:c2"].path)
        assert.are.equal("/downloads/Manga/Chapter 3.cbz", plugin.ledger["m1:c3"].path)
        assert.are.same({
            "/downloads/Manga/Chapter 2.cbz",
            "/downloads/Manga/Chapter 2.cbz.sdr/metadata.lua",
            "/downloads/Manga/Chapter 2.cbz.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 2.cbz.sdr",
        }, removed_paths)
        assert.are.same({}, plugin.messages)
    end)

    it("uses the ledger path for delete-while-reading cleanup", function()
        local plugin = build_plugin({
            delete_chapters_settings = {
                delete_after_mark_read = false,
                delete_finished_while_reading = 1,
            },
            existing = {
                ["/downloads/Local source/Manga/Chapter 1.cbz"] = true,
            },
            ledger = {
                ["m1:c1"] = {
                    manga_id = "m1",
                    chapter_id = "c1",
                    path = "/downloads/Local source/Manga/Chapter 1.cbz",
                    read = true,
                },
            },
        })

        assert.are.equal(1, plugin:deleteFinishedChaptersWhileReading(manga, chapter))

        assert.is_nil(plugin.ledger["m1:c1"].path)
        assert.are.same({
            "/downloads/Local source/Manga/Chapter 1.cbz",
            "/downloads/Local source/Manga/Chapter 1.cbz.sdr/metadata.lua",
            "/downloads/Local source/Manga/Chapter 1.cbz.sdr/metadata.lua.old",
            "/downloads/Local source/Manga/Chapter 1.cbz.sdr",
        }, removed_paths)
    end)

    it("does not use stale chapter context from a different manga for delete-while-reading", function()
        local plugin = build_plugin({
            delete_chapters_settings = {
                delete_after_mark_read = false,
                delete_finished_while_reading = 2,
            },
            existing = {
                ["/downloads/Manga/Chapter 10.cbz"] = true,
            },
            current_chapter_context = {
                manga = { id = "other", title = "Other manga" },
                chapters = {
                    { id = "c9", name = "Chapter 9", is_read = true },
                    { id = "c10", name = "Chapter 10", is_read = true },
                },
            },
            ledger = {
                ["m1:c10"] = {
                    manga_id = "m1",
                    chapter_id = "c10",
                    path = "/downloads/Manga/Chapter 10.cbz",
                    read = true,
                },
            },
        })

        assert.are.equal(0, plugin:deleteFinishedChaptersWhileReading(manga, { id = "c10", name = "Chapter 10" }))

        assert.are.equal("/downloads/Manga/Chapter 10.cbz", plugin.ledger["m1:c10"].path)
        assert.are.same({}, removed_paths)
    end)

    it("marks a downloaded chapter read and schedules sync by default", function()
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
            current_chapter_context = {
                chapters = {
                    { id = "c1", name = "Chapter 1", is_read = false },
                },
            },
        })

        assert.is_true(plugin:markChapterRead(manga, chapter))

        assert.are.same({ { path = "/downloads/Manga/Chapter 1.cbz", read = true } }, plugin.metadata_updates)
        assert.is_true(plugin.ledger["m1:c1"].read)
        assert.is_true(plugin.ledger["m1:c1"].pending_read_sync)
        assert.is_true(plugin.ledger["m1:c1"].pending_read_state)
        assert.is_true(plugin.current_chapter_context.chapters[1].is_read)
        assert.are.equal(1, #plugin.refreshes)
        assert.are.equal(1, plugin.scheduled_count)
        assert.are.equal(manga, plugin.keep_next_policy_manga)
    end)

    it("deletes a downloaded chapter after manually marking it read when enabled", function()
        local plugin = build_plugin({
            delete_chapters_settings = {
                delete_after_mark_read = true,
                delete_finished_while_reading = 0,
            },
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
            current_chapter_context = {
                manga = manga,
                chapters = {
                    { id = "c1", name = "Chapter 1", is_read = false },
                },
            },
        })

        assert.is_true(plugin:markChapterRead(manga, chapter))

        assert.is_nil(plugin.ledger["m1:c1"].path)
        assert.are.same({
            "/downloads/Manga/Chapter 1.cbz",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua",
            "/downloads/Manga/Chapter 1.cbz.sdr/metadata.lua.old",
            "/downloads/Manga/Chapter 1.cbz.sdr",
        }, removed_paths)
        assert.are.same({}, plugin.messages)
    end)

    it("honors mark-read skip flags", function()
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
        })

        assert.is_true(plugin:markChapterRead(manga, chapter, {
            skip_refresh = true,
            skip_schedule = true,
        }))

        assert.are.equal(0, #plugin.refreshes)
        assert.are.equal(0, plugin.scheduled_count)
    end)

    it("honors mark-read keep policy skip flag", function()
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
        })

        assert.is_true(plugin:markChapterRead(manga, chapter, {
            skip_keep_policy = true,
        }))

        assert.is_nil(plugin.keep_next_policy_manga)
    end)

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

        assert.are.same({ team_a }, plugin.enqueued.chapters)
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

    it("marks a chapter unread and schedules sync by default", function()
        local plugin = build_plugin({
            existing = {
                ["/downloads/Manga/Chapter 1.cbz"] = true,
            },
            current_chapter_context = {
                chapters = {
                    { id = "c1", name = "Chapter 1", is_read = true },
                },
            },
        })

        assert.is_true(plugin:markChapterUnread(manga, chapter))

        assert.are.same({ { path = "/downloads/Manga/Chapter 1.cbz", read = false } }, plugin.metadata_updates)
        assert.is_false(plugin.ledger["m1:c1"].read)
        assert.is_true(plugin.ledger["m1:c1"].pending_read_sync)
        assert.is_false(plugin.ledger["m1:c1"].pending_read_state)
        assert.is_false(plugin.current_chapter_context.chapters[1].is_read)
        assert.are.equal(1, #plugin.refreshes)
        assert.are.equal(1, plugin.scheduled_count)
    end)

    it("marks a chapter list read with a shared ledger save", function()
        local chapters = {
            { id = "c1", name = "Chapter 1" },
            { id = "c2", name = "Chapter 2" },
        }
        local plugin = build_plugin({
            current_chapter_context = {
                chapters = chapters,
            },
        })

        assert.are.equal(2, plugin:markChapterListRead(manga, chapters))

        assert.is_true(plugin.ledger["m1:c1"].read)
        assert.is_true(plugin.ledger["m1:c2"].read)
        assert.are.equal(1, #plugin.saved_ledgers)
        assert.are.equal(1, #plugin.refreshes)
        assert.are.equal(1, plugin.scheduled_count)
        assert.are.equal(manga, plugin.keep_next_policy_manga)
    end)
end)
