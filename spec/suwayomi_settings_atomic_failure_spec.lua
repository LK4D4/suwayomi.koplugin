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
end)
