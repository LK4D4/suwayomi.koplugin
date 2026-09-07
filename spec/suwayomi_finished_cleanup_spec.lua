package.path = "?.lua;" .. package.path

describe("suwayomi/chapters/finished_cleanup", function()
    local function clone(value)
        if type(value) ~= "table" then
            return value
        end
        local result = {}
        for key, item in pairs(value) do
            result[clone(key)] = clone(item)
        end
        return result
    end

    local function installModule(state)
        for _, name in ipairs({
            "suwayomi/chapters/finished_cleanup",
            "suwayomi/settings",
            "suwayomi/debug",
            "suwayomi/i18n",
            "ui/uimanager",
            "ffi/util",
        }) do
            package.loaded[name] = nil
        end

        local settings = {
            loadDeleteChaptersSettings = function()
                return { delete_finished_while_reading = state.setting }
            end,
            loadDownloadDirectory = function()
                return state.download_directory
            end,
            loadFinishedChapterCleanupJournal = function()
                return clone(state.journal), state.journal_error
            end,
            saveFinishedChapterCleanupJournal = function(_, journal)
                state.save_count = state.save_count + 1
                state.journal = clone(journal)
                return clone(journal)
            end,
            clearFinishedChapterCleanupJournal = function()
                state.save_count = state.save_count + 1
                state.journal = { version = 1, next_sequence = 1, mangas = {} }
                return clone(state.journal)
            end,
        }
        local ui_manager = {
            scheduleIn = function(_, delay, callback)
                table.insert(state.scheduled, { delay = delay, callback = callback })
            end,
        }

        package.preload["suwayomi/settings"] = function()
            return settings
        end
        package.preload["ui/uimanager"] = function()
            return ui_manager
        end
        package.preload["suwayomi/debug"] = function()
            return {
                now = function()
                    return state.now
                end,
                log = function(event)
                    table.insert(state.debug_events, clone(event))
                end,
            }
        end
        package.preload["suwayomi/i18n"] = function()
            return {
                f = function(message, value)
                    return message:gsub("%%1", tostring(value))
                end,
                t = function(message)
                    return message
                end,
            }
        end
        package.preload["ffi/util"] = function()
            return {
                realpath = function(path)
                    table.insert(state.realpath_calls, path)
                    if state.realpaths[path] ~= nil then
                        return state.realpaths[path] or nil
                    end
                    return path
                end,
            }
        end

        return require("suwayomi/chapters/finished_cleanup")
    end

    local function buildPlugin(options)
        options = options or {}
        local state = {
            setting = options.setting == nil and 1 or options.setting,
            download_directory = options.download_directory or "/downloads",
            journal = clone(options.journal or { version = 1, next_sequence = 1, mangas = {} }),
            journal_error = options.journal_error,
            save_count = 0,
            scheduled = {},
            now = options.now or 100,
            debug_events = {},
            realpaths = options.realpaths or {},
            realpath_calls = {},
        }
        local module = installModule(state)
        local queue_status = options.queue_status or {}
        local queue = {
            getStatus = function(_, manga, chapter)
                return queue_status[tostring(manga.id) .. ":" .. tostring(chapter.id)]
            end,
        }
        local plugin = {
            state = state,
            queue_status = queue_status,
            ledger = clone(options.ledger or {}),
            existing = clone(options.existing or {}),
            delete_state = options.delete_state or "deleted",
            delete_states = options.delete_states or {},
            delete_calls = {},
            saved_ledgers = {},
            messages = {},
            current_document = options.current_document,
            finished_cleanup_batch_size = options.batch_size,
            getDownloadQueue = function()
                return queue
            end,
            loadChapterLedger = function(self)
                return clone(self.ledger)
            end,
            saveChapterLedger = function(self, ledger)
                self.ledger = clone(ledger)
                table.insert(self.saved_ledgers, clone(ledger))
                return ledger
            end,
            getCurrentReaderDocumentPath = function(self)
                return self.current_document
            end,
            chapterArchiveExists = function(self, path)
                return self.existing[path] == true
            end,
            deleteChapterFromDeviceWithOptions = function(self, manga, chapter, delete_options)
                table.insert(self.delete_calls, {
                    manga = clone(manga), chapter = clone(chapter), options = delete_options,
                })
                local key = tostring(manga.id) .. ":" .. tostring(chapter.id)
                local result = self.delete_states[key] or self.delete_state
                if options.on_delete then
                    options.on_delete(self, manga, chapter, delete_options)
                end
                if result == "deleted" then
                    self.existing[chapter.path] = nil
                    for ledger_key, entry in pairs(delete_options.ledger or {}) do
                        if tostring(entry.manga_id) == tostring(manga.id)
                            and tostring(entry.chapter_id) == tostring(chapter.id)
                        then
                            entry.path = nil
                            if entry.read ~= true and entry.pending_read_sync ~= true then
                                delete_options.ledger[ledger_key] = nil
                            end
                        end
                    end
                end
                return result == "deleted", result
            end,
            showMessage = function(self, message)
                table.insert(self.messages, message)
            end,
        }
        for name, method in pairs(module.methods) do
            plugin[name] = method
        end
        return plugin
    end

    local function journalRecord(plugin, manga_id, chapter_id)
        local manga = plugin.state.journal.mangas[tostring(manga_id)]
        if not manga then
            return nil
        end
        for _, entry in ipairs(manga.records or {}) do
            if entry.chapter_id == tostring(chapter_id) then
                return entry
            end
        end
        return nil
    end

    local function retainedCount(plugin, manga_id)
        local manga = plugin.state.journal.mangas[tostring(manga_id)]
        return manga and #(manga.records or {}) or 0
    end

    local function record(plugin, manga_id, chapter_id, path, options)
        options = options or {}
        local key = tostring(manga_id) .. ":" .. tostring(chapter_id)
        local entry = {
            manga_id = tostring(manga_id),
            chapter_id = tostring(chapter_id),
            path = path,
            read = options.read ~= false,
        }
        plugin.ledger[key] = clone(entry)
        if options.exists ~= false then
            plugin.existing[path] = true
        end
        return plugin:recordFinishedChapter(entry)
    end

    after_each(function()
        package.preload["suwayomi/settings"] = nil
        package.preload["ui/uimanager"] = nil
        package.preload["suwayomi/debug"] = nil
        package.preload["suwayomi/i18n"] = nil
        package.preload["ffi/util"] = nil
    end)

    for setting = 1, 5 do
        it("retains " .. tostring(setting - 1) .. " newest records for setting " .. tostring(setting), function()
            local plugin = buildPlugin({ setting = setting })
            record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
            record(plugin, "m1", "c2", "/downloads/source/manga/c2.cbz")
            record(plugin, "m1", "c3", "/downloads/source/manga/c3.cbz")
            record(plugin, "m1", "c4", "/downloads/source/manga/c4.cbz")
            record(plugin, "m1", "c5", "/downloads/source/manga/c5.cbz")
            plugin:processFinishedChapterCleanup()
            assert.are.equal(math.min(setting - 1, 5), retainedCount(plugin, "m1"))
        end)
    end

    it("records completion durably and schedules cleanup without deleting inline", function()
        local plugin = buildPlugin({ setting = 1 })
        assert.is_true(record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz"))
        assert.are.equal(1, plugin.state.save_count)
        assert.are.equal(1, #plugin.state.scheduled)
        assert.are.equal(0, #plugin.delete_calls)
    end)

    it("moves a reread chapter to newest without duplicating it", function()
        local plugin = buildPlugin({ setting = 3 })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        record(plugin, "m1", "c2", "/downloads/source/manga/c2.cbz")
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        assert.are.equal(2, retainedCount(plugin, "m1"))
        assert.are.equal(3, journalRecord(plugin, "m1", "c1").sequence)
    end)

    it("does not record unread gaps", function()
        local plugin = buildPlugin({ setting = 3 })
        assert.is_true(record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz"))
        assert.is_false(record(plugin, "m1", "c2", "/downloads/source/manga/c2.cbz", { read = false }))
        assert.is_true(record(plugin, "m1", "c3", "/downloads/source/manga/c3.cbz"))
        assert.is_nil(journalRecord(plugin, "m1", "c2"))
        plugin:processFinishedChapterCleanup()
        assert.are.equal(2, retainedCount(plugin, "m1"))
    end)

    it("keeps manga completion histories independent", function()
        local plugin = buildPlugin({ setting = 2 })
        record(plugin, "m1", "c1", "/downloads/source/m1/c1.cbz")
        record(plugin, "m2", "c1", "/downloads/source/m2/c1.cbz")
        record(plugin, "m1", "c2", "/downloads/source/m1/c2.cbz")
        plugin:processFinishedChapterCleanup()
        assert.are.equal(1, retainedCount(plugin, "m1"))
        assert.are.equal(1, retainedCount(plugin, "m2"))
    end)

    it("applies retention increases and decreases to current history", function()
        local plugin = buildPlugin({ setting = 5 })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        record(plugin, "m1", "c2", "/downloads/source/manga/c2.cbz")
        record(plugin, "m1", "c3", "/downloads/source/manga/c3.cbz")
        record(plugin, "m1", "c4", "/downloads/source/manga/c4.cbz")
        plugin.state.setting = 3
        plugin:onFinishedCleanupSettingChanged(5, 3)
        plugin:processFinishedChapterCleanup()
        assert.are.equal(2, retainedCount(plugin, "m1"))
        plugin.state.setting = 5
        plugin:onFinishedCleanupSettingChanged(3, 5)
        record(plugin, "m1", "c5", "/downloads/source/manga/c5.cbz")
        record(plugin, "m1", "c6", "/downloads/source/manga/c6.cbz")
        plugin:processFinishedChapterCleanup()
        assert.are.equal(4, retainedCount(plugin, "m1"))
    end)

    it("disabling cleanup clears history and invalidates scheduled callbacks", function()
        local plugin = buildPlugin({ setting = 2 })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        local callback = plugin.state.scheduled[1].callback
        plugin.state.setting = 0
        plugin:onFinishedCleanupSettingChanged(2, 0)
        assert.are.equal(0, retainedCount(plugin, "m1"))
        callback()
        assert.are.equal(0, #plugin.delete_calls)
    end)

    it("never passes an unmanaged path to deletion", function()
        local plugin = buildPlugin({ setting = 1, download_directory = "/downloads" })
        record(plugin, "m1", "c1", "/private/c1.cbz")
        local summary = plugin:processFinishedChapterCleanup()
        assert.are.equal(0, #plugin.delete_calls)
        assert.are.equal(1, summary.rejected)
        assert.are.equal("unsafe_path", journalRecord(plugin, "m1", "c1").blocked_reason)
    end)

    it("persists exponential retry state and resumes after restart", function()
        local first = buildPlugin({ setting = 1, now = 100, delete_state = "delete_failed" })
        record(first, "m1", "c1", "/downloads/source/manga/c1.cbz")
        first:processFinishedChapterCleanup()
        assert.are.equal(1, journalRecord(first, "m1", "c1").retry_count)
        assert.are.equal(105, journalRecord(first, "m1", "c1").retry_after)
        local restarted = buildPlugin({
            setting = 1,
            now = 105,
            journal = first.state.journal,
            ledger = first.ledger,
            existing = first.existing,
            delete_state = "deleted",
        })
        restarted:processFinishedChapterCleanup()
        assert.is_nil(journalRecord(restarted, "m1", "c1"))
    end)

    it("retries actual sidecar removal after restart before deleting the archive", function()
        local path = "/downloads/source/manga/c1.cbz"
        local metadata_path = "/settings/hash/ab/book.sdr/metadata.cbz.lua"
        local sidecars = { [metadata_path] = true, [metadata_path .. ".old"] = true }
        local fail_backup = true
        local plugin = buildPlugin({ setting = 1 })
        record(plugin, "m1", "c1", path)
        local old_remove = os.remove
        local old_delete = package.loaded["suwayomi/chapters/delete_actions"]
        local old_local = package.loaded["suwayomi/chapters/local_downloads"]
        package.loaded["suwayomi/chapters/delete_actions"] = nil
        package.loaded["suwayomi/chapters/local_downloads"] = nil
        local delete_methods = require("suwayomi/chapters/delete_actions").methods
        local local_methods = require("suwayomi/chapters/local_downloads").methods
        local function installBoundary(subject)
            subject.deleteChapterFromDeviceWithOptions = delete_methods.deleteChapterFromDeviceWithOptions
            subject.removeChapterArchiveAndSidecars = local_methods.removeChapterArchiveAndSidecars
            subject.getChapterLedgerKey = function() return "m1:c1" end
            subject.getKoreaderMetadataPathForDocument = function()
                -- Hash metadata must still be discoverable from the archive.
                assert.is_true(subject.existing[path])
                return metadata_path
            end
            subject.getDownloadQueue = function() return {
                getStatus = function() end, cancelPending = function() return false end,
                clearStatus = function() return true end,
            } end
        end
        os.remove = function(candidate)
            if candidate == metadata_path .. ".old" and fail_backup then
                return nil, "Permission denied", 13
            end
            if candidate == path then plugin.existing[path] = nil; return true end
            if sidecars[candidate] then sidecars[candidate] = nil; return true end
            return nil, "No such file or directory", 2
        end
        local ok, err = pcall(function()
            installBoundary(plugin)
            assert.are.equal(1, plugin:processFinishedChapterCleanup().retrying)
            assert.is_true(plugin.existing[path])
            assert.is_nil(sidecars[metadata_path])
            assert.is_true(sidecars[metadata_path .. ".old"])
            assert.are.equal(105, journalRecord(plugin, "m1", "c1").retry_after)
            plugin = buildPlugin({ setting = 1, now = 105,
                journal = plugin.state.journal, ledger = plugin.ledger, existing = plugin.existing })
            fail_backup = false
            installBoundary(plugin)
            assert.are.equal(1, plugin:processFinishedChapterCleanup().deleted)
            assert.is_nil(plugin.existing[path])
            assert.is_nil(sidecars[metadata_path .. ".old"])
            assert.is_nil(plugin.ledger["m1:c1"].path)
            assert.is_nil(journalRecord(plugin, "m1", "c1"))
        end)
        os.remove = old_remove
        package.loaded["suwayomi/chapters/delete_actions"] = old_delete
        package.loaded["suwayomi/chapters/local_downloads"] = old_local
        assert.is_true(ok, err)
    end)

    it("cancels cleanup intent when the ledger chapter becomes unread", function()
        local plugin = buildPlugin({ setting = 1 })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        plugin.ledger["m1:c1"].read = false
        local summary = plugin:processFinishedChapterCleanup()
        assert.are.equal(1, summary.cancelled)
        assert.is_nil(journalRecord(plugin, "m1", "c1"))
        assert.are.equal(0, #plugin.delete_calls)
    end)

    it("removes unread retained records before retrying older finished chapters", function()
        local plugin = buildPlugin({ setting = 3, delete_state = "delete_failed" })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        record(plugin, "m1", "c2", "/downloads/source/manga/c2.cbz")
        record(plugin, "m1", "c3", "/downloads/source/manga/c3.cbz")
        plugin:processFinishedChapterCleanup()
        -- Server reconciliation changes the ledger without the manual unread callback.
        plugin.ledger["m1:c3"].read = nil
        plugin.delete_state = "deleted"
        plugin.state.now = 105
        local summary = plugin:processFinishedChapterCleanup()
        assert.are.equal(1, summary.cancelled)
        assert.are.equal(0, summary.deleted)
        assert.are.equal(1, #plugin.delete_calls)
        assert.is_nil(journalRecord(plugin, "m1", "c3"))
        assert.is_not_nil(journalRecord(plugin, "m1", "c1"))
        assert.is_not_nil(journalRecord(plugin, "m1", "c2"))
    end)

    it("keeps archive inspection failures pending across restart", function()
        local path = "/downloads/source/manga/c1.cbz"
        local plugin = buildPlugin({ setting = 1 })
        record(plugin, "m1", "c1", path)
        plugin.chapterArchiveExists = function() return nil, "stat_failed" end
        local summary = plugin:processFinishedChapterCleanup()
        assert.are.equal(0, summary.missing)
        assert.are.equal(1, summary.retrying)
        assert.are.equal(path, plugin.ledger["m1:c1"].path)
        assert.are.equal(105, journalRecord(plugin, "m1", "c1").retry_after)
        local restarted = buildPlugin({ setting = 1, now = 105,
            journal = plugin.state.journal, ledger = plugin.ledger, existing = plugin.existing })
        assert.are.equal(1, restarted:processFinishedChapterCleanup().deleted)
    end)

    it("retries temporary realpath failures instead of permanently blocking the archive", function()
        local path = "/downloads/source/manga/c1.cbz"
        local plugin = buildPlugin({ setting = 1, realpaths = { [path] = false } })
        record(plugin, "m1", "c1", path)
        local summary = plugin:processFinishedChapterCleanup()
        assert.are.equal(1, summary.retrying)
        assert.are.equal(0, summary.rejected)
        assert.is_nil(journalRecord(plugin, "m1", "c1").blocked_reason)
        plugin.state.realpaths[path] = path
        plugin.state.now = 105
        assert.are.equal(1, plugin:processFinishedChapterCleanup().deleted)
    end)

    it("converges a missing archive and clears only its matching ledger path", function()
        local plugin = buildPlugin({ setting = 1 })
        record(plugin, "m1", "c1", "/private/missing.cbz", { exists = false })
        local summary = plugin:processFinishedChapterCleanup()
        assert.are.equal(1, summary.missing)
        assert.is_nil(journalRecord(plugin, "m1", "c1"))
        assert.is_nil(plugin.ledger["m1:c1"].path)
        assert.are.equal(0, #plugin.delete_calls)
    end)

    it("keeps a missing archive while it remains in the retention window", function()
        local plugin = buildPlugin({ setting = 2 })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz", { exists = false })
        local summary = plugin:processFinishedChapterCleanup()
        assert.are.equal(0, summary.missing)
        assert.is_not_nil(journalRecord(plugin, "m1", "c1"))
        assert.are.equal("/downloads/source/manga/c1.cbz", plugin.ledger["m1:c1"].path)
    end)

    it("rejects a journal and ledger path mismatch", function()
        local plugin = buildPlugin({ setting = 1 })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        plugin.ledger["m1:c1"].path = "/downloads/source/manga/other.cbz"
        local summary = plugin:processFinishedChapterCleanup()
        assert.are.equal(1, summary.rejected)
        assert.are.equal("path_mismatch", journalRecord(plugin, "m1", "c1").blocked_reason)
        assert.are.equal(0, #plugin.delete_calls)
    end)

    it("defers deletion while the candidate is the current document", function()
        local path = "/downloads/source/manga/c1.cbz"
        local plugin = buildPlugin({ setting = 1, now = 100, current_document = path })
        record(plugin, "m1", "c1", path)
        local summary = plugin:processFinishedChapterCleanup()
        assert.are.equal(1, summary.retrying)
        assert.are.equal(105, journalRecord(plugin, "m1", "c1").retry_after)
        assert.are.equal(0, #plugin.delete_calls)
    end)

    for _, state_name in ipairs({ "queued", "downloading" }) do
        it("defers deletion while the candidate is " .. state_name, function()
            local plugin = buildPlugin({
                setting = 1,
                now = 100,
                queue_status = { ["m1:c1"] = { state = state_name } },
            })
            record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
            local summary = plugin:processFinishedChapterCleanup()
            assert.are.equal(1, summary.retrying)
            assert.are.equal(105, journalRecord(plugin, "m1", "c1").retry_after)
            assert.are.equal(0, #plugin.delete_calls)
        end)
    end

    it("uses 5/10/20/.../300-second backoff without a retry limit", function()
        local plugin = buildPlugin({ setting = 1, now = 100, delete_state = "delete_failed" })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        plugin:cancelFinishedChapterCleanup()
        local expected_delays = { 5, 10, 20, 40, 80, 160, 300, 300 }
        for retry_count, delay in ipairs(expected_delays) do
            local before = plugin.state.now
            plugin:processFinishedChapterCleanup()
            local entry = journalRecord(plugin, "m1", "c1")
            assert.are.equal(retry_count, entry.retry_count)
            assert.are.equal(before + delay, entry.retry_after)
            plugin.state.now = entry.retry_after
            plugin:cancelFinishedChapterCleanup()
        end
        assert.is_not_nil(journalRecord(plugin, "m1", "c1"))
    end)

    it("keeps retrying journal records whose persisted count is already high", function()
        local path = "/downloads/source/manga/c1.cbz"
        local plugin = buildPlugin({
            setting = 1,
            now = 100,
            delete_state = "delete_failed",
            existing = { [path] = true },
            ledger = { ["m1:c1"] = { manga_id = "m1", chapter_id = "c1", path = path, read = true } },
            journal = { version = 1, next_sequence = 2, mangas = { m1 = { records = {
                { chapter_id = "c1", path = path, sequence = 1, retry_count = 100, retry_after = 100 },
            } } } },
        })
        plugin:processFinishedChapterCleanup()
        assert.are.equal(101, journalRecord(plugin, "m1", "c1").retry_count)
        assert.are.equal(400, journalRecord(plugin, "m1", "c1").retry_after)
    end)

    it("stops one manga after a transient failure and continues another manga", function()
        local plugin = buildPlugin({
            setting = 1,
            delete_states = { ["m1:c1"] = "delete_failed", ["m1:c2"] = "deleted", ["m2:c1"] = "deleted" },
        })
        record(plugin, "m1", "c1", "/downloads/source/m1/c1.cbz")
        record(plugin, "m1", "c2", "/downloads/source/m1/c2.cbz")
        record(plugin, "m2", "c1", "/downloads/source/m2/c1.cbz")
        local summary = plugin:processFinishedChapterCleanup()
        assert.are.equal(1, summary.retrying)
        assert.are.equal(1, summary.deleted)
        assert.are.same({ "m1:c1", "m2:c1" }, {
            plugin.delete_calls[1].manga.id .. ":" .. plugin.delete_calls[1].chapter.id,
            plugin.delete_calls[2].manga.id .. ":" .. plugin.delete_calls[2].chapter.id,
        })
    end)

    it("removes only the successful candidate after a retry", function()
        local plugin = buildPlugin({ setting = 2, now = 100, delete_state = "delete_failed" })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        record(plugin, "m1", "c2", "/downloads/source/manga/c2.cbz")
        plugin:processFinishedChapterCleanup()
        plugin.state.now = 105
        plugin.delete_state = "deleted"
        plugin:cancelFinishedChapterCleanup()
        plugin:processFinishedChapterCleanup()
        assert.is_nil(journalRecord(plugin, "m1", "c1"))
        assert.is_not_nil(journalRecord(plugin, "m1", "c2"))
    end)

    it("bounds a pass and schedules immediate follow-up work", function()
        local plugin = buildPlugin({ setting = 1, batch_size = 2 })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        record(plugin, "m1", "c2", "/downloads/source/manga/c2.cbz")
        record(plugin, "m1", "c3", "/downloads/source/manga/c3.cbz")
        plugin:cancelFinishedChapterCleanup()
        local summary = plugin:processFinishedChapterCleanup()
        assert.are.equal(2, summary.processed)
        assert.are.equal(1, retainedCount(plugin, "m1"))
        assert.are.equal(0, plugin.state.scheduled[#plugin.state.scheduled].delay)
        plugin.state.scheduled[#plugin.state.scheduled].callback()
        assert.are.equal(0, retainedCount(plugin, "m1"))
    end)

    it("preserves unsupported journals and returns a compatibility summary", function()
        local journal = { version = 9, opaque = { keep = true } }
        local plugin = buildPlugin({ journal = journal, journal_error = "unsupported_version" })
        local summary = plugin:processFinishedChapterCleanup()
        assert.are.equal("unsupported_version", summary.compatibility_error)
        assert.are.same(journal, plugin.state.journal)
        assert.are.equal(0, plugin.state.save_count)
        assert.are.equal(1, #plugin.messages)
        assert.is_nil(plugin.messages[1]:match("version = 9"))
        plugin:processFinishedChapterCleanup()
        assert.are.equal(1, #plugin.messages)
    end)

    it("logs only redacted cleanup fields", function()
        local plugin = buildPlugin({ setting = 1, delete_state = "delete_failed" })
        record(plugin, "m1", "c1", "/downloads/Secret Source/Private Manga/Chapter.cbz")
        plugin:processFinishedChapterCleanup()
        local allowed = {
            operation = true, event = true, reason = true, count = true,
            retry_count = true, retry_after = true,
        }
        assert.is_true(#plugin.state.debug_events > 0)
        for _, event in ipairs(plugin.state.debug_events) do
            for key, value in pairs(event) do
                assert.is_true(allowed[key], "unexpected debug key: " .. tostring(key))
                assert.is_nil(tostring(value):match("Secret"))
                assert.is_nil(tostring(value):match("/downloads"))
            end
        end
    end)

    it("notifies once until a retry reason changes or pending count increases", function()
        local plugin = buildPlugin({ setting = 1, now = 100, delete_state = "delete_failed" })
        record(plugin, "m1", "c1", "/downloads/source/m1/c1.cbz")
        plugin:processFinishedChapterCleanup()
        assert.are.equal(1, #plugin.messages)
        plugin.state.now = 105
        plugin:cancelFinishedChapterCleanup()
        plugin:processFinishedChapterCleanup()
        assert.are.equal(1, #plugin.messages)
        plugin.state.now = 115
        plugin.queue_status["m1:c1"] = { state = "queued" }
        plugin:cancelFinishedChapterCleanup()
        plugin:processFinishedChapterCleanup()
        assert.are.equal(2, #plugin.messages)
        record(plugin, "m2", "c1", "/downloads/source/m2/c1.cbz")
        plugin.queue_status["m2:c1"] = { state = "queued" }
        plugin.state.now = 120
        plugin:cancelFinishedChapterCleanup()
        plugin:processFinishedChapterCleanup()
        assert.are.equal(3, #plugin.messages)
        for _, message in ipairs(plugin.messages) do
            assert.is_nil(message:match("m1"))
            assert.is_nil(message:match("/downloads"))
        end
    end)

    it("maps transient delete result states even when the delete boundary reports success", function()
        for _, delete_state in ipairs({ "queued", "downloading", "delete_failed" }) do
            local plugin = buildPlugin({ setting = 1, delete_state = delete_state })
            record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
            local summary = plugin:processFinishedChapterCleanup()
            assert.are.equal(1, summary.retrying)
            assert.is_not_nil(journalRecord(plugin, "m1", "c1"))
        end
    end)

    it("clears stale safety state when a directory change makes the path managed", function()
        local path = "/private/source/manga/c1.cbz"
        local plugin = buildPlugin({ setting = 1, download_directory = "/downloads" })
        record(plugin, "m1", "c1", path)
        plugin:processFinishedChapterCleanup()
        assert.are.equal("unsafe_path", journalRecord(plugin, "m1", "c1").blocked_reason)
        plugin.state.download_directory = "/private"
        plugin:onFinishedCleanupDownloadDirectoryChanged()
        plugin:cancelFinishedChapterCleanup()
        plugin:processFinishedChapterCleanup()
        assert.is_nil(journalRecord(plugin, "m1", "c1"))
    end)

    it("converges a previously rejected record once its archive is absent", function()
        local path = "/private/c1.cbz"
        local plugin = buildPlugin({ setting = 1 })
        record(plugin, "m1", "c1", path)
        plugin:processFinishedChapterCleanup()
        plugin.existing[path] = nil
        plugin:processFinishedChapterCleanup()
        assert.is_nil(journalRecord(plugin, "m1", "c1"))
    end)

    it("does not revalidate a persisted unsafe path on ordinary restart processing", function()
        local path = "/private/c1.cbz"
        local first = buildPlugin({ setting = 1 })
        record(first, "m1", "c1", path)
        first:processFinishedChapterCleanup()
        assert.are.equal("unsafe_path", journalRecord(first, "m1", "c1").blocked_reason)
        local restarted = buildPlugin({
            setting = 1,
            journal = first.state.journal,
            ledger = first.ledger,
            existing = first.existing,
        })
        local summary = restarted:processFinishedChapterCleanup()
        assert.are.equal(1, summary.rejected)
        assert.are.equal(0, #restarted.state.realpath_calls)
        assert.are.equal(0, #restarted.delete_calls)
        assert.are.equal(0, #restarted.state.scheduled)
    end)

    it("resets backoff when a transient reason changes", function()
        local plugin = buildPlugin({ setting = 1, now = 100, delete_state = "delete_failed" })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        plugin:processFinishedChapterCleanup()
        plugin.state.now = 105
        plugin.queue_status["m1:c1"] = { state = "queued" }
        plugin:cancelFinishedChapterCleanup()
        plugin:processFinishedChapterCleanup()
        assert.are.equal(1, journalRecord(plugin, "m1", "c1").retry_count)
        assert.are.equal(110, journalRecord(plugin, "m1", "c1").retry_after)
    end)

    it("cancels one recorded chapter without disturbing its manga history", function()
        local plugin = buildPlugin({ setting = 3 })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        record(plugin, "m1", "c2", "/downloads/source/manga/c2.cbz")
        assert.is_true(plugin:cancelFinishedChapter("m1", "c1"))
        assert.is_nil(journalRecord(plugin, "m1", "c1"))
        assert.is_not_nil(journalRecord(plugin, "m1", "c2"))
        assert.is_false(plugin:cancelFinishedChapter("m1", "missing"))
    end)

    it("rejects malformed event records without treating them as unread", function()
        local plugin = buildPlugin({ setting = 1 })
        local ok, reason = plugin:recordFinishedChapter({ read = true, manga_id = "m1" })
        assert.is_false(ok)
        assert.are.equal("invalid_entry", reason)
        ok, reason = plugin:recordFinishedChapter({ manga_id = "m1", chapter_id = "c1" })
        assert.is_false(ok)
        assert.are.equal("invalid_entry", reason)
    end)

    it("allows a fresh failure notification after cleanup is disabled and re-enabled", function()
        local plugin = buildPlugin({ setting = 1, delete_state = "delete_failed" })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        plugin:processFinishedChapterCleanup()
        assert.are.equal(1, #plugin.messages)
        plugin.state.setting = 0
        plugin:onFinishedCleanupSettingChanged(1, 0)
        plugin.state.setting = 1
        plugin:onFinishedCleanupSettingChanged(0, 1)
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        plugin:processFinishedChapterCleanup()
        assert.are.equal(2, #plugin.messages)
    end)

    it("carries the bounded cursor past blocked records instead of spinning", function()
        local plugin = buildPlugin({ setting = 1, batch_size = 2 })
        record(plugin, "m1", "c1", "/private/m1/c1.cbz")
        record(plugin, "m1", "c2", "/private/m1/c2.cbz")
        record(plugin, "m1", "c3", "/private/m1/c3.cbz")
        record(plugin, "m2", "c1", "/downloads/source/m2/c1.cbz")
        plugin:cancelFinishedChapterCleanup()

        local first = plugin:processFinishedChapterCleanup()
        assert.are.equal(2, first.processed)
        assert.are.equal(0, first.deleted)
        assert.are.equal(0, plugin.state.scheduled[#plugin.state.scheduled].delay)

        plugin.state.scheduled[#plugin.state.scheduled].callback()
        assert.is_nil(journalRecord(plugin, "m2", "c1"))
        assert.are.equal(1, #plugin.delete_calls)
        assert.is_false(plugin.finished_cleanup_scheduled == true)
    end)

    it("finishes bounded traversal before scheduling the earliest waiting retry", function()
        local waiting_path_1 = "/downloads/source/m1/c1.cbz"
        local waiting_path_2 = "/downloads/source/m2/c1.cbz"
        local ready_path = "/downloads/source/m3/c1.cbz"
        local plugin = buildPlugin({
            setting = 1,
            now = 100,
            batch_size = 2,
            journal = { version = 1, next_sequence = 4, mangas = {
                m1 = { records = { { chapter_id = "c1", path = waiting_path_1,
                    sequence = 1, retry_count = 1, retry_after = 300 } } },
                m2 = { records = { { chapter_id = "c1", path = waiting_path_2,
                    sequence = 2, retry_count = 1, retry_after = 250 } } },
                m3 = { records = { { chapter_id = "c1", path = ready_path,
                    sequence = 3, retry_count = 0, retry_after = 0 } } },
            } },
            ledger = {
                ["m1:c1"] = { manga_id = "m1", chapter_id = "c1", path = waiting_path_1, read = true },
                ["m2:c1"] = { manga_id = "m2", chapter_id = "c1", path = waiting_path_2, read = true },
                ["m3:c1"] = { manga_id = "m3", chapter_id = "c1", path = ready_path, read = true },
            },
            existing = { [waiting_path_1] = true, [waiting_path_2] = true, [ready_path] = true },
        })

        plugin:processFinishedChapterCleanup()
        assert.are.equal(0, plugin.state.scheduled[#plugin.state.scheduled].delay)
        plugin.state.scheduled[#plugin.state.scheduled].callback()
        assert.is_nil(journalRecord(plugin, "m3", "c1"))
        assert.are.equal(150, plugin.state.scheduled[#plugin.state.scheduled].delay)
    end)

    it("reports mixed failures once per completed multi-batch traversal", function()
        local plugin = buildPlugin({ setting = 1, now = 100, batch_size = 2, delete_state = "delete_failed" })
        record(plugin, "m1", "c1", "/private/m1/c1.cbz")
        record(plugin, "m1", "c2", "/private/m1/c2.cbz")
        record(plugin, "m2", "c1", "/downloads/source/m2/c1.cbz")
        plugin:cancelFinishedChapterCleanup()

        plugin:processFinishedChapterCleanup()
        assert.are.equal(0, #plugin.messages)
        plugin.state.scheduled[#plugin.state.scheduled].callback()
        assert.are.equal(1, #plugin.messages)
        assert.is_not_nil(plugin.messages[1]:match("3"))

        plugin.state.now = 105
        plugin.state.scheduled[#plugin.state.scheduled].callback()
        assert.are.equal(1, #plugin.messages)
        plugin.state.scheduled[#plugin.state.scheduled].callback()
        assert.are.equal(1, #plugin.messages)
    end)

    it("preserves an unsupported journal even while cleanup is disabled", function()
        local journal = { version = 9, opaque = { keep = true } }
        local plugin = buildPlugin({ setting = 0, journal = journal, journal_error = "unsupported_version" })
        local summary = plugin:processFinishedChapterCleanup()
        assert.are.equal("unsupported_version", summary.compatibility_error)
        assert.are.same(journal, plugin.state.journal)
        assert.are.equal(0, plugin.state.save_count)
        assert.are.equal(1, #plugin.messages)
    end)

    it("converges a missing old path before rejecting a changed ledger path", function()
        local old_path = "/downloads/source/manga/old.cbz"
        local new_path = "/downloads/source/manga/new.cbz"
        local plugin = buildPlugin({ setting = 1 })
        record(plugin, "m1", "c1", old_path, { exists = false })
        plugin.ledger["m1:c1"].path = new_path

        local summary = plugin:processFinishedChapterCleanup()

        assert.are.equal(1, summary.missing)
        assert.are.equal(0, summary.rejected)
        assert.is_nil(journalRecord(plugin, "m1", "c1"))
        assert.are.equal(new_path, plugin.ledger["m1:c1"].path)
        assert.are.equal(0, #plugin.delete_calls)
    end)

    it("replaces a later cleanup timer with an earlier request", function()
        local path = "/downloads/source/manga/c1.cbz"
        local plugin = buildPlugin({
            setting = 1,
            journal = { version = 1, next_sequence = 2, mangas = { m1 = { records = {
                { chapter_id = "c1", path = path, sequence = 1, retry_count = 0, retry_after = 0 },
            } } } },
            ledger = { ["m1:c1"] = { manga_id = "m1", chapter_id = "c1", path = path, read = true } },
            existing = { [path] = true },
        })

        assert.is_true(plugin:scheduleFinishedChapterCleanup(300))
        assert.is_true(plugin:scheduleFinishedChapterCleanup(0))
        assert.is_false(plugin:scheduleFinishedChapterCleanup(10))
        assert.are.same({ 300, 0 }, {
            plugin.state.scheduled[1].delay,
            plugin.state.scheduled[2].delay,
        })
        plugin.state.scheduled[1].callback()
        assert.are.equal(0, #plugin.delete_calls)
        plugin.state.scheduled[2].callback()
        assert.are.equal(1, #plugin.delete_calls)
    end)

    it("does not reenter an active processor", function()
        local plugin
        plugin = buildPlugin({
            setting = 1,
            on_delete = function()
                local nested = plugin:processFinishedChapterCleanup()
                assert.is_true(nested.busy)
            end,
        })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        plugin:processFinishedChapterCleanup()
        assert.are.equal(1, #plugin.delete_calls)
    end)
end)
