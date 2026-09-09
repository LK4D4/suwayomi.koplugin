package.path = "?.lua;" .. package.path

local runtime_helper = require("spec/support/plugin_runtime_spec_helper")

describe("stopping download reservations through the process service", function()
    local service, queue, settings, directory, timers, workers, clock, files
    local manga = { id = "m1", title = "Example", source = { id = "s1", name = "Source" } }
    local chapters = {
        { id = "a", name = "A" }, { id = "b", name = "B" },
        { id = "c", name = "C" }, { id = "d", name = "D" },
    }
    local modules = { "suwayomi/settings/store", "suwayomi/chapters/manual_deletion",
        "suwayomi/chapters/archive_identity", "docsettings" }
    local function clear()
        runtime_helper.clearModules()
        runtime_helper.clearPreloads()
        for _, name in ipairs(modules) do package.loaded[name], package.preload[name] = nil, nil end
    end
    local function write(path, content)
        files[path] = true
        local handle = assert(io.open(path, "wb"))
        assert(handle:write(content))
        assert(handle:close())
    end
    local function read(path)
        local handle = io.open(path, "rb")
        if not handle then return nil end
        local content = handle:read("*a")
        handle:close()
        return content
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
    local function active(index)
        return queue:getActiveJob("m1:" .. chapters[index].id)
    end
    local function enqueue(count)
        for index = 1, count do assert(queue:enqueue(manga, chapters[index], directory)) end
        advance(0)
    end
    local function setLimit(limit)
        queue.max_active_chapters = assert(settings:saveMaxParallelChapterDownloads(limit))
        queue:process()
    end
    local function complete(index)
        local job = assert(active(index))
        local path = directory .. "/" .. chapters[index].id .. ".cbz"
        write(path, "completed archive")
        write(job.progress_path, "state=downloaded\ncurrent=1\ntotal=1\npath=" .. path .. "\n")
        workers[job.pid].done = true
        advance(0.5)
        assert.are.equal("downloaded", queue:getStatus(manga, chapters[index]).state)
        assert.are.equal(path, settings:loadChapterLedger()[job.key].path)
    end
    local function failTransient(job)
        write(job.progress_path, "state=failed\nerror=temporary network error\nretryable=true\n")
        advance(0.5)
        local retry = assert(queue:findPersistentJob(job.key))
        assert.are.equal("queued", retry.state)
        assert.are.equal(1, retry.retry_count)
        return retry.retry_at
    end
    local function reservations(count)
        local live = 0
        for _, worker in ipairs(workers) do if not worker.done then live = live + 1 end end
        assert.are.equal(count, live)
        assert.are.equal(count, queue:getActiveCount())
    end
    before_each(function()
        clear()
        runtime_helper.install()
        clock, timers, workers, files = 100, {}, {}, {}
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
        assert(settings:saveDownloadDirectory(directory))
        assert(settings:saveMaxParallelChapterDownloads(2))
        local ui = require("ui/uimanager")
        ui.quit = function() end
        ui.scheduleIn = function(_, delay, callback) timers[#timers + 1] = { at = clock + delay, callback = callback } end
        ui.unschedule = function(_, callback)
            for index = #timers, 1, -1 do if timers[index].callback == callback then table.remove(timers, index) end end
        end
        local ffi_util = require("ffi/util")
        ffi_util.runInSubProcess = function(callback)
            local live = 0
            for _, worker in ipairs(workers) do if not worker.done then live = live + 1 end end
            assert.is_true(live < queue.max_active_chapters, "a launch must count every unconfirmed worker")
            workers[#workers + 1] = { callback = callback }
            return #workers
        end
        ffi_util.isSubProcessDone = function(pid) return workers[pid].done == true end
        ffi_util.terminateSubProcess = function(pid) workers[pid].terminated = true end
        local downloader = require("suwayomi/downloads/downloader")
        downloader.getTargetPath = function(_, root, _, chapter) return root, root .. "/" .. chapter.id .. ".cbz" end
        downloader.chapterExists = function(_, path) return read(path) ~= nil end
        downloader.getPartialPath = function(_, path, id) return path .. "." .. id .. ".part" end
        downloader.getDirectPartialPath = function(_, path, id) return path .. "." .. id .. ".direct.part" end
        package.preload.docsettings = function()
            return { findSidecarFile = function() end,
                getSidecarFilename = function() return "metadata.lua" end,
                getSidecarDir = function(_, path) return path .. ".sdr" end,
                isHashLocationEnabled = function() return false end }
        end
        service = require("suwayomi/downloads/service"):new{
            settings = settings, ui_manager = ui, ffi_util = ffi_util, downloader = downloader,
            now = function() return clock end,
        }
        queue = service:getQueue()
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

    it("starts C after B completes while canceled A keeps its slot and attempt files", function()
        enqueue(3)
        local first = assert(active(1))
        local progress = "state=downloading\ncurrent=1\ntotal=8\n"
        local path = directory .. "/a.cbz"
        local partial = queue.downloader:getPartialPath(path, first.attempt_id)
        local direct = queue.downloader:getDirectPartialPath(path, first.attempt_id)
        write(first.progress_path, progress)
        write(partial, "owned partial")
        write(direct, "owned direct partial")
        write(path .. ".part", "unknown partial")
        assert(queue:cancelPending(manga, chapters[1]))
        assert.is_true(workers[first.pid].terminated)
        reservations(2)
        assert.is_nil(active(3))
        complete(2)
        assert.is_not_nil(active(3))
        assert.is_true(queue:isChapterBusy(first.key))
        assert.is_false(queue:enqueue(manga, chapters[1], directory))
        assert.are.equal(progress, read(first.progress_path))
        assert.are.equal("owned partial", read(partial))
        assert.are.equal("owned direct partial", read(direct))
        reservations(2)
        advance(2)
        assert.are.equal(3, #workers)
        assert.are.equal(progress, read(first.progress_path))
        write(path, "published while stopping")
        workers[first.pid].done = true
        advance(1)
        reservations(1)
        assert.is_false(queue:isChapterBusy(first.key))
        assert.is_nil(read(first.progress_path))
        assert.is_nil(read(partial))
        assert.is_nil(read(direct))
        assert.are.equal("unknown partial", read(path .. ".part"))
        assert.are.equal("published while stopping", read(path))
    end)

    it("keeps a full concurrency-one slot and same chapter reserved until confirmed exit", function()
        setLimit(1)
        enqueue(2)
        local first = assert(active(1))
        write(first.progress_path, "state=downloading\n")
        assert(queue:cancelPending(manga, chapters[1]))
        advance(2)
        reservations(1)
        assert.are.equal(1, #workers)
        assert.is_nil(active(2))
        assert.is_false(queue:enqueue(manga, chapters[1], directory))
        assert.are.equal("state=downloading\n", read(first.progress_path))
        workers[first.pid].done = true
        advance(1)
        assert.is_not_nil(active(2))
        assert.is_false(queue:isChapterBusy(first.key))
        assert.is_nil(read(first.progress_path))
        assert(queue:enqueue(manga, chapters[1], directory))
        complete(2)
        local replacement = assert(active(1))
        assert.are_not.equal(first.pid, replacement.pid)
        assert.are_not.equal(first.attempt_id, replacement.attempt_id)
        reservations(1)
    end)

    it("skips an overdue retry's stopping attempt without blocking ready fresh chapters", function()
        enqueue(4)
        local first = assert(active(1))
        local retry_at = failTransient(first)
        complete(2)
        assert.is_not_nil(active(3))
        advance(retry_at - clock + 1)
        assert.is_nil(active(1))
        assert.is_true(queue:isChapterBusy(first.key))
        assert.is_not_nil(read(first.progress_path))
        reservations(2)
        complete(3)
        assert.is_not_nil(active(4))
        assert.is_nil(active(1))
        assert.are.equal(4, #workers)
        workers[first.pid].done = true
        advance(1)
        local replacement = assert(active(1))
        assert.are_not.equal(first.attempt_id, replacement.attempt_id)
        assert.are.equal(1, queue:findPersistentJob(first.key).retry_count)
        assert.is_nil(read(first.progress_path))
        reservations(2)
    end)

    it("keeps a future retry deadline and selects that retry ahead of fresh work once ready", function()
        enqueue(4)
        local first = assert(active(1))
        local retry_at = failTransient(first)
        workers[first.pid].done = true
        advance(0.5)
        assert.is_not_nil(active(3))
        assert.is_nil(active(1))
        assert.are.equal(retry_at, queue:findPersistentJob(first.key).retry_at)
        assert.are.equal(1, queue:findPersistentJob(first.key).retry_count)
        advance(retry_at - clock - 0.25)
        assert.is_nil(active(1))
        advance(0.25)
        reservations(2)
        complete(2)
        assert.is_not_nil(active(1))
        assert.is_nil(active(4))
        assert.are.equal(1, queue:findPersistentJob(first.key).retry_count)
        complete(3)
        assert.is_not_nil(active(4))
        reservations(2)
    end)

    it("honors lower and higher limits while a canceled child still reserves capacity", function()
        enqueue(4)
        local first, second = assert(active(1)), assert(active(2))
        assert(queue:cancelPending(manga, chapters[1]))
        setLimit(1)
        assert.is_nil(workers[second.pid].terminated)
        complete(2)
        reservations(1)
        assert.is_nil(active(3))
        setLimit(2)
        advance(0)
        assert.is_not_nil(active(3))
        assert.is_nil(active(4))
        reservations(2)
        setLimit(1)
        workers[first.pid].done = true
        advance(1)
        reservations(1)
        assert.is_nil(active(4))
        complete(3)
        assert.is_not_nil(active(4))
        reservations(1)
    end)
end)
