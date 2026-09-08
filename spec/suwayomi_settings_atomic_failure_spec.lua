package.path = "?.lua;" .. package.path

describe("suwayomi settings atomic failure handling", function()
    local SettingsStore
    local SuwayomiSettings
    local DownloadQueue
    local stored_data
    local io_adapter
    local mock_dir = "/atomic_fail_test"
    local settings_path = mock_dir .. "/suwayomi.lua"

    before_each(function()
        stored_data = {
            credentials = {
                server_url = "http://suwayomi.test",
                auth_method = "basic_auth",
            },
            browse_settings = {
                show_nsfw_sources = false,
                hide_in_library_results = false,
            },
            max_parallel_chapter_downloads = 2,
            delete_chapters_settings = {
                delete_after_mark_read = false,
                delete_finished_while_reading = 0,
            },
            download_directory = "/sdcard/manga",
            download_queue = {},
        }

        package.loaded["suwayomi/settings/store"] = nil
        package.loaded["suwayomi/settings"] = nil
        package.loaded["suwayomi/downloads/queue"] = nil
        package.loaded["suwayomi/downloads/job_store"] = nil
        package.loaded.datastorage = nil
        package.loaded.luasettings = nil

        package.preload.datastorage = function()
            return {
                getSettingsDir = function()
                    return mock_dir
                end,
            }
        end

        package.preload.luasettings = function()
            return {
                open = function(_, path)
                    return {
                        file = path,
                        data = stored_data,
                        readSetting = function(self, key, default)
                            if self.data[key] == nil and default ~= nil then
                                self.data[key] = default
                            end
                            return self.data[key]
                        end,
                        saveSetting = function(self, key, value)
                            self.data[key] = value
                            return self
                        end,
                        flush = function() end,
                    }
                end,
            }
        end

        local helper = require("spec/support/controller_module_spec_helper")
        helper.stubControllerDependencies()

        -- Mock IO adapter simulating real filesystem
        local files = {
            [settings_path] = "return {\n    store_transaction = {\n        id = \"init\",\n        version = 1,\n    },\n}\n",
        }
        local dirs = {
            [mock_dir] = true,
        }

        io_adapter = {
            fail_open = false,
            fail_write = false,
            fail_rename = false,
            fail_sync = false,
            fail_sync_dir = false,
            files = files,
            dirs = dirs,
            read = function(path)
                return files[path]
            end,
            open = function(path, mode)
                if io_adapter.fail_open then
                    return nil, "injected open failure"
                end
                if mode == "w" then
                    return { path = path, buffer = {} }
                end
                return nil, "unsupported mode"
            end,
            write = function(handle, str)
                if io_adapter.fail_write then
                    error("injected write failure")
                end
                table.insert(handle.buffer, str)
                return true
            end,
            flush = function()
                return true
            end,
            sync_file = function()
                if io_adapter.fail_sync then
                    return false, "injected sync failure"
                end
                return true
            end,
            close = function(handle)
                files[handle.path] = table.concat(handle.buffer)
                return true
            end,
            rename = function(old_path, new_path)
                if io_adapter.fail_rename then
                    return nil, "injected rename failure"
                end
                local content = files[old_path]
                if not content then
                    return nil, "source file not found"
                end
                files[new_path] = content
                files[old_path] = nil
                return true
            end,
            remove = function(path)
                files[path] = nil
                return true
            end,
            sync_dir = function()
                if io_adapter.fail_sync_dir then
                    return false, "injected sync dir failure"
                end
                return true
            end,
            dir_exists = function(path)
                return dirs[path] == true
            end,
            mkdir = function(path)
                dirs[path] = true
                return true
            end,
        }

        SettingsStore = require("suwayomi/settings/store")
        SuwayomiSettings = require("suwayomi/settings")
        DownloadQueue = require("suwayomi/downloads/queue")

        local store = SettingsStore:new({
            path = settings_path,
            io = io_adapter,
            luasettings = SuwayomiSettings:open(),
        })
        SuwayomiSettings:setStore(store)
    end)

    after_each(function()
        package.preload.datastorage = nil
        package.preload.luasettings = nil
    end)

    it("restores failed chapter status alongside Downloads after a cold restart", function()
        local manga = { id = "m1", title = "Example" }
        local chapter = { id = "c1", name = "One" }
        assert(SuwayomiSettings:saveDownloadQueue({ {
            key = "m1:c1", state = "failed", download_directory = "/books",
            manga = manga, chapter = chapter,
            progress = { state = "failed", error = "No address associated with hostname" },
        } }))
        SuwayomiSettings:setStore(SettingsStore:new({
            path = settings_path, io = io_adapter, luasettings = SuwayomiSettings:open(),
        }))
        local queue = DownloadQueue:new{
            settings = SuwayomiSettings,
            ui_manager = { scheduleIn = function() end },
        }
        assert(queue:recover())
        local status = queue:getStatus(manga, chapter)
        assert.is_not_nil(status)
        assert.are.equal("failed", status.state)
        assert.are.equal("Failed", queue:formatChapterMenuStatus(chapter, status))
        assert.are.equal("failed", queue:getSnapshot().failed[1].state)
    end)

    it("reports failure on preference save when write fails, and does not leak rejected mutation to next save", function()
        -- Initial state
        assert.is_false(SuwayomiSettings:loadBrowseSettings().show_nsfw_sources)

        -- Inject failure during write
        io_adapter.fail_write = true
        local saved, err = SuwayomiSettings:saveBrowseSettings({ show_nsfw_sources = true })
        assert.is_nil(saved)
        assert.is_truthy(err)

        -- Memory cache must not have changed to the rejected value
        assert.is_false(SuwayomiSettings:loadBrowseSettings().show_nsfw_sources)

        -- Clear injected failure
        io_adapter.fail_write = false

        -- Now make an unrelated preference save (e.g. max_parallel_chapter_downloads)
        local parallel_saved = SuwayomiSettings:saveMaxParallelChapterDownloads(3)
        assert.are.equal(3, parallel_saved)

        -- Verify browse settings STILL did not leak show_nsfw_sources = true
        assert.is_false(SuwayomiSettings:loadBrowseSettings().show_nsfw_sources)
        assert.are.equal(3, SuwayomiSettings:loadMaxParallelChapterDownloads())
    end)

    local function build_test_queue()
        return DownloadQueue:new({
            settings = SuwayomiSettings,
            ui_manager = {
                scheduleIn = function(_, _delay, _callback)
                    -- in tests, do not immediately process
                end,
            },
        })
    end

    it("keeps startup failure terminal in storage and every subscriber snapshot", function()
        local queue = build_test_queue()
        local launches = 0
        local snapshot
        queue.onStatusChanged = function() snapshot = queue:getSnapshot() end
        queue.ffi_util = {
            runInSubProcess = function() launches = launches + 1; return nil, "fork failed" end,
            isSubProcessDone = function() return true end,
        }
        assert.is_true(queue:enqueue({ id = "m1" }, { id = "c1" }, "."))
        queue:process()
        assert.are.equal(0, #queue:getSnapshot().queued)
        assert.are.equal(1, #queue:getSnapshot().failed)
        assert.are.same(queue:getSnapshot(), snapshot)
        queue:process()
        assert.are.equal(1, launches)
        assert.are.equal("failed", SuwayomiSettings:loadDownloadQueue()[1].state)
    end)

    it("retries rejected startup failure bookkeeping without launching another worker", function()
        local queue = build_test_queue()
        local launches = 0
        queue.ffi_util = {
            runInSubProcess = function()
                launches = launches + 1
                io_adapter.fail_write = true
                return nil, "fork failed"
            end,
            isSubProcessDone = function() return true end,
        }
        assert.is_true(queue:enqueue({ id = "m1" }, { id = "c1" }, "."))
        queue:process()
        assert.are.equal(0, #queue:getSnapshot().failed)
        assert.are.equal("downloading", SuwayomiSettings:loadDownloadQueue()[1].state)
        io_adapter.fail_write = false
        queue:process()
        assert.are.equal(1, launches)
        assert.are.equal(0, #queue:getSnapshot().queued)
        assert.are.equal(1, #queue:getSnapshot().failed)
    end)

    it("retains retryable worker failure after a rejected retry save until polling commits the retry", function()
        local queue = build_test_queue()
        queue.now = function() return 100 end
        queue.ffi_util = {
            runInSubProcess = function() return 123 end,
            isSubProcessDone = function() return true end,
            terminateSubProcess = function() end,
        }
        local manga, chapter = { id = "m1" }, { id = "c1" }
        assert.is_true(queue:enqueue(manga, chapter, "."))
        queue:process()
        local path = queue:getActiveJob(queue:getKey(manga, chapter)).progress_path
        local ProgressFile = require("suwayomi/downloads/progress_file")
        ProgressFile.writeFallback(path, "failed", 2, 10, nil, "network failure", true)
        local write = io_adapter.write
        io_adapter.write = function()
            io_adapter.write = write
            error("injected retry save failure")
        end
        queue:poll()
        local pending = queue:getSnapshot()
        local stored = SuwayomiSettings:loadDownloadQueue()
        os.remove(path)
        queue:poll()
        os.remove(path)
        assert.are.equal(1, #pending.active)
        assert.are.equal(0, #pending.failed)
        assert.are.equal("downloading", stored[1].state)
        local retry = SuwayomiSettings:loadDownloadQueue()[1]
        assert.are.equal("queued", retry.state)
        assert.are.equal(1, retry.retry_count)
        assert.is_true(retry.retry_at > 100)
        assert.are.equal(1, #queue:getSnapshot().queued)
    end)

    it("reconstructs committed enqueue and launch intent without duplicating owned workers", function()
        local queue = build_test_queue()
        local launches = 0
        queue.ffi_util = {
            runInSubProcess = function() launches = launches + 1; return launches end,
            isSubProcessDone = function() return false end,
        }
        local manga, chapter = { id = "m1" }, { id = "c1" }
        io_adapter.fail_sync_dir = true
        assert.is_false(queue:enqueue(manga, chapter, "."))
        io_adapter.fail_sync_dir = false
        assert.is_true(queue:reconcile())
        assert.are.equal(1, #queue:getSnapshot().queued)
        io_adapter.fail_sync_dir = true
        queue:process()
        assert.are.equal(0, launches)
        io_adapter.fail_sync_dir = false
        assert.is_true(queue:reconcile())
        queue:process()
        assert.are.equal(1, launches)
        assert.are.equal(1, #queue:getSnapshot().active)
        assert.is_true(queue:reconcile())
        queue:process()
        assert.are.equal(1, launches)
        assert.are.equal(0, #queue:getSnapshot().queued)
    end)

    it("keeps rejected launch normalization out of the settings cache and later transactions", function()
        local queue = build_test_queue()
        local launches = 0
        queue.ffi_util = {
            runInSubProcess = function() launches = launches + 1; return launches end,
            isSubProcessDone = function() return false end,
        }
        assert.is_true(queue:enqueue({ id = "m1" }, { id = "c1" }, "."))
        io_adapter.fail_sync_dir = true
        queue:process()
        local committed_launch = io_adapter.files[settings_path]
        io_adapter.fail_sync_dir = false
        io_adapter.fail_write = true
        local reconciled, err = queue:reconcile()
        assert.is_false(reconciled)
        assert.is_truthy(err:match("write_failed"))
        assert.are.equal(committed_launch, io_adapter.files[settings_path])
        assert.are.equal("downloading", SuwayomiSettings:loadDownloadQueue()[1].state)
        assert.are.equal(0, launches)

        io_adapter.fail_write = false
        assert.are.equal(3, SuwayomiSettings:saveMaxParallelChapterDownloads(3))
        local stored = assert(loadstring(io_adapter.files[settings_path]))()
        assert.are.equal("downloading", stored.download_queue[1].state)
        assert.is_true(queue:reconcile())
        stored = assert(loadstring(io_adapter.files[settings_path]))()
        assert.are.equal("queued", stored.download_queue[1].state)
        assert.are.equal("queued", SuwayomiSettings:loadDownloadQueue()[1].state)
        queue:process()
        assert.are.equal(1, launches)
    end)

    it("reconciles committed retry intent while retiring only its previous worker", function()
        local queue = build_test_queue()
        local launches, terminated = 0, {}
        local current_time = 100
        queue.now = function() return current_time end
        queue.ffi_util = {
            runInSubProcess = function() launches = launches + 1; return launches end,
            isSubProcessDone = function() return true end,
            terminateSubProcess = function(pid) table.insert(terminated, pid) end,
        }
        local manga, chapter = { id = "m1" }, { id = "c1" }
        assert.is_true(queue:enqueue(manga, chapter, "."))
        queue:process()
        local path = queue:getActiveJob(queue:getKey(manga, chapter)).progress_path
        require("suwayomi/downloads/progress_file").writeFallback(path, "failed", 2, 10, nil, "network failure", true)
        io_adapter.fail_sync_dir = true
        queue:poll()
        assert.is_true(queue:isBlocked())
        assert.are.equal(1, #queue:getSnapshot().active)
        assert.are.equal(0, #terminated)
        io_adapter.fail_sync_dir = false
        assert.is_true(queue:reconcile())
        assert.are.same({}, terminated) -- The helper already confirmed this child exited.
        local retry = queue:getSnapshot().queued[1]
        assert.are.equal(1, retry.retry_count)
        queue:process()
        assert.are.equal(1, launches)
        current_time = retry.retry_at
        queue:process()
        assert.are.equal(2, launches)
        assert.are.equal(1, #queue:getSnapshot().active)
        os.remove(path)
    end)

    it("resumes consumed polling through scheduled reconciliation after storage becomes available", function()
        local queue = build_test_queue()
        local timers = {}
        queue.ui_manager.scheduleIn = function(_, _, callback) table.insert(timers, callback) end
        queue.ffi_util = {
            runInSubProcess = function() return 123 end,
            isSubProcessDone = function() return true end,
        }
        local manga, chapter = { id = "m1" }, { id = "c1" }
        assert.is_true(queue:enqueue(manga, chapter, "."))
        table.remove(timers, 1)()
        io_adapter.fail_sync_dir = true
        assert.is_nil(SuwayomiSettings:saveMaxParallelChapterDownloads(3))
        table.remove(timers, 1)()
        assert.are.equal(1, #queue:getSnapshot().active)
        io_adapter.fail_sync_dir = false
        for _ = 1, 5 do
            if #timers > 0 then table.remove(timers, 1)() end
        end
        assert.is_false(queue:isBlocked())
        assert.are.equal(0, #queue:getSnapshot().active)
        assert.are.equal(1, #queue:getSnapshot().failed)
    end)

    it("preserves interrupted recovery files and memory until recovery intent commits", function()
        local queue = build_test_queue()
        local manga, chapter = { id = "m1" }, { id = "c1" }
        assert.is_truthy(SuwayomiSettings:saveDownloadQueue({
            queue:buildPersistentJob(manga, chapter, ".", "downloading"),
        }))
        local path = os.tmpname()
        local ProgressFile = require("suwayomi/downloads/progress_file")
        ProgressFile.writeFallback(path, "downloading", 2, 10)
        io_adapter.fail_write = true
        local ok = queue:recover()
        local progress = ProgressFile.read(path)
        local snapshot = queue:getSnapshot()
        io_adapter.fail_write = false
        queue:recover()
        os.remove(path)
        assert.is_false(ok)
        assert.are.equal("downloading", progress and progress.state)
        assert.are.equal(0, #snapshot.queued)
        assert.are.equal(0, #queue:getSnapshot().failed)
        assert.are.equal(1, #queue:getSnapshot().queued)
        assert.are.equal("queued", SuwayomiSettings:loadDownloadQueue()[1].state)
    end)

    it("reports rejected single and capped batch download actions without claiming queued work", function()
        local queue = build_test_queue()
        local messages, cleared = {}, false
        local plugin = {
            max_batch_queue_chapters = 1,
            loadMangaScanlatorFilter = function() return nil end,
            getDownloadQueue = function() return queue end,
            getDownloadDirectoryOrChoose = function() return "." end,
            isChapterDownloaded = function() return false end,
            withChapterMenuRefreshSuppressed = function(_, callback) callback() end,
            refreshChapterMenu = function() end,
            clearChapterSelection = function() cleared = true end,
            showMessage = function(_, message) table.insert(messages, message) end,
            showBulkActionConfirmation = function(_, _, _, callback) return callback() end,
        }
        for name, method in pairs(require("suwayomi/chapters/actions").methods) do
            if plugin[name] == nil then plugin[name] = method end
        end
        io_adapter.fail_write = true
        local ok, single_err = plugin:performChapterAction({ id = "m1" }, { id = "c1" }, "download")
        assert.is_false(ok)
        assert.is_truthy(single_err:match("write_failed"))
        local count, batch_err = plugin:enqueueSelectedChapterDownloads({ id = "m1" }, {
            { id = "c1" }, { id = "c2" },
        }, ".")
        assert.are.equal(0, count)
        assert.is_truthy(batch_err:match("write_failed"))
        assert.are.equal(2, #messages)
        assert.is_truthy(messages[1]:find(single_err, 1, true))
        assert.is_false(cleared)
        assert.are.equal(0, #queue:getSnapshot().queued)
    end)


    it("DownloadQueue:enqueue returns false, save_failed and does not modify in-memory items or statuses on failure", function()
        local queue = build_test_queue()

        local manga = { id = "m1", title = "Manga 1" }
        local chapter = { id = "c1", name = "Chapter 1" }

        -- Inject failure during rename
        io_adapter.fail_rename = true
        local ok, status = queue:enqueue(manga, chapter, "/sdcard/manga")
        assert.is_false(ok)
        assert.is_truthy(status and status:match("replacement_failed"))

        -- In-memory queue must remain empty, status must remain nil
        assert.are.equal(0, #queue.items)
        assert.is_nil(queue:getStatus(manga, chapter))

        -- Unblock rename
        io_adapter.fail_rename = false

        -- Next enqueue succeeds cleanly
        local ok2, status2 = queue:enqueue(manga, chapter, "/sdcard/manga")
        assert.is_true(ok2)
        assert.are.equal("queued", status2)
        assert.are.equal(1, #queue.items)
        assert.are.equal("queued", queue:getStatus(manga, chapter).state)
    end)

    it("DownloadQueue:enqueueBatch returns 0, err and rolls back candidates on failure", function()
        local queue = build_test_queue()

        local manga = { id = "m1", title = "Manga 1" }
        local chapters = {
            { id = "c1", name = "Chapter 1" },
            { id = "c2", name = "Chapter 2" },
        }

        io_adapter.fail_write = true
        local count, err = queue:enqueueBatch(manga, chapters, "/sdcard/manga")
        assert.are.equal(0, count)
        assert.is_truthy(err and err:match("write_failed"))

        -- Items and statuses must not be populated
        assert.are.equal(0, #queue.items)
        assert.is_nil(queue:getStatus(manga, chapters[1]))
        assert.is_nil(queue:getStatus(manga, chapters[2]))

        -- After clearing failure, normal batch works
        io_adapter.fail_write = false
        local count2 = queue:enqueueBatch(manga, chapters, "/sdcard/manga")
        assert.are.equal(2, count2)
        assert.are.equal(2, #queue.items)
    end)

    it("DownloadQueue:cancelPending does not remove job if save fails", function()
        local queue = build_test_queue()

        local manga = { id = "m1", title = "Manga 1" }
        local chapter = { id = "c1", name = "Chapter 1" }

        -- Enqueue successfully
        local ok = queue:enqueue(manga, chapter, "/sdcard/manga")
        assert.is_true(ok)
        assert.are.equal(1, #queue.items)

        -- Inject failure on cancel
        io_adapter.fail_rename = true
        local cancelled, err = queue:cancelPending(manga, chapter)
        assert.is_false(cancelled)
        assert.is_truthy(err and err:match("replacement_failed"))

        -- Job must remain in queue
        assert.are.equal(1, #queue.items)
        assert.is_not_nil(queue:getStatus(manga, chapter))

        -- Unblock failure and cancel succeeds
        io_adapter.fail_rename = false
        local cancelled2, state = queue:cancelPending(manga, chapter)
        assert.is_true(cancelled2)
        assert.are.equal("queued", state)
        assert.are.equal(0, #queue.items)
        assert.is_nil(queue:getStatus(manga, chapter))
    end)

    it("DownloadQueue:clearFailed does not wipe in-memory statuses if save fails", function()
        local queue = build_test_queue()

        local manga = { id = "m1", title = "Manga 1" }
        local chapter = { id = "c1", name = "Chapter 1" }
        local key = queue:getKey(manga, chapter)

        -- Set a failed job in persistent store
        SuwayomiSettings:saveDownloadQueue({
            {
                key = key,
                manga = manga,
                chapter = chapter,
                state = "failed",
                download_directory = "/sdcard/manga",
            },
        })
        queue.statuses[key] = { state = "failed" }

        -- Fail write
        io_adapter.fail_write = true
        local cleared, err = queue:clearFailed()
        assert.are.equal(0, cleared)
        assert.is_truthy(err and err:match("write_failed"))

        -- Status must still be failed
        assert.are.equal("failed", queue:getStatus(manga, chapter).state)

        -- Restore and clear succeeds
        io_adapter.fail_write = false
        local cleared2 = queue:clearFailed()
        assert.are.equal(1, cleared2)
        assert.is_nil(queue:getStatus(manga, chapter))
    end)

    it("saveDocument updates luasettings cache without calling luasettings:flush()", function()
        local luasettings_flushed = false
        local custom_luasettings = {
            data = {},
            flush = function()
                luasettings_flushed = true
            end,
        }
        local store = SettingsStore:new({
            path = settings_path,
            io = io_adapter,
            luasettings = custom_luasettings,
        })
        local ok = store:saveKey("foo", "bar")
        assert.is_true(ok)
        assert.are.equal("bar", custom_luasettings.data.foo)
        assert.is_false(luasettings_flushed)
    end)

    it("returns checked failure when settings directory is unavailable and does not update committed data", function()
        local missing_io = {
            dir_exists = function()
                return false
            end,
            read = function()
                return nil
            end,
            open = function()
                error("open should not be called")
            end,
        }
        local legacy_flushed = false
        local store = SettingsStore:new({
            path = "/nonexistent_dir/suwayomi.lua",
            io = missing_io,
            luasettings = {
                data = {},
                flush = function()
                    legacy_flushed = true
                end,
            },
        })
        local ok, err = store:saveKey("test", "val")
        assert.is_nil(ok)
        assert.are.equal("destination_directory_unavailable", err)
        assert.is_nil(store.committed_data.test)
        assert.is_false(legacy_flushed)
    end)

    it("rejected source-filter draft save does not leak into memory or later saves", function()
        local creds = { server_url = "http://suwayomi.test", auth_method = "basic_auth" }
        local initial_drafts = SuwayomiSettings:loadSourceFilterDraft(creds, "s1")
        assert.are.same({}, initial_drafts.filters or {})

        io_adapter.fail_write = true
        local saved, err = SuwayomiSettings:saveSourceFilterDraft(creds, "s1", {
            query = "manga",
            filters = { { id = "f1", value = "v1" } },
        })
        assert.is_nil(saved)
        assert.is_truthy(err)

        local after_fail = SuwayomiSettings:loadSourceFilterDraft(creds, "s1")
        assert.are.same({}, after_fail.filters or {})

        io_adapter.fail_write = false
        SuwayomiSettings:saveMaxParallelChapterDownloads(4)

        local final_draft = SuwayomiSettings:loadSourceFilterDraft(creds, "s1")
        assert.are.same({}, final_draft.filters or {})
    end)

    it("active cancellation reports failure, preserves worker, and leaves files and status intact on save failure", function()
        local queue = build_test_queue()
        local terminated_pids = {}
        queue.ffi_util = {
            runInSubProcess = function() return 999 end,
            isSubProcessDone = function() return false end,
            terminateSubProcess = function(pid) terminated_pids[pid] = true end,
        }

        local manga = { id = "m1", title = "Manga 1" }
        local chapter = { id = "c1", name = "Chapter 1" }
        queue:enqueue(manga, chapter, "/sdcard/manga")

        local item = table.remove(queue.items, 1)
        local started = queue.active_job_lifecycle:startQueuedJob(item)
        assert.is_true(started)
        assert.are.equal("downloading", queue:getStatus(manga, chapter).state)

        io_adapter.fail_rename = true
        local ok, err = queue:cancelPending(manga, chapter)
        assert.is_false(ok)
        assert.is_truthy(err and err:match("replacement_failed"))

        assert.is_nil(terminated_pids[999])
        assert.is_not_nil(queue:getActiveJob(queue:getKey(manga, chapter)))
        assert.are.equal("downloading", queue:getStatus(manga, chapter).state)

        io_adapter.fail_rename = false
        local ok2, state2 = queue:cancelPending(manga, chapter)
        assert.is_true(ok2)
        assert.are.equal("downloading", state2)
        assert.is_true(terminated_pids[999])
        assert.is_nil(queue:getActiveJob(queue:getKey(manga, chapter)))
        assert.is_nil(queue:getStatus(manga, chapter))
    end)

    it("ambiguity fence blocks queue processing, workers, and destructive operations until reconciled", function()
        local queue = build_test_queue()
        local launched = false
        queue.ffi_util = {
            runInSubProcess = function() launched = true; return 100 end,
            isSubProcessDone = function() return false end,
        }

        local manga = { id = "m1", title = "Manga 1" }
        local chapter = { id = "c1", name = "Chapter 1" }
        queue:enqueue(manga, chapter, "/sdcard/manga")
        assert.are.equal(1, #queue.items)

        io_adapter.fail_sync_dir = true
        local saved, err = SuwayomiSettings:saveMaxParallelChapterDownloads(3)
        assert.is_nil(saved)
        assert.is_truthy(err and err:match("ambiguous"))
        assert.is_true(SuwayomiSettings:isBlocked())
        assert.is_true(queue:isBlocked())

        queue:process()
        assert.is_false(launched)
        assert.are.equal(1, #queue.items)

        local cancel_ok = queue:cancelPending(manga, chapter)
        assert.is_false(cancel_ok)
        assert.are.equal(1, #queue.items)

        io_adapter.fail_sync_dir = false
        local reconciled = queue:reconcile()
        assert.is_true(reconciled)
        assert.is_false(queue:isBlocked())

        queue:process()
        assert.is_true(launched)
    end)

    it("preserves current filter and selection when scanlator filter save fails", function()
        local ChaptersContext = require("suwayomi/chapters/context")
        local context_obj = {
            current_scanlator_filter = "OriginalScanlator",
            current_chapter_context = {
                manga = { id = "m1", title = "Manga 1" },
            },
            selection_cleared = false,
            menu_refreshed = false,
            messages = {},
        }
        for k, v in pairs(ChaptersContext.methods) do
            context_obj[k] = v
        end
        context_obj.clearChapterSelection = function(self) self.selection_cleared = true end
        context_obj.refreshChapterMenu = function(self) self.menu_refreshed = true end
        context_obj.showMessage = function(self, msg) table.insert(self.messages, msg) end

        io_adapter.fail_write = true
        local ok, err = context_obj:setScanlatorFilter("NewScanlator")
        assert.is_false(ok)
        assert.is_truthy(err)
        assert.are.equal("OriginalScanlator", context_obj.current_scanlator_filter)
        assert.is_false(context_obj.selection_cleared)
        assert.is_false(context_obj.menu_refreshed)
        assert.are.equal(1, #context_obj.messages)

        io_adapter.fail_write = false
        local ok2 = context_obj:setScanlatorFilter("NewScanlator")
        assert.is_true(ok2)
        assert.are.equal("NewScanlator", context_obj.current_scanlator_filter)
        assert.is_true(context_obj.selection_cleared)
        assert.is_true(context_obj.menu_refreshed)
    end)

    it("defaultIoAdapter checked synchronization propagates inner flush failure and fails on nonexistent directory", function()
        local default_io = SettingsStore:new().io
        local failing_handle = {
            flush = function()
                return nil, "injected_flush_error"
            end,
        }
        local sync_ok, sync_err = default_io.sync_file(failing_handle, "/any/path")
        assert.is_nil(sync_ok)
        assert.are.equal("injected_flush_error", sync_err)

        local dir_ok, dir_err = default_io.sync_dir("/nonexistent/sync/dir/12345")
        assert.is_nil(dir_ok)
        assert.is_truthy(dir_err)
    end)

    it("defaultIoAdapter Windows replacement preserves existing destination when rename fails", function()
        local default_io = SettingsStore:new().io
        local ok_lfs, lfs = pcall(require, "lfs")
        local base = (ok_lfs and lfs and lfs.currentdir()) or "."
        local test_dst = base:gsub("\\", "/") .. "/.test_dst_" .. os.time() .. ".lua"
        local f = io.open(test_dst, "w")
        f:write("destination_committed_data")
        f:close()

        local ren_ok, ren_err = default_io.rename(base:gsub("\\", "/") .. "/nonexistent_src_probe.tmp", test_dst)
        assert.is_nil(ren_ok)
        assert.is_truthy(ren_err)

        local f_check = io.open(test_dst, "r")
        assert.is_not_nil(f_check)
        local content = f_check:read("*a")
        f_check:close()
        os.remove(test_dst)
        assert.are.equal("destination_committed_data", content)
    end)

    it("reports failure and does not queue downloads when download-ahead preference save fails", function()
        local DownloadsController = require("suwayomi/downloads/controller")
        local manga = { id = "m1", title = "Manga 1" }
        local queued_count = 0
        local messages = {}
        local controller = {
            current_chapter_context = {
                manga = manga,
            },
            getDownloadDirectoryOrChoose = function(_, _cb)
                return "/sdcard/manga"
            end,
            enqueueSelectedChapterDownloads = function(_, _m, chs)
                queued_count = #chs
                return queued_count
            end,
            showMessage = function(_, msg)
                table.insert(messages, msg)
            end,
        }
        for k, v in pairs(DownloadsController.methods) do
            controller[k] = v
        end
        controller.getUnreadDownloadBufferCandidates = function()
            return { { id = "c1", name = "Chapter 1" } }
        end

        io_adapter.fail_write = true
        local res = controller:keepNextUnreadChaptersDownloaded(5)
        assert.are.equal(0, res)
        assert.are.equal(0, queued_count)
        assert.are.equal(1, #messages)

        io_adapter.fail_write = false
        local res2 = controller:keepNextUnreadChaptersDownloaded(5)
        assert.are.equal(1, res2)
        assert.are.equal(1, queued_count)
    end)

    it("MangaController reports failure when download-ahead preference save fails", function()
        local MangaController = require("suwayomi/manga/controller")
        local manga = { id = "m1", title = "Manga 1" }
        local messages = {}
        local controller = {
            showMessage = function(_, msg)
                table.insert(messages, msg)
            end,
        }
        for k, v in pairs(MangaController.methods) do
            controller[k] = v
        end

        io_adapter.fail_write = true
        local ok = controller:performMangaAction(manga, "keep_next_0_unread")
        assert.is_false(ok)
        assert.are.equal(1, #messages)

        io_adapter.fail_write = false
        local ok2 = controller:performMangaAction(manga, "keep_next_0_unread")
        assert.is_true(ok2)
    end)

    it("reader-return context mutation does not leak into memory or later saves when save fails", function()
        local ReaderReturn = require("suwayomi/reader_return")
        local rr = {}
        for k, v in pairs(ReaderReturn.methods) do
            rr[k] = v
        end
        local manga = { id = "m1", title = "Manga 1" }
        local chapter = { id = "c1", name = "Chapter 1" }
        local chapter_path = "/sdcard/manga/m1/c1.cbz"

        assert.are.same({}, SuwayomiSettings:loadReaderReturnContexts())

        io_adapter.fail_write = true
        local saved_ctx, err = rr:saveReaderReturnContext(manga, chapter, chapter_path)
        assert.is_nil(saved_ctx)
        assert.is_truthy(err)

        -- Cached contexts must still be empty
        assert.are.same({}, SuwayomiSettings:loadReaderReturnContexts())

        io_adapter.fail_write = false
        -- Unrelated preference save
        SuwayomiSettings:saveMaxParallelChapterDownloads(3)

        -- Stored file must not contain the rejected reader return context
        assert.are.same({}, SuwayomiSettings:loadReaderReturnContexts())
    end)

    it("ActiveJobs does not launch worker and preserves queued item when upsertPersistentJob fails", function()
        local queue = build_test_queue()
        local launched = false
        queue.ffi_util = {
            runInSubProcess = function() launched = true; return 100 end,
            isSubProcessDone = function() return false end,
        }
        local manga = { id = "m1", title = "Manga 1" }
        local chapter = { id = "c1", name = "Chapter 1" }
        queue:enqueue(manga, chapter, "/sdcard/manga")
        assert.are.equal(1, #queue.items)

        io_adapter.fail_sync_dir = true
        queue:process()

        assert.is_false(launched)
        assert.are.equal(1, #queue.items)
        assert.is_true(queue:isBlocked())
    end)

    it("queue:poll() does not remove progress file or finalize job when storage is blocked", function()
        local queue = build_test_queue()
        queue.ffi_util = {
            runInSubProcess = function() return 200 end,
            isSubProcessDone = function() return true end,
        }
        local manga = { id = "m1", title = "Manga 1" }
        local chapter = { id = "c1", name = "Chapter 1" }
        local test_dir = "."
        queue:enqueue(manga, chapter, test_dir)
        queue:process()

        local key = queue:getKey(manga, chapter)
        local active = queue:getActiveJob(key)
        assert.is_not_nil(active)

        local ProgressFile = require("suwayomi/downloads/progress_file")
        ProgressFile.writeFallback(active.progress_path, "downloaded", 10, 10, "./c1.cbz")
        queue.getExistingArchivePath = function() return "./c1.cbz" end

        io_adapter.fail_sync_dir = true
        SuwayomiSettings:saveMaxParallelChapterDownloads(3)
        assert.is_true(queue:isBlocked())

        queue:poll()

        assert.is_not_nil(queue:getActiveJob(key))
        local f = io.open(active.progress_path, "r")
        assert.is_not_nil(f)
        if f then f:close() end

        os.remove(active.progress_path)
        os.remove(active.progress_path .. ".tmp")
    end)

    it("deleteChapterFromDeviceWithOptions returns false, store_blocked and preserves files when storage is ambiguous", function()
        local ChapterDeleteActions = require("suwayomi/chapters/delete_actions")
        local queue = build_test_queue()
        local deleted_archive = false
        local messages = {}
        local actions_obj = {
            getDownloadQueue = function() return queue end,
            showMessage = function(_, msg) table.insert(messages, msg) end,
            isChapterDownloaded = function() return true, "/sdcard/manga/m1/c1.cbz" end,
            getKoreaderMetadataPathForDocument = function() return "/sdcard/manga/m1/c1.sdr" end,
            removeChapterArchiveAndSidecars = function() deleted_archive = true; return true end,
        }
        for k, v in pairs(ChapterDeleteActions.methods) do
            actions_obj[k] = v
        end

        local manga = { id = "m1", title = "Manga 1" }
        local chapter = { id = "c1", name = "Chapter 1" }

        io_adapter.fail_sync_dir = true
        SuwayomiSettings:saveMaxParallelChapterDownloads(3)
        assert.is_true(queue:isBlocked())

        local ok, err = actions_obj:deleteChapterFromDeviceWithOptions(manga, chapter)
        assert.is_false(ok)
        assert.are.equal("store_blocked", err)
        assert.is_false(deleted_archive)
        assert.are.equal(1, #messages)
    end)

    it("DownloadQueue:reconcile removes in-memory queued and active jobs that are not in committed storage", function()
        local queue = build_test_queue()
        local manga = { id = "m1", title = "Manga 1" }
        local chapter = { id = "c1", name = "Chapter 1" }
        queue:enqueue(manga, chapter, "/sdcard/manga")
        assert.are.equal(1, #queue.items)

        io_adapter.fail_sync_dir = true
        local ok_cancel, err_cancel = queue:cancelPending(manga, chapter)
        assert.is_false(ok_cancel)
        assert.is_truthy(err_cancel and err_cancel:match("ambiguous"))
        assert.are.equal(1, #queue.items)
        assert.is_true(queue:isBlocked())

        io_adapter.fail_sync_dir = false
        local ok, res = queue:reconcile()
        assert.is_true(ok)
        assert.are.equal("committed", res)
        assert.are.equal(0, #queue.items)
        assert.is_nil(queue:getStatus(manga, chapter))
    end)

    it("cancelAll returns partial count and error, and controller displays error message", function()
        local DownloadsController = require("suwayomi/downloads/controller")
        local SuwayomiUI = require("suwayomi/ui")
        local queue = build_test_queue()
        local manga1 = { id = "m1", title = "Manga 1" }
        local chapter1 = { id = "c1", name = "Chapter 1" }
        local manga2 = { id = "m2", title = "Manga 2" }
        local chapter2 = { id = "c2", name = "Chapter 2" }

        queue:enqueue(manga1, chapter1, "/sdcard/manga")
        queue:enqueue(manga2, chapter2, "/sdcard/manga")

        queue.ffi_util = {
            runInSubProcess = function() return 301 end,
            isSubProcessDone = function() return false end,
            terminateSubProcess = function() end,
        }
        local item1 = table.remove(queue.items, 1)
        queue.active_job_lifecycle:startQueuedJob(item1)
        assert.are.equal(1, queue:getActiveCount())
        assert.are.equal(1, #queue.items)

        queue.active_job_lifecycle.finishWithCancel = function()
            return false, "active_cancel_failed"
        end

        local total, err = queue:cancelAll()
        assert.are.equal(1, total)
        assert.are.equal("active_cancel_failed", err)

        local messages = {}
        local controller = {}
        for k, v in pairs(DownloadsController.methods) do
            controller[k] = v
        end
        controller.getDownloadQueue = function() return queue end
        controller.showMessage = function(_, msg) table.insert(messages, msg) end
        controller.closeMenu = function() end
        controller.showDownloads = function() end

        local orig_confirm = SuwayomiUI.showConfirm
        SuwayomiUI.showConfirm = function(opts)
            if opts and opts.ok_callback then
                opts.ok_callback()
            end
        end

        controller:performDownloadsTitleAction({ id = "cancel_all" })
        SuwayomiUI.showConfirm = orig_confirm
        assert.are.equal(1, #messages)
        assert.are.equal("active_cancel_failed", messages[1])
    end)
end)
