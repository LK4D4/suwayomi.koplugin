package.path = "?.lua;" .. package.path

local runtime_helper = require("spec/support/plugin_runtime_spec_helper")

-- Real action preload, checked store, process service and archive identity.
-- Host UI, network results, reader state and time are controlled; files are real.
describe("remote unread revokes deferred manual deletion (#38)", function()
    local directory, runtime, settings, service, plugin, chapters, timers, clock
    local original_time = os.time
    local manga
    local extra_modules = {
        "suwayomi/settings/store", "suwayomi/chapters/manual_deletion",
        "suwayomi/chapters/archive_identity", "docsettings",
    }
    local function clear()
        runtime_helper.teardown()
        for _, name in ipairs(extra_modules) do package.loaded[name], package.preload[name] = nil, nil end
    end
    local function path(id) return directory .. "/" .. id .. ".cbz" end
    local function write(file, content)
        local handle = assert(io.open(file, "wb"))
        assert(handle:write(content))
        assert(handle:close())
    end
    local function read(file)
        local handle = io.open(file, "rb")
        if not handle then return nil end
        local content = handle:read("*a")
        handle:close()
        return content
    end
    local function committed()
        return assert(loadfile(settings.store.path))()
    end
    local function removeTree(root)
        local lfs = require("lfs")
        for name in lfs.dir(root) do
            if name ~= "." and name ~= ".." then
                local file = root .. "/" .. name
                if lfs.symlinkattributes(file, "mode") == "directory" then removeTree(file)
                else os.remove(file) end
            end
        end
        assert(lfs.rmdir(root))
    end
    local function advance(seconds)
        clock = clock + seconds
        for _ = 1, 1000 do
            local selected
            for index, timer in ipairs(timers) do
                if timer.at <= clock and (not selected or timer.at < timers[selected].at) then selected = index end
            end
            if not selected then return end
            table.remove(timers, selected).callback()
        end
        error("callbacks did not yield")
    end
    local function publish(chapter)
        assert(service.queue:enqueue(manga, chapter, directory, { provenance = "explicit" }))
        service.queue:process()
        local active = assert(service.queue:getActiveJob("m:" .. chapter.id))
        write(path(chapter.id), "archive pages")
        write(active.progress_path, "state=downloaded\ncurrent=1\ntotal=1\npath=" .. path(chapter.id) .. "\n")
        service.queue:poll()
        assert.is_nil(service.queue:getActiveJob("m:" .. chapter.id))
        assert.equals(path(chapter.id), committed().chapter_ledger["m:" .. chapter.id].path)
    end
    local function holdAndMarkRead(chapter)
        runtime.reader_ui.instance = { document = { file = path(chapter.id) } }
        plugin.ui.document = runtime.reader_ui.instance.document
        plugin.ui.doc_settings = { readSetting = function(_, key)
            if key == "summary" then return { status = "reading" } end
            if key == "percent_finished" then return 1 end
        end }
        assert(plugin:performChapterAction(manga, chapter, "mark_read"))
        local request = assert(service.manual_deletion:snapshot()["m:" .. chapter.id])
        assert.equals("pending", request.state)
        assert.equals("archive pages", read(path(chapter.id)))
        plugin:trackSuwayomiScreen("manga_actions", {})
        return request
    end
    local function acknowledge()
        local batch = plugin:buildPendingReadSyncBatch(plugin:loadChapterLedger())
        assert.equals(1, #batch)
        local synced = plugin:applyPendingReadSyncResult({ batch = batch }, { successes = batch, attempted = #batch })
        assert.equals(1, synced)
        assert.is_nil(committed().chapter_ledger[batch[1].key].pending_read_sync)
    end
    local function preload(remote_read, other_read)
        local options, context
        local network = require("suwayomi/network/request_job")
        network.start = function(value) options = value; return {} end
        assert(plugin:startLoadMangaChapterContext(manga, function(value) context = value end))
        assert.equals("fetch_chapters_for_manga", options.request.action)
        options.on_finish({ ok = true, chapters = {
            { id = "A", name = "A", is_read = remote_read },
            { id = "B", name = "B", is_read = other_read == true },
        } })
        return context
    end
    local function releaseReader()
        plugin:onCloseDocument()
        runtime.reader_ui.instance = nil
        plugin.ui.document, plugin.ui.doc_settings = nil, nil
        advance(10)
    end
    before_each(function()
        clear()
        runtime = runtime_helper.install()
        timers, clock = {}, 100
        os.time = function() return clock end
        manga = { id = "m", title = "Manga", source = { id = "s", name = "Source" } }
        directory = os.tmpname():gsub("\\", "/")
        os.remove(directory)
        package.loaded.lfs, package.preload.lfs = nil, nil
        package.preload["suwayomi/fs"] = nil
        assert(require("lfs").mkdir(directory))
        package.preload["suwayomi/settings"] = nil
        package.preload["suwayomi/downloads/queue"] = nil
        package.preload["suwayomi/navigation"] = nil
        package.preload.datastorage = function() return { getSettingsDir = function() return directory end } end
        package.preload.luasettings = function() return { open = function() return { data = {} } end } end
        settings = require("suwayomi/settings")
        settings.store = require("suwayomi/settings/store"):new{ path = directory .. "/settings.lua" }
        assert(settings.store:saveKey("download_directory", directory))
        local ui = require("ui/uimanager")
        ui.scheduleIn = function(_, delay, callback) timers[#timers + 1] = { at = clock + delay, callback = callback } end
        ui.unschedule = function(_, callback)
            for index = #timers, 1, -1 do
                if timers[index].callback == callback then table.remove(timers, index) end
            end
        end
        ui.nextTick = function(_, callback) ui:scheduleIn(0, callback) end
        ui.quit = function() end
        local debug = require("suwayomi/debug")
        debug.now = function() return clock end
        debug.elapsedMs = function(start) return (clock - start) * 1000 end
        local ffi_util = require("ffi/util")
        local next_pid = 0
        ffi_util.runInSubProcess = function() next_pid = next_pid + 1; return next_pid end
        ffi_util.isSubProcessDone = function() return true end
        local downloader = require("suwayomi/downloads/downloader")
        downloader.getTargetPath = function(_, _, _, chapter) return directory, path(chapter.id) end
        downloader.chapterExists = function(_, file) return read(file) ~= nil end
        package.preload.docsettings = function()
            return {
                findSidecarFile = function() end,
                getSidecarFilename = function(file) return file:match("([^/]+)$") .. ".lua" end,
                getSidecarDir = function() return directory end,
                isHashLocationEnabled = function() return false end,
            }
        end
        local facade = require("suwayomi/ui")
        facade.formatRefillStatus = require("suwayomi/ui/downloads").formatRefillStatus
        facade.updateChapterMenu = function(menu, options) menu.chapters = options.chapters end
        local shell = require("main")
        plugin = shell({ ui = { menu = { registerToMainMenu = function() end } } })
        plugin:init()
        service = require("suwayomi/downloads/service").get()
        chapters = { { id = "A", name = "A" }, { id = "B", name = "B" } }
        for _, chapter in ipairs(chapters) do publish(chapter) end
        plugin:setCurrentMangaChapterContext(manga, chapters)
        plugin.current_chapter_menu = {}
        plugin:trackSuwayomiScreen("chapters", plugin.current_chapter_menu)
        plugin:refreshChapterMenu()
        assert(settings:saveDeleteChaptersSettings({ delete_after_mark_read = true, delete_finished_while_reading = 0 }))
    end)
    after_each(function()
        os.time = original_time
        if directory then removeTree(directory) end
        clear()
    end)

    it("commits revocation during action preload before any menu refresh or reader release", function()
        local other = holdAndMarkRead(chapters[2])
        acknowledge()
        local captured = holdAndMarkRead(chapters[1])
        write(path("A") .. ".lua.old", "preserved backup")
        local metadata = assert(read(path("A") .. ".lua"))
        acknowledge()
        local unrelated = committed().manual_archive_state.archives["m:B"]
        local context = assert(preload(false, true))
        assert.is_false(context.chapters[1].is_read)
        assert.is_false(settings:loadChapterLedger()["m:A"].read)
        local doc = committed()
        assert.is_false(doc.chapter_ledger["m:A"].read)
        assert.is_nil(doc.chapter_ledger["m:A"].pending_read_sync)
        assert.equals("revoked", doc.manual_archive_state.requests["m:A"].state)
        assert.equals("unread", doc.manual_archive_state.requests["m:A"].reason)
        assert.same(captured.target, doc.manual_archive_state.requests["m:A"].target)
        assert.same(unrelated, doc.manual_archive_state.archives["m:B"])
        assert.same(other, doc.manual_archive_state.requests["m:B"])
        releaseReader()
        assert.equals("archive pages", read(path("A")))
        assert.is_nil(read(path("B")))
        assert.equals("removed", service.manual_deletion:snapshot()["m:B"].state)
        assert.equals(metadata, read(path("A") .. ".lua"))
        assert.equals("preserved backup", read(path("A") .. ".lua.old"))
        assert.is_false(committed().chapter_ledger["m:A"].read)
    end)

    it("keeps an unacknowledged local read ahead of stale remote unread", function()
        local captured = holdAndMarkRead(chapters[1])
        local context = assert(preload(false))
        assert.is_true(context.chapters[1].is_read)
        assert.is_true(committed().chapter_ledger["m:A"].pending_read_state)
        assert.same(captured, service.manual_deletion:snapshot()["m:A"])
        acknowledge()
        releaseReader()
        assert.is_nil(read(path("A")))
        assert.equals("archive pages", read(path("B")))
        assert.equals("removed", service.manual_deletion:snapshot()["m:A"].state)
    end)

    it("removes only the captured generation and never a later identical publication", function()
        local captured = holdAndMarkRead(chapters[1])
        acknowledge()
        releaseReader()
        assert.is_nil(read(path("A")))
        local metadata = assert(read(path("A") .. ".lua"))
        local removed = service.manual_deletion:snapshot()["m:A"]
        assert.equals("removed", removed.state)
        assert.same(captured.target, removed.target)
        publish(chapters[1])
        local replacement = committed().manual_archive_state.archives["m:A"]
        assert.is_true(replacement.generation > captured.target.generation)
        advance(10)
        service.manual_deletion:process()
        assert.equals("archive pages", read(path("A")))
        assert.equals(metadata, read(path("A") .. ".lua"))
        assert.equals("archive pages", read(path("B")))
        assert.same(removed, service.manual_deletion:snapshot()["m:A"])
    end)

    it("does not publish unread or revoke intent when its checked save is rejected", function()
        holdAndMarkRead(chapters[1])
        acknowledge()
        local before = read(settings.store.path)
        local open = settings.store.io.open
        settings.store.io.open = function() return nil, "injected storage failure" end
        local context = preload(false)
        settings.store.io.open = open
        assert.is_nil(context)
        assert.equals(before, read(settings.store.path))
        assert.is_true(committed().chapter_ledger["m:A"].read)
        assert.equals("pending", service.manual_deletion:snapshot()["m:A"].state)
        assert.equals("archive pages", read(path("A")))
    end)

    it("preserves an archive when an older committed unread entry omits the read field", function()
        holdAndMarkRead(chapters[1])
        acknowledge()
        assert(settings.store:saveDocument(function(doc) doc.chapter_ledger["m:A"].read = nil end))
        assert.is_false(settings:loadChapterLedger()["m:A"].read)
        local metadata = assert(read(path("A") .. ".lua"))
        releaseReader()
        assert.equals("revoked", service.manual_deletion:snapshot()["m:A"].state)
        assert.equals("archive pages", read(path("A")))
        assert.equals(metadata, read(path("A") .. ".lua"))
    end)
end)
