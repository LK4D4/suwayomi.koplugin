package.path = "?.lua;" .. package.path

local runtime_helper = require("spec/support/plugin_runtime_spec_helper")

describe("process-owned download navigation", function()
    local original_time = os.time
    local runtime, shell, settings, ui, workers, clock, timers, directory, files, hosts
    local manga = { id = "m1", title = "Example", source = { id = "s1", name = "Source" } }
    local chapters = {
        { id = "c1", name = "Chapter 1" }, { id = "c2", name = "Chapter 2" },
        { id = "c3", name = "Chapter 3" }, { id = "c4", name = "Chapter 4" },
    }
    local extra_modules = {
        "suwayomi/downloads/service", "suwayomi/downloads/cleanup_adapter", "suwayomi/settings/store",
        "suwayomi/ui/downloads", "suwayomi/ui/menu_utils", "suwayomi/ui/list_menu",
        "suwayomi/ui/list_rows", "docsettings",
        "suwayomi/chapters/manual_deletion", "suwayomi/chapters/archive_identity",
        "suwayomi/downloads/refill", "suwayomi/network/request_worker", "suwayomi/network/request_job",
        "ui/widget/textviewer",
    }
    local function clear()
        runtime_helper.clearModules()
        runtime_helper.clearPreloads()
        for _, name in ipairs(extra_modules) do package.loaded[name], package.preload[name] = nil, nil end
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
        local turns = 0
        while true do
            local next_index
            for index, timer in ipairs(timers) do
                if timer.at <= clock and (not next_index or timer.at < timers[next_index].at) then next_index = index end
            end
            if not next_index then return end
            turns = turns + 1
            assert.is_true(turns < 1000, "scheduled callbacks must yield")
            table.remove(timers, next_index).callback()
        end
    end
    -- KOReader WidgetContainer dispatches to children first, stopping on true.
    local function dispatch(widget, event)
        for _, child in ipairs(widget) do
            if dispatch(child, event) then return true end
        end
        local handler = widget["on" .. event]
        if handler then return handler(widget) end
    end
    local function host(kind, path)
        local owner = { menu = { registerToMainMenu = function() end }, events = {} }
        if kind ~= "files" then
            owner.document = {
                file = path or directory .. "/" .. kind .. ".cbz",
                close = function(document)
                    document.closed = true
                    owner.events[#owner.events + 1] = "DocumentClosed"
                end,
            }
        end
        runtime.reader_ui.instance = kind ~= "files" and owner or nil
        local plugin = shell({ ui = owner })
        plugin:init()
        owner.plugin = plugin
        owner[1] = plugin
        owner[2] = {
            onShowingReader = function() owner.events[#owner.events + 1] = "ShowingReader" end,
            onCloseDocument = function()
                assert.is_not_nil(owner.document)
                assert.is_nil(owner.document.closed)
                owner.events[#owner.events + 1] = "CloseDocument"
            end,
            onCloseWidget = function()
                assert.is_nil(owner.document, "the document closes before host teardown")
                assert.is_nil(plugin.download_snapshot, "the preceding plugin has detached")
                owner.events[#owner.events + 1] = "CloseWidget"
            end,
        }
        function owner:handleEvent(event) return dispatch(self, event) end
        function owner:onCloseWidget()
            self.closed = true
            for index, widget in ipairs(hosts) do
                if widget == self then table.remove(hosts, index); break end
            end
            if runtime.reader_ui.instance == self then runtime.reader_ui.instance = nil end
        end
        function owner:close()
            if self.document then
                self:handleEvent("CloseDocument")
                self.document:close()
                self.document = nil
            end
            self:handleEvent("CloseWidget")
            assert.are.equal("CloseWidget", self.events[#self.events], "CloseWidget must reach the downstream recipient")
            assert.is_true(self.closed, "CloseWidget must reach the host after its modules")
        end
        function owner:onShowingReader() self:close() end
        hosts[#hosts + 1] = owner
        return plugin, owner
    end
    before_each(function()
        clear()
        runtime = runtime_helper.install()
        files, workers, timers, hosts, clock = {}, {}, {}, {}, 100
        os.time = function() return clock end
        directory = os.tmpname():gsub("\\", "/")
        os.remove(directory)
        package.preload["suwayomi/downloads/queue"] = nil
        package.preload["suwayomi/settings"] = nil
        package.preload["suwayomi/navigation"] = nil
        package.preload.lfs, package.loaded.lfs = nil, nil
        package.preload["suwayomi/fs"] = nil
        assert(require("lfs").mkdir(directory))
        package.preload.datastorage = function() return { getSettingsDir = function() return directory end } end
        package.preload.luasettings = function() return { open = function() return { data = {} } end } end
        settings = require("suwayomi/settings")
        local store = require("suwayomi/settings/store"):new{ path = directory .. "-settings.lua" }
        settings.store = store
        files[store.path] = true
        assert(store:saveDocument(function(doc)
            doc.download_directory = directory
            doc.max_parallel_chapter_downloads = 2
        end))
        ui = require("ui/uimanager")
        ui.quit = function(_, ...) return select("#", ...), ... end
        ui.scheduleIn = function(_, delay, callback) timers[#timers + 1] = { at = clock + delay, callback = callback } end
        ui.unschedule = function(_, callback)
            for index = #timers, 1, -1 do
                if timers[index].callback == callback then table.remove(timers, index) end
            end
        end
        ui.nextTick = function(_, callback) ui:scheduleIn(0, callback) end
        ui.broadcastEvent = function(_, event)
            local recipients = {}
            for index, widget in ipairs(hosts) do recipients[index] = widget end
            for _, widget in ipairs(recipients) do widget:handleEvent(event) end
        end
        runtime.reader_ui.showReader = function(_, path)
            assert.is_not_nil(read(path))
            ui:broadcastEvent("ShowingReader")
            ui:nextTick(function() host("reader", path) end)
        end
        local debug = require("suwayomi/debug")
        debug.now = function() return clock end
        debug.elapsedMs = function(start) return (clock - start) * 1000 end
        local ffi_util = require("ffi/util")
        ffi_util.runInSubProcess = function(callback)
            local pid = #workers + 1
            workers[pid] = { callback = callback, alive = true }
            return pid
        end
        ffi_util.isSubProcessDone = function(pid) return not workers[pid].alive end
        ffi_util.terminateSubProcess = function(pid) workers[pid].terminated = true end
        local downloader = require("suwayomi/downloads/downloader")
        downloader.getTargetPath = function(_, _, _, chapter) return directory, directory .. "/" .. chapter.id .. ".cbz" end
        downloader.chapterExists = function(_, path) return read(path) ~= nil end
        downloader.getPartialPath = function(_, path, id) return path .. "." .. id .. ".part" end
        downloader.getDirectPartialPath = function(_, path, id) return path .. "." .. id .. ".direct.part" end
        package.preload.docsettings = function()
            return {
                findSidecarFile = function() end,
                getSidecarFilename = function() return "metadata.lua" end,
                getSidecarDir = function(_, path) return path .. ".sdr" end,
                isHashLocationEnabled = function() return false end,
            }
        end
        package.preload["suwayomi/ui/list_menu"] = function()
            return {
                show = function(options) return options end,
                update = function(menu, options) menu.item_table = options.item_table; return true end,
            }
        end
        local facade = require("suwayomi/ui")
        for name, method in pairs(require("suwayomi/ui/downloads")) do facade[name] = method end
        facade.updateChapterMenu = function(menu, options)
            menu.item_table = require("suwayomi/ui/list_rows").buildChapterMenuTable(options.chapters)
        end
        shell = require("main")
    end)
    after_each(function()
        os.time = original_time
        for path in pairs(files or {}) do os.remove(path) end
        if directory then
            for _, chapter in ipairs(chapters) do require("lfs").rmdir(directory .. "/" .. chapter.id .. ".cbz.sdr") end
        end
        if directory then require("lfs").rmdir(directory) end
        clear()
    end)

    for _, limit in ipairs({ 2, 1 }) do
    it("keeps workers, progress and rendered rows through both navigation routes at concurrency " .. limit, function()
        assert(settings:saveMaxParallelChapterDownloads(limit))
        local plugin, owner = host("files")
        local queue = plugin:getDownloadQueue()
        for _, chapter in ipairs(chapters) do assert(queue:enqueue(manga, chapter, directory)) end
        advance(0)
        local active = queue:getActiveJob("m1:c1")
        write(active.progress_path, "state=downloading\ncurrent=3\ntotal=8\n")
        write(directory .. "/c1.cbz.part", "partial pages")
        advance(0.5)
        local committed = read(settings.store.path)
        for _, destination in ipairs({ "reader-a", "files", "reader-b", "reader-c" }) do
            local previous, was_reader = owner, owner.document ~= nil
            if destination == "files" then
                owner:close()
                plugin, owner = host("files")
                assert.are.same({ "CloseDocument", "DocumentClosed", "CloseWidget" }, previous.events)
            else
                local path = directory .. "/" .. destination .. ".cbz"
                write(path, "already downloaded reader archive")
                runtime.reader_ui:showReader(path)
                assert.is_true(previous.closed)
                assert.is_nil(runtime.reader_ui.instance, "ShowingReader closes the old host before reader construction")
                assert.are.same(was_reader and {
                    "ShowingReader", "CloseDocument", "DocumentClosed", "CloseWidget",
                } or { "ShowingReader", "CloseWidget" }, previous.events)
                advance(0)
                owner = runtime.reader_ui.instance
                plugin = owner.plugin
                assert.are.equal(path, owner.document.file)
            end
            assert.are.equal(queue, plugin:getDownloadQueue())
            assert.are.equal(active, queue:getActiveJob("m1:c1"))
            assert.are.equal(limit, #workers)
            assert.are.equal("partial pages", read(directory .. "/c1.cbz.part"))
            assert.is_not_nil(read(active.progress_path))
            assert.are.equal(committed, read(settings.store.path))
            assert.are.equal("Downloads", plugin:showHome().actions[3].text)
            plugin:setCurrentMangaChapterContext(manga, chapters)
            plugin.current_chapter_menu = {}
            plugin:trackSuwayomiScreen("chapters", plugin.current_chapter_menu)
            plugin:refreshChapterMenu({ quick = true })
            assert.are.equal("Downloading 3/8", plugin.current_chapter_menu.item_table[1].mandatory)
            local menu = plugin:showDownloads()
            local progress_row
            for _, row in ipairs(menu.item_table) do
                if row.text == "Example / Chapter 1" then progress_row = row end
            end
            assert.are.equal("Downloading 3/8", progress_row.mandatory)
            local queued_ids = {}
            for _, job in ipairs(queue:getSnapshot().queued) do queued_ids[#queued_ids + 1] = job.chapter.id end
            assert.are.same(limit == 2 and { "c3", "c4" } or { "c2", "c3", "c4" }, queued_ids)
        end
    end)
    end

    it("requeues startup work with its retry budget and leaves final adoption to workers", function()
        local jobs = {}
        for index, chapter in ipairs(chapters) do
            jobs[index] = { key = "m1:" .. chapter.id, manga = manga, chapter = chapter,
                download_directory = directory, state = index == 1 and "downloading" or "queued",
                retry_count = 3, retry_at = 999,
            }
        end
        jobs[3].state, jobs[3].progress = "failed", { error = "HTTP 401: full original diagnostic" }
        jobs[5] = { key = "future", state = "future-version", custom = { preserve = true } }
        assert(settings:saveDownloadQueue(jobs))
        local path = directory .. "/c4.cbz"
        write(path, "already complete")
        write(directory .. "/c1.cbz.part", "old untracked partial")
        local plugin = host("files")
        local queue = plugin:getDownloadQueue()
        advance(0)
        assert.are.equal(0, #workers)
        assert.are.equal(1, queue:getFailedCount())
        assert.are.equal("queued", queue:getStatus(manga, chapters[1]).state)
        assert.are.equal("queued", queue:getStatus(manga, chapters[2]).state)
        assert.are.equal(999, queue:findPersistentJob("m1:c2").retry_at)
        assert.are.equal(3, queue:findPersistentJob("m1:c2").retry_count)
        assert.are.equal("HTTP 401: full original diagnostic", queue:findPersistentJob("m1:c3").progress.error)
        assert.are.same(jobs[5], queue:findPersistentJob("future"))
        assert.is_nil(settings:loadChapterLedger()["m1:c4"])
        assert.is_nil(settings:loadReaderReturnContexts()[path])
        assert.are.equal("old untracked partial", read(directory .. "/c1.cbz.part"))
        local failed_rows = 0
        for _, row in ipairs(plugin:showDownloads().item_table) do
            if row.mandatory == "Failed" then failed_rows = failed_rows + 1 end
        end
        assert.are.equal(1, failed_rows)
        advance(899)
        advance(0)
        assert.are.equal("downloading", queue:getStatus(manga, chapters[2]).state)
        local active = queue:getActiveJob("m1:c1")
        local retried_path = directory .. "/c1.cbz"
        write(retried_path, "worker validated restart completion")
        write(active.progress_path, "state=downloaded\npath=" .. retried_path .. "\n")
        workers[active.pid].alive = false
        advance(0.5)
        assert.are.equal(retried_path, settings:loadChapterLedger()["m1:c1"].path)
        assert.are.equal("downloaded", queue:getStatus(manga, chapters[1]).state)
    end)

    it("keeps canceled workers and their files busy until the helper confirms exit", function()
        local plugin = host("files")
        local queue = plugin:getDownloadQueue()
        assert(queue:enqueue(manga, chapters[1], directory))
        assert(queue:enqueue(manga, chapters[2], directory))
        advance(0)
        local active = queue:getActiveJob("m1:c1")
        write(active.progress_path, "state=downloading\ncurrent=1\ntotal=8\n")
        local legacy_path = directory .. "/Chapter 1.cbz"
        queue.downloader.getChapterPathCandidates = function()
            return { directory .. "/c1.cbz", legacy_path }
        end
        local partial = queue.downloader:getPartialPath(legacy_path, active.attempt_id)
        write(legacy_path .. ".part", "unknown worker")
        write(partial, "partial")
        local confirm
        require("suwayomi/ui").showConfirm = function(options) confirm = options.ok_callback end
        assert(plugin:performDownloadsTitleAction({ id = "cancel_all" }, plugin:showDownloads()))
        assert.is_function(confirm)
        confirm()
        assert.is_true(workers[active.pid].terminated)
        assert.are.equal(2, queue:getActiveCount())
        assert.is_not_nil(read(active.progress_path))
        assert.are.equal("partial", read(partial))
        assert.is_false(queue:enqueue(manga, chapters[1], directory))
        assert.is_false(plugin:deleteChapterFromDevice(manga, chapters[1]))
        write(directory .. "/c1.cbz", "finished during cancellation")
        advance(1)
        assert.are.equal(2, #workers)
        assert.is_not_nil(read(active.progress_path))
        for _, worker in ipairs(workers) do worker.alive = false end
        advance(1)
        assert.are.equal(0, queue:getActiveCount())
        assert.is_nil(read(active.progress_path))
        assert.is_nil(read(partial))
        assert.are.equal("unknown worker", read(legacy_path .. ".part"))
        assert.are.equal("finished during cancellation", read(directory .. "/c1.cbz"))
        assert.is_nil(settings:loadChapterLedger()["m1:c1"])
        assert.is_nil(queue:findPersistentJob("m1:c1"))
        assert(queue:enqueue(manga, chapters[2], directory))
        advance(0)
        assert.are.equal(3, #workers)
    end)

    it("chains quit once, invalidates callbacks, and restarts unfinished work with isolated files", function()
        local plugin, owner = host("files")
        local queue = plugin:getDownloadQueue()
        for _, chapter in ipairs(chapters) do assert(queue:enqueue(manga, chapter, directory)) end
        advance(0)
        local active = queue:getActiveJob("m1:c1")
        write(active.progress_path, "state=downloading\n")
        local calls = 0
        plugin.onDownloadSnapshot = function() calls = calls + 1 end
        require("suwayomi/downloads/service").get():notify()
        local wrapped = ui.quit
        local reader = host("reader-a")
        assert.are.equal(wrapped, ui.quit)
        local count, code, middle, last = ui:quit(85, nil, "restart")
        assert.are.equal(3, count)
        assert.are.equal(85, code)
        assert.is_nil(middle)
        assert.are.equal("restart", last)
        assert.is_true(workers[1].terminated)
        assert.is_true(workers[2].terminated)
        assert.is_false(queue:enqueue(manga, { id = "later" }, directory))
        assert.are.equal(1, ui:quit(0))
        owner:close()
        reader:onCloseWidget()
        advance(100)
        assert.are.equal(0, calls)
        assert.are.equal(2, #workers)
        assert.is_not_nil(read(active.progress_path))
        package.loaded["suwayomi/downloads/service"] = nil
        package.loaded["main"] = nil
        ui.quit = function() return "fresh quit" end
        shell = require("main")
        local restarted = host("files")
        assert.are_not.equal(queue, restarted:getDownloadQueue())
        advance(0)
        assert.are.equal(0, restarted:getDownloadQueue():getFailedCount())
        assert.are.equal(4, #workers)
        assert.are_not.equal(active.progress_path, restarted:getDownloadQueue():getActiveJob("m1:c1").progress_path)
        assert.is_not_nil(read(active.progress_path))
    end)

    it("retries startup saves as service work while admission stays fenced through navigation", function()
        assert(settings:saveDownloadQueue({ {
            key = "m1:c1", state = "downloading", manga = manga, chapter = chapters[1], download_directory = directory,
        } }))
        local write_file = settings.store.io.write
        settings.store.io.write = function() return nil, "injected write failure" end
        local plugin, owner = host("files")
        local queue = plugin:getDownloadQueue()
        assert.is_false(queue:enqueue(manga, chapters[2], directory))
        owner:close()
        local next_plugin, next_owner = host("reader-a")
        assert.are.equal(queue, next_plugin:getDownloadQueue())
        next_owner:close()
        assert.are.equal("downloading", settings:loadDownloadQueue()[1].state)
        assert.are.equal(0, #workers)
        settings.store.io.write = write_file
        advance(1)
        assert.are.equal("downloading", settings:loadDownloadQueue()[1].state)
        assert.are.equal(0, queue:getFailedCount())
        assert.are.equal(1, #workers)
        assert(queue:enqueue(manga, chapters[2], directory))
    end)

    it("retains failed worker files after Clear failed and blocks explicit retry until exit", function()
        local plugin = host("files")
        local queue = plugin:getDownloadQueue()
        assert(queue:enqueue(manga, chapters[1], directory))
        advance(0)
        local active = queue:getActiveJob("m1:c1")
        write(active.progress_path, "state=failed\nerror=full worker diagnostic\n")
        local partial = queue.downloader:getPartialPath(directory .. "/c1.cbz", active.attempt_id)
        write(partial, "worker may still write")
        advance(0.5)
        assert.are.equal(1, queue:getFailedCount())
        assert.is_false(plugin:retryDownloadJob(queue:findPersistentJob("m1:c1")))
        assert(plugin:performDownloadsTitleAction({ id = "clear_failed" }, plugin:showDownloads()))
        assert.are.equal(0, queue:getFailedCount())
        assert.is_true(queue:isChapterBusy("m1:c1"))
        assert.is_false(queue:enqueue(manga, chapters[1], directory))
        assert.are.equal("worker may still write", read(partial))
        workers[active.pid].alive = false
        advance(1)
        assert.is_nil(read(active.progress_path))
        assert.is_nil(read(partial))
        assert(queue:enqueue(manga, chapters[1], directory))
        advance(0)
        assert.are.equal(2, #workers)
    end)

    it("retains terminal progress and completion ownership until the child exits", function()
        local plugin, owner = host("files")
        local queue = plugin:getDownloadQueue()
        assert(queue:enqueue(manga, chapters[1], directory))
        advance(0)
        local active = queue:getActiveJob("m1:c1")
        local path = directory .. "/c1.cbz"
        write(path, "final archive")
        write(active.progress_path, "state=downloaded\npath=" .. path .. "\n")
        owner:close()
        advance(0.5)
        assert.is_not_nil(read(active.progress_path))
        assert.are.equal(1, queue:getActiveCount())
        assert.is_nil(settings:loadChapterLedger()["m1:c1"])
        assert.is_true(queue:cancelPending(manga, chapters[1]))
        assert.is_true(workers[active.pid].terminated)
        assert.is_false(queue:enqueue(manga, chapters[1], directory))
        workers[active.pid].alive = false
        advance(0.5)
        assert.is_nil(settings:loadChapterLedger()["m1:c1"])
        assert.are.equal("final archive", read(path))
        assert.is_nil(read(active.progress_path))
        assert.are.equal(1, #workers)
    end)

    it("commits archive, queue completion, ledger and return context with no hosts", function()
        local plugin, owner = host("files")
        local queue = plugin:getDownloadQueue()
        assert(queue:enqueue(manga, chapters[1], directory))
        advance(0)
        local active = queue:getActiveJob("m1:c1")
        local path = directory .. "/c1.cbz"
        assert(settings.store:saveDocument(function(doc)
            doc.chapter_ledger = { ["m1:c1"] = { read = true, pending_read_sync = true, pending_read_state = false } }
            doc.reader_return_contexts = { [path] = { custom = "preserve" } }
            doc.unrelated = "preserve"
        end))
        write(path, "synthetic archive")
        write(active.progress_path, "state=downloaded\ncurrent=8\ntotal=8\npath=" .. path .. "\n")
        owner:close()
        workers[active.pid].alive = false
        advance(0.5)
        assert.are.same({}, settings:loadDownloadQueue())
        assert.are.equal(path, settings:loadChapterLedger()["m1:c1"].path)
        assert.are.equal("s1", settings:loadReaderReturnContexts()[path].source.id)
        assert.are.equal("preserve", settings:loadReaderReturnContexts()[path].custom)
        assert.is_true(settings:loadChapterLedger()["m1:c1"].read)
        assert.is_true(settings:loadChapterLedger()["m1:c1"].pending_read_sync)
        assert.is_false(settings:loadChapterLedger()["m1:c1"].pending_read_state)
        assert.are.equal("preserve", settings.store:readKey("unrelated"))
        assert.is_nil(read(active.progress_path))
        assert.are.equal("synthetic archive", read(path))
        plugin = host("reader-a")
        assert.are.same({}, plugin.download_snapshot.active)
        assert.are.equal("downloaded", plugin:getDownloadQueue():getStatus(manga, chapters[1]).state)
        assert.are.equal("0 active, 0 queued, 0 failed", plugin:showDownloads().item_table[2].subtitle)
    end)

    for _, case in ipairs({
        { failure = "write", retry_count = 0 }, { failure = "write", retry_count = 6 },
        { failure = "sync_dir", retry_count = 0 }, { failure = "sync_dir", retry_count = 6 },
    }) do
        local failure, retry_count = case.failure, case.retry_count
        it("retains completed work beyond the watchdog with " .. failure .. " failure and " .. retry_count .. " retries", function()
            local plugin, owner = host("files")
            local queue = plugin:getDownloadQueue()
            assert(queue:enqueue(manga, chapters[1], directory))
            advance(0)
            local active = queue:getActiveJob("m1:c1")
            active.retry_count = retry_count
            assert(queue:upsertPersistentJob(queue:buildPersistentJob(manga, chapters[1], directory,
                "downloading", { retry_count = retry_count, archive_generation = active.archive_generation,
                    provenance = active.provenance })))
            local path = directory .. "/c1.cbz"
            write(path, "synthetic archive")
            write(active.progress_path, "state=downloaded\ncurrent=8\ntotal=8\npath=" .. path .. "\n")
            workers[active.pid].alive = false
            local original = settings.store.io[failure]
            settings.store.io[failure] = function() return nil, "injected failure" end
            advance(0.5)
            assert.are.equal(active, queue:getActiveJob("m1:c1"))
            assert.are.equal("downloading", queue:getStatus(manga, chapters[1]).state)
            assert.is_nil(settings:loadChapterLedger()["m1:c1"])
            if failure == "sync_dir" then
                assert.is_true(settings:isBlocked())
                assert(queue:reconcile())
                assert.are.equal(active, queue:getActiveJob("m1:c1"))
            end
            local removed = plugin:deleteChapterFromDevice(manga, chapters[1])
            assert.is_false(removed)
            assert.are.equal("synthetic archive", read(path))
            assert.is_not_nil(read(active.progress_path))
            owner:close()
            advance(36 * 60)
            assert.are.equal(active, queue:getActiveJob("m1:c1"))
            assert.are.equal(retry_count, queue:getSnapshot().active[1].retry_count)
            if failure == "write" then
                assert.are.equal(retry_count, settings:loadDownloadQueue()[1].retry_count)
            end
            assert.are.equal("synthetic archive", read(path))
            assert.is_not_nil(read(active.progress_path))
            settings.store.io[failure] = original
            advance(1)
            advance(1)
            advance(0.5)
            assert.are.equal("downloaded", queue:getStatus(manga, chapters[1]).state)
            assert.are.equal(path, settings:loadChapterLedger()["m1:c1"].path)
            assert.are.equal(path, settings:loadReaderReturnContexts()[path].path)
            assert.are.same({}, settings:loadDownloadQueue())
            assert.are.equal(1, #workers)
            assert.is_nil(workers[active.pid].terminated)
            assert.is_nil(read(active.progress_path))
            assert.are.equal("synthetic archive", read(path))
            plugin = host("reader-a")
            assert.are.equal("0 active, 0 queued, 0 failed", plugin:showDownloads().item_table[2].subtitle)
        end)
    end

    for _, field in ipairs({ "chapter_ledger", "reader_return_contexts" }) do
        for _, shape in ipairs({ "container", "entry" }) do
            it("completes downloads with an invalid legacy " .. field .. " " .. shape, function()
                local plugin = host("files")
                local queue = plugin:getDownloadQueue()
                assert(queue:enqueue(manga, chapters[1], directory))
                advance(0)
                local active = queue:getActiveJob("m1:c1")
                local path = directory .. "/c1.cbz"
                local key = field == "chapter_ledger" and "m1:c1" or path
                assert(settings.store:saveDocument(function(doc)
                    doc[field] = shape == "container" and "invalid" or {
                        [key] = "invalid", unrelated = { custom = "preserve" },
                    }
                    doc.unrelated = { version = 99, custom = "preserve" }
                end))
                write(path, "completed archive")
                write(active.progress_path, "state=downloaded\ncurrent=8\ntotal=8\npath=" .. path .. "\n")
                workers[active.pid].alive = false
                advance(0.5)
                assert.are.same({}, settings:loadDownloadQueue())
                assert.are.equal(path, settings:loadChapterLedger()["m1:c1"].path)
                assert.are.equal("s1", settings:loadReaderReturnContexts()[path].source.id)
                assert.are.equal("downloaded", queue:getStatus(manga, chapters[1]).state)
                assert.are.equal("completed archive", read(path))
                assert.is_nil(read(active.progress_path))
                assert.are.equal("0 active, 0 queued, 0 failed", plugin:showDownloads().item_table[2].subtitle)
                assert.are.same({ version = 99, custom = "preserve" }, settings.store:readKey("unrelated"))
                if shape == "entry" then
                    assert.are.same({ custom = "preserve" }, settings.store:readKey(field).unrelated)
                end
                assert.are.equal(1, #workers)
            end)
        end
    end

    it("wakes eligible durable cleanup on queue completion with no hosts", function()
        local plugin, owner = host("files")
        local queue = plugin:getDownloadQueue()
        assert(queue:enqueue(manga, chapters[1], directory))
        advance(0)
        local active = queue:getActiveJob("m1:c1")
        local completed_path, cleanup_path = directory .. "/c1.cbz", directory .. "/c2.cbz"
        write(cleanup_path, "previously finished archive")
        assert(settings:saveDeleteChaptersSettings({ delete_finished_while_reading = 1 }))
        assert(settings:saveChapterLedger({ ["m1:c2"] = {
            manga_id = "m1", chapter_id = "c2", path = cleanup_path, read = true,
        } }))
        local target = assert(queue.manual_deletion:prepareRemoval("m1:c2", cleanup_path, directory))
        -- Seed durable work after startup has drained. No UI cleanup action or
        -- existing cleanup timer can wake it; the next queue transition must.
        assert(settings:saveFinishedChapterCleanupJournal({
            version = 1, next_sequence = 2,
            mangas = { m1 = { records = { {
                chapter_id = "c2", path = cleanup_path, sequence = 1, retry_count = 0, retry_after = 0,
                archive_target = target,
            } } } },
        }))
        owner:close()
        advance(0.25)
        assert.are.equal("previously finished archive", read(cleanup_path))
        assert.are.equal(cleanup_path, settings:loadFinishedChapterCleanupJournal().mangas.m1.records[1].path)
        write(completed_path, "newly completed archive")
        write(active.progress_path, "state=downloaded\ncurrent=8\ntotal=8\npath=" .. completed_path .. "\n")
        workers[active.pid].alive = false
        advance(0.25)
        assert.is_nil(read(cleanup_path))
        assert.is_nil(settings:loadChapterLedger()["m1:c2"].path)
        assert.is_true(settings:loadChapterLedger()["m1:c2"].read)
        assert.are.same({}, settings:loadFinishedChapterCleanupJournal().mangas)
        assert.are.equal("newly completed archive", read(completed_path))
        assert.are.equal(completed_path, settings:loadChapterLedger()["m1:c1"].path)
        assert.are.equal(completed_path, settings:loadReaderReturnContexts()[completed_path].path)
        assert.are.same({}, settings:loadDownloadQueue())
        assert.is_nil(read(active.progress_path))
        assert.are.equal(1, #workers)
    end)

    it("provides independent immediate snapshots and releases detached callbacks", function()
        local plugin, owner = host("files")
        local queue = plugin:getDownloadQueue()
        assert(queue:enqueue(manga, chapters[1], directory))
        advance(0)
        local service = require("suwayomi/downloads/service").get()
        local first, second
        local detach = service:subscribe(function(snapshot)
            first = snapshot
            snapshot.active[1].manga.source.name = "changed by view"
        end)
        service:subscribe(function(snapshot) second = snapshot end)
        assert.are.equal("Source", second.active[1].manga.source.name)
        assert.are_not.equal(first, second)
        local public = queue:getSnapshot()
        public.active[1].manga.source.name = "changed by controller"
        assert.are.equal("Source", service:getSnapshot().active[1].manga.source.name)
        detach()
        detach()
        service:subscribe(function() error("broken view") end)
        service:notify()
        local retired = setmetatable({ plugin }, { __mode = "v" })
        owner:close()
        plugin, owner = nil, nil
        assert.is_nil(plugin)
        assert.is_nil(owner)
        collectgarbage("collect")
        assert.is_nil(retired[1])
        advance(0)
        assert.are.equal("Source", second.active[1].manga.source.name)
    end)

    it("refreshes live chapter rows but leaves hidden and retired widgets unchanged", function()
        local plugin, owner = host("files")
        local queue = plugin:getDownloadQueue()
        assert(queue:enqueue(manga, chapters[1], directory))
        advance(0)
        plugin:setCurrentMangaChapterContext(manga, chapters)
        local menu = {}
        plugin.current_chapter_menu = menu
        plugin:trackSuwayomiScreen("chapters", menu)
        plugin:refreshChapterMenu({ quick = true })
        local initial = menu.item_table[1].mandatory
        local active = queue:getActiveJob("m1:c1")
        write(active.progress_path, "state=downloading\ncurrent=3\ntotal=8\n")
        advance(0.5)
        assert.are_not.equal(initial, menu.item_table[1].mandatory)
        assert.is_truthy(menu.item_table[1].mandatory:find("3/8", 1, true))
        local visible = menu.item_table
        local downloads = plugin:showDownloads()
        write(active.progress_path, "state=downloading\ncurrent=5\ntotal=8\n")
        advance(0.5)
        assert.are.equal(visible, menu.item_table)
        assert.are.equal("Downloading 5/8", downloads.item_table[1].mandatory)
        plugin:getNavigation():pop(downloads)
        advance(0)
        assert.is_truthy(menu.item_table[1].mandatory:find("5/8", 1, true))
        owner:close()
        write(active.progress_path, "state=downloading\ncurrent=6\ntotal=8\n")
        advance(0.5)
        assert.are.equal("Downloading 5/8", downloads.item_table[1].mandatory)
        local next_plugin = host("reader-a")
        assert.are.equal("Downloading 6/8", next_plugin:showDownloads().item_table[1].mandatory)
    end)

    it("rebuilds only the affected manga after deferred cleanup", function()
        local affected, unrelated = host("files"), host("files")
        local other_manga = { id = "m2", title = "Other" }
        local other_chapter = { id = "other", name = "Other chapter" }
        local cleanup_path, other_path = directory .. "/c1.cbz", directory .. "/other.cbz"
        write(cleanup_path, "finished archive")
        write(other_path, "unrelated archive")
        for _, view in ipairs({
            { plugin = affected, manga = manga, chapters = { chapters[1] } },
            { plugin = unrelated, manga = other_manga, chapters = { other_chapter } },
        }) do
            view.plugin:setCurrentMangaChapterContext(view.manga, view.chapters)
            view.plugin.current_chapter_menu = {}
            view.plugin:trackSuwayomiScreen("chapters", view.plugin.current_chapter_menu)
            view.plugin:refreshChapterMenu()
        end
        unrelated:toggleChapterSelection(other_manga, other_chapter)
        advance(0)
        local observed = unrelated.current_chapter_menu.item_table[1].mandatory
        assert.is_truthy(observed:find("Downloaded", 1, true))
        assert.is_truthy(affected.current_chapter_menu.item_table[1].mandatory:find("Downloaded", 1, true))
        assert(os.remove(other_path))
        -- External changes to the unrelated manga remain unobserved until that
        -- view explicitly rebuilds; cleaning another manga must not reconcile it.
        assert(settings:saveDeleteChaptersSettings({ delete_finished_while_reading = 1 }))
        local ledger = settings:loadChapterLedger()
        ledger["m1:c1"].read = true
        assert(settings:saveChapterLedger(ledger))
        assert(affected:getDownloadQueue().manual_deletion:prepareRemoval("m1:c1", cleanup_path, directory))
        ledger = settings:loadChapterLedger()
        assert(affected:recordFinishedChapter(ledger["m1:c1"]))
        advance(0)
        assert.is_nil(read(cleanup_path))
        assert.is_nil(settings:loadChapterLedger()["m1:c1"].path)
        assert.are.same({}, settings:loadFinishedChapterCleanupJournal().mangas)
        assert.is_nil(affected.current_chapter_menu.item_table[1].mandatory)
        assert.are.equal(observed, unrelated.current_chapter_menu.item_table[1].mandatory)
        assert.is_true(unrelated:isChapterSelected(other_manga, other_chapter))
        assert.are.equal(other_path, settings:loadChapterLedger()["m2:other"].path)
        unrelated:refreshChapterMenu()
        assert.are.equal("●", unrelated.current_chapter_menu.item_table[1].mandatory)
    end)

    it("shows an unsupported cleanup journal warning once from the first host and preserves its saved data", function()
        local path = directory .. "/c1.cbz"
        local journal = { version = 9, opaque = { path = path, keep = true } }
        write(path, "finished archive")
        assert(settings:saveDeleteChaptersSettings({ delete_finished_while_reading = 1 }))
        assert(settings.store:saveDocument(function(doc)
            doc.finished_chapter_cleanup = journal
            doc.chapter_ledger = { ["m1:c1"] = { manga_id = "m1", chapter_id = "c1", path = path, read = true } }
        end))
        local committed = read(settings.store.path)
        local messages = {}
        ui.show = function(_, widget) messages[#messages + 1] = widget.text end
        local plugin, owner = host("files")
        assert.are.same({}, messages, "startup messages wait for the UI loop")
        advance(0)
        local expected = {
            "Automatic chapter cleanup is paused because its saved data uses an unsupported version.",
        }
        assert.are.same(expected, messages)
        assert.are.same(journal, settings:loadFinishedChapterCleanupJournal())
        assert.are.equal(committed, read(settings.store.path))
        assert.are.equal("finished archive", read(path))
        plugin:processFinishedChapterCleanup()
        advance(0)
        assert.are.same(expected, messages)
        for _, destination in ipairs({ "reader-a", "files", "reader-b" }) do
            owner:close()
            plugin, owner = host(destination)
            plugin:processFinishedChapterCleanup()
            advance(0)
            assert.are.same(expected, messages)
            assert.are.same(journal, settings:loadFinishedChapterCleanupJournal())
            assert.are.equal(committed, read(settings.store.path))
            assert.are.equal("finished archive", read(path))
        end
    end)

    it("keeps one cleanup timer through reader retirement and uses the live reader path", function()
        local plugin, owner = host("files")
        local path = directory .. "/c1.cbz"
        write(path, "completed archive")
        assert(settings:saveDeleteChaptersSettings({ delete_finished_while_reading = 1 }))
        assert(settings:saveChapterLedger({ ["m1:c1"] = {
            manga_id = "m1", chapter_id = "c1", path = path, read = true,
        } }))
        assert(plugin:getDownloadQueue().manual_deletion:prepareRemoval("m1:c1", path, directory))
        assert(plugin:recordFinishedChapter(settings:loadChapterLedger()["m1:c1"]))
        owner:close()
        local reader, reader_owner = host("reader-a")
        reader_owner.document.file = path
        advance(0)
        assert.are.equal("completed archive", read(path))
        assert.are.equal(1, settings:loadFinishedChapterCleanupJournal().mangas.m1.records[1].retry_count)
        reader_owner:close()
        -- KOReader can retain its closed document object elsewhere; the adapter
        -- must consult ReaderUI.instance rather than this retired plugin.
        reader.document = { file = path }
        advance(5)
        assert.is_nil(read(path))
        assert.is_nil(settings:loadChapterLedger()["m1:c1"].path)
        assert.are.same({}, settings:loadFinishedChapterCleanupJournal().mangas)
    end)

    it("applies concurrency changes from a later host without replacing workers on wake", function()
        local plugin, owner = host("files")
        local queue = plugin:getDownloadQueue()
        for _, chapter in ipairs(chapters) do assert(queue:enqueue(manga, chapter, directory)) end
        advance(0)
        local first, second = queue:getActiveJob("m1:c1"), queue:getActiveJob("m1:c2")
        owner:close()
        plugin = host("reader-a")
        local choices
        require("suwayomi/ui").showParallelDownloadsMenu = function(options) choices = options end
        plugin:showParallelDownloadsDialog()
        choices.onSelect(1)
        for _, name in ipairs({ "onSuspend", "onResume", "onCloseDocument" }) do
            if plugin[name] then plugin[name](plugin) end
        end
        assert.are.equal(first, queue:getActiveJob("m1:c1"))
        assert.are.equal(second, queue:getActiveJob("m1:c2"))
        local path = directory .. "/c1.cbz"
        write(path, "synthetic archive")
        write(first.progress_path, "state=downloaded\ncurrent=8\ntotal=8\npath=" .. path .. "\n")
        workers[first.pid].alive = false
        advance(0.5)
        assert.are.equal(2, #workers)
        assert.are.equal(1, queue:getActiveCount())
        assert.are.equal(2, #queue:getSnapshot().queued)
    end)

    it("isolates a broken host while another host displays committed completion", function()
        local broken = host("files")
        local healthy = host("files")
        local queue = healthy:getDownloadQueue()
        assert.are.equal(queue, broken:getDownloadQueue())
        assert(queue:enqueue(manga, chapters[1], directory))
        advance(0)
        local menu = healthy:showDownloads()
        function broken:onDownloadSnapshot() error("retired renderer failure") end
        local active = queue:getActiveJob("m1:c1")
        local path = directory .. "/c1.cbz"
        write(path, "synthetic archive")
        write(active.progress_path, "state=downloaded\ncurrent=8\ntotal=8\npath=" .. path .. "\n")
        workers[active.pid].alive = false
        advance(0.5)
        assert.are.equal("No downloads queued.", menu.item_table[3].text)
        assert.are.same({}, healthy.download_snapshot.active)
        assert.are.equal(path, settings:loadChapterLedger()["m1:c1"].path)
        assert.are.equal("synthetic archive", read(path))
    end)

    local function manualHost(retention, reader)
        assert(settings:saveDeleteChaptersSettings{
            delete_after_mark_read = true, delete_finished_while_reading = retention or 0,
        })
        local ffi = require("ffi")
        ffi.cdef[[char *realpath(const char *path, char *resolved_path); void free(void *ptr);]]
        require("ffi/util").realpath = function(path)
            local resolved = ffi.C.realpath(path, nil)
            if resolved == nil then return nil end
            local result = ffi.string(resolved)
            ffi.C.free(resolved)
            return result
        end
        local plugin, owner = host(reader and "reader" or "files", directory .. "/c1.cbz")
        plugin.current_chapter_context = { manga = manga, chapters = chapters }
        plugin.current_chapter_menu = { item_table = {} }
        plugin.manual_messages = {}
        plugin.showMessage = function(_, message)
            plugin.manual_messages[#plugin.manual_messages + 1] = message
        end
        return plugin, owner
    end

    for _, retention in ipairs({ 0, 3 }) do
        it("commits manual read before physically unlinking only the selected archive with retention " .. retention, function()
            local plugin = manualHost(retention)
            local path = directory .. "/c1.cbz"
            write(path, "captured archive")
            assert(require("lfs").mkdir(path .. ".sdr"))
            write(path .. ".sdr/metadata.lua", "return { custom = 'reading metadata' }")
            write(path .. ".sdr/metadata.lua.old", "metadata backup")
            write(directory .. "/c2.cbz", "non-target archive")
            local original_remove = os.remove
            local saw_committed
            os.remove = function(value)
                if value == path then
                    local durable = assert(loadfile(settings.store.path))()
                    assert.is_true(durable.chapter_ledger["m1:c1"].read)
                    assert.is_true(durable.chapter_ledger["m1:c1"].pending_read_sync)
                    assert.is_not_nil(durable.manual_archive_state.requests["m1:c1"].target)
                    saw_committed = true
                end
                return original_remove(value)
            end
            local ok, result = pcall(plugin.performChapterAction, plugin, manga, chapters[1], "mark_read")
            os.remove = original_remove
            assert.is_true(ok, result)
            assert.is_true(result)
            assert.is_true(saw_committed)
            assert.is_nil(read(path))
            assert.is_not_nil(read(path .. ".sdr/metadata.lua"))
            assert.are.equal("metadata backup", read(path .. ".sdr/metadata.lua.old"))
            assert.are.equal("non-target archive", read(directory .. "/c2.cbz"))
            assert.is_true(settings:loadChapterLedger()["m1:c1"].read)
            assert.is_nil(settings:loadChapterLedger()["m1:c1"].path)
            assert.are.same({}, plugin.manual_messages)
        end)
    end

    it("keeps accepted archive removal through a live reader, disabled settings, and zero hosts", function()
        local plugin, owner = manualHost(0, true)
        local path = directory .. "/c1.cbz"
        write(path, "live archive")
        assert(plugin:performChapterAction(manga, chapters[1], "mark_read"))
        local pending_request = settings.store:readKey("manual_archive_state").requests["m1:c1"]
        assert.is_not_nil(pending_request.target)
        assert.are.equal("live archive", read(path))
        assert(settings:saveDeleteChaptersSettings{ delete_after_mark_read = false, delete_finished_while_reading = 0 })
        assert(settings:saveDownloadDirectory(directory .. "/elsewhere"))
        owner:close()
        advance(5)
        assert.is_nil(read(path))
        assert.is_true(settings:loadChapterLedger()["m1:c1"].read)
        assert.is_nil(settings:loadChapterLedger()["m1:c1"].path)
    end)

    it("rejects busy manual removal without changing queued work or promising later removal", function()
        local plugin = manualHost(0)
        local queue = plugin:getDownloadQueue()
        assert(queue:enqueue(manga, chapters[1], directory, { provenance = "explicit" }))
        local original_jobs = settings:loadDownloadQueue()
        write(directory .. "/c1.cbz", "busy archive")
        assert(plugin:performChapterAction(manga, chapters[1], "mark_read"))
        assert.are.same(original_jobs, settings:loadDownloadQueue())
        assert.are.equal("busy archive", read(directory .. "/c1.cbz"))
        assert.is_true(settings:loadChapterLedger()["m1:c1"].read)
        local state = settings.store:readKey("manual_archive_state", {})
        local request = (state.requests or {})["m1:c1"]
        assert.is_true(request == nil or request.target == nil)
        assert.matches("again", plugin.manual_messages[1])
    end)

    it("revokes accepted removal in the checked unread transaction", function()
        local plugin, owner = manualHost(0, true)
        local path = directory .. "/c1.cbz"
        write(path, "keep unread archive")
        assert(plugin:performChapterAction(manga, chapters[1], "mark_read"))
        assert(plugin:performChapterAction(manga, chapters[1], "mark_unread"))
        assert.is_false(settings:loadChapterLedger()["m1:c1"].read)
        assert.is_false(settings:loadChapterLedger()["m1:c1"].pending_read_state)
        owner:close()
        advance(300)
        assert.are.equal("keep unread archive", read(path))
    end)

    for _, failure in ipairs({ "write", "sync_dir" }) do
        it("preserves archives without claiming durable read after " .. failure .. " admission failure", function()
            local plugin = manualHost(0)
            local path = directory .. "/c1.cbz"
            write(path, "not authorized")
            local original = settings.store.io[failure]
            settings.store.io[failure] = function() return nil, "injected admission failure" end
            local ok = plugin:performChapterAction(manga, chapters[1], "mark_read")
            settings.store.io[failure] = original
            assert.is_false(ok)
            assert.are.equal("not authorized", read(path))
            assert.are.equal(1, #plugin.manual_messages)
            if failure == "write" then
                assert.is_nil(settings:loadChapterLedger()["m1:c1"])
            else
                assert.is_true(settings:isBlocked())
                assert(plugin:getDownloadQueue():reconcile())
                advance(5)
                assert.is_nil(read(path))
            end
        end)
    end

    it("handles a selected mixed batch with live-reader, busy, and removable archives together", function()
        local plugin = manualHost(3, true)
        local queue = plugin:getDownloadQueue()
        assert(queue:enqueue(manga, chapters[2], directory, { provenance = "explicit" }))
        for index = 1, 4 do write(directory .. "/c" .. index .. ".cbz", "archive " .. index) end
        plugin.selected_chapters = { ["m1:c1"] = true, ["m1:c2"] = true, ["m1:c3"] = true }
        plugin.selection_mode = true
        local count = plugin:markSelectedChaptersRead()
        assert.are.equal(3, count)
        assert.are.same({}, plugin.selected_chapters)
        assert.is_false(plugin.selection_mode)
        local ledger = settings:loadChapterLedger()
        for index = 1, 3 do assert.is_true(ledger["m1:c" .. index].read) end
        assert.are.equal("archive 1", read(directory .. "/c1.cbz"))
        assert.are.equal("archive 2", read(directory .. "/c2.cbz"))
        assert.is_nil(read(directory .. "/c3.cbz"))
        assert.are.equal("archive 4", read(directory .. "/c4.cbz"))
        assert.are.equal("queued", queue:getStatus(manga, chapters[2]).state)
        assert.are.equal(1, #plugin.manual_messages)
    end)

    it("protects a same-path same-content deliberate replacement from old removal", function()
        local plugin, owner = manualHost(0, true)
        local path = directory .. "/c1.cbz"
        write(path, "same contents")
        assert(plugin:performChapterAction(manga, chapters[1], "mark_read"))
        local queue = plugin:getDownloadQueue()
        local before = settings.store:readKey("manual_archive_state").requests["m1:c1"]
        local duplicate = queue:enqueue(manga, chapters[1], directory, { provenance = "explicit" })
        assert.is_false(duplicate)
        assert.are.same(before, settings.store:readKey("manual_archive_state").requests["m1:c1"])
        assert(os.remove(path))
        local automatic = queue:enqueue(manga, chapters[1], directory, { provenance = "automatic" })
        assert.is_false(automatic)
        assert.are.same(before, settings.store:readKey("manual_archive_state").requests["m1:c1"])
        local original_write = settings.store.io.write
        settings.store.io.write = function() return nil, "injected admission failure" end
        local failed = queue:enqueue(manga, chapters[1], directory, { provenance = "explicit" })
        settings.store.io.write = original_write
        assert.is_false(failed)
        assert.are.same(before, settings.store:readKey("manual_archive_state").requests["m1:c1"])
        assert(queue:enqueue(manga, chapters[1], directory, { provenance = "explicit" }))
        advance(0)
        local active = assert(queue:getActiveJob("m1:c1"))
        write(path, "same contents")
        write(active.progress_path, "state=downloaded\ncurrent=1\ntotal=1\npath=" .. path .. "\n")
        workers[active.pid].alive = false
        advance(0.5)
        local replacement = settings.store:readKey("manual_archive_state").archives["m1:c1"]
        assert.are_not.equal(before.target.generation, replacement.generation)
        owner:close()
        advance(300)
        assert.are.equal("same contents", read(path))
        assert.are.equal(path, settings:loadChapterLedger()["m1:c1"].path)
        assert.are.equal(replacement.generation, settings:loadChapterLedger()["m1:c1"].archive_generation)
    end)

    it("recovers a real unlink whose progress save failed without requiring a shutdown save", function()
        local plugin, owner = manualHost(0, true)
        local path = directory .. "/c1.cbz"
        write(path, "archive before crash")
        write(path .. ".old", "unrelated backup")
        assert(plugin:performChapterAction(manga, chapters[1], "mark_read"))
        owner:close()
        local original_remove, original_write = os.remove, settings.store.io.write
        os.remove = function(value)
            local removed, message, code = original_remove(value)
            if value == path and removed then
                settings.store.io.write = function() return nil, "crash after unlink" end
            end
            return removed, message, code
        end
        local ran, error_message = pcall(advance, 5)
        os.remove, settings.store.io.write = original_remove, original_write
        assert.is_true(ran, error_message)
        assert.is_nil(read(path))
        assert.are.equal("unrelated backup", read(path .. ".old"))
        local store_path = settings.store.path
        local old_service = require("suwayomi/downloads/service").get()
        old_service:shutdown()
        timers = {}
        settings.store = require("suwayomi/settings/store"):new{ path = store_path }
        package.loaded["suwayomi/downloads/service"] = nil
        local restarted = require("suwayomi/downloads/service").get()
        restarted:start()
        advance(300)
        assert.is_nil(settings:loadChapterLedger()["m1:c1"].path)
        assert.is_true(settings:loadChapterLedger()["m1:c1"].read)
        assert.are.equal("unrelated backup", read(path .. ".old"))
        assert.are.equal("removed", restarted.manual_deletion:snapshot()["m1:c1"].state)
    end)

    it("blocks a symlink escaping the captured managed root", function()
        local plugin = manualHost(0)
        local outside, path = directory .. "-outside.cbz", directory .. "/c1.cbz"
        write(outside, "outside archive")
        assert(require("lfs").link(outside, path, true))
        files[path] = true
        assert(plugin:performChapterAction(manga, chapters[1], "mark_read"))
        advance(300)
        assert.are.equal("outside archive", read(outside))
        assert.are.equal("outside archive", read(path))
        assert.are.equal(1, #plugin.manual_messages)
    end)

    it("preserves unknown manual state and never grants deletion authority over it", function()
        local plugin = manualHost(0)
        local path = directory .. "/c1.cbz"
        write(path, "unknown ownership")
        local unknown = { version = 99, requests = { opaque = "keep" } }
        assert(settings.store:saveKey("manual_archive_state", unknown))
        plugin:performChapterAction(manga, chapters[1], "mark_read")
        advance(300)
        assert.are.same(unknown, settings.store:readKey("manual_archive_state"))
        assert.are.equal("unknown ownership", read(path))
    end)

    it("preserves newer read and return context changes between unlink and bookkeeping", function()
        local plugin = manualHost(0)
        local path = directory .. "/c1.cbz"
        write(path, "captured archive")
        assert(settings.store:saveKey("reader_return_contexts", {
            [path] = { path = path, manga_id = "m1", chapter_id = "c1", visit = "original" },
        }))
        local original_remove = os.remove
        os.remove = function(value)
            local removed, message, code = original_remove(value)
            if value == path and removed then
                assert(settings.store:saveDocument(function(doc)
                    doc.chapter_ledger["m1:c1"].read = false
                    doc.chapter_ledger["m1:c1"].pending_read_state = false
                    doc.reader_return_contexts[path].visit = "newer"
                end))
            end
            return removed, message, code
        end
        local ran, result = pcall(plugin.performChapterAction, plugin, manga, chapters[1], "mark_read")
        os.remove = original_remove
        assert.is_true(ran, result)
        assert.is_nil(read(path))
        assert.is_false(settings:loadChapterLedger()["m1:c1"].read)
        assert.is_false(settings:loadChapterLedger()["m1:c1"].pending_read_state)
        assert.are.equal("newer", settings:loadReaderReturnContexts()[path].visit)
    end)

    for _, failure in ipairs({ "write", "sync_dir" }) do
        it("reports ordinary Delete bookkeeping failure after physical unlink with " .. failure, function()
            local plugin = manualHost(0)
            local path = directory .. "/c1.cbz"
            write(path, "ordinary archive")
            assert(settings:saveChapterLedger{ ["m1:c1"] = {
                manga_id = "m1", chapter_id = "c1", path = path, read = true, pending_read_sync = true,
            } })
            local draft = settings:loadChapterLedger()
            local original_remove, original_failure = os.remove, settings.store.io[failure]
            os.remove = function(value)
                local removed, message, code = original_remove(value)
                if value == path and removed then
                    settings.store.io[failure] = function() return nil, "post-unlink failure" end
                end
                return removed, message, code
            end
            local ran, ok, state = pcall(plugin.deleteChapterFromDeviceWithOptions, plugin, manga, chapters[1],
                { ledger = draft })
            os.remove, settings.store.io[failure] = original_remove, original_failure
            assert.is_true(ran, ok)
            assert.is_false(ok)
            assert.are.equal(failure == "sync_dir" and "store_blocked" or "delete_failed", state)
            assert.is_nil(read(path))
            assert.are.equal(path, draft["m1:c1"].path)
            assert.is_true(settings:loadChapterLedger()["m1:c1"].pending_read_sync)
            if failure == "sync_dir" then
                assert(settings:reconcile())
                assert.is_nil(settings:loadChapterLedger()["m1:c1"].path)
            end
        end)
    end

    for _, ownership in ipairs({ "running", "stopping", "finalizing" }) do
        it("requires a fresh manual action after " .. ownership .. " ownership finishes", function()
            local plugin = manualHost(0)
            local queue = plugin:getDownloadQueue()
            assert(queue:enqueue(manga, chapters[1], directory, { provenance = "explicit" }))
            advance(0)
            local active = assert(queue:getActiveJob("m1:c1"))
            if ownership == "stopping" then queue:cancelPending(manga, chapters[1]) end
            local path = directory .. "/c1.cbz"
            write(path, "owned archive")
            write(active.progress_path, "state=downloaded\ncurrent=1\ntotal=1\npath=" .. path .. "\n")
            if ownership == "finalizing" then
                workers[active.pid].alive = false
                local original_write = settings.store.io.write
                settings.store.io.write = function() return nil, "completion save rejected" end
                queue:poll()
                settings.store.io.write = original_write
                assert.is_not_nil(queue:getActiveJob("m1:c1"))
            end
            local ok, result = plugin:performChapterAction(manga, chapters[1], "mark_read")
            assert.is_true(ok)
            assert.are.equal(1, result.busy)
            local requests = settings.store:readKey("manual_archive_state").requests
            assert.is_nil(requests["m1:c1"])
            assert.are.equal("owned archive", read(path))
            workers[active.pid].alive = false
            advance(1)
            advance(1)
            assert.are.equal("owned archive", read(path))
            assert.is_false(queue:isChapterBusy("m1:c1"))
            assert(plugin:performChapterAction(manga, chapters[1], "mark_read"))
            assert.is_nil(read(path))
        end)
    end

    it("persists capped retries without abandonment while another archive completes", function()
        local plugin = manualHost(0)
        local blocked, ready = directory .. "/c1.cbz", directory .. "/c2.cbz"
        write(blocked, "temporarily locked")
        write(ready, "ready archive")
        local original_remove = os.remove
        os.remove = function(path)
            if path == blocked then return nil, "permission denied", 13 end
            return original_remove(path)
        end
        local ran, failure = pcall(function()
            assert.are.equal(2, plugin:markChapterListRead(manga, { chapters[1], chapters[2] }))
            assert.is_nil(read(ready))
            local request = settings.store:readKey("manual_archive_state").requests["m1:c1"]
            assert.are.equal(5, request.retry_after - clock)
            for _ = 1, 9 do
                advance(request.retry_after - clock)
                request = settings.store:readKey("manual_archive_state").requests["m1:c1"]
            end
            assert.are.equal("pending", request.state)
            assert.is_true(request.retry_count >= 10)
            assert.are.equal(300, request.retry_after - clock)
            assert.are.equal("temporarily locked", read(blocked))
            assert.are.same({}, plugin.manual_messages)
        end)
        os.remove = original_remove
        assert.is_true(ran, failure)
        advance(300)
        assert.is_nil(read(blocked))
    end)

    it("preserves a replacement when a historical retention target is malformed", function()
        local plugin = manualHost(1)
        local path = directory .. "/c1.cbz"
        write(path, "replacement without original authority")
        assert(settings:saveChapterLedger{ ["m1:c1"] = {
            manga_id = "m1", chapter_id = "c1", path = path, read = true,
        } })
        assert(settings:saveFinishedChapterCleanupJournal{
            version = 1, next_sequence = 2, mangas = { m1 = { records = {
                { chapter_id = "c1", path = path, sequence = 1, retry_count = 0,
                    retry_after = 0, archive_target = {} },
            } } },
        })
        plugin:processFinishedChapterCleanup()
        assert.are.equal("replacement without original authority", read(path))
        local record = settings:loadFinishedChapterCleanupJournal().mangas.m1.records[1]
        assert.are.equal(1, record.sequence)
        assert.are.same({}, record.archive_target)
        assert.is_not_nil(record.blocked_reason)
        assert.is_nil((settings.store:readKey("manual_archive_state", {}).archives or {})["m1:c1"])
    end)

    it("renders replacement download state instead of obsolete removed history", function()
        local plugin = manualHost(0)
        local path = directory .. "/c1.cbz"
        write(path, "original archive")
        assert(plugin:performChapterAction(manga, chapters[1], "mark_read"))
        assert.is_nil(read(path))
        assert(settings:save({ server_url = "https://example.invalid" }))
        local scoped = { id = manga.id, title = manga.title, source = manga.source, endpoint_scope = "https://example.invalid" }
        plugin:setCurrentMangaChapterContext(scoped, chapters)
        assert(plugin:performChapterAction(scoped, chapters[1], "download"))
        local function rowStatus()
            for _, row in ipairs(plugin.current_chapter_options.chapters) do
                if row.id == chapters[1].id then return row.menu_status end
            end
        end
        assert.matches("Queued", rowStatus())
        assert.is_nil(rowStatus():find("Archive removed", 1, true))
        advance(0)
        local queue = plugin:getDownloadQueue()
        local active = assert(queue:getActiveJob("m1:c1"))
        write(path, "replacement archive")
        write(active.progress_path, "state=downloaded\ncurrent=1\ntotal=1\npath=" .. path .. "\n")
        workers[active.pid].alive = false
        advance(0.5)
        plugin:refreshChapterMenu()
        assert.are.equal("replacement archive", read(path))
        assert.matches("Downloaded", rowStatus())
        assert.is_nil(rowStatus():find("Archive removed", 1, true))
    end)

    it("does not let retention remove metadata while manual archive-only removal is pending", function()
        local plugin = manualHost(1)
        local path = directory .. "/c1.cbz"
        write(path, "pending archive")
        assert(require("lfs").mkdir(path .. ".sdr"))
        write(path .. ".sdr/metadata.lua", "return { custom = 'keep' }")
        write(path .. ".sdr/metadata.lua.old", "keep backup")
        local original_remove = os.remove
        os.remove = function(value)
            if value == path then return nil, "temporarily busy", 13 end
            return original_remove(value)
        end
        local ran, result = pcall(plugin.performChapterAction, plugin, manga, chapters[1], "mark_read")
        os.remove = original_remove
        assert.is_true(ran, result)
        assert.is_true(result)
        plugin:processFinishedChapterCleanup()
        assert.are.equal("pending archive", read(path))
        assert.is_not_nil(read(path .. ".sdr/metadata.lua"))
        assert.are.equal("keep backup", read(path .. ".sdr/metadata.lua.old"))
        advance(5)
        assert.is_nil(read(path))
        assert.is_not_nil(read(path .. ".sdr/metadata.lua"))
        assert.are.equal("keep backup", read(path .. ".sdr/metadata.lua.old"))
    end)

    it("verifies legacy and pending-removal archives without publishing download authority", function()
        local plugin, owner = manualHost(0, true)
        local path = directory .. "/c1.cbz"
        local native = require("spec/support/native_archiver")
        local writer = native.Writer:new()
        files[path] = true
        assert(writer:open(path, "zip"))
        assert(writer:addFileFromMemory("1.png", "test page"))
        assert(writer:close())
        local queue = plugin:getDownloadQueue()
        local function verify()
            local outcome
            assert(queue:verifyArchive(manga, chapters[1], path, function(result) outcome = result.state end))
            local worker = workers[#workers]
            local previous_archiver, previous_headers = package.loaded["ffi/archiver"], package.loaded["ffi/libarchive_h"]
            local restore = native.install()
            local ran, err = pcall(worker.callback)
            restore()
            package.loaded["ffi/archiver"], package.loaded["ffi/libarchive_h"] = previous_archiver, previous_headers
            assert.is_true(ran, err)
            worker.alive = false
            advance(0)
            assert.are.equal("valid", outcome)
            assert.is_nil(queue.verification)
        end
        verify()
        assert.is_nil(queue.manual_deletion:getTarget("m1:c1", path))
        assert(plugin:performChapterAction(manga, chapters[1], "mark_read"))
        local before = settings.store:readKey("manual_archive_state").requests["m1:c1"]
        verify()
        local after = settings.store:readKey("manual_archive_state").requests["m1:c1"]
        assert.are.equal(before.revision, after.revision)
        assert.are.equal(before.target.generation, after.target.generation)
        assert.are.equal("pending", after.state)
        owner:close()
        advance(300)
        assert.is_nil(read(path))
    end)

    it("keeps explicit repair authority through cancellation and late publication", function()
        local plugin, owner = manualHost(0, true)
        local queue = plugin:getDownloadQueue()
        local path = directory .. "/c1.cbz"
        write(path, "original damaged archive")
        assert(plugin:performChapterAction(manga, chapters[1], "mark_read"))
        local original = settings.store:readKey("manual_archive_state").requests["m1:c1"]
        assert(queue:upsertPersistentJob(queue:buildPersistentJob(manga, chapters[1], directory, "failed", {
            archive_generation = original.target.generation,
            progress = { state = "failed", archive_state = "damaged",
                identity = require("suwayomi/downloads/archive").identity(path), path = path },
        })))
        assert(queue:redownload(manga, chapters[1], directory))
        assert.are.equal("original damaged archive", read(path))
        assert.are.equal("revoked", settings.store:readKey("manual_archive_state").requests["m1:c1"].state)
        advance(0)
        local active = assert(queue:getActiveJob("m1:c1"))
        assert(queue:cancelPending(manga, chapters[1]))
        write(path, "validated late replacement")
        write(active.progress_path, "state=downloaded\ncurrent=1\ntotal=1\npath=" .. path .. "\n")
        workers[active.pid].alive = false
        advance(0.5)
        assert(queue:commitChapterCompletion(active, path))
        owner:close()
        advance(300)
        assert.are.equal("validated late replacement", read(path))
        assert.are.equal(path, settings:loadChapterLedger()["m1:c1"].path)
        assert.are_not.equal(original.target.generation, settings:loadChapterLedger()["m1:c1"].archive_generation)
        assert.are.same({}, settings:loadDownloadQueue())
    end)

    it("refills the sixth position after completed native reader navigation without a chapter view", function()
        assert(settings:save({ server_url = "https://example.invalid" }))
        local scoped = {
            id = "m1", title = "Example", source = manga.source,
            endpoint_scope = "https://example.invalid",
        }
        local complete, ledger = {}, {}
        for index = 1, 6 do
            complete[index] = { id = "c" .. index, name = "Chapter " .. index, source_order = index, is_read = false }
            if index <= 5 then
                local path = directory .. "/c" .. index .. ".cbz"
                write(path, "existing archive")
                ledger["m1:c" .. index] = {
                    manga_id = "m1", chapter_id = "c" .. index, path = path, read = false,
                    endpoint_scope = scoped.endpoint_scope,
                }
            end
        end
        assert(settings:saveChapterLedger(ledger))
        local api = require("suwayomi/api")
        api.fetchChaptersForManga = function() return { ok = true, chapters = complete } end
        api.fetchMangaById = function() return { ok = true, manga = scoped } end
        local plugin, files_owner = host("files")
        local queue = plugin:getDownloadQueue()
        assert(queue.refill:associate(scoped))
        assert(settings:saveMangaKeepNextUnreadDownloads(scoped, 5))
        runtime.reader_ui:showReader(directory .. "/c1.cbz")
        advance(0)
        assert.is_true(files_owner.closed)
        local reader_a = runtime.reader_ui.instance
        reader_a.doc_settings = { readSetting = function(_, key)
            if key == "summary" then return { status = "complete" } end
        end }
        reader_a:handleEvent("CloseDocument")
        runtime.reader_ui:showReader(directory .. "/c2.cbz")
        assert.is_true(reader_a.closed)
        assert.are.equal(0, #workers, "close must only admit durable work, never launch network inline")
        local entry = settings:loadChapterLedger()["m1:c1"]
        assert.is_true(entry.read)
        assert.is_true(entry.pending_read_sync)
        assert.are.equal(1, #queue:getSnapshot().refills)
        advance(0)
        local reader_b = runtime.reader_ui.instance
        assert.are.equal(directory .. "/c2.cbz", reader_b.document.file)
        assert.is_nil(reader_b.plugin.current_chapter_context)
        assert.are.equal(1, #workers, "duplicate closes must coalesce into one context helper")
        reader_b:close()
        assert.is_nil(runtime.reader_ui.instance)
        local before_result = read(settings.store.path)
        workers[1].callback()
        assert.are.equal(before_result, read(settings.store.path), "the context child only writes its result")
        advance(1)
        assert.are.same({}, settings:loadDownloadQueue(), "a result file does not prove known-child exit")
        workers[1].alive = false
        advance(1)
        local jobs = settings:loadDownloadQueue()
        assert.are.equal(1, #jobs)
        assert.are.equal("c6", jobs[1].chapter.id)
        assert.are.equal(directory, jobs[1].download_directory)
        assert.are.same({}, queue:getSnapshot().refills)
        assert.is_true(settings:loadChapterLedger()["m1:c1"].pending_read_sync)
        assert.are.equal("existing archive", read(directory .. "/c1.cbz"))
        local returned = host("files")
        local snapshot = returned:getDownloadQueue():getSnapshot()
        assert.are.equal("c6", snapshot.active[1].chapter.id)
        local visible
        for _, row in ipairs(returned:showDownloads().item_table) do
            if row.text == "Example / Chapter 6" then visible = row end
        end
        assert.is_not_nil(visible)
        assert.are.equal("Downloading", visible.mandatory)
    end)

    it("ignores final-page-only, unfinished, and unlinked completed reader closes", function()
        assert(settings:save({ server_url = "https://example.invalid" }))
        local plugin, owner = host("files")
        local queue = plugin:getDownloadQueue()
        assert(queue.refill:associate({
            id = "m1", title = "Example", source = manga.source,
            endpoint_scope = "https://example.invalid",
        }))
        assert(settings:saveMangaKeepNextUnreadDownloads(manga, 5))
        local path = directory .. "/c1.cbz"
        write(path, "managed archive")
        assert(settings:saveChapterLedger({
            ["m1:c1"] = { manga_id = "m1", chapter_id = "c1", path = path, read = false },
        }))
        owner:close()
        for _, control in ipairs({
            { path = path, summary = { status = "reading" }, percent = 1 },
            { path = path, summary = { status = "reading" }, percent = 0.5 },
            { path = directory .. "/unlinked.cbz", summary = { status = "complete" }, percent = 1 },
        }) do
            local _, reader = host("reader", control.path)
            reader.doc_settings = { readSetting = function(_, key)
                if key == "summary" then return control.summary end
                if key == "percent_finished" then return control.percent end
            end }
            reader:close()
            advance(0)
            assert.are.same({}, queue:getSnapshot().refills)
            assert.are.same({}, settings:loadDownloadQueue())
            assert.is_false(settings:loadChapterLedger()["m1:c1"].read)
            assert.are.equal(0, #workers)
        end
    end)

    it("renders durable retry deadlines and rejects retired refill controls", function()
        assert(settings:save({ server_url = "https://example.invalid" }))
        local scoped = {
            id = "m1", title = "Example", source = manga.source,
            endpoint_scope = "https://example.invalid",
        }
        local api = require("suwayomi/api")
        api.fetchChaptersForManga = function()
            return { ok = false, error = "offline", retryable = true }
        end
        local shown
        package.preload["ui/widget/textviewer"] = function() return {
            new = function(_, options)
                options.onClose = function() end
                return options
            end,
        } end
        ui.show = function(_, widget) shown = widget end
        local plugin, owner = host("files")
        local queue = plugin:getDownloadQueue()
        assert(queue.refill:setPolicy(scoped, 5))
        advance(0)
        workers[1].callback()
        workers[1].alive = false
        advance(1)
        local request = assert(queue:getSnapshot().refills[1])
        assert.are.equal("waiting", request.state)
        assert.is_true(request.next_retry_at > clock)
        local function refillRow(menu)
            for _, row in ipairs(menu.item_table) do
                if row.text == "Example" then return row end
            end
            error("pending refill must be visible in Downloads")
        end
        local row = refillRow(plugin:showDownloads())
        assert.are.equal("Ahead waiting", row.mandatory)
        local subtitle = row.subtitle
        assert.is_not_nil(subtitle:find(require("suwayomi/downloads/status_formatter").formatRetryTime(request.next_retry_at), 1, true))
        plugin:refreshDownloadsMenu()
        row = refillRow(plugin.current_downloads_menu)
        assert.are.equal(subtitle, row.subtitle, "repainting must retain the fixed retry time")
        row.callback()
        local retired_controls = assert(shown).buttons_table[1]
        local committed = read(settings.store.path)
        owner:close()
        shown = nil
        row.callback()
        assert.is_nil(shown, "retired rows must not open overlays")
        retired_controls[1].callback()
        retired_controls[2].callback()
        assert.are.equal(committed, read(settings.store.path))
        local current = host("files")
        refillRow(current:showDownloads()).callback()
        shown.buttons_table[1][2].callback()
        assert.are.equal(0, settings:loadMangaKeepNextUnreadDownloads(scoped))
        assert.are.same({}, queue:getSnapshot().refills)
        advance(300)
        assert.are.equal(1, #workers, "Stop must retire the delayed retry without a replacement helper")
        assert.are.same({}, settings:loadDownloadQueue())
    end)

    it("removes the oldest completed archive after reader closes across restart", function()
        local plugin, files_owner = manualHost(3)
        assert(settings:saveDeleteChaptersSettings({
            delete_after_mark_read = false, delete_finished_while_reading = 3,
        }))
        local ledger = {}
        for index = 1, 3 do
            local chapter = chapters[index]
            local path = directory .. "/" .. chapter.id .. ".cbz"
            write(path, "archive " .. index)
            ledger["m1:" .. chapter.id] = {
                manga_id = "m1", chapter_id = chapter.id, path = path, read = false,
            }
        end
        assert(settings:saveChapterLedger(ledger))
        for index = 1, 3 do
            local key = "m1:" .. chapters[index].id
            assert(plugin:getDownloadQueue().manual_deletion:prepareRemoval(key, ledger[key].path, directory))
        end
        files_owner:close()
        require("socket").sleep(1.1) -- lfs reports ctime in whole seconds.
        for index = 1, 3 do
            local path = directory .. "/" .. chapters[index].id .. ".cbz"
            local _, owner = host("reader", path)
            owner:handleEvent("ReadSettings")
            -- ReadHistory:addItem updates access time between plugin init and ReaderReady.
            assert(require("lfs").touch(path, original_time(), require("lfs").attributes(path, "modification")))
            owner:handleEvent("ReaderReady")
            owner.doc_settings = { readSetting = function(_, key)
                if key == "summary" then return { status = "complete" } end
            end }
            owner:close()
            advance(0)
            if index == 2 then
                assert.are.equal("archive 1", read(directory .. "/c1.cbz"))
                ui:quit()
                timers = {}
                settings.store = require("suwayomi/settings/store"):new{ path = settings.store.path }
                package.loaded["suwayomi/downloads/service"] = nil
                package.loaded.main = nil
                shell = require("main")
            end
        end
        assert.is_nil(read(directory .. "/c1.cbz"))
        assert.are.equal("archive 2", read(directory .. "/c2.cbz"))
        assert.are.equal("archive 3", read(directory .. "/c3.cbz"))
        assert.is_true(settings:loadChapterLedger()["m1:c1"].read)
        assert.is_nil(settings:loadChapterLedger()["m1:c1"].path)
    end)

    for _, replaced_before_capture in ipairs({ true, false }) do
        it("preserves a replacement around reader access capture " .. tostring(replaced_before_capture), function()
            local plugin, files_owner = manualHost(1)
            assert(settings:saveDeleteChaptersSettings({ delete_finished_while_reading = 1 }))
            local path = directory .. "/c1.cbz"
            write(path, "same contents")
            assert(settings:saveChapterLedger({ ["m1:c1"] = {
                manga_id = "m1", chapter_id = "c1", path = path, read = false,
            } }))
            assert(plugin:getDownloadQueue().manual_deletion:prepareRemoval("m1:c1", path, directory))
            files_owner:close()
            local _, owner = host("reader", path)
            if not replaced_before_capture then owner:handleEvent("ReadSettings") end
            write(path .. ".replacement", "same contents")
            assert(os.rename(path .. ".replacement", path))
            if replaced_before_capture then owner:handleEvent("ReadSettings") end
            owner:handleEvent("ReaderReady")
            owner.doc_settings = { readSetting = function(_, key)
                if key == "summary" then return { status = "complete" } end
            end }
            owner:close()
            advance(300)
            assert.are.equal("same contents", read(path))
            assert.are.equal(path, settings:loadChapterLedger()["m1:c1"].path)
            assert.is_not_nil(settings:loadFinishedChapterCleanupJournal().mangas.m1.records[1].blocked_reason)
        end)
    end

    it("keeps pending manual removal bound through a reader access-time update", function()
        local plugin, owner = manualHost(0, true)
        local path = directory .. "/c1.cbz"
        write(path, "pending archive")
        assert(require("lfs").mkdir(path .. ".sdr"))
        write(path .. ".sdr/metadata.lua", "return { custom = 'preserve' }")
        write(path .. ".sdr/metadata.lua.old", "preserve backup")
        assert(plugin:performChapterAction(manga, chapters[1], "mark_read"))
        owner:handleEvent("ReadSettings")
        require("socket").sleep(1.1)
        assert(require("lfs").touch(path, original_time(), require("lfs").attributes(path, "modification")))
        owner:handleEvent("ReaderReady")
        assert.are.equal("pending archive", read(path))
        owner:close()
        advance(5)
        assert.is_nil(read(path))
        assert.is_not_nil(read(path .. ".sdr/metadata.lua"))
        assert.are.equal("preserve backup", read(path .. ".sdr/metadata.lua.old"))
    end)

    for _, route in ipairs({ "chapter list", "downloaded ledger" }) do
        it("preserves synchronized unread state despite reader history through " .. route, function()
            local plugin = manualHost(0)
            local chapter = { id = "c1", name = "Chapter 1", is_read = false }
            local path = directory .. "/c1.cbz"
            write(path, "unfinished archive")
            assert(require("lfs").mkdir(path .. ".sdr"))
            write(path .. ".sdr/metadata.lua", 'return { ["summary"] = { ["status"] = "reading" }, ["percent_finished"] = 0.2 }')
            write(directory .. "/history.lua", "return { { file = " .. string.format("%q", path) .. " } }")
            plugin:setCurrentMangaChapterContext(manga, { chapter })
            assert(plugin:performChapterAction(manga, chapter, "mark_unread"))
            local batch = plugin:buildPendingReadSyncBatch(plugin:loadChapterLedger(), 50)
            assert.are.equal(1, plugin:applyPendingReadSyncResult({ batch = batch }, { successes = batch }))
            plugin:setCurrentMangaChapterContext(manga, {
                { id = "c1", name = "Chapter 1", is_read = false },
            })
            if route == "chapter list" then plugin:refreshChapterMenu()
            else plugin:reconcileDownloadedChapterLedger() end
            local entry = settings:loadChapterLedger()["m1:c1"]
            assert.is_false(entry.read)
            assert.is_nil(entry.pending_read_sync)
            local metadata = assert(loadfile(path .. ".sdr/metadata.lua"))()
            assert.is_nil(metadata.summary.status)
            assert.are.equal(0, metadata.percent_finished)
            assert.are.equal("unfinished archive", read(path))
        end)
    end

    for _, already_read in ipairs({ false, true }) do
    it("records completed close for retention with ahead Off and prior read " .. tostring(already_read), function()
        local path = directory .. "/c1.cbz"
        write(path, "completed archive")
        assert(settings:saveDeleteChaptersSettings({ delete_finished_while_reading = 3 }))
        assert(settings:saveChapterLedger({ ["m1:c1"] = {
            manga_id = "m1", chapter_id = "c1", path = path, read = already_read,
        } }))
        local plugin, owner = host("reader", path)
        owner.doc_settings = { readSetting = function(_, key)
            if key == "summary" then return { status = "complete" } end
        end }
        owner:close()
        advance(0)
        local entry = settings:loadChapterLedger()["m1:c1"]
        assert.is_true(entry.read)
        if not already_read then assert.is_true(entry.pending_read_sync) end
        local records = settings:loadFinishedChapterCleanupJournal().mangas.m1.records
        assert.are.equal(1, #records)
        assert.are.equal("c1", records[1].chapter_id)
        assert.are.equal(path, records[1].path)
        assert.are.equal("completed archive", read(path))
        assert.are.same({}, plugin:getDownloadQueue():getSnapshot().refills)
        assert.are.equal(0, #workers)
    end)
    end

end)
