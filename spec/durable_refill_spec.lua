package.path = "?.lua;" .. package.path

local runtime_helper = require("spec/support/plugin_runtime_spec_helper")

describe("durable refill through the process service", function()
    local service, settings, directory, timers, workers, clock, responses, files
    local modules = { "suwayomi/downloads/refill", "suwayomi/chapters/manual_deletion",
        "suwayomi/chapters/archive_identity", "suwayomi/settings/store", "suwayomi/network/request_worker" }
    local function clear()
        runtime_helper.clearModules()
        runtime_helper.clearPreloads()
        for _, name in ipairs(modules) do package.loaded[name], package.preload[name] = nil, nil end
    end
    local function manga(id)
        return { id = id or "1", title = "Example", source = { id = "10", name = "Source" },
            endpoint_scope = "http://example.invalid" }
    end
    local function chapters(count)
        local result = {}
        for index = 1, count do result[index] = { id = tostring(index), name = "Chapter " .. index,
            source_order = index, is_read = false, scanlator = "A" } end
        return result
    end
    local function advance(seconds)
        clock = clock + seconds
        for _ = 1, 500 do
            local index
            for candidate, timer in ipairs(timers) do
                if timer.at <= clock and (not index or timer.at < timers[index].at) then index = candidate end
            end
            if not index then return end
            table.remove(timers, index).callback()
        end
        error("scheduler did not yield")
    end
    local function finishContext()
        local active = assert(service.refill.active)
        local worker = assert(workers[active.pid])
        worker.callback()
        files[active.result_path], files[active.result_path .. ".tmp"] = true, true
        worker.done = true
        advance(0.5)
    end
    local function persisted()
        return settings:getStore():load()
    end
    local function jobIds(id)
        local result = {}
        for _, job in ipairs(settings:loadDownloadQueue()) do
            if tostring(job.manga.id) == tostring(id or "1") then result[#result + 1] = job.chapter.id end
        end
        table.sort(result)
        return result
    end
    before_each(function()
        clear()
        runtime_helper.install()
        clock, timers, workers, responses, files = 100, {}, {}, {}, {}
        directory = os.tmpname():gsub("\\", "/")
        os.remove(directory)
        package.preload.lfs, package.loaded.lfs = nil, nil
        package.preload["suwayomi/fs"] = nil
        assert(require("lfs").mkdir(directory))
        package.preload.datastorage = function() return { getSettingsDir = function() return directory end } end
        package.preload.luasettings = function() return { open = function() return { data = {} } end } end
        package.preload["suwayomi/settings"] = nil
        package.preload["suwayomi/downloads/queue"] = nil
        settings = require("suwayomi/settings")
        settings.store = require("suwayomi/settings/store"):new{ path = directory .. "/settings.lua" }
        files[settings.store.path] = true
        assert(settings:save{ server_url = "http://example.invalid" })
        assert(settings:saveDownloadDirectory(directory))
        local ui = require("ui/uimanager")
        ui.quit = function() end
        ui.scheduleIn = function(_, delay, callback) timers[#timers + 1] = { at = clock + delay, callback = callback } end
        ui.unschedule = function(_, callback)
            for index = #timers, 1, -1 do if timers[index].callback == callback then table.remove(timers, index) end end
        end
        local ffi_util = require("ffi/util")
        ffi_util.runInSubProcess = function(callback)
            workers[#workers + 1] = { callback = callback }
            return #workers
        end
        ffi_util.isSubProcessDone = function(pid) return workers[pid].done == true end
        ffi_util.terminateSubProcess = function(pid) workers[pid].terminated = true end
        local api = require("suwayomi/api")
        api.fetchChaptersForManga = function(_, id)
            local response = responses[tostring(id)]
            if type(response) == "function" then return response() end
            return response or { ok = true, chapters = chapters(8) }
        end
        local downloader = require("suwayomi/downloads/downloader")
        downloader.getTargetPath = function(_, root, owner, chapter) return root, root .. "/" .. owner.id .. "-" .. chapter.id .. ".cbz" end
        downloader.chapterExists = function(_, path) return require("lfs").attributes(path, "mode") == "file" end
        service = require("suwayomi/downloads/service"):new{
            settings = settings, ui_manager = ui, ffi_util = ffi_util, downloader = downloader,
            now = function() return clock end,
        }
        service:start()
        advance(0)
    end)
    after_each(function()
        if service then service:shutdown() end
        for path in pairs(files or {}) do os.remove(path) end
        if directory then
            for name in require("lfs").dir(directory) do
                if name ~= "." and name ~= ".." then os.remove(directory .. "/" .. name) end
            end
            require("lfs").rmdir(directory)
        end
        clear()
    end)

    it("coalesces revisions and rejects read-sync acknowledgment races before admission", function()
        local owner = manga()
        assert.are.equal(5, service.refill:setPolicy(owner, 5))
        local ledger = { ["1:1"] = { manga_id = "1", chapter_id = "1", read = true,
            pending_read_sync = true, pending_read_state = true } }
        assert(service.refill:commitLedger(ledger, { owner }))
        advance(0)
        local original = service:getSnapshot().refills[1].revision
        ledger["1:1"].pending_read_sync, ledger["1:1"].pending_read_state = nil, nil
        assert(settings:saveChapterLedger(ledger))
        finishContext()
        assert.same({}, jobIds())
        assert.is_true(service:getSnapshot().refills[1].revision > original)
        responses["1"] = { ok = true, chapters = chapters(8) }
        responses["1"].chapters[1].is_read = true
        advance(0)
        finishContext()
        assert.same({ "2", "3", "4", "5", "6" }, jobIds())
        assert.same({}, service:getSnapshot().refills)
        assert.is_true(settings:loadChapterLedger()["1:1"].read)
        assert.is_not_nil(persisted().download_refill.associations["1"])
    end)

    it("preserves terminal failures and deletion fences without selecting beyond the buffer", function()
        local owner = manga()
        assert(settings:getStore():saveDocument(function(doc)
            doc.download_queue = { { key = "1:1", state = "failed", manga = owner, chapter = chapters(1)[1],
                download_directory = directory, retry_count = 9, progress = { error = "Permanent failure" } } }
            doc.manual_archive_state = { version = 1, next_revision = 2, archives = {}, requests = {
                ["1:2"] = { version = 99, state = "blocked" },
            } }
        end))
        assert(service.queue:reconcile())
        assert.are.equal(5, service.refill:setPolicy(owner, 5))
        advance(0)
        finishContext()
        assert.same({ "1", "3", "4", "5" }, jobIds())
        assert.are.equal(9, service.queue:findPersistentJob("1:1").retry_count)
        assert.are.equal("blocked", service:getSnapshot().refills[1].state)
        local count = #workers
        advance(600)
        assert.are.equal(count, #workers)
        assert.are.equal(99, persisted().manual_archive_state.requests["1:2"].version)
    end)

    it("keeps offline deadlines through restart and lets another manga proceed", function()
        responses["1"] = { ok = false, error = "Offline" }
        assert.are.equal(5, service.refill:setPolicy(manga("1"), 5))
        assert.are.equal(5, service.refill:setPolicy(manga("2"), 5))
        advance(0)
        finishContext()
        local pending = persisted().download_refill.requests["1"]
        assert.are.equal("waiting", pending.state)
        assert.are.equal(1, pending.retry_count)
        local deadline = pending.next_retry_at
        finishContext()
        assert.same({ "1", "2", "3", "4", "5" }, jobIds("2"))
        service:shutdown()
        timers = {}
        service = require("suwayomi/downloads/service"):new{ settings = settings,
            ui_manager = require("ui/uimanager"), ffi_util = require("ffi/util"),
            downloader = require("suwayomi/downloads/downloader"), now = function() return clock end }
        service:start()
        advance(0)
        assert.is_nil(service.refill.active)
        assert.are.equal(deadline, persisted().download_refill.requests["1"].next_retry_at)
        responses["1"] = { ok = true, chapters = chapters(8) }
        advance(deadline - clock)
        finishContext()
        assert.same({ "1", "2", "3", "4", "5" }, jobIds("1"))
    end)

    it("atomically cancels an in-flight refill with no chapter jobs and rejects late files", function()
        assert.are.equal(5, service.refill:setPolicy(manga(), 5))
        advance(0)
        local active = assert(service.refill.active)
        workers[active.pid].callback()
        files[active.result_path] = true
        local result_file = assert(io.open(active.result_path, "rb")); result_file:close()
        assert.are.equal(0, service.queue:cancelAll())
        advance(0)
        assert.is_nil(persisted().download_refill.requests["1"])
        assert.are.equal(5, settings:loadMangaKeepNextUnreadDownloads(manga()))
        local handle = assert(io.open(active.result_path, "rb")); handle:close()
        workers[active.pid].done = true
        advance(0.5)
        assert.is_nil(io.open(active.result_path, "rb"))
        assert.same({}, jobIds())
        assert.same({}, service:getSnapshot().refills)
    end)

    it("preserves unknown versions and rejects stale Retry and Stop commands", function()
        assert.are.equal(5, service.refill:setPolicy(manga(), 5))
        local revision = service:getSnapshot().refills[1].revision
        assert(service.refill:request(manga()))
        assert.is_nil(service.refill:stop("1", revision))
        assert.is_nil(service.refill:retry("1", revision))
        assert.are.equal(5, settings:loadMangaKeepNextUnreadDownloads(manga()))
        assert(settings:getStore():saveDocument(function(doc) doc.download_refill.version = 99 end))
        assert.is_nil(service.refill:setPolicy(manga(), 0))
        assert.are.equal(99, persisted().download_refill.version)
        assert.are.equal("unsupported_state", service:getSnapshot().refills[1].reason)
    end)

    it("requires archived origin after an endpoint rebind and never persists URL credentials", function()
        assert.are.equal(5, service.refill:setPolicy(manga(), 5))
        assert(settings:save{ server_url = "http://other.invalid" })
        local current = manga()
        current.endpoint_scope = "http://other.invalid"
        assert(service.refill:associate(current))
        assert(service.refill:commitLedger({}, { { id = "1", title = "Old archive", require_origin = true } }))
        assert.are.equal("origin_unknown", service:getSnapshot().refills[1].reason)
        assert.is_nil(service.refill:retry("1", service:getSnapshot().refills[1].revision))
        advance(0)
        assert.is_nil(service.refill.active)
        assert(settings:save{ server_url = "http://user:secret@other.invalid/?token=secret" })
        current.endpoint_scope = "http://user:secret@other.invalid/?token=secret"
        assert.is_nil(service.refill:associate(current))
        assert.are.equal("http://other.invalid", persisted().download_refill.associations["1"].endpoint_scope)
    end)

    it("joins chapter cancellation and refill retirement in one checked save", function()
        local owner = manga()
        assert.are.equal(5, service.refill:setPolicy(owner, 5))
        assert(service.queue:enqueue(owner, chapters(1)[1], directory, { provenance = "explicit" }))
        local store, original = settings:getStore(), settings:getStore().io.rename
        store.io.rename = function() return nil, "rejected" end
        assert.is_false(service.queue:cancelPending(owner, chapters(1)[1]))
        assert.is_not_nil(persisted().download_refill.requests["1"])
        assert.same({ "1" }, jobIds())
        store.io.rename = original
        assert.is_true(service.queue:cancelPending(owner, chapters(1)[1]))
        assert.is_nil(persisted().download_refill.requests["1"])
        assert.same({}, jobIds())
        assert.are.equal(5, settings:loadMangaKeepNextUnreadDownloads(owner))
        advance(0)
        assert.is_nil(service.refill.active)
    end)

    it("admits nothing after a rejected or uncertain consumption write", function()
        assert.are.equal(5, service.refill:setPolicy(manga(), 5))
        advance(0)
        local store = settings:getStore()
        local rename = store.io.rename
        store.io.rename = function() return nil, "rejected" end
        finishContext()
        assert.same({}, jobIds())
        assert.is_not_nil(persisted().download_refill.requests["1"])
        assert.are.equal("pending", service:getSnapshot().refills[1].state)
        store.io.rename = rename
        advance(5)
        assert.is_not_nil(service.refill.active)
        local sync = store.io.sync_dir
        store.io.sync_dir = function() return nil, "uncertain" end
        finishContext()
        assert.is_true(store:isBlocked())
        assert.are.equal(0, service.queue:getActiveCount())
        store.io.sync_dir = sync
        assert(service.queue:reconcile())
        assert.same({ "1", "2", "3", "4", "5" }, jobIds())
        assert.same({}, service:getSnapshot().refills)
    end)

    it("blocks rejected server requests until explicit Retry rather than treating authentication as an outage", function()
        responses["1"] = { ok = false, status_code = 401, retryable = false, error = "HTTP 401" }
        assert.are.equal(5, service.refill:setPolicy(manga(), 5))
        advance(0)
        finishContext()
        local request = service:getSnapshot().refills[1]
        assert.are.equal("blocked", request.state)
        assert.are.equal("fetch_rejected", request.reason)
        advance(300)
        assert.are.equal(1, #workers)
        assert.same({}, jobIds())
        responses["1"] = { ok = true, chapters = {} }
        assert(service.refill:retry("1", request.revision))
        advance(0)
        finishContext()
        assert.same({}, service:getSnapshot().refills)
    end)
end)
