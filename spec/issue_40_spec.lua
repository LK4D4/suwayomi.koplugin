package.path = "?.lua;" .. package.path

local runtime_helper = require("spec/support/plugin_runtime_spec_helper")

-- Exercise public completion routes with real checked storage, archive identity,
-- retention and files. Reject only enrollment writes, after the read commit.
describe("completion enrollment storage recovery (#40)", function()
    local directory, runtime, settings, service, plugin, chapters, timers, clock
    local reject_enrollment, writing_enrollment
    local original_time = os.time
    local manga = { id = "m", title = "Manga", source = { id = "s", name = "Source" } }
    local function clear()
        runtime_helper.teardown()
        for _, name in ipairs({ "suwayomi/settings/store", "suwayomi/chapters/manual_deletion",
            "suwayomi/chapters/archive_identity", "docsettings" }) do
            package.loaded[name], package.preload[name] = nil, nil
        end
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
    local function recordIds()
        local journal = settings:loadFinishedChapterCleanupJournal()
        local ids = {}
        for _, record in ipairs(journal.mangas.m and journal.mangas.m.records or {}) do
            ids[#ids + 1] = record.chapter_id
        end
        return ids
    end
    local function publish(chapter, content)
        assert(service.queue:enqueue(manga, chapter, directory, { provenance = "explicit" }))
        service.queue:process()
        local active = assert(service.queue:getActiveJob("m:" .. chapter.id))
        write(path(chapter.id), content or "archive pages")
        write(active.progress_path, "state=downloaded\ncurrent=1\ntotal=1\npath=" .. path(chapter.id) .. "\n")
        service.queue:poll()
        assert.is_nil(service.queue:getActiveJob("m:" .. chapter.id))
    end
    before_each(function()
        clear()
        runtime = runtime_helper.install()
        timers, clock, reject_enrollment, writing_enrollment = {}, 100, false, false
        os.time = function() return clock end
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
        facade.showChapterMenu = function(options) return { chapters = options.chapters, title = options.title } end
        facade.updateChapterMenu = function(menu, options)
            if menu then menu.chapters, menu.title = options.chapters, options.title end
        end
        plugin = require("main")({ ui = { menu = { registerToMainMenu = function() end } } })
        plugin:init()
        service = require("suwayomi/downloads/service").get()
        chapters = {}
        for _, id in ipairs({ "A", "B", "C", "D" }) do
            local chapter = { id = id, name = id }
            chapters[#chapters + 1] = chapter
            publish(chapter)
        end
        plugin:setCurrentMangaChapterContext(manga, chapters)
        plugin.current_chapter_menu = {}
        plugin:trackSuwayomiScreen("chapters", plugin.current_chapter_menu)
        plugin:refreshChapterMenu()
        assert(settings:saveDeleteChaptersSettings({ delete_after_mark_read = false, delete_finished_while_reading = 3 }))
        local save = settings.saveFinishedChapterCleanupJournal
        settings.saveFinishedChapterCleanupJournal = function(self, journal)
            writing_enrollment = true
            local saved, err = save(self, journal)
            writing_enrollment = false
            return saved, err
        end
        local open = settings.store.io.open
        settings.store.io.open = function(...)
            if writing_enrollment and reject_enrollment then return nil, "injected enrollment rejection" end
            return open(...)
        end
        advance(0)
    end)
    after_each(function()
        os.time = original_time
        if directory then removeTree(directory) end
        clear()
    end)

    it("retains reread A and later C after rejecting A enrollment following its read commit", function()
        assert(plugin:markChapterRead(manga, chapters[1]))
        assert(plugin:markChapterRead(manga, chapters[2]))
        reject_enrollment = true
        local ok, result = plugin:markChapterRead(manga, chapters[1])
        assert.is_true(ok)
        assert.is_true(result.committed)
        assert.is_true(settings:loadChapterLedger()["m:A"].pending_read_state)
        assert.same({ "A", "B" }, recordIds())
        reject_enrollment = false
        assert(plugin:markChapterRead(manga, chapters[3]))
        advance(0)
        assert.equals("archive pages", read(path("A")))
        assert.is_nil(read(path("B")))
        assert.equals("archive pages", read(path("C")))
        assert.same({ "A", "C" }, recordIds())
        assert.is_true(plugin:isChapterPathFinishedInKoreader(path("A")))
        assert.is_false(plugin:isChapterPathFinishedInKoreader(path("B")))
    end)

    it("blocks stale cleanup during rejection and retries without another completion action", function()
        assert(plugin:markChapterListRead(manga, { chapters[1], chapters[2], chapters[3] }))
        reject_enrollment = true
        local completions = {}
        assert(plugin:markChapterRead(manga, chapters[1], { finished_entries = completions }))
        local saved, err = plugin:recordFinishedChapter(completions[1])
        assert.is_false(saved)
        assert.is_truthy(err)
        advance(0)
        assert.equals("archive pages", read(path("A")))
        assert.equals("archive pages", read(path("B")))
        assert.same({ "A", "B", "C" }, recordIds())
        -- Mutating the caller's buffer must not alter captured deletion authority.
        completions[1].path = path("D")
        completions[1].archive_target.path = path("D")
        reject_enrollment = false
        advance(10)
        assert.same({ "C", "A" }, recordIds())
        assert.is_nil(read(path("B")))
        assert.equals("archive pages", read(path("A")))
        assert.equals("archive pages", read(path("D")))
        assert(settings:saveDeleteChaptersSettings({ delete_finished_while_reading = 1 }))
        plugin:processFinishedChapterCleanup()
        assert.is_nil(read(path("A")))
        assert.equals("archive pages", read(path("D")))
    end)

    it("preserves bulk input order, deduplication and pathless positions through recovery", function()
        assert(os.remove(path("C")))
        reject_enrollment = true
        assert(plugin:markChapterListRead(manga, { chapters[2], chapters[1], chapters[2], chapters[3] }))
        assert.same({}, recordIds())
        reject_enrollment = false
        publish(chapters[3], "later pathless replacement")
        advance(5)
        assert.same({ "B", "C" }, recordIds())
        assert.is_nil(read(path("A")))
        assert.equals("archive pages", read(path("B")))
        assert(plugin:markChapterRead(manga, chapters[4]))
        advance(0)
        assert.same({ "C", "D" }, recordIds())
        assert.is_nil(read(path("A")))
        assert.is_nil(read(path("B")))
        assert.equals("later pathless replacement", read(path("C")))
        assert.equals("archive pages", read(path("D")))
    end)

    it("recovers native completed-close enrollment and preserves the active reader", function()
        assert(plugin:markChapterListRead(manga, { chapters[1], chapters[2] }))
        assert(plugin:setKoreaderChapterReadState(path("C"), true))
        plugin.ui.document = { file = path("C") }
        plugin.ui.doc_settings = { readSetting = function() return { status = "complete" } end }
        runtime.reader_ui.instance = { document = { file = path("A") } }
        reject_enrollment = true
        plugin:onCloseDocument()
        assert.is_true(settings:loadChapterLedger()["m:C"].read)
        assert.same({ "A", "B" }, recordIds())
        reject_enrollment = false
        assert(plugin:markChapterRead(manga, chapters[4]))
        advance(5)
        assert.equals("archive pages", read(path("A")))
        assert.same({ "A", "B", "C", "D" }, recordIds())
        runtime.reader_ui.instance = nil
        advance(5)
        assert.is_nil(read(path("A")))
        assert.is_nil(read(path("B")))
        assert.equals("archive pages", read(path("C")))
        assert.same({ "C", "D" }, recordIds())
    end)

    it("never transfers a pending completion to a replacement archive generation", function()
        reject_enrollment = true
        assert(plugin:markChapterRead(manga, chapters[1]))
        reject_enrollment = false
        assert(os.remove(path("A")))
        publish(chapters[1], "replacement generation")
        assert(plugin:markChapterListRead(manga, { chapters[2], chapters[3] }))
        advance(5)
        assert.equals("replacement generation", read(path("A")))
        assert.equals("archive pages", read(path("B")))
        assert.equals("archive pages", read(path("C")))
    end)

    it("does not resurrect a pending completion after explicit unread", function()
        reject_enrollment = true
        assert(plugin:markChapterRead(manga, chapters[1]))
        assert(plugin:markChapterUnread(manga, chapters[1]))
        reject_enrollment = false
        assert(plugin:markChapterListRead(manga, { chapters[2], chapters[3], chapters[4] }))
        advance(5)
        assert.is_false(settings:loadChapterLedger()["m:A"].read)
        assert.same({ "C", "D" }, recordIds())
        assert.equals("archive pages", read(path("A")))
    end)
end)
