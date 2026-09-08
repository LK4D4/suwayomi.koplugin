-- Optional Linux helper probe: luajit scripts/check-download-subprocess.lua /path/to/koreader/base
-- Uses the supplied KOReader helper unchanged and real children; no network or user settings.
local helper_root = assert(arg[1], "provide the KOReader base directory")
package.path = helper_root .. "/?.lua;?.lua;" .. package.path
package.preload["libs/libkoreader-lfs"] = function() return require("lfs") end
package.preload["suwayomi/i18n"] = function() return {} end
local util = require("ffi/util")
local socket = require("socket")
local lifecycle = require("suwayomi/downloads/active_jobs"):new{
    queue = { ffi_util = util },
}
local workers, markers = {}, {}
for index = 1, 4 do
    local marker = os.tmpname()
    os.remove(marker)
    markers[#markers + 1] = marker
    local pid = assert(util.runInSubProcess(function()
        local file = assert(io.open(marker, "wb"))
        file:write("ready")
        file:close()
        socket.sleep(10)
    end))
    workers[#workers + 1] = pid
    lifecycle.jobs[tostring(index)] = { key = tostring(index), pid = pid }
end
local ready_deadline = socket.gettime() + 3
local all_ready
repeat
    all_ready = true
    for _, marker in ipairs(markers) do
        local file = io.open(marker, "rb")
        if file then file:close() else all_ready = false end
    end
    if not all_ready then socket.sleep(0.01) end
until all_ready or socket.gettime() >= ready_deadline
-- Include a child already in ordinary cancellation handling.
lifecycle:terminateJob(lifecycle.jobs["1"])
lifecycle.jobs["1"] = nil
local started = socket.gettime()
lifecycle:shutdown()
local elapsed = socket.gettime() - started
local deadline = socket.gettime() + 2
local all_done
repeat
    all_done = true
    for _, pid in ipairs(workers) do
        if not util.isSubProcessDone(pid) then all_done = false end
    end
    if not all_done then socket.sleep(0.01) end
until all_done or socket.gettime() >= deadline
for _, marker in ipairs(markers) do os.remove(marker) end
assert(all_ready, "children did not reach the helper's process group setup")
assert(elapsed < 2, "shutdown exceeded its total two-second budget")
assert(all_done, "a known child remained alive after helper termination")
print(string.format("KOReader helper: four children stopped; shutdown added %.6f seconds", elapsed))

-- Result publication is not child completion. A canceled request must keep its
-- files until the known child exits, and must never deliver the obsolete result.
local Job = require("suwayomi/subprocess/job")
local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end
local function await(predicate, message)
    local limit = socket.gettime() + 3
    repeat
        if predicate() then return end
        socket.sleep(0.01)
    until socket.gettime() >= limit
    error(message)
end
for _, cancel in ipairs({ false, true }) do
    local result_path, release_path = os.tmpname(), os.tmpname()
    os.remove(result_path)
    os.remove(release_path)
    local delivered
    local active = assert(Job.start{
        result_path = result_path,
        ffi_util = util,
        ui_manager = { scheduleIn = function() end },
        run = function(path)
            assert(Job.writeResult(path, { ok = true, chapter_id = "6" }))
            local release_deadline = socket.gettime() + 5
            while not exists(release_path) and socket.gettime() < release_deadline do socket.sleep(0.01) end
        end,
        on_finish = function(_, result) delivered = result end,
    })
    await(function() return exists(result_path) end, "context child did not publish its result")
    Job.poll(active)
    assert(not delivered, "result delivered before known-child completion")
    assert(exists(result_path), "running child's result was removed")
    if cancel then
        Job.cancel(active)
        assert(exists(result_path), "cancel removed a result without confirmed child completion")
    else
        local release = assert(io.open(release_path, "wb"))
        assert(release:close())
    end
    await(function() return util.isSubProcessDone(active.pid) end, "context child failed to exit")
    Job.poll(active)
    if cancel then
        assert(not delivered, "canceled context result was delivered")
    else
        assert(delivered and delivered.chapter_id == "6", "completed context result was lost")
    end
    assert(not exists(result_path), "known exited child's result was not cleaned")
    assert(not exists(result_path .. ".tmp"), "known exited child's temporary result was not cleaned")
    os.remove(release_path)
end
print("KOReader helper: result lifetime, completed delivery, cancellation rejection, and known-child cleanup passed")
