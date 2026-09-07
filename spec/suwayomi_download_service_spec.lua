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

    it("fails unfinished startup jobs quietly, preserves files and diagnostics, and permits explicit retry", function()
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
        assert.are.equal(3, queue:getFailedCount())
        assert.are.equal("failed", queue:getStatus(manga, chapters[1]).state)
        assert.are.equal("failed", queue:getStatus(manga, chapters[2]).state)
        assert.is_nil(queue:findPersistentJob("m1:c2").retry_at)
        assert.are.equal(3, queue:findPersistentJob("m1:c2").retry_count)
        assert.are.equal("Interrupted; retry download", queue:findPersistentJob("m1:c2").progress.error)
        assert.are.equal("HTTP 401: full original diagnostic", queue:findPersistentJob("m1:c3").progress.error)
        assert.are.same(jobs[5], queue:findPersistentJob("future"))
        assert.are.equal(path, settings:loadChapterLedger()["m1:c4"].path)
        assert.are.equal(path, settings:loadReaderReturnContexts()[path].path)
        assert.are.equal("old untracked partial", read(directory .. "/c1.cbz.part"))
        local failed_rows = 0
        for _, row in ipairs(plugin:showDownloads().item_table) do
            if row.mandatory == "Failed" then failed_rows = failed_rows + 1 end
        end
        assert.are.equal(3, failed_rows)
        assert.are.equal("Downloads · 3 failed", plugin:showHome().actions[3].text)
        plugin:retryDownloadJob(queue:findPersistentJob("m1:c1"))
        advance(0)
        assert.are.equal(1, #workers)
        local active = queue:getActiveJob("m1:c1")
        local retried_path = directory .. "/c1.cbz"
        write(retried_path, "explicit retry complete")
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
        write(directory .. "/c1.cbz.part", "partial")
        local confirm
        require("suwayomi/ui").showConfirm = function(options) confirm = options.ok_callback end
        assert(plugin:performDownloadsTitleAction({ id = "cancel_all" }, plugin:showDownloads()))
        assert.is_function(confirm)
        confirm()
        assert.is_true(workers[active.pid].terminated)
        assert.are.equal(2, queue:getActiveCount())
        assert.is_not_nil(read(active.progress_path))
        assert.are.equal("partial", read(directory .. "/c1.cbz.part"))
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
        assert.is_nil(read(directory .. "/c1.cbz.part"))
        assert.are.equal("finished during cancellation", read(directory .. "/c1.cbz"))
        assert.are.equal(directory .. "/c1.cbz", settings:loadChapterLedger()["m1:c1"].path)
        assert(queue:enqueue(manga, chapters[2], directory))
        advance(0)
        assert.are.equal(3, #workers)
    end)

    it("chains quit once, invalidates callbacks, preserves unconfirmed files and fails unfinished work on relaunch", function()
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
        assert.are.equal(4, restarted:getDownloadQueue():getFailedCount())
        assert.are.equal(2, #workers)
        assert.is_not_nil(read(active.progress_path))
    end)

    it("retries startup saves as service work while admission stays fenced through navigation", function()
        assert(settings:saveDownloadQueue({ {
            key = "m1:c1", state = "queued", manga = manga, chapter = chapters[1], download_directory = directory,
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
        assert.are.equal("queued", settings:loadDownloadQueue()[1].state)
        assert.are.equal(0, #workers)
        settings.store.io.write = write_file
        advance(1)
        assert.are.equal("failed", settings:loadDownloadQueue()[1].state)
        assert.are.equal(1, queue:getFailedCount())
        assert.are.equal(0, #workers)
        assert(queue:enqueue(manga, chapters[2], directory))
    end)

    it("retains failed worker files after Clear failed and blocks explicit retry until exit", function()
        local plugin = host("files")
        local queue = plugin:getDownloadQueue()
        assert(queue:enqueue(manga, chapters[1], directory))
        advance(0)
        local active = queue:getActiveJob("m1:c1")
        write(active.progress_path, "state=failed\nerror=full worker diagnostic\n")
        write(directory .. "/c1.cbz.part", "worker may still write")
        advance(0.5)
        assert.are.equal(1, queue:getFailedCount())
        assert.is_false(plugin:retryDownloadJob(queue:findPersistentJob("m1:c1")))
        assert(plugin:performDownloadsTitleAction({ id = "clear_failed" }, plugin:showDownloads()))
        assert.are.equal(0, queue:getFailedCount())
        assert.is_true(queue:isChapterBusy("m1:c1"))
        assert.is_false(queue:enqueue(manga, chapters[1], directory))
        assert.are.equal("worker may still write", read(directory .. "/c1.cbz.part"))
        workers[active.pid].alive = false
        advance(1)
        assert.is_nil(read(active.progress_path))
        assert.is_nil(read(directory .. "/c1.cbz.part"))
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
        assert.are.equal(path, settings:loadChapterLedger()["m1:c1"].path)
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
                "downloading", { retry_count = retry_count })))
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
        -- Seed durable work after startup has drained. No UI cleanup action or
        -- existing cleanup timer can wake it; the next queue transition must.
        assert(settings:saveFinishedChapterCleanupJournal({
            version = 1, next_sequence = 2,
            mangas = { m1 = { records = { {
                chapter_id = "c2", path = cleanup_path, sequence = 1, retry_count = 0, retry_after = 0,
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

end)
