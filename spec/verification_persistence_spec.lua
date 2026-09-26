package.path = "?.lua;" .. package.path

-- Queue seam with real archives and checked storage, controlled worker exit and IO faults.
describe("verification persistence recovery", function()
    local queue, settings, store, scheduled, workers, outcomes, events
    local root, path, metadata, original, saved_modules, restore_native, clock
    local manga = { id = "m", title = "Fixture", endpoint_scope = "https://suwayomi.example" }
    local chapter = { id = "c", name = "Fixture" }
    local function read(file)
        local handle = io.open(file, "rb")
        if not handle then return nil end
        local bytes = handle:read("*a")
        handle:close()
        return bytes
    end
    local function tick()
        table.sort(scheduled, function(a, b) return a.at < b.at end)
        local task = table.remove(scheduled, 1)
        if task then clock = task.at; task.callback() end
    end
    local function verify(options, callback)
        return queue:verifyArchive(manga, chapter, path, callback or function(result)
            outcomes[#outcomes + 1] = result
        end, options)
    end
    before_each(function()
        saved_modules = {}
        for _, name in ipairs({ "suwayomi/settings", "ffi/archiver", "ffi/libarchive_h" }) do
            saved_modules[name] = package.loaded[name]
        end
        root = os.tmpname()
        os.remove(root)
        assert(require("lfs").mkdir(root))
        package.loaded["suwayomi/settings"] = { getSettingsDir = function() return root end }
        local Native = require("spec/support/native_archiver")
        restore_native = Native.install()
        path, metadata = root .. "/fixture.cbz", root .. "/progress.lua"
        local writer = Native.Writer:new()
        assert(writer:open(path, "zip"))
        assert(writer:addFileFromMemory("001.png", "fixture page"))
        assert(writer:close())
        original = read(path)
        local handle = assert(io.open(metadata, "wb"))
        assert(handle:write("return { read = true, last_page = 7 }"))
        handle:close()
        settings = require("spec/support/checked_queue_settings")()
        store = settings:getStore()
        assert(store:saveKey("chapter_ledger", { ["m:c"] = { read = true, last_page = 7 } }))
        scheduled, workers, outcomes, events, clock = {}, {}, {}, {}, 0
        queue = require("suwayomi/downloads/queue"):new{
            settings = settings,
            ui_manager = { scheduleIn = function(_, delay, callback)
                scheduled[#scheduled + 1] = { at = clock + delay, callback = callback }
            end },
            now = function() return clock end,
            ffi_util = {
                runInSubProcess = function(callback)
                    workers[#workers + 1] = { done = true }
                    callback()
                    return #workers
                end,
                isSubProcessDone = function(pid) return workers[pid].done end,
                terminateSubProcess = function(pid) workers[pid].terminated = true end,
            },
            debug_logger = function(event) events[#events + 1] = event end,
        }
    end)
    after_each(function()
        restore_native()
        for name, value in pairs(saved_modules) do package.loaded[name] = value end
        for _, name in ipairs({ "suwayomi/settings", "ffi/archiver", "ffi/libarchive_h" }) do
            if saved_modules[name] == nil then package.loaded[name] = nil end
        end
        for entry in require("lfs").dir(root) do
            if entry ~= "." and entry ~= ".." then os.remove(root .. "/" .. entry) end
        end
        assert(require("lfs").rmdir(root))
    end)

    it("ends rejected completion promptly and permits an ordinary safe retry", function()
        local rename = store.io.rename
        store.io.rename = function() return nil, "private /secret/archive token=hidden" end
        assert(verify())
        tick()
        assert.are.equal(1, #outcomes)
        assert.are.equal("unverified", outcomes[1].state)
        assert.are.equal("persistence", outcomes[1].stage)
        assert.are.equal("replacement_failed", outcomes[1].code)
        assert.is_nil(outcomes[1].error:find("secret", 1, true))
        assert.is_nil(queue:getStatus(manga, chapter))
        assert(verify())
        tick()
        assert.are.equal(2, #outcomes)
        assert.are.equal("persistence", outcomes[2].stage)
        store.io.rename = rename
        assert(verify())
        tick()
        assert.are.equal(3, #outcomes)
        assert.are.equal("valid", outcomes[3].state)
        for _ = 1, 4 do tick() end
        assert.are.equal(3, #outcomes)
        assert.are.equal(original, read(path))
        assert.are.equal("return { read = true, last_page = 7 }", read(metadata))
        assert.are.same({ ["m:c"] = { read = true, last_page = 7 } }, store:readKey("chapter_ledger"))
        assert.are.equal("downloaded", queue:getStatus(manga, chapter).state)
        for entry in require("lfs").dir(root) do assert.is_nil(entry:match("^suwayomi_verify_")) end
    end)

    it("keeps uncertain writes fenced until checked reconciliation permits a fresh retry", function()
        local sync = store.io.sync_dir
        store.io.sync_dir = function() return nil, "private /secret/storage" end
        assert(verify())
        tick()
        assert.are.equal(1, #outcomes)
        assert.are.equal("persistence", outcomes[1].stage)
        assert.are.equal("store_blocked", outcomes[1].code)
        assert.is_true(store:isBlocked())
        local accepted, reason = verify()
        assert.is_false(accepted)
        assert.are.equal("store_blocked", reason)
        assert.are.equal(1, #workers)
        store.io.sync_dir = sync
        tick() -- Existing queue reconciliation, not a new recovery mechanism.
        assert.is_false(store:isBlocked())
        assert(verify())
        tick()
        assert.are.equal(2, #outcomes)
        assert.are.equal("valid", outcomes[2].state)
        for _ = 1, 4 do tick() end
        assert.are.equal(2, #outcomes)
        assert.are.equal(original, read(path))
        assert.are.same({ ["m:c"] = { read = true, last_page = 7 } }, store:readKey("chapter_ledger"))
    end)

    it("reports a fence raised while the inspection was running without another write", function()
        assert(verify())
        store.io.sync_dir = function() return nil, "private failure" end
        assert.is_nil(store:saveKey("other_setting", true))
        tick()
        assert.are.equal(1, #outcomes)
        assert.are.equal("persistence", outcomes[1].stage)
        assert.are.equal("store_blocked", outcomes[1].code)
        assert.are.equal(original, read(path))
    end)

    it("waits for a live worker and retains its result until confirmed exit", function()
        assert(verify())
        workers[1].done = false
        tick()
        assert.are.equal(0, #outcomes)
        assert.is_true(queue:getStatus(manga, chapter).verifying)
        local accepted, reason = verify()
        assert.is_false(accepted)
        assert.are.equal("verification_busy", reason)
        local result_file
        for entry in require("lfs").dir(root) do
            if entry:match("^suwayomi_verify_") then result_file = root .. "/" .. entry end
        end
        assert.is_not_nil(read(result_file))
        workers[1].done = true
        tick()
        assert.are.equal("valid", outcomes[1].state)
        assert.is_nil(read(result_file))
    end)

    it("suppresses canceled and navigated callbacks while keeping live-worker ownership", function()
        local current = true
        assert(verify({ is_current = function() return current end }))
        workers[1].done = false
        current = false
        tick()
        assert.is_true(workers[1].terminated)
        assert.are.equal(0, #outcomes)
        assert.is_false(verify())
        workers[1].done = true
        tick()
        assert(verify())
        queue:invalidateVerification()
        tick()
        assert.are.equal(0, #outcomes)
        assert.are.equal(original, read(path))
    end)

    it("drops stale archive identity without saving or delivering inspection evidence", function()
        assert(verify())
        local handle = assert(io.open(path, "ab"))
        handle:write("replacement")
        handle:close()
        local replacement = read(path)
        store.io.rename = function() error("Stale verification must not write") end
        tick()
        assert.are.equal(0, #outcomes)
        assert.is_nil(queue:getStatus(manga, chapter))
        assert.are.equal(replacement, read(path))
    end)

    it("does not deliver on shutdown or clean a worker with unconfirmed exit", function()
        assert(verify())
        workers[1].done = false
        queue:shutdown(2, function() return 0 end)
        tick()
        assert.is_true(workers[1].terminated)
        assert.are.equal(0, #outcomes)
        assert.is_false(verify())
        local retained = false
        for entry in require("lfs").dir(root) do
            if entry:match("^suwayomi_verify_") then retained = true end
        end
        assert.is_true(retained)
        assert.are.equal(original, read(path))
    end)

    it("returns inconclusive inspection for an exited worker with no result", function()
        queue.ffi_util.runInSubProcess = function()
            workers[1] = { done = true }
            return 1
        end
        assert(verify())
        tick()
        assert.are.equal(1, #outcomes)
        assert.are.equal("unverified", outcomes[1].state)
        assert.is_nil(outcomes[1].stage)
        assert.are.equal("unverified", queue:getStatus(manga, chapter).archive_state)
        assert.are.equal(original, read(path))
    end)

    it("logs a redacted delivery failure and never repeats that callback", function()
        local count = 0
        assert(verify(nil, function()
            count = count + 1
            error("private /secret/path token=hidden")
        end))
        tick()
        for _ = 1, 4 do tick() end
        assert.are.equal(1, count)
        assert.are.same({ operation = "downloadQueue.verification", event = "callback_error", status = "valid" },
            events[#events])
        assert(verify())
        tick()
        assert.are.equal("valid", outcomes[1].state)
    end)

    it("does not mistake an unsaved damaged result for a saved repair decision", function()
        local handle = assert(io.open(path, "wb"))
        handle:write("damaged fixture")
        handle:close()
        local rename = store.io.rename
        store.io.rename = function() return nil, "controlled reject" end
        assert(verify())
        tick()
        assert.are.equal("persistence", outcomes[1].stage)
        assert.is_nil(queue:getStatus(manga, chapter))
        assert.are.same({}, settings:loadDownloadQueue())
        store.io.rename = rename
        assert(verify())
        tick()
        assert.are.equal("damaged", outcomes[2].state)
        assert.are.equal("damaged", queue:getStatus(manga, chapter).archive_state)
        assert.are.equal("damaged fixture", read(path))
        assert.are.equal("return { read = true, last_page = 7 }", read(metadata))
    end)

    it("does not deliver a watchdog failure or clean result files before worker exit", function()
        assert(verify())
        workers[1].done = false
        scheduled[1].at = queue.WATCHDOG_TIMEOUT_SECONDS + 1
        tick()
        assert.is_true(workers[1].terminated)
        assert.are.equal(0, #outcomes)
        assert.is_false(verify())
        workers[1].done = true
        tick()
        assert.are.equal(1, #outcomes)
        assert.are.equal("unverified", outcomes[1].state)
        assert.is_nil(outcomes[1].stage)
        assert.are.equal(original, read(path))
    end)
end)
