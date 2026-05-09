package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

local modules_to_clear = {
    "ffi/util",
    "gettext",
    "ui/uimanager",
    "suwayomi/readsync/worker",
    "suwayomi/settings",
    "suwayomi/debug",
    "suwayomi/readsync/controller",
}

local function clearModules()
    for _, name in ipairs(modules_to_clear) do
        package.loaded[name] = nil
        package.preload[name] = nil
    end
end

local function buildPlugin(controller, options)
    options = options or {}
    local ledger = options.ledger or {}
    local plugin = {
        messages = {},
        saved_ledgers = {},
        read_sync_delay_seconds = options.read_sync_delay_seconds or 0.5,
        read_sync_failure_delay_seconds = options.read_sync_failure_delay_seconds or 5,
        read_sync_max_failure_delay_seconds = options.read_sync_max_failure_delay_seconds or 20,
        read_sync_batch_size = options.read_sync_batch_size or 2,
        read_sync_poll_interval_seconds = options.read_sync_poll_interval_seconds or 0.1,
        read_sync_watchdog_timeout_seconds = options.read_sync_watchdog_timeout_seconds or 30,
    }
    for name, method in pairs(controller.methods) do
        plugin[name] = method
    end
    function plugin:showMessage(message)
        table.insert(self.messages, message)
    end
    function plugin:loadChapterLedger()
        return ledger
    end
    function plugin:saveChapterLedger(saved)
        ledger = saved
        table.insert(self.saved_ledgers, saved)
        return saved
    end
    function plugin:hasPendingReadSync(source_ledger)
        for _, entry in pairs(source_ledger or ledger) do
            if entry.pending_read_sync == true and entry.chapter_id then
                return true
            end
        end
        return false
    end
    function plugin:getDesiredReadStateFromLedgerEntry(entry)
        if not entry then
            return nil
        end
        if entry.pending_read_state ~= nil then
            return entry.pending_read_state == true
        end
        return entry.read == true
    end
    function plugin:buildPendingReadSyncBatch(source_ledger, max_count)
        local batch = {}
        for key, entry in pairs(source_ledger or ledger) do
            if entry.pending_read_sync == true and entry.chapter_id then
                table.insert(batch, {
                    key = key,
                    chapter_id = entry.chapter_id,
                    desired_read_state = self:getDesiredReadStateFromLedgerEntry(entry),
                })
                if max_count and #batch >= max_count then
                    break
                end
            end
        end
        return batch
    end
    function plugin:markLedgerEntryRead(entry)
        entry.read = true
        entry.pending_read_sync = true
        entry.pending_read_state = true
        self:saveChapterLedger(ledger)
        self:schedulePendingReadSync()
    end
    function plugin:reconcileDownloadedChapterLedger()
        self.reconcile_count = (self.reconcile_count or 0) + 1
    end
    function plugin:getCurrentDocumentPath()
        return options.current_document_path
    end
    function plugin:isCurrentDocumentFinished()
        return options.current_document_finished == true
    end
    return plugin
end

local function installController(options)
    options = options or {}
    clearModules()
    local scheduled = {}
    local debug_events = {}
    local worker_runs = {}
    local child_callback

    package.preload.gettext = function()
        return function(text)
            return text
        end
    end
    package.preload["ui/uimanager"] = function()
        return {
            scheduleIn = function(_, delay, callback)
                table.insert(scheduled, { delay = delay, callback = callback })
            end,
        }
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
            runInSubProcess = options.runInSubProcess or function(callback)
                child_callback = callback
                return 1234
            end,
            isSubProcessDone = options.isSubProcessDone or function()
                return true
            end,
            terminateSubProcess = options.terminateSubProcess,
        }
    end
    package.preload["suwayomi/readsync/worker"] = function()
        return {
            run = function(_, credentials, batch, result_path)
                table.insert(worker_runs, {
                    credentials = credentials,
                    batch = batch,
                    result_path = result_path,
                })
            end,
            readResult = options.readResult or function()
                return options.worker_result
            end,
        }
    end
    package.preload["suwayomi/settings"] = function()
        return {
            getSettingsDir = function()
                return "/settings"
            end,
            load = function()
                return options.credentials or { server_url = "https://suwayomi.example" }
            end,
        }
    end
    package.preload["suwayomi/debug"] = function()
        return {
            log = function(event)
                table.insert(debug_events, event)
            end,
        }
    end

    local controller = require("suwayomi/readsync/controller")
    return controller, {
        scheduled = scheduled,
        debug_events = debug_events,
        worker_runs = worker_runs,
        get_child_callback = function()
            return child_callback
        end,
    }
end

