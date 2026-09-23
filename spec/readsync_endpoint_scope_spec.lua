package.path = "?.lua;" .. package.path

local runtime = require("spec/support/plugin_runtime_spec_helper")

describe("read sync endpoint authority", function()
    local settings, plugin, timers, children, calls, results, messages
    local scope = "https://suwayomi.example"
    local foreign = "https://other.example"
    local function clear()
        runtime.teardown()
        for _, name in ipairs({ "suwayomi/settings/store", "suwayomi/chapters/manual_deletion",
            "suwayomi/chapters/archive_identity", "suwayomi/downloads/refill" }) do
            package.loaded[name], package.preload[name] = nil, nil
        end
    end
    local function entry(origin, read)
        return { manga_id = "1", chapter_id = "2", endpoint_scope = origin,
            read = read, pending_read_sync = true, pending_read_state = read }
    end
    local function save(value) assert(settings:saveChapterLedger(value)) end
    local function ledger() return settings:loadChapterLedger() end
    local function finish()
        local active = assert(plugin.pending_read_sync_active)
        children[active.pid]()
        plugin:pollPendingReadSync()
    end
    before_each(function()
        clear()
        runtime.install()
        timers, children, calls, results, messages = {}, {}, {}, {}, {}
        package.preload["suwayomi/settings"] = nil
        package.preload["suwayomi/downloads/queue"] = nil
        package.preload["suwayomi/readsync/worker"] = nil
        settings = require("suwayomi/settings")
        settings:setStore(require("spec/support/checked_queue_settings")():getStore())
        assert(settings:save{ server_url = scope })
        local ui = require("ui/uimanager")
        require("suwayomi/debug").elapsedMs = function() return 0 end
        ui.scheduleIn = function(_, delay, callback) timers[#timers + 1] = { delay = delay, callback = callback } end
        ui.unschedule = function() end
        local ffi = require("ffi/util")
        ffi.runInSubProcess = function(callback) children[#children + 1] = callback; return #children end
        ffi.isSubProcessDone = function() return true end
        local api = require("suwayomi/api")
        api.markChaptersReadState = function(credentials, ids, read)
            calls[#calls + 1] = { endpoint = credentials.server_url, ids = ids, read = read }
            local chapters = {}
            for _, id in ipairs(ids) do chapters[#chapters + 1] = { id = id, is_read = read } end
            return { ok = true, chapters = chapters }
        end
        local worker = require("suwayomi/readsync/worker")
        worker.writeResult = function(_, path, result) results[path] = result end
        worker.readResult = function(_, path) return results[path] end
        local service = require("suwayomi/downloads/service"):new{ settings = settings, ui_manager = ui }
        plugin = { read_sync_delay_seconds = 0.5, read_sync_failure_delay_seconds = 5,
            read_sync_max_failure_delay_seconds = 20, read_sync_batch_size = 50,
            read_sync_poll_interval_seconds = 0.1, read_sync_watchdog_timeout_seconds = 30 }
        for _, name in ipairs({ "suwayomi/readsync/ledger", "suwayomi/readsync/controller",
            "suwayomi/chapters/read_actions", "suwayomi/downloads/controller" }) do
            for key, method in pairs(require(name).methods) do plugin[key] = method end
        end
        plugin.getDownloadQueue = function() return service.queue end
        plugin.getChapterDownloadKey = function(_, manga, chapter) return manga.id .. ":" .. chapter.id end
        plugin.showMessage = function(_, message) messages[#messages + 1] = message end
        plugin.isChapterDownloaded = function() return false end
        plugin.refreshChapterMenu = function() end
        plugin.isChapterPathFinishedInKoreader = function() return true end
        plugin.getCurrentDocumentPath = function() return "/books/recovered.cbz" end
        plugin.isCurrentDocumentFinished = function() return true end
    end)
    after_each(clear)

    it("never sends a foreign pending choice with current credentials", function()
        save({ ["1:2"] = entry(foreign, true) })
        local before = ledger()
        assert.is_false(plugin:startPendingReadSyncWorker())
        assert.same({}, children)
        assert.same(before, ledger())
    end)

    it("keeps an unknown-origin completed close local-only", function()
        local item = entry(nil, false)
        item.path, item.pending_read_sync, item.pending_read_state = "/books/recovered.cbz", nil, nil
        save({ ["1:2"] = item })
        plugin:onCloseDocument()
        assert.is_true(ledger()["1:2"].read)
        assert.is_nil(ledger()["1:2"].pending_read_sync)
        assert.is_false(plugin:startPendingReadSyncWorker())
    end)

    it("preserves a foreign replacement when an old worker succeeds with identical IDs and state", function()
        save({ ["1:2"] = entry(scope, true) })
        assert.is_true(plugin:startPendingReadSyncWorker())
        save({ ["1:2"] = entry(foreign, true) })
        finish()
        assert.is_true(ledger()["1:2"].pending_read_sync)
        assert.equals(foreign, ledger()["1:2"].endpoint_scope)
    end)

    it("persists scope on a legitimate new pathless read choice", function()
        plugin.isChapterDownloaded = function() return false, "/books/future.cbz" end
        assert.is_true(plugin:markChapterRead({ id = "1", endpoint_scope = scope }, { id = "2" }))
        assert.equals(scope, ledger()["1:2"].endpoint_scope)
        assert.is_nil(ledger()["1:2"].path)
        assert.is_true(plugin:startPendingReadSyncWorker())
        finish()
        assert.is_nil(ledger()["1:2"].pending_read_sync)
    end)

    for _, read in ipairs({ true, false }) do
        it("syncs same-server " .. tostring(read) .. " choices and preserves ineligible mixed entries", function()
            local eligible, unknown, other = entry(scope, read), entry(nil, read), entry(foreign, read)
            unknown.chapter_id, other.chapter_id = "3", "4"
            save({ ["1:2"] = eligible, ["1:3"] = unknown, ["1:4"] = other })
            assert.is_true(plugin:startPendingReadSyncWorker())
            assert.equals(1, #plugin.pending_read_sync_active.batch)
            finish()
            assert.same({ { endpoint = scope, ids = { "2" }, read = read } }, calls)
            assert.same(unknown, ledger()["1:3"])
            assert.same(other, ledger()["1:4"])
            assert.is_nil(ledger()["1:2"] and ledger()["1:2"].pending_read_sync)
            assert.is_nil(plugin.pending_read_sync_scheduled)
        end)
    end

    it("captures current credentials and reselects the batch after a scheduled server change", function()
        local other = entry(foreign, false)
        other.chapter_id = "3"
        save({ ["1:2"] = entry(scope, true), ["1:3"] = other })
        plugin:schedulePendingReadSync(settings:load())
        assert(settings:save{ server_url = foreign })
        table.remove(timers, 1).callback()
        finish()
        assert.same({ { endpoint = foreign, ids = { "3" }, read = false } }, calls)
        assert.is_true(ledger()["1:2"].pending_read_sync)
    end)

    it("rejects explicitly stale dispatch credentials", function()
        save({ ["1:2"] = entry(scope, true) })
        assert.is_false(plugin:startPendingReadSyncWorker({ server_url = foreign }))
        assert.same({}, children)
    end)

    it("uses normalized endpoint identity", function()
        assert(settings:save{ server_url = scope .. "/" })
        save({ ["1:2"] = entry(scope, true) })
        assert.is_true(plugin:startPendingReadSyncWorker())
        finish()
        assert.is_nil(ledger()["1:2"].pending_read_sync)
    end)

    it("does not acknowledge a replacement archive on the same endpoint", function()
        local original = entry(scope, true)
        original.archive_generation, original.path = 1, "/books/recovered.cbz"
        save({ ["1:2"] = original })
        assert.is_true(plugin:startPendingReadSyncWorker())
        original.archive_generation = 2
        save({ ["1:2"] = original })
        finish()
        assert.is_true(ledger()["1:2"].pending_read_sync)
    end)

    it("does not falsely report unsendable pending changes as synced or retry them forever", function()
        save({ ["1:2"] = entry(nil, true) })
        assert.is_false(plugin:syncReadStateNow())
        assert.equals(1, #messages)
        assert.is_nil(messages[1]:find("already synced", 1, true))
        plugin:finishPendingReadSync({}, 0, 1)
        assert.is_nil(plugin.pending_read_sync_scheduled)
        plugin:schedulePendingReadSync()
        table.remove(timers, 1).callback()
        assert.same({}, timers)
        assert.same({}, children)
    end)

    it("keeps known-origin completed-close sync", function()
        local item = entry(scope, false)
        item.path, item.pending_read_sync, item.pending_read_state = "/books/recovered.cbz", nil, nil
        save({ ["1:2"] = item })
        plugin:onCloseDocument()
        assert.is_true(ledger()["1:2"].pending_read_sync)
        assert.is_true(plugin:startPendingReadSyncWorker())
        finish()
        assert.is_true(ledger()["1:2"].read)
        assert.is_nil(ledger()["1:2"].pending_read_sync)
    end)

    it("persists scope on a legitimate new pathless unread choice", function()
        plugin.isChapterDownloaded = function() return false, "/books/future.cbz" end
        assert.is_true(plugin:markChapterUnread({ id = "1", endpoint_scope = scope }, { id = "2" }))
        assert.equals(scope, ledger()["1:2"].endpoint_scope)
        assert.is_nil(ledger()["1:2"].path)
        assert.is_true(plugin:startPendingReadSyncWorker())
        finish()
        assert.same({ { endpoint = scope, ids = { "2" }, read = false } }, calls)
    end)

    for _, origin in ipairs({ "unknown", foreign }) do
        it("refuses manual ID collisions with " .. origin .. " choices before metadata or persistence", function()
            save({ ["1:2"] = entry(origin ~= "unknown" and origin or nil, false) })
            local before = ledger()
            plugin.setKoreaderChapterReadState = function() error("must not write metadata") end
            plugin.isChapterDownloaded = function() return true, "/books/recovered.cbz" end
            local manga, chapter = { id = "1", endpoint_scope = scope }, { id = "2" }
            assert.is_false(plugin:markChapterRead(manga, chapter))
            assert.is_false(plugin:markChapterUnread(manga, chapter))
            assert.same(before, ledger())
            assert.equals(2, #messages)
        end)

        it("does not clear " .. origin .. " pathless choices during remote reconciliation", function()
            save({ ["1:2"] = entry(origin ~= "unknown" and origin or nil, false) })
            local before = ledger()
            assert(plugin:mergeChaptersWithReadLedger({ id = "1", endpoint_scope = scope }, { { id = "2", is_read = false } }))
            assert.same(before, ledger())
        end)
    end

    it("does not enroll unknown archives through download reconciliation or ledger marking", function()
        local item = entry(nil, false)
        item.path, item.pending_read_sync, item.pending_read_state = "/books/recovered.cbz", nil, nil
        save({ ["1:2"] = item })
        plugin:reconcileDownloadedChapterLedger()
        assert.is_nil(ledger()["1:2"].pending_read_sync)
        save({ ["1:2"] = item })
        assert.is_true(plugin:markLedgerEntryRead(item))
        assert.is_nil(ledger()["1:2"].pending_read_sync)
    end)

    it("preserves a foreign collision even when a caller supplies an older scoped ledger", function()
        local old = { ["1:2"] = entry(scope, true) }
        save({ ["1:2"] = entry(foreign, false) })
        local before = ledger()
        assert.is_false(plugin:markChapterRead({ id = "1", endpoint_scope = scope }, { id = "2" }, { ledger = old }))
        assert.same(before, ledger())
    end)

    it("worker rejects unscoped and foreign items even in a malformed mixed batch", function()
        local result = require("suwayomi/readsync/worker"):run(settings:load(), {
            { key = "1:2", chapter_id = "2", desired_read_state = true, endpoint_scope = scope },
            { key = "1:3", chapter_id = "3", desired_read_state = false },
            { key = "1:4", chapter_id = "4", desired_read_state = true, endpoint_scope = foreign },
        }, "controlled-result")
        assert.equals(1, #calls)
        assert.same({ "2" }, calls[1].ids)
        assert.equals(2, #result.failures)
        assert.equals(scope, result.successes[1].endpoint_scope)
    end)

    it("retries eligible failure using updated same-endpoint credentials", function()
        save({ ["1:2"] = entry(scope, true) })
        require("suwayomi/api").markChaptersReadState = function() return { ok = false, error = "offline" } end
        assert.is_true(plugin:startPendingReadSyncWorker())
        finish()
        assert.is_true(ledger()["1:2"].pending_read_sync)
        assert.is_true(plugin.pending_read_sync_scheduled)
        assert(settings:save{ server_url = scope, password = "updated" })
        local retry = timers[#timers]
        assert.equals(5, retry.delay)
        retry.callback()
        assert.equals("updated", plugin.pending_read_sync_active.credentials.password)
    end)

    for _, failure in ipairs({ "rejected", "uncertain" }) do
        local function fail(store)
            if failure == "rejected" then store.io.open = function() return nil, "injected rejection" end
            else store.io.sync_dir = function() return nil, "injected uncertainty" end end
        end
        it("does not publish new read intent after " .. failure .. " persistence", function()
            fail(settings:getStore())
            assert.is_false(plugin:markChapterRead({ id = "1", endpoint_scope = scope }, { id = "2" }))
            assert.is_nil(ledger()["1:2"])
            assert.is_nil(plugin.pending_read_sync_scheduled)
            assert.same({}, children)
        end)
        it("retains pending choices after " .. failure .. " acknowledgment persistence", function()
            save({ ["1:2"] = entry(scope, true) })
            assert.is_true(plugin:startPendingReadSyncWorker())
            local active = plugin.pending_read_sync_active
            children[active.pid]()
            fail(settings:getStore())
            assert.equals(0, plugin:applyPendingReadSyncResult(active, results[active.result_path]))
            assert.is_true(ledger()["1:2"].pending_read_sync)
        end)
        it("does not publish completed close after " .. failure .. " persistence", function()
            local item = entry(scope, false)
            item.path, item.pending_read_sync, item.pending_read_state = "/books/recovered.cbz", nil, nil
            save({ ["1:2"] = item })
            fail(settings:getStore())
            plugin:onCloseDocument()
            assert.same(item, ledger()["1:2"])
            assert.is_nil(plugin.pending_read_sync_scheduled)
        end)
    end

    it("does not dispatch while persistence is uncertain", function()
        save({ ["1:2"] = entry(scope, true) })
        settings:getStore().io.sync_dir = function() return nil, "injected uncertainty" end
        assert.is_nil(settings:getStore():saveKey("unrelated", true))
        assert.is_false(plugin:startPendingReadSyncWorker())
        assert.same({}, children)
    end)

    for _, scoped_choice in ipairs({ false, true }) do
        it("opens unknown archive locally even with a scoped pathless choice " .. tostring(scoped_choice), function()
            local path = "/books/recovered.cbz"
            if scoped_choice then
                local item = entry(scope, false)
                item.pending_read_sync, item.pending_read_state = nil, nil
                save({ ["1:2"] = item })
            end
            assert(settings:saveReaderReturnContexts({ [path] = { path = path, manga_id = "1", chapter_id = "2" } }))
            assert(settings:saveDownloadDirectory("/books"))
            local before = ledger()
            local contexts = settings:loadReaderReturnContexts()
            for key, method in pairs(require("suwayomi/chapters/actions").methods) do plugin[key] = method end
            local downloader = require("suwayomi/downloads/downloader")
            downloader.getTargetPath = function() return "/books", path end
            downloader.chapterExists = function(_, candidate) return candidate == path end
            local opened
            package.loaded["apps/reader/readerui"] = nil
            package.preload["apps/reader/readerui"] = function()
                return { showReader = function(_, candidate) opened = candidate end }
            end
            plugin:getDownloadQueue().verifyArchive = function(_, _, _, candidate, callback, options)
                assert.equals(path, candidate)
                assert.is_true(options.read_only)
                callback({ state = "valid" })
                return true
            end
            assert.is_true(plugin:openChapter({ id = "1", endpoint_scope = scope }, { id = "2" }))
            assert.equals(path, opened)
            assert.same(before, ledger())
            assert.same(contexts, settings:loadReaderReturnContexts())
            plugin:onCloseDocument()
            assert.is_false(plugin:startPendingReadSyncWorker())
        end)
    end
end)
