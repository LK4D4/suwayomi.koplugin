package.path = "?.lua;" .. package.path

describe("suwayomi/subprocess/job", function()
    local original_io_open
    local original_os_rename
    local original_os_remove
    local files
    local removed
    local open_options

    local function install_file_mock()
        original_io_open = io.open
        original_os_rename = os.rename
        original_os_remove = os.remove
        files = {}
        removed = {}
        open_options = {}

        io.open = function(path, mode)
            if tostring(path):match("subprocess") then
                if mode == "w" then
                    local chunks = {}
                    return {
                        write = function(_, ...)
                            if open_options.write_fails then
                                return nil, "disk full"
                            end
                            for _, chunk in ipairs({...}) do
                                table.insert(chunks, chunk)
                            end
                            return true
                        end,
                        close = function()
                            if open_options.close_fails then
                                return nil, "close failed"
                            end
                            files[path] = table.concat(chunks)
                            return true
                        end,
                    }
                end

                local content = files[path]
                if not content then
                    return nil
                end
                local read_offset = 1
                return {
                    read = function(_, what)
                        if what == "*a" then
                            local chunk = content:sub(read_offset)
                            read_offset = #content + 1
                            return chunk
                        end
                        if type(what) == "number" then
                            local chunk = content:sub(read_offset, read_offset + what - 1)
                            read_offset = read_offset + #chunk
                            return chunk
                        end
                    end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end

        os.rename = function(from, to)
            if tostring(from):match("subprocess") or tostring(to):match("subprocess") then
                files[to] = files[from]
                files[from] = nil
                return true
            end
            return original_os_rename(from, to)
        end

        os.remove = function(path)
            if tostring(path):match("subprocess") then
                removed[path] = true
                files[path] = nil
                return true
            end
            return original_os_remove(path)
        end
    end

    before_each(function()
        install_file_mock()
        package.loaded["suwayomi/subprocess/job"] = nil
        package.loaded["suwayomi/settings"] = nil
        package.preload["suwayomi/settings"] = function()
            return {
                getSettingsDir = function()
                    return "/settings"
                end,
            }
        end
    end)

    after_each(function()
        io.open = original_io_open
        os.rename = original_os_rename
        os.remove = original_os_remove
        package.loaded["suwayomi/subprocess/job"] = nil
        package.loaded["suwayomi/settings"] = nil
        package.preload["suwayomi/settings"] = nil
    end)

    it("writes and reads JSON result files atomically", function()
        local Job = require("suwayomi/subprocess/job")

        assert.is_true(Job.writeResult("/settings/subprocess_result.json", {
            ok = true,
            values = { "a", "b" },
        }))

        assert.is_nil(files["/settings/subprocess_result.json.tmp"])
        assert.are.same({
            ok = true,
            values = { "a", "b" },
        }, Job.readResult("/settings/subprocess_result.json", function(parsed)
            parsed.values = type(parsed.values) == "table" and parsed.values or {}
            return parsed
        end))
    end)

    it("rejects oversized result files before JSON decode", function()
        local Job = require("suwayomi/subprocess/job")
        files["/settings/subprocess_oversized.json"] = '{"ok":true,"value":"' .. string.rep("x", 32) .. '"}'

        assert.is_nil(Job.readResult("/settings/subprocess_oversized.json", nil, 16))
    end)

    it("removes temporary result files when JSON writes fail", function()
        local Job = require("suwayomi/subprocess/job")
        open_options.write_fails = true

        assert.is_false(Job.writeResult("/settings/subprocess_write_failure.json", {
            ok = true,
        }))

        assert.is_true(removed["/settings/subprocess_write_failure.json.tmp"])
        assert.is_nil(files["/settings/subprocess_write_failure.json.tmp"])
        assert.is_nil(files["/settings/subprocess_write_failure.json"])
    end)

    it("removes temporary result files when JSON closes fail", function()
        local Job = require("suwayomi/subprocess/job")
        open_options.close_fails = true

        assert.is_false(Job.writeResult("/settings/subprocess_close_failure.json", {
            ok = true,
        }))

        assert.is_true(removed["/settings/subprocess_close_failure.json.tmp"])
        assert.is_nil(files["/settings/subprocess_close_failure.json.tmp"])
        assert.is_nil(files["/settings/subprocess_close_failure.json"])
    end)

    it("builds unique result paths under the settings directory", function()
        local Job = require("suwayomi/subprocess/job")

        local first = Job.buildResultPath("source_fetch")
        local second = Job.buildResultPath("source_fetch")

        assert.are.equal("/settings/suwayomi_dl_source_fetch_1.json", first)
        assert.are.equal("/settings/suwayomi_dl_source_fetch_2.json", second)
    end)

    it("cleans result files and reports launch failures", function()
        local Job = require("suwayomi/subprocess/job")
        local reported_error
        local cleaned

        local active = Job.start({
            result_path = "/settings/subprocess_launch.json",
            ffi_util = {
                runInSubProcess = function()
                    return nil, "spawn failed"
                end,
            },
            on_error = function(err)
                reported_error = err
            end,
            on_cleanup = function()
                cleaned = true
            end,
        })

        assert.is_nil(active)
        assert.are.equal("spawn failed", reported_error)
        assert.is_true(cleaned)
        assert.is_true(removed["/settings/subprocess_launch.json"])
        assert.is_true(removed["/settings/subprocess_launch.json.tmp"])
    end)

    it("polls until the subprocess finishes and then reads the result", function()
        local Job = require("suwayomi/subprocess/job")
        local scheduled
        local finished_result
        local done = false

        local active = Job.start({
            result_path = "/settings/subprocess_poll.json",
            poll_interval_seconds = 0.25,
            ffi_util = {
                runInSubProcess = function()
                    files["/settings/subprocess_poll.json"] = '{"ok":true,"count":2}'
                    return 42
                end,
                isSubProcessDone = function()
                    return done
                end,
            },
            ui_manager = {
                scheduleIn = function(_, delay, callback)
                    scheduled = { delay = delay, callback = callback }
                end,
            },
            read_result = function(path)
                return Job.readResult(path)
            end,
            on_finish = function(_, result)
                finished_result = result
            end,
        })

        assert.are.equal(42, active.pid)
        assert.are.equal(0.25, scheduled.delay)
        assert.is_nil(finished_result)

        done = true
        scheduled.callback()

        assert.are.same({ ok = true, count = 2 }, finished_result)
        assert.is_true(removed["/settings/subprocess_poll.json"])
        assert.is_true(removed["/settings/subprocess_poll.json.tmp"])
    end)

    it("terminates timed-out jobs and keeps polling until the child is reaped", function()
        local Job = require("suwayomi/subprocess/job")
        local scheduled
        local terminated_pid
        local timeout_count = 0
        local cleaned = false
        local done = false

        local active = Job.start({
            result_path = "/settings/subprocess_timeout.json",
            poll_interval_seconds = 0.5,
            timeout_seconds = 5,
            now = function()
                return 100
            end,
            ffi_util = {
                runInSubProcess = function()
                    return 99
                end,
                isSubProcessDone = function()
                    return done
                end,
                terminateSubProcess = function(pid)
                    terminated_pid = pid
                end,
            },
            ui_manager = {
                scheduleIn = function(_, _, callback)
                    scheduled = callback
                end,
            },
            on_timeout = function(timed_out_active)
                timeout_count = timeout_count + 1
                timed_out_active.canceled = true
            end,
            on_cleanup = function()
                cleaned = true
            end,
        })
        active.started_at = 90

        scheduled()
        assert.are.equal(99, terminated_pid)
        assert.are.equal(1, timeout_count)
        assert.is_false(cleaned)

        done = true
        scheduled()

        assert.are.equal(1, timeout_count)
        assert.is_true(cleaned)
        assert.is_true(removed["/settings/subprocess_timeout.json"])
        assert.is_true(removed["/settings/subprocess_timeout.json.tmp"])
    end)

    it("cancels active jobs after the child is reaped", function()
        local Job = require("suwayomi/subprocess/job")
        local scheduled
        local terminated_pid
        local canceled
        local finished = false
        local cleaned = false
        local done = false

        local active = Job.start({
            result_path = "/settings/subprocess_cancel.json",
            ffi_util = {
                runInSubProcess = function()
                    return 321
                end,
                isSubProcessDone = function()
                    return done
                end,
                terminateSubProcess = function(pid)
                    terminated_pid = pid
                end,
            },
            ui_manager = {
                scheduleIn = function(_, _, callback)
                    scheduled = callback
                end,
            },
            on_cancel = function()
                canceled = true
            end,
            on_finish = function()
                finished = true
            end,
            on_cleanup = function()
                cleaned = true
            end,
        })

        removed = {}
        Job.cancel(active)
        assert.are.equal(321, terminated_pid)
        assert.is_true(canceled)
        assert.is_false(finished)
        assert.is_false(cleaned)
        assert.is_nil(removed["/settings/subprocess_cancel.json"])

        assert.is_not_nil(scheduled)
        done = true
        scheduled()

        assert.is_true(cleaned)
        assert.is_true(removed["/settings/subprocess_cancel.json"])
        assert.is_true(removed["/settings/subprocess_cancel.json.tmp"])
    end)
end)