describe("suwayomi/readsync/controller", function()
    after_each(clearModules)

    it("exports read-sync worker orchestration methods", function()
        helper.assertControllerModule("suwayomi/readsync/controller", {
            "startPendingReadSyncWorker",
            "applyPendingReadSyncResult",
            "syncReadStateNow",
            "onCloseDocument",
        })
    end)

    it("starts manual sync after reconciling downloaded state", function()
        local controller, state = installController()
        local plugin = buildPlugin(controller, {
            ledger = {
                ["m1:c1"] = {
                    chapter_id = "c1",
                    read = true,
                    pending_read_sync = true,
                    pending_read_state = true,
                },
            },
        })

        assert.is_true(plugin:syncReadStateNow())

        assert.are.equal(1, plugin.reconcile_count)
        assert.are.equal("Read state sync started.", plugin.messages[#plugin.messages])
        assert.are.equal(1234, plugin.pending_read_sync_active.pid)
        assert.are.equal(1, #state.scheduled)
        assert.is_function(state.get_child_callback())
        state.get_child_callback()()
        assert.are.equal("c1", state.worker_runs[1].batch[1].chapter_id)
    end)

    it("reports manual sync states without starting duplicate or empty workers", function()
        local controller = installController()
        local plugin = buildPlugin(controller)

        assert.is_false(plugin:syncReadStateNow())
        assert.are.equal("Read state is already synced.", plugin.messages[#plugin.messages])

        plugin.pending_read_sync_active = { pid = 99 }
        assert.is_false(plugin:syncReadStateNow())
        assert.are.equal("Read state sync is already running.", plugin.messages[#plugin.messages])
    end)

    it("applies worker successes while preserving stale or failed entries", function()
        local controller, state = installController()
        local plugin = buildPlugin(controller, {
            ledger = {
                ["m1:c1"] = {
                    chapter_id = "c1",
                    read = true,
                    pending_read_sync = true,
                    pending_read_state = true,
                },
                ["m1:c2"] = {
                    chapter_id = "c2",
                    read = false,
                    pending_read_sync = true,
                    pending_read_state = false,
                },
                ["m1:c3"] = {
                    chapter_id = "c3",
                    read = true,
                    pending_read_sync = true,
                    pending_read_state = true,
                },
            },
        })

        local synced, attempted = plugin:applyPendingReadSyncResult({
            batch = {
                { key = "m1:c1", chapter_id = "c1", desired_read_state = true },
                { key = "m1:c2", chapter_id = "c2", desired_read_state = true },
                { key = "m1:c3", chapter_id = "c3", desired_read_state = true },
            },
        }, {
            attempted = 3,
            successes = {
                { key = "m1:c1", chapter_id = "c1", desired_read_state = true },
                { key = "m1:c2", chapter_id = "c2", desired_read_state = true },
            },
            failures = {
                { key = "m1:c3", chapter_id = "c3", desired_read_state = true, error = "offline" },
            },
        })

        assert.are.equal(1, synced)
        assert.are.equal(3, attempted)
        assert.is_nil(plugin:loadChapterLedger()["m1:c1"].pending_read_sync)
        assert.is_true(plugin:loadChapterLedger()["m1:c2"].pending_read_sync)
        assert.is_true(plugin:loadChapterLedger()["m1:c3"].pending_read_sync)
        assert.are.equal("failure", state.debug_events[1].event)
        assert.are.equal("conflict", state.debug_events[2].event)
    end)

    it("keeps pending state and schedules retry when worker result is missing", function()
        local controller, state = installController({ worker_result = nil })
        local plugin = buildPlugin(controller, {
            ledger = {
                ["m1:c1"] = {
                    chapter_id = "c1",
                    read = true,
                    pending_read_sync = true,
                    pending_read_state = true,
                },
            },
        })
        assert.is_true(plugin:startPendingReadSyncWorker(nil, 1))

        state.scheduled[1].callback()

        assert.is_true(plugin:loadChapterLedger()["m1:c1"].pending_read_sync)
        assert.is_nil(plugin.pending_read_sync_active)
        assert.are.equal(2, #state.scheduled)
        assert.are.equal(5, state.scheduled[2].delay)
    end)

    it("batches pending work and backs off failed worker starts", function()
        local attempts = 0
        local controller, state = installController({
            runInSubProcess = function()
                attempts = attempts + 1
                return false, "fork failed"
            end,
        })
        local plugin = buildPlugin(controller, {
            ledger = {
                ["m1:c1"] = { chapter_id = "c1", read = true, pending_read_sync = true },
                ["m1:c2"] = { chapter_id = "c2", read = true, pending_read_sync = true },
                ["m1:c3"] = { chapter_id = "c3", read = true, pending_read_sync = true },
            },
        })

        plugin:schedulePendingReadSync()
        assert.are.equal(0.5, state.scheduled[1].delay)
        state.scheduled[1].callback()

        assert.are.equal(1, attempts)
        assert.are.equal("Could not start read sync: fork failed", plugin.messages[#plugin.messages])
        assert.are.equal(5, state.scheduled[2].delay)

        state.scheduled[2].callback()
        assert.are.equal(2, attempts)
        assert.are.equal(10, state.scheduled[3].delay)
    end)

    it("marks the matching ledger entry read when KOReader closes a finished document", function()
        local controller, state = installController()
        local plugin = buildPlugin(controller, {
            current_document_path = "/books/Frieren/Ch. 1.cbz",
            current_document_finished = true,
            ledger = {
                ["m1:c1"] = {
                    chapter_id = "c1",
                    path = "/books/Frieren/Ch. 1.cbz",
                    read = false,
                },
            },
        })

        plugin:onCloseDocument()

        assert.is_true(plugin:loadChapterLedger()["m1:c1"].read)
        assert.is_true(plugin:loadChapterLedger()["m1:c1"].pending_read_sync)
        assert.are.equal(1, #plugin.saved_ledgers)
        assert.are.equal(1, #state.scheduled)
    end)
end)
