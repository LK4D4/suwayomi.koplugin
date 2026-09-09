package.path = "?.lua;" .. package.path

local runtime_helper = require("spec/support/plugin_runtime_spec_helper")

-- Public manual/menu actions composed with the real process service, queue,
-- checked store, retention, archive identity and temporary files. Only host UI,
-- DocSettings location APIs, network workers and scheduling are replaced.
describe("manual read completion integration", function()
    local directory, runtime, settings, service, plugin, chapters, timers, messages
    local original_time = os.time
    local clock
    local manga = { id = "m", title = "Manga", source = { id = "s", name = "Source" } }
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
    local function records()
        local journal = settings:loadFinishedChapterCleanupJournal()
        return journal.mangas.m and journal.mangas.m.records or {}
    end
    local function recordIds()
        local ids = {}
        for _, record in ipairs(records()) do ids[#ids + 1] = record.chapter_id end
        return ids
    end
    local function configure(immediate, retention)
        assert(settings:saveDeleteChaptersSettings({
            delete_after_mark_read = immediate, delete_finished_while_reading = retention,
        }))
    end
    local function publish(chapter, content)
        assert(service.queue:enqueue(manga, chapter, directory, { provenance = "explicit" }))
        service.queue:process()
        local active = assert(service.queue:getActiveJob("m:" .. chapter.id))
        write(path(chapter.id), content or "archive pages")
        write(active.progress_path, "state=downloaded\ncurrent=1\ntotal=1\npath=" .. path(chapter.id) .. "\n")
        service.queue:poll()
        assert.is_nil(service.queue:getActiveJob("m:" .. chapter.id))
        assert.equals(path(chapter.id), settings:loadChapterLedger()["m:" .. chapter.id].path)
    end
    local function row(id)
        for _, item in ipairs(plugin.current_chapter_menu.chapters or {}) do
            if item.id == id then return item end
        end
        error("missing chapter row")
    end
    local function enableAhead(target, list)
        target, list = target or manga, list or chapters
        assert(settings:save({ server_url = "https://suwayomi.example" }))
        local network = require("suwayomi/network/request_job")
        local start = network.start
        network.start = function(options)
            assert.equals("https://suwayomi.example", options.credentials.server_url)
            options.on_finish({ ok = true, chapters = list })
            return {}
        end
        local ok = plugin:startFetchChaptersForManga(target)
        network.start = start
        assert(ok)
        assert(plugin:performMangaAction(target, "keep_next_5_unread"))
        assert.equals(5, settings:loadMangaKeepNextUnreadDownloads(target))
        assert(service.queue:cancelAll())
        assert.same({}, service.queue:getSnapshot().refills)
    end
    before_each(function()
        clear()
        runtime = runtime_helper.install()
        timers, messages, clock = {}, {}, 100
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
        ui.show = function(_, widget) messages[#messages + 1] = widget.text end
        ui.quit = function() end
        local debug = require("suwayomi/debug")
        debug.now = function() return clock end
        debug.elapsedMs = function(start) return (clock - start) * 1000 end
        local ffi_util = require("ffi/util")
        local next_pid = 0
        ffi_util.runInSubProcess = function()
            next_pid = next_pid + 1
            return next_pid
        end
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
        local shell = require("main")
        plugin = shell({ ui = { menu = { registerToMainMenu = function() end } } })
        plugin:init()
        service = require("suwayomi/downloads/service").get()
        chapters = {
            { id = "A", name = "A", chapter_number = 8, scanlator = "Team A" },
            { id = "B", name = "B", chapter_number = 2, scanlator = "Team A" },
            { id = "C", name = "C", chapter_number = 99, scanlator = "Team A" },
            { id = "D", name = "D", chapter_number = 1, scanlator = "Team A" },
        }
        for _, chapter in ipairs(chapters) do publish(chapter) end
        plugin:setCurrentMangaChapterContext(manga, chapters)
        plugin.current_chapter_menu = {}
        plugin:trackSuwayomiScreen("chapters", plugin.current_chapter_menu)
        plugin:refreshChapterMenu()
        configure(false, 3)
        timers, messages = {}, {}
    end)
    after_each(function()
        os.time = original_time
        if directory then removeTree(directory) end
        clear()
    end)

    for _, action in ipairs({ "single", "selected", "previous" }) do
        it("preserves visible completion order and pathless positions for " .. action, function()
            assert(os.remove(path("C")))
            if action == "single" then
                for index = 1, 3 do assert(plugin:performChapterAction(manga, chapters[index], "mark_read")) end
            elseif action == "selected" then
                for index = 3, 1, -1 do plugin:toggleChapterSelection(manga, chapters[index]) end
                assert.equals(3, plugin:markSelectedChaptersRead())
                assert.equals(0, plugin:getSelectedChapterCount())
                assert.is_false(plugin.selection_mode)
            else
                assert.equals(3, plugin:markChaptersBeforeRead(manga, chapters[4]))
            end
            assert.same({ "A", "B", "C" }, recordIds())
            assert.is_nil(records()[3].path)
            local ledger = settings:loadChapterLedger()
            for _, id in ipairs({ "A", "B", "C" }) do
                assert.is_true(ledger["m:" .. id].read)
                assert.is_true(ledger["m:" .. id].pending_read_sync)
                assert.is_true(row(id).is_read)
            end
            assert.is_false(ledger["m:D"].read)
            plugin:processFinishedChapterCleanup()
            assert.is_nil(read(path("A")))
            assert.equals("archive pages", read(path("B")))
            assert.same({ "B", "C" }, recordIds())
            publish(chapters[3], "later pathless replacement")
            assert(plugin:markChapterRead(manga, chapters[4]))
            plugin:processFinishedChapterCleanup()
            assert.equals("later pathless replacement", read(path("C")))
            assert.same({ "C", "D" }, recordIds())
        end)
    end

    for _, action in ipairs({ "selected", "previous" }) do
        it("commits non-target metadata reconciliation with the " .. action .. " batch", function()
            if action == "selected" then
                plugin:toggleChapterSelection(manga, chapters[2])
                plugin:toggleChapterSelection(manga, chapters[1])
            end
            assert(plugin:setKoreaderChapterReadState(path("C"), true))
            if action == "selected" then assert.equals(2, plugin:markSelectedChaptersRead())
            else assert.equals(2, plugin:markChaptersBeforeRead(manga, chapters[3])) end
            local ledger = settings:loadChapterLedger()
            assert.is_true(ledger["m:C"].read)
            assert.is_true(ledger["m:C"].pending_read_sync)
            assert.is_true(row("C").is_read)
            assert.same({ "A", "B" }, recordIds())
            assert.equals("archive pages", read(path("C")))
        end)
    end

    it("applies the scanlator filter to predecessor and selected scope", function()
        chapters[2].scanlator = "Team B"
        assert(settings:saveMangaScanlatorFilter(manga, "Team A"))
        plugin:setCurrentMangaChapterContext(manga, chapters)
        assert.equals(2, plugin:markChaptersBeforeRead(manga, chapters[4]))
        assert.same({ "A", "C" }, recordIds())
        assert.is_false(settings:loadChapterLedger()["m:B"].read)
    end)

    for _, action in ipairs({ "selected", "previous", "list" }) do
        it("leaves files and committed state unchanged for empty " .. action .. " scope", function()
            local before = read(settings.store.path)
            if action == "selected" then assert.equals(0, plugin:markSelectedChaptersRead())
            elseif action == "previous" then assert.equals(0, plugin:markChaptersBeforeRead(manga, chapters[1]))
            else assert.equals(0, plugin:markChapterListRead(manga, {})) end
            assert.equals(before, read(settings.store.path))
            assert.equals("archive pages", read(path("A")))
            assert.same({}, recordIds())
        end)
    end

    for _, retention in ipairs({ 0, 3 }) do
        it("removes only manual archives and retains metadata with retention " .. retention, function()
            configure(true, retention)
            local backup = "return { bookmarks = { 'preserved' } }"
            write(path("A") .. ".lua.old", backup)
            local count, result = plugin:markChapterListRead(manga, { chapters[1], chapters[2] })
            assert.equals(2, count)
            assert.is_true(result.committed)
            assert.equals(2, result.removed)
            assert.equals(0, result.pending)
            assert.is_nil(read(path("A")))
            assert.is_nil(read(path("B")))
            assert.equals(backup, read(path("A") .. ".lua.old"))
            assert.is_true(plugin:isChapterPathFinishedInKoreader(path("A")))
            assert.is_true(plugin:isChapterPathFinishedInKoreader(path("B")))
            assert.is_nil(settings:loadChapterLedger()["m:A"].path)
            assert.is_true(settings:loadChapterLedger()["m:A"].pending_read_sync)
            assert.same({}, messages)
            assert.equals("Read", row("A").menu_status)
            if retention == 3 then
                assert.same({ "A", "B" }, recordIds())
                for _, record in ipairs(records()) do assert.is_true(record.archive_retired) end
            end
        end)
    end

    it("checked supplied-ledger actions commit despite suppression and unread revokes the captured request", function()
        configure(true, 3)
        runtime.reader_ui.instance = { document = { file = path("A") } }
        local ledger = plugin:loadChapterLedger()
        local ok, result = plugin:markChapterRead(manga, chapters[1], {
            ledger = ledger, skip_refresh = true, skip_schedule = true, skip_keep_policy = true,
        })
        assert.is_true(ok)
        assert.equals(1, result.pending)
        assert.same({}, messages)
        assert.is_true(settings:loadChapterLedger()["m:A"].pending_read_state)
        assert.equals("pending", service.manual_deletion:snapshot()["m:A"].state)
        assert(plugin:markChapterUnread(manga, chapters[1], { ledger = ledger, skip_refresh = true, skip_schedule = true }))
        runtime.reader_ui.instance = nil
        service.manual_deletion:process()
        advance(10)
        assert.equals("archive pages", read(path("A")))
        assert.is_false(settings:loadChapterLedger()["m:A"].read)
        assert.is_false(settings:loadChapterLedger()["m:A"].pending_read_state)
        assert.same({}, recordIds())
    end)

    it("keeps a failed checked save out of completion publication and immediate removal", function()
        configure(true, 3)
        local original_open = settings.store.io.open
        settings.store.io.open = function() return nil, "injected storage failure" end
        local ok, result = plugin:markChapterRead(manga, chapters[1])
        settings.store.io.open = original_open
        assert.is_false(ok)
        assert.is_false(result.committed)
        assert.equals(0, result.marked_read)
        assert.equals(0, result.removed)
        assert.equals("archive pages", read(path("A")))
        assert.same({}, recordIds())
        assert.is_nil(service.manual_deletion:snapshot()["m:A"])
        assert.is_false(settings:loadChapterLedger()["m:A"].read)
        assert.is_false(row("A").is_read)
        assert.is_true(plugin:isChapterPathFinishedInKoreader(path("A")))
        assert.equals(1, #messages)
    end)

    it("publishes captured buffer completions without acquiring a later archive path", function()
        assert(os.remove(path("A")))
        local completions = {}
        assert(plugin:markChapterRead(manga, chapters[1], { finished_entries = completions, skip_refresh = true }))
        publish(chapters[1], "later archive")
        assert(plugin:recordFinishedChapter(completions[1]))
        assert.is_nil(records()[1].path)
        assert(plugin:markChapterListRead(manga, { chapters[2], chapters[3] }))
        plugin:processFinishedChapterCleanup()
        assert.equals("later archive", read(path("A")))
    end)

    it("moves repeated completion newest and removes it on explicit unread", function()
        for _, index in ipairs({ 1, 2, 3, 1 }) do assert(plugin:markChapterRead(manga, chapters[index])) end
        assert.same({ "B", "C", "A" }, recordIds())
        assert(plugin:markChapterUnread(manga, chapters[1]))
        assert.same({ "B", "C" }, recordIds())
        assert.is_false(settings:loadChapterLedger()["m:A"].read)
        assert.is_false(plugin:isChapterPathFinishedInKoreader(path("A")))
        assert.is_false(row("A").is_read)
        assert.is_truthy(row("A").menu_status:find("Downloaded", 1, true))
        assert.is_nil(row("A").menu_status:find("Read", 1, true))
    end)

    it("keeps explicit batch unread ahead of older KOReader history reconciliation", function()
        assert.equals(2, plugin:markChapterListRead(manga, { chapters[1], chapters[2] }))
        write(directory .. "/history.lua", "return {{ file = " .. string.format("%q", path("A")) .. " }}")
        assert.equals(2, plugin:markChapterListUnread(manga, { chapters[1], chapters[2] }))
        plugin:refreshChapterMenu()
        assert.is_false(settings:loadChapterLedger()["m:A"].read)
        assert.is_false(settings:loadChapterLedger()["m:A"].pending_read_state)
        assert.is_false(plugin:isChapterPathFinishedInKoreader(path("A")))
        assert.is_false(row("A").is_read)
        assert.equals("archive pages", read(path("A")))
    end)

    it("never infers completion authorization from server or metadata reconciliation", function()
        chapters[1].is_read = true
        plugin:setCurrentMangaChapterContext(manga, plugin:mergeChaptersWithReadLedger(manga, chapters))
        assert(plugin:setKoreaderChapterReadState(path("B"), true))
        plugin:refreshChapterMenu()
        assert.is_true(settings:loadChapterLedger()["m:A"].read)
        assert.is_true(settings:loadChapterLedger()["m:B"].read)
        assert.same({}, recordIds())
        plugin:processFinishedChapterCleanup()
        assert.equals("archive pages", read(path("A")))
        assert.equals("archive pages", read(path("B")))
    end)

    for _, action in ipairs({ "single", "selected", "previous" }) do
        it("durably enrolls one refill with the public " .. action .. " read action", function()
            enableAhead()
            if action == "single" then
                assert(plugin:performChapterAction(manga, chapters[1], "mark_read"))
            elseif action == "selected" then
                plugin:toggleChapterSelection(manga, chapters[1])
                plugin:toggleChapterSelection(manga, chapters[2])
                assert.equals(2, plugin:markSelectedChaptersRead())
            else
                assert.equals(2, plugin:markChaptersBeforeRead(manga, chapters[3]))
            end
            local requests = service.queue:getSnapshot().refills
            assert.equals(1, #requests)
            assert.equals("m", requests[1].manga_id)
            assert.is_true(settings:loadChapterLedger()["m:A"].pending_read_state)
            assert.is_true(row("A").is_read)
            assert.equals("archive pages", read(path("A")))
            local saved = read(settings.store.path)
            plugin:refreshChapterMenu({ quick = true })
            assert.equals(saved, read(settings.store.path))
        end)
    end

    it("enrolls unread with deletion revocation and preserves the live archive", function()
        enableAhead()
        configure(true, 0)
        runtime.reader_ui.instance = { document = { file = path("A") } }
        assert(plugin:performChapterAction(manga, chapters[1], "mark_read"))
        assert.equals("pending", service.manual_deletion:snapshot()["m:A"].state)
        assert(service.queue:cancelAll())
        assert(plugin:performChapterAction(manga, chapters[1], "mark_unread"))
        assert.equals(1, #service.queue:getSnapshot().refills)
        assert.is_false(settings:loadChapterLedger()["m:A"].pending_read_state)
        assert.is_false(row("A").is_read)
        runtime.reader_ui.instance = nil
        service.manual_deletion:process()
        assert.equals("archive pages", read(path("A")))
    end)

    it("does not enroll refill or publish read success when the shared read save fails", function()
        enableAhead()
        local open = settings.store.io.open
        settings.store.io.open = function() return nil, "injected storage failure" end
        local ok, result = plugin:markChapterRead(manga, chapters[1])
        settings.store.io.open = open
        assert.is_false(ok)
        assert.is_false(result.committed)
        assert.same({}, service.queue:getSnapshot().refills)
        assert.is_false(settings:loadChapterLedger()["m:A"].read)
        assert.is_false(row("A").is_read)
        assert.equals("archive pages", read(path("A")))
    end)

    it("enrolls reconciliation for a nonvisible manga without completion deletion", function()
        local other = { id = "other", title = "Other", initialized = true, source = manga.source }
        local other_chapter = { id = "E", name = "E" }
        enableAhead(other, { other_chapter })
        write(path("E"), "other archive")
        assert(plugin:upsertChapterLedgerEntry(other, other_chapter, { path = path("E"), read = false }))
        plugin:setCurrentMangaChapterContext(manga, chapters)
        plugin:refreshChapterMenu()
        assert(plugin:setKoreaderChapterReadState(path("E"), true))
        assert.equals(1, plugin:reconcileDownloadedChapterLedger())
        local requests = service.queue:getSnapshot().refills
        assert.equals(1, #requests)
        assert.equals("other", requests[1].manga_id)
        assert.is_true(settings:loadChapterLedger()["other:E"].pending_read_state)
        assert.same({}, recordIds())
        assert.is_not_true(row("A").is_read)
        assert.equals("other archive", read(path("E")))
    end)

    for _, route in ipairs({ "chapter", "manga" }) do
        it("stops pending ahead from the " .. route .. " action without canceling chapter work", function()
            enableAhead()
            assert(plugin:performMangaAction(manga, "keep_next_5_unread"))
            local missing = { id = "E", name = "E" }
            chapters[#chapters + 1] = missing
            plugin:setCurrentMangaChapterContext(manga, chapters)
            assert(plugin:performChapterAction(manga, missing, "download"))
            local before = assert(service.queue:findPersistentJob("m:E"))
            if route == "chapter" then assert(plugin:performBulkChapterAction("keep_next_0_unread"))
            else assert(plugin:performMangaAction(manga, "keep_next_0_unread")) end
            assert.equals(0, settings:loadMangaKeepNextUnreadDownloads(manga))
            assert.same({}, service.queue:getSnapshot().refills)
            assert.equals(before.state, assert(service.queue:findPersistentJob("m:E")).state)
            assert.equals("archive pages", read(path("A")))
        end)
    end

    it("keeps policy and refill together across rejected enable and stop saves", function()
        enableAhead()
        assert(plugin:performMangaAction(manga, "keep_next_0_unread"))
        local open = settings.store.io.open
        settings.store.io.open = function() return nil, "injected storage failure" end
        assert.is_false(plugin:performMangaAction(manga, "keep_next_5_unread"))
        assert.equals(0, settings:loadMangaKeepNextUnreadDownloads(manga))
        assert.same({}, service.queue:getSnapshot().refills)
        settings.store.io.open = open
        assert(plugin:performMangaAction(manga, "keep_next_5_unread"))
        assert.equals(1, #service.queue:getSnapshot().refills)
        settings.store.io.open = function() return nil, "injected storage failure" end
        assert.is_false(plugin:performMangaAction(manga, "keep_next_0_unread"))
        settings.store.io.open = open
        assert.equals(5, settings:loadMangaKeepNextUnreadDownloads(manga))
        assert.equals(1, #service.queue:getSnapshot().refills)
        assert.equals("archive pages", read(path("A")))
    end)
end)
