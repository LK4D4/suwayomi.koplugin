package.path = "?.lua;" .. package.path

local runtime_helper = require("spec/support/plugin_runtime_spec_helper")

describe("issue #45 source worker cancellation ownership", function()
    local runtime, Job, plugin, processes, paths, removed, original_remove
    local credentials = { server_url = "https://suwayomi.example" }

    local function temporaryPath()
        local path = os.tmpname()
        paths[#paths + 1] = path
        return path
    end

    local function writeFile(path, content)
        local file = assert(io.open(path, "w"))
        assert(file:write(content))
        assert(file:close())
    end

    local function exists(path)
        local file = io.open(path, "r")
        if not file then return false end
        file:close()
        return true
    end

    local function tick()
        local scheduled = runtime.scheduled
        runtime.scheduled = {}
        for _, task in ipairs(scheduled) do task.callback() end
    end

    local function buildPlugin()
        return require("main")({
            published = {},
            getSourceFetchResultPath = function() return temporaryPath() end,
            showFetchedSources = function(self, result)
                self.published[#self.published + 1] = result
            end,
        })
    end

    local function startSource(owner, name)
        assert.is_true(owner:startSourceFetchWorker(credentials))
        local active = owner.source_fetch_active
        writeFile(active.result_path, '{"ok":true,"sources":[{"id":"' .. name .. '"}]}')
        writeFile(active.result_path .. ".tmp", "pending")
        removed[active.result_path] = 0
        removed[active.result_path .. ".tmp"] = 0
        return active
    end

    before_each(function()
        runtime = runtime_helper.install({ credentials = credentials })
        processes, paths, removed = {}, {}, {}
        original_remove = os.remove
        os.remove = function(path)
            removed[path] = (removed[path] or 0) + 1
            return original_remove(path)
        end
        local ffi_util = require("ffi/util")
        ffi_util.runInSubProcess = function()
            local pid = #processes + 1
            processes[pid] = { done = false, terminations = 0, checks = 0 }
            return pid
        end
        ffi_util.isSubProcessDone = function(pid)
            local process = assert(processes[pid])
            process.checks = process.checks + 1
            return process.done
        end
        ffi_util.terminateSubProcess = function(pid)
            local process = assert(processes[pid])
            process.terminations = process.terminations + 1
        end
        Job = require("suwayomi/subprocess/job")
        package.preload["suwayomi/browse/source_fetch_worker"] = function()
            return { readResult = function(_, path) return Job.readResult(path) end }
        end
        plugin = buildPlugin()
    end)

    after_each(function()
        os.remove = original_remove
        for _, path in ipairs(paths) do
            os.remove(path)
            os.remove(path .. ".tmp")
        end
        runtime_helper.teardown()
    end)

    it("terminates once, polls until exit, and cleans only the canceled worker files", function()
        local unrelated_path = temporaryPath()
        writeFile(unrelated_path, "download data")
        local download_pid = require("ffi/util").runInSubProcess()
        local active = startSource(plugin, "canceled")
        local loading = active.loading_message

        assert.is_true(plugin:cancelSourceFetchWorker())
        assert.is_false(plugin:cancelSourceFetchWorker())
        Job.cancel(active)
        assert.are.equal(1, processes[active.pid].terminations)
        assert.are.same({ loading }, runtime.closed_widgets)
        tick()
        tick()
        assert.are.equal(2, processes[active.pid].checks)
        assert.is_true(exists(active.result_path))
        assert.is_true(exists(active.result_path .. ".tmp"))
        assert.are.equal(0, removed[active.result_path])
        assert.are.same({}, plugin.published)

        processes[active.pid].done = true
        tick()
        Job.poll(active)
        Job.cancel(active)
        assert.are.equal(3, processes[active.pid].checks)
        assert.are.equal(1, processes[active.pid].terminations)
        assert.are.equal(1, removed[active.result_path])
        assert.are.equal(1, removed[active.result_path .. ".tmp"])
        assert.is_false(exists(active.result_path))
        assert.is_false(exists(active.result_path .. ".tmp"))
        assert.are.same({}, plugin.published)
        assert.are.equal(0, processes[download_pid].terminations)
        assert.are.equal(0, processes[download_pid].checks)
        assert.is_true(exists(unrelated_path))
    end)

    it("dismisses loading without letting old callbacks cancel or publish over a replacement", function()
        local old = startSource(plugin, "old")
        local dismiss = old.loading_message.dismiss_callback
        assert.is_function(dismiss)
        dismiss()
        local replacement = startSource(plugin, "replacement")
        dismiss()
        assert.are.equal(0, processes[replacement.pid].terminations)
        processes[old.pid].done = true
        tick()
        assert.are.equal(replacement, plugin.source_fetch_active)
        assert.are.same({}, plugin.published)
        assert.are.equal(1, #runtime.closed_widgets)

        local loading = replacement.loading_message
        processes[replacement.pid].done = true
        tick()
        assert.are.same({ { ok = true, sources = { { id = "replacement" } } } }, plugin.published)
        assert.is_nil(loading.dismiss_callback)
        assert.are.equal(0, processes[replacement.pid].terminations)
        assert.are.equal(2, #runtime.closed_widgets)
    end)

    it("retires a host without affecting another host or publishing delayed cache refreshes", function()
        plugin:scheduleSourceCacheRefresh(credentials)
        local active = startSource(plugin, "retired")
        local loading = active.loading_message
        assert.is_nil(plugin:onCloseWidget())
        assert.are.equal(1, processes[active.pid].terminations)
        assert.are.same({ loading }, runtime.closed_widgets)
        assert.is_false(plugin:startSourceFetchWorker(credentials))
        local later_host = buildPlugin()
        local later = startSource(later_host, "later")
        processes[active.pid].done = true
        processes[later.pid].done = true
        tick()
        assert.are.same({}, plugin.published)
        assert.are.same({ { ok = true, sources = { { id = "later" } } } }, later_host.published)
        assert.are.equal(2, #processes)
    end)

    it("does not treat unavailable polling as proof that a canceled worker exited", function()
        local active = startSource(plugin, "unscheduled")
        runtime.scheduled = {}
        active.poll_scheduled = false
        active.ui_manager = nil
        plugin:cancelSourceFetchWorker()
        assert.is_true(exists(active.result_path))
        assert.are.equal(0, removed[active.result_path])
        Job.poll(active)
        assert.is_true(exists(active.result_path))
        processes[active.pid].done = true
        Job.poll(active)
        assert.is_false(exists(active.result_path))
        assert.are.equal(1, removed[active.result_path])
        assert.are.same({}, plugin.published)
    end)
end)
