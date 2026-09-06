package.path = "?.lua;" .. package.path

-- Exercise public actions, ledger, metadata, reader close and cleanup together.
-- Only storage, filesystem and UI scheduling are replaced.
describe("manual read completion integration", function()
    local modules = {
        "suwayomi/chapters/actions", "suwayomi/chapters/read_actions",
        "suwayomi/chapters/delete_actions", "suwayomi/chapters/local_downloads",
        "suwayomi/chapters/context", "suwayomi/chapters/finished_cleanup",
        "suwayomi/readsync/ledger", "suwayomi/readsync/koreader_metadata",
        "suwayomi/readsync/controller", "suwayomi/readsync/worker",
        "suwayomi/settings", "suwayomi/debug", "suwayomi/i18n",
        "suwayomi/manga/action_menu", "ui/uimanager", "ffi/util",
        "suwayomi/reader_return", "suwayomi/network/request_job", "apps/reader/readerui",
        "suwayomi/downloads/controller", "suwayomi/ui",
        "suwayomi/chapters/menu", "suwayomi/downloads/downloader",
        "suwayomi/downloads/queue", "suwayomi/downloads/active_jobs",
        "suwayomi/downloads/job_store", "suwayomi/downloads/progress_file",
        "suwayomi/downloads/status_formatter",
    }
    local saved_modules, saved_preloads
    local function clone(value)
        if type(value) ~= "table" then return value end
        local copy = {}
        for key, item in pairs(value) do copy[key] = clone(item) end
        return copy
    end
    local function noop() end
    local manga = { id = "m", title = "Manga" }
    local function chapter(id, number)
        return { id = id, name = id, chapter_number = number }
    end
    local function path(id)
        return "/downloads/source/manga/" .. id .. ".cbz"
    end
    local function records(state)
        local result = {}
        local journal_manga = state.journal.mangas.m
        for _, record in ipairs(journal_manga and journal_manga.records or {}) do
            result[#result + 1] = record.chapter_id
        end
        return result
    end
    local function fixture(setting)
        local state = {
            setting = setting or 3, immediate = false, ledger = {}, metadata = {},
            journal = { version = 1, next_sequence = 1, mangas = {} },
            existing = {}, scheduled = {}, removed = {}, events = {}, now = 100,
        }
        local settings = {
            loadDeleteChaptersSettings = function()
                return { delete_finished_while_reading = state.setting, delete_after_mark_read = state.immediate }
            end,
            loadDownloadDirectory = function() return "/downloads" end,
            loadDownloadQueue = function() return clone(state.jobs or {}) end,
            saveDownloadQueue = function(_, jobs) state.jobs = clone(jobs) end,
            loadChapterLedger = function() return clone(state.ledger) end,
            saveChapterLedger = function(_, ledger)
                state.ledger = clone(ledger)
                state.events[#state.events + 1] = { kind = "ledger", ledger = clone(ledger) }
                return clone(ledger)
            end,
            loadFinishedChapterCleanupJournal = function() return clone(state.journal) end,
            saveFinishedChapterCleanupJournal = function(_, journal)
                state.journal = clone(journal)
                state.events[#state.events + 1] = { kind = "journal", ledger = clone(state.ledger) }
                return clone(journal)
            end,
        }
        local stubs = {
            ["suwayomi/settings"] = settings,
            ["ui/uimanager"] = {
                scheduleIn = function(_, delay, callback)
                    state.scheduled[#state.scheduled + 1] = { delay = delay, callback = callback }
                end,
                unschedule = noop,
            },
            ["ffi/util"] = { realpath = function(value) return value end },
            ["suwayomi/debug"] = { now = function() return state.now end, elapsedMs = function() return 0 end, log = noop },
            ["suwayomi/i18n"] = {
                t = function(value) return value end,
                f = function(value) return value end,
                join = table.concat,
                count = function(_, singular) return singular end,
            },
            ["suwayomi/readsync/worker"] = {},
            ["suwayomi/network/request_job"] = {},
            ["suwayomi/ui"] = {
                updateChapterMenu = function(menu, options)
                    if not menu then return end
                    assert.is_not_true(menu.closed)
                    menu.title = options.title
                    menu.chapters = clone(options.chapters)
                    menu.refreshes = (menu.refreshes or 0) + 1
                    if state.on_refresh then state.on_refresh() end
                end,
                updateDownloadsMenu = function(menu, snapshot)
                    assert.is_not_true(menu.closed)
                    menu.snapshot = clone(snapshot)
                    menu.refreshes = (menu.refreshes or 0) + 1
                end,
            },
            ["suwayomi/downloads/downloader"] = {
                getTargetPath = function(_, _, _, c) return nil, path(c.id) end,
                findExistingChapterPath = function(_, _, _, c)
                    return state.existing[path(c.id)] and path(c.id) or nil
                end,
                chapterExists = function(_, value)
                    if state.on_stat then state.on_stat(value) end
                    return state.existing[value] == true
                end,
            },
            ["apps/reader/readerui"] = {},
        }
        for name, value in pairs(stubs) do
            package.loaded[name] = nil
            package.preload[name] = function() return value end
        end
        local mixins = {}
        for _, name in ipairs({
            "suwayomi/chapters/actions", "suwayomi/chapters/context",
            "suwayomi/readsync/ledger", "suwayomi/readsync/koreader_metadata",
            "suwayomi/readsync/controller", "suwayomi/chapters/finished_cleanup",
            "suwayomi/reader_return", "suwayomi/chapters/menu",
        }) do mixins[#mixins + 1] = require(name).methods end
        local function instance(chapters)
            local plugin = {}
            for _, methods in ipairs(mixins) do
                for name, method in pairs(methods) do plugin[name] = method end
            end
            plugin.current_chapter_context = { manga = manga, chapters = chapters or {} }
            plugin.current_chapter_menu = {}
            plugin.isSuwayomiScreenActive = function(_, menu) return not menu.closed end
            plugin.loadKoreaderHistoryPaths = function() return {} end
            plugin.saveReaderReturnContextsForChapters = nil
            plugin.isChapterPathFinishedInKoreader = function(_, value)
                return ((state.metadata[value .. ".lua"] or {}).summary or {}).status == "complete"
            end
            plugin.schedulePendingReadSync = noop
            plugin.showMessage = noop
            plugin.getChapterDownloadKey = function(_, m, c) return m.id .. ":" .. c.id end
            plugin.getKoreaderMetadataPathForDocument = function(_, value) return value .. ".lua" end
            plugin.loadKoreaderMetadataTable = function(_, value)
                return clone(state.metadata[value .. ".lua"] or {}), value .. ".lua"
            end
            plugin.saveKoreaderMetadataTable = function(_, value, metadata)
                state.metadata[value] = clone(metadata)
                return true
            end
            plugin.removeChapterArchiveAndSidecars = function(_, value)
                if state.fail_delete then return false end
                state.existing[value] = nil
                state.metadata[value .. ".lua"] = nil
                state.removed[#state.removed + 1] = value
                return true
            end
            local queue = require("suwayomi/downloads/queue"):new{
                settings = settings,
                downloader = stubs["suwayomi/downloads/downloader"],
                onStatusChanged = function()
                    plugin:scheduleFinishedChapterCleanup(0)
                    plugin:refreshChapterMenu({ quick = true })
                end,
            }
            plugin.getDownloadQueue = function() return queue end
            local downloads = require("suwayomi/downloads/controller").methods
            for _, name in ipairs({ "refreshDownloadsMenu", "getDownloadsMenuOptions",
                "getDownloadsTitleBarOptions", "getDownloadsMenuCallbacks" }) do
                plugin[name] = downloads[name]
            end
            return plugin
        end
        for _, id in ipairs({ "A", "B", "C", "D" }) do
            state.existing[path(id)] = true
        end
        return state, instance
    end

    before_each(function()
        saved_modules, saved_preloads = {}, {}
        for _, name in ipairs(modules) do
            saved_modules[name], saved_preloads[name] = package.loaded[name], package.preload[name]
            package.loaded[name], package.preload[name] = nil, nil
        end
    end)
    after_each(function()
        for _, name in ipairs(modules) do
            package.loaded[name], package.preload[name] = saved_modules[name], saved_preloads[name]
        end
    end)

    local function runScheduled(state)
        local scheduled = table.remove(state.scheduled, 1)
        assert.is_not_nil(scheduled)
        state.now = state.now + scheduled.delay
        scheduled.callback()
    end

    local function assertDownloaded(state, plugin, id, downloaded)
        assert.equals(downloaded, state.existing[path(id)] == true)
        assert.equals(downloaded and path(id) or nil, state.ledger["m:" .. id].path)
        local row
        for _, item in ipairs(plugin.current_chapter_menu.chapters) do
            if item.id == id then row = item end
        end
        assert.is_not_nil(row)
        assert.equals(downloaded, row.menu_status:find("Downloaded", 1, true) ~= nil)
        assert.equals(downloaded and "downloaded" or nil,
            row._suwayomi_download_status and row._suwayomi_download_status.state)
    end

    for _, action in ipairs({ "selected", "previous", "explicit" }) do
        it("clears displayed downloads after scheduled " .. action .. " completion cleanup", function()
            local state, instance = fixture(3)
            local chapters = { chapter("A"), chapter("B"), chapter("C"), chapter("D") }
            local plugin = instance(chapters)
            plugin:refreshChapterMenu()
            if action == "selected" then
                for index = 1, 3 do plugin:toggleChapterSelection(manga, chapters[index]) end
                assert.equals(3, plugin:markSelectedChaptersRead())
            elseif action == "previous" then
                assert.equals(3, plugin:markChaptersBeforeRead(manga, chapters[4]))
            else
                for index = 1, 3 do plugin:markChapterRead(manga, chapters[index]) end
            end
            assertDownloaded(state, plugin, "A", true)
            local refreshes = plugin.current_chapter_menu.refreshes
            runScheduled(state)
            assert.same({ path("A") }, state.removed)
            assert.same({ "B", "C" }, records(state))
            assertDownloaded(state, plugin, "A", false)
            assertDownloaded(state, plugin, "B", true)
            assertDownloaded(state, plugin, "C", true)
            assert.equals(refreshes + 1, plugin.current_chapter_menu.refreshes)
            assert.equals(4, state.journal.next_sequence)
            plugin:refreshChapterMenu({ quick = true })
            assertDownloaded(state, plugin, "A", false)
        end)
    end

    it("refreshes once per bounded deletion batch and keeps quick refresh converged", function()
        local state, instance = fixture(1)
        local chapters = { chapter("A"), chapter("B"), chapter("C"), chapter("D") }
        local plugin = instance(chapters)
        plugin.finished_cleanup_batch_size = 2
        plugin:markChapterListRead(manga, chapters)
        local refreshes = plugin.current_chapter_menu.refreshes
        runScheduled(state)
        assert.same({ "C", "D" }, records(state))
        assertDownloaded(state, plugin, "A", false)
        assertDownloaded(state, plugin, "B", false)
        assertDownloaded(state, plugin, "C", true)
        assertDownloaded(state, plugin, "D", true)
        assert.equals(refreshes + 1, plugin.current_chapter_menu.refreshes)
        runScheduled(state)
        assert.same({}, records(state))
        assert.same({ path("A"), path("B"), path("C"), path("D") }, state.removed)
        assert.equals(refreshes + 2, plugin.current_chapter_menu.refreshes)
        plugin:refreshChapterMenu({ quick = true })
        for _, c in ipairs(chapters) do assertDownloaded(state, plugin, c.id, false) end
        assert.equals(5, state.journal.next_sequence)
        assert.same({}, state.scheduled)
    end)

    for _, status in ipairs({ "downloaded", "failed" }) do
        it("converges missing archives and obsolete " .. status .. " queue state together", function()
            local state, instance = fixture(1)
            local chapters = { chapter("A"), chapter("B") }
            local plugin = instance(chapters)
            plugin:markChapterListRead(manga, chapters)
            local queue = plugin:getDownloadQueue()
            queue.statuses["m:A"] = { state = status }
            state.jobs = { queue:buildPersistentJob(manga, chapters[1], "/downloads", status) }
            plugin.current_downloads_menu = {}
            plugin:refreshDownloadsMenu()
            if status == "failed" then assert.equals(1, #plugin.current_downloads_menu.snapshot.failed) end
            state.existing[path("A")] = nil
            local refreshes = plugin.current_chapter_menu.refreshes
            runScheduled(state)
            assert.same({}, records(state))
            assert.same({ path("B") }, state.removed)
            assert.same({}, state.jobs)
            assert.same({}, plugin.current_downloads_menu.snapshot.failed)
            assert.equals(2, plugin.current_downloads_menu.refreshes)
            assert.equals(refreshes + 1, plugin.current_chapter_menu.refreshes)
            assert.is_nil(queue:getStatus(manga, chapters[1]))
            plugin:refreshChapterMenu({ quick = true })
            assertDownloaded(state, plugin, "A", false)
            assertDownloaded(state, plugin, "B", false)
            assert.same({}, state.scheduled)
        end)
    end

    for _, status in ipairs({ "queued", "downloading" }) do
        it("preserves " .. status .. " work when its older archive is missing", function()
            local state, instance = fixture(1)
            local chapters = { chapter("A") }
            local plugin = instance(chapters)
            plugin:markChapterListRead(manga, chapters)
            local queue = plugin:getDownloadQueue()
            queue.statuses["m:A"] = { state = status }
            state.jobs = { queue:buildPersistentJob(manga, chapters[1], "/downloads", status) }
            state.existing[path("A")] = nil
            runScheduled(state)
            assert.same({}, records(state))
            assert.same({}, state.removed)
            assert.equals(status, queue:getStatus(manga, chapters[1]).state)
            assert.equals(status, state.jobs[1].state)
            assertDownloaded(state, plugin, "A", false)
            assert.equals(status == "queued" and "Read · Queued" or "Read · Downloading",
                plugin.current_chapter_menu.chapters[1].menu_status)
        end)
    end

    for _, blocked in ipairs({ "current_document", "delete_failed" }) do
        it("keeps displayed downloads during " .. blocked .. " and refreshes on retry success", function()
            local state, instance = fixture(1)
            local plugin = instance({ chapter("A"), chapter("B") })
            plugin:markChapterListRead(manga, plugin.current_chapter_context.chapters)
            if blocked == "current_document" then
                require("apps/reader/readerui").instance = { document = { file = path("A") } }
            else
                state.fail_delete = true
            end
            local refreshes = plugin.current_chapter_menu.refreshes
            runScheduled(state)
            assert.same({ "A", "B" }, records(state))
            assertDownloaded(state, plugin, "A", true)
            assertDownloaded(state, plugin, "B", true)
            assert.equals(refreshes, plugin.current_chapter_menu.refreshes)
            assert.equals(1, state.journal.mangas.m.records[1].retry_count)
            assert.equals(105, state.journal.mangas.m.records[1].retry_after)
            assert.equals(1, plugin:processFinishedChapterCleanup().deferred)
            assert.equals(refreshes, plugin.current_chapter_menu.refreshes)
            require("apps/reader/readerui").instance = nil
            state.fail_delete = false
            -- Direct processing superseded the first retry timer; its callback is inert.
            runScheduled(state)
            runScheduled(state)
            assert.same({}, records(state))
            assertDownloaded(state, plugin, "A", false)
            assertDownloaded(state, plugin, "B", false)
            assert.equals(refreshes + 1, plugin.current_chapter_menu.refreshes)
        end)
    end

    it("does not refresh retained or empty processing", function()
        local state, instance = fixture(3)
        local plugin = instance({ chapter("A"), chapter("B") })
        plugin:markChapterListRead(manga, plugin.current_chapter_context.chapters)
        local refreshes = plugin.current_chapter_menu.refreshes
        runScheduled(state)
        assert.same({ "A", "B" }, records(state))
        assertDownloaded(state, plugin, "A", true)
        assertDownloaded(state, plugin, "B", true)
        assert.equals(refreshes, plugin.current_chapter_menu.refreshes)
        plugin:cancelFinishedChapter("m", "A")
        plugin:cancelFinishedChapter("m", "B")
        assert.equals(0, plugin:processFinishedChapterCleanup().processed)
        assert.equals(refreshes, plugin.current_chapter_menu.refreshes)
        assert.same({}, state.removed)
    end)

    it("refreshes when an archive disappears between validation and deletion", function()
        local state, instance = fixture(1)
        local plugin = instance({ chapter("A") })
        plugin:markChapterRead(manga, chapter("A"))
        plugin:getDownloadQueue().statuses["m:A"] = { state = "downloaded" }
        local inspections = 0
        state.on_stat = function(value)
            if value ~= path("A") then return end
            inspections = inspections + 1
            if inspections == 2 then state.existing[value] = nil end
        end
        runScheduled(state)
        assert.same({}, records(state))
        assert.same({}, state.removed)
        assertDownloaded(state, plugin, "A", false)
        assert.is_nil(plugin:getDownloadQueue():getStatus(manga, chapter("A")))
        plugin:refreshChapterMenu({ quick = true })
        assertDownloaded(state, plugin, "A", false)
    end)

    it("preserves a replacement ledger path and queue status when the old archive is missing", function()
        local state, instance = fixture(1)
        local plugin = instance({ chapter("A") })
        plugin:markChapterRead(manga, chapter("A"))
        state.ledger["m:A"].path = path("replacement")
        state.existing[path("replacement")] = true
        state.existing[path("A")] = nil
        plugin:getDownloadQueue().statuses["m:A"] = { state = "downloaded" }
        local refreshes = plugin.current_chapter_menu.refreshes
        runScheduled(state)
        assert.same({}, records(state))
        assert.same({}, state.removed)
        assert.equals(path("replacement"), state.ledger["m:A"].path)
        assert.is_true(state.existing[path("replacement")])
        assert.equals("downloaded", plugin:getDownloadQueue():getStatus(manga, chapter("A")).state)
        assert.equals(refreshes, plugin.current_chapter_menu.refreshes)
    end)

    it("does not refresh an unrelated chapter menu after cleanup", function()
        local state, instance = fixture(1)
        local plugin = instance({ chapter("A") })
        plugin:markChapterRead(manga, chapter("A"))
        plugin.current_chapter_context.manga = { id = "other", title = "Other" }
        plugin:refreshChapterMenu()
        local refreshes = plugin.current_chapter_menu.refreshes
        runScheduled(state)
        assert.same({}, records(state))
        assert.same({ path("A") }, state.removed)
        assert.is_nil(state.ledger["m:A"].path)
        assert.equals(refreshes, plugin.current_chapter_menu.refreshes)
    end)

    it("cancels unread journal records without refreshing unchanged downloads", function()
        local state, instance = fixture(1)
        local plugin = instance({ chapter("A") })
        plugin:markChapterRead(manga, chapter("A"))
        state.ledger["m:A"].read = false
        local refreshes = plugin.current_chapter_menu.refreshes
        runScheduled(state)
        assert.same({}, records(state))
        assert.same({}, state.removed)
        assertDownloaded(state, plugin, "A", true)
        assert.equals(refreshes, plugin.current_chapter_menu.refreshes)
    end)

    it("commits transitions before refresh and preserves callback writes without recursive cleanup", function()
        local state, instance = fixture(1)
        local plugin = instance({ chapter("A"), chapter("B"), chapter("D") })
        plugin:markChapterListRead(manga, { chapter("A"), chapter("B") })
        state.on_refresh = function()
            state.on_refresh = nil
            assert.same({}, records(state))
            assertDownloaded(state, plugin, "A", false)
            assertDownloaded(state, plugin, "B", false)
            assert.is_true(plugin:processFinishedChapterCleanup().busy)
            plugin:markChapterRead(manga, chapter("D"), { skip_refresh = true })
        end
        runScheduled(state)
        assert.same({ "D" }, records(state))
        assert.equals(4, state.journal.next_sequence)
        assert.is_true(state.ledger["m:D"].read)
        assert.is_true(state.ledger["m:D"].pending_read_sync)
        assert.is_nil(state.ledger["m:A"].path)
        assert.is_nil(state.ledger["m:B"].path)
        runScheduled(state)
        assertDownloaded(state, plugin, "D", false)
        assert.same({}, records(state))
    end)

    for _, closed in ipairs({ "absent", "closed" }) do
        it("converges with " .. closed .. " menus and rebuilds on a fresh instance", function()
            local state, instance = fixture(1)
            local plugin = instance({ chapter("A") })
            plugin:markChapterRead(manga, chapter("A"))
            local old_menu = plugin.current_chapter_menu
            local refreshes = old_menu.refreshes
            old_menu.closed = true
            plugin.current_downloads_menu = { closed = true }
            if closed == "absent" then
                plugin.current_chapter_menu = nil
                plugin.current_downloads_menu = nil
                plugin.current_chapter_context = nil
            end
            runScheduled(state)
            assert.same({}, records(state))
            assert.same({ path("A") }, state.removed)
            assert.is_nil(state.ledger["m:A"].path)
            assert.equals(refreshes, old_menu.refreshes)
            plugin = instance({ { id = "A", name = "A", is_read = true } })
            plugin:refreshChapterMenu()
            assertDownloaded(state, plugin, "A", false)
            plugin:refreshChapterMenu({ quick = true })
            assertDownloaded(state, plugin, "A", false)
        end)
    end

    it("refreshes the fresh processor instance after restart without touching its closed predecessor", function()
        local state, instance = fixture(3)
        local plugin = instance({ chapter("A"), chapter("B"), chapter("C") })
        plugin:markChapterListRead(manga, plugin.current_chapter_context.chapters)
        local old_menu = plugin.current_chapter_menu
        old_menu.closed = true
        state.scheduled = {}
        local fresh = instance(clone(plugin.current_chapter_context.chapters))
        fresh:refreshChapterMenu()
        fresh:scheduleFinishedChapterCleanup(0)
        runScheduled(state)
        assert.same({ "B", "C" }, records(state))
        assertDownloaded(state, fresh, "A", false)
        assertDownloaded(state, fresh, "B", true)
        assertDownloaded(state, fresh, "C", true)
        assert.equals(1, old_menu.refreshes)
    end)

    it("keeps mixed manual and reader completions across a fresh plugin instance", function()
        local state, instance = fixture()
        local plugin = instance()
        plugin:markChapterRead(manga, chapter("A"))
        plugin:markChapterRead(manga, chapter("B"))
        assert.equals("complete", state.metadata[path("A") .. ".lua"].summary.status)
        plugin = instance()
        plugin:upsertChapterLedgerEntry(manga, chapter("C"), { path = path("C") })
        plugin.ui = {
            document = { file = path("C") },
            doc_settings = { readSetting = function() return { status = "complete" } end },
        }
        require("apps/reader/readerui").instance = plugin.ui
        plugin:onCloseDocument()
        plugin:processFinishedChapterCleanup()
        assert.same({ path("A") }, state.removed)
        assert.same({ "B", "C" }, records(state))
        assert.is_true(state.existing[path("B")])
        assert.is_true(state.existing[path("C")])
    end)

    for _, action in ipairs({ "selected", "previous" }) do
        it("uses visible order for " .. action .. " bulk completion and saves the entire ledger first", function()
            local state, instance = fixture()
            local chapters = { chapter("C", 1), chapter("A", 99), chapter("B", 3), chapter("D", 0) }
            local plugin = instance(chapters)
            if action == "selected" then
                plugin:toggleChapterSelection(manga, chapters[3])
                plugin:toggleChapterSelection(manga, chapters[1])
                plugin:toggleChapterSelection(manga, chapters[2])
                state.events = {}
                plugin:markSelectedChaptersRead()
            else
                plugin:markChaptersBeforeRead(manga, chapters[4])
            end
            assert.same({ "C", "A", "B" }, records(state))
            local ledger_saves, journal_saves = 0, 0
            for _, event in ipairs(state.events) do
                if event.kind == "ledger" then ledger_saves = ledger_saves + 1 end
                if event.kind == "journal" then
                    journal_saves = journal_saves + 1
                    for _, id in ipairs({ "C", "A", "B" }) do
                        assert.is_true(event.ledger["m:" .. id].read)
                    end
                end
            end
            assert.equals(1, ledger_saves)
            assert.equals(3, journal_saves)
            plugin:processFinishedChapterCleanup()
            assert.same({ path("C") }, state.removed)
            assert.same({ "A", "B" }, records(state))
        end)
    end

    for _, action in ipairs({ "selected", "previous" }) do
        it("persists non-target refresh reconciliation before " .. action .. " completion publication", function()
            local state, instance = fixture()
            local chapters = { chapter("A"), chapter("B"), chapter("C") }
            local plugin = instance(chapters)
            plugin:refreshChapterMenu()
            if action == "selected" then
                plugin:toggleChapterSelection(manga, chapters[1])
                plugin:toggleChapterSelection(manga, chapters[2])
                assert.equals("%1 selected", plugin.current_chapter_menu.title)
                for index = 1, 2 do
                    local row = plugin.current_chapter_menu.chapters[index]
                    assert.equals(plugin:addChapterSelectionMarker(""), row.menu_status:sub(1, #"●"))
                end
            end

            -- Finish the non-target chapter after selection refreshes, so only
            -- the mark-read action's full rebuild can reconcile this change.
            state.metadata[path("C") .. ".lua"] = { summary = { status = "complete" } }
            assert.is_false(state.ledger["m:C"].read)
            state.events = {}
            local refreshes = plugin.current_chapter_menu.refreshes
            local syncs, keep_policies = 0, 0
            plugin.schedulePendingReadSync = function() syncs = syncs + 1 end
            plugin.applyMangaKeepNextUnreadDownloadsPolicy = function(_, target)
                assert.same(manga, target)
                keep_policies = keep_policies + 1
            end
            if action == "selected" then
                assert.equals(2, plugin:markSelectedChaptersRead())
            else
                assert.equals(2, plugin:markChaptersBeforeRead(manga, chapters[3]))
            end

            assert.equals(refreshes + 1, plugin.current_chapter_menu.refreshes)
            assert.equals(1, syncs)
            assert.equals(1, keep_policies)
            assert.same({ "A", "B" }, records(state))
            assert.equals(3, #state.events)
            assert.equals("ledger", state.events[1].kind)
            for index, event in ipairs(state.events) do
                if index > 1 then assert.equals("journal", event.kind) end
                assert.is_true(event.ledger["m:C"].read)
                assert.is_true(event.ledger["m:C"].pending_read_sync)
                assert.equals(path("C"), event.ledger["m:C"].path)
            end
            assert.same({}, state.removed)
            for _, c in ipairs(chapters) do
                assertDownloaded(state, plugin, c.id, true)
                assert.is_true(state.ledger["m:" .. c.id].read)
            end
            assert.is_true(chapters[3].is_read)
            assert.is_true(plugin.current_chapter_menu.chapters[3].is_read)
            assert.is_true(plugin.current_chapter_menu.chapters[3].pending_read_sync)
            if action == "selected" then
                assert.equals(0, plugin:getSelectedChapterCount())
                assert.is_false(plugin.selection_mode)
                assert.equals("Manga", plugin.current_chapter_menu.title)
                for _, row in ipairs(plugin.current_chapter_menu.chapters) do
                    assert.is_nil(row.menu_status:find("●", 1, true))
                end
            end
        end)
    end

    for _, action in ipairs({ "selected", "previous", "list" }) do
        it("keeps durable state and displayed downloads unchanged for empty " .. action .. " actions", function()
            local state, instance = fixture()
            local chapters = { chapter("A") }
            local plugin = instance(chapters)
            plugin:refreshChapterMenu()
            local ledger = clone(state.ledger)
            local menu = clone(plugin.current_chapter_menu)
            state.events = {}
            local syncs, keep_policies = 0, 0
            plugin.schedulePendingReadSync = function() syncs = syncs + 1 end
            plugin.applyMangaKeepNextUnreadDownloadsPolicy = function() keep_policies = keep_policies + 1 end
            if action == "selected" then
                assert.equals(0, plugin:markSelectedChaptersRead())
            elseif action == "previous" then
                assert.equals(0, plugin:markChaptersBeforeRead(manga, chapters[1]))
            else
                assert.equals(0, plugin:markChapterListRead(manga, {}))
            end
            assert.same(ledger, state.ledger)
            assert.same(menu, plugin.current_chapter_menu)
            assert.same({}, state.events)
            assert.same({}, state.removed)
            assert.same({}, records(state))
            assert.same({}, state.scheduled)
            assert.equals(0, syncs)
            assert.equals(0, keep_policies)
            assertDownloaded(state, plugin, "A", true)
        end)
    end

    it("moves repeated explicit completion newest without duplicate records", function()
        local state, instance = fixture()
        local plugin = instance()
        for _, id in ipairs({ "A", "B", "C", "A" }) do plugin:markChapterRead(manga, chapter(id)) end
        assert.same({ "B", "C", "A" }, records(state))
        plugin:processFinishedChapterCleanup()
        assert.same({ path("B") }, state.removed)
    end)

    it("immediate deletion wins and preserves a new pathless completion record", function()
        local state, instance = fixture()
        local plugin = instance({ chapter("A") })
        plugin:markChapterRead(manga, chapter("A"))
        assert.same({ "A" }, records(state))
        state.immediate = true
        plugin:markChapterRead(manga, chapter("A"))
        assert.same({ path("A") }, state.removed)
        assert.same({ "A" }, records(state))
        assert.is_nil(state.journal.mangas.m.records[1].path)
        assert.is_nil(state.ledger["m:A"].path)
        assert.is_true(state.ledger["m:A"].pending_read_sync)
        assertDownloaded(state, plugin, "A", false)
        local refreshes = plugin.current_chapter_menu.refreshes
        runScheduled(state)
        assert.equals(refreshes, plugin.current_chapter_menu.refreshes)
    end)

    it("immediate bulk deletion preserves completion records without downloaded paths", function()
        local state, instance = fixture()
        local plugin = instance({ chapter("A"), chapter("B") })
        plugin:markChapterListRead(manga, { chapter("A"), chapter("B") })
        assert.same({ "A", "B" }, records(state))
        state.immediate = true
        plugin:markChapterListRead(manga, { chapter("A"), chapter("B") })
        assert.same({ path("A"), path("B") }, state.removed)
        assert.same({ "A", "B" }, records(state))
        for _, record in ipairs(state.journal.mangas.m.records) do assert.is_nil(record.path) end
        assert.is_nil(state.ledger["m:A"].path)
        assert.is_nil(state.ledger["m:B"].path)
        assert.is_true(state.ledger["m:A"].read)
        assert.is_true(state.ledger["m:B"].read)
        assertDownloaded(state, plugin, "A", false)
        assertDownloaded(state, plugin, "B", false)
    end)
    it("journals failed immediate deletion for durable cleanup retry", function()
        local state, instance = fixture(1)
        state.immediate, state.fail_delete = true, true
        local plugin = instance()
        plugin:markChapterListRead(manga, { chapter("A"), chapter("B") })
        assert.same({ "A", "B" }, records(state))
        state.fail_delete = false
        plugin:processFinishedChapterCleanup()
        assert.same({ path("A"), path("B") }, state.removed)
        assert.same({}, records(state))
    end)

    it("excludes disabled actions but includes non-downloaded chapters and cancels unread", function()
        local state, instance = fixture(0)
        local plugin = instance()
        plugin:markChapterRead(manga, chapter("A"))
        assert.same({}, records(state))
        state.setting = 3
        plugin:markChapterRead(manga, chapter("missing"))
        assert.same({ "missing" }, records(state))
        plugin:markChapterRead(manga, chapter("B"))
        assert.same({ "missing", "B" }, records(state))
        plugin:markChapterUnread(manga, chapter("B"))
        assert.same({ "missing" }, records(state))
        plugin:markChapterUnread(manga, chapter("missing"))
        assert.same({}, records(state))
        assert.is_false(state.ledger["m:B"].read)
    end)

    for _, action in ipairs({ "single", "selected", "previous" }) do
        it("advances mixed " .. action .. " completions and retains pathless positions across restart", function()
            local state, instance = fixture(3)
            state.existing[path("C")] = nil
            local chapters = { chapter("A"), chapter("B"), chapter("C"), chapter("D") }
            local plugin = instance(chapters)
            if action == "single" then
                for index = 1, 3 do plugin:markChapterRead(manga, chapters[index]) end
            elseif action == "selected" then
                for index = 3, 1, -1 do plugin:toggleChapterSelection(manga, chapters[index]) end
                plugin:markSelectedChaptersRead()
            else
                plugin:markChaptersBeforeRead(manga, chapters[4])
            end
            assert.same({ "A", "B", "C" }, records(state))
            assert.is_nil(state.journal.mangas.m.records[3].path)
            for _, event in ipairs(state.events) do
                if event.kind == "journal" then
                    assert.is_true(event.ledger["m:A"].read)
                    if action ~= "single" then
                        assert.is_true(event.ledger["m:B"].read)
                        assert.is_true(event.ledger["m:C"].read)
                    end
                end
            end
            plugin = instance(chapters)
            plugin:processFinishedChapterCleanup()
            assert.same({ path("A") }, state.removed)
            assert.same({ "B", "C" }, records(state))
            plugin:processFinishedChapterCleanup()
            assert.same({ "B", "C" }, records(state))
            plugin:markChapterRead(manga, chapter("D"))
            plugin:processFinishedChapterCleanup()
            assert.same({ path("A"), path("B") }, state.removed)
            assert.same({ "C", "D" }, records(state))
        end)
    end

    for _, immediate in ipairs({ false, true }) do
        it("never deletes a later download from an older pathless completion, immediate=" .. tostring(immediate), function()
            local state, instance = fixture(3)
            state.immediate = immediate
            if not immediate then state.existing[path("A")] = nil end
            local plugin = instance()
            plugin:markChapterRead(manga, chapter("A"))
            assert.same({ "A" }, records(state))
            assert.is_nil(state.journal.mangas.m.records[1].path)
            state.immediate = false
            state.existing[path("A")] = true
            plugin:upsertChapterLedgerEntry(manga, chapter("A"), { path = path("A") })
            plugin:markChapterListRead(manga, { chapter("B"), chapter("C") })
            plugin = instance()
            plugin:processFinishedChapterCleanup()
            assert.same({ "B", "C" }, records(state))
            assert.is_true(state.existing[path("A")])
            assert.equals(path("A"), state.ledger["m:A"].path)
            assert.equals(immediate and 1 or 0, #state.removed)
            -- Only a new explicit completion may capture the later download.
            plugin:markChapterRead(manga, chapter("A"))
            assert.equals(path("A"), state.journal.mangas.m.records[3].path)
        end)
    end

    it("moves repeated pathless completion newest and cancels it when marked unread", function()
        local state, instance = fixture(3)
        local plugin = instance()
        state.existing[path("A")] = nil
        -- A stale ledger path must not become deletion eligibility.
        plugin:upsertChapterLedgerEntry(manga, chapter("A"), { path = path("A") })
        for _, id in ipairs({ "A", "B", "C", "A" }) do plugin:markChapterRead(manga, chapter(id)) end
        assert.same({ "B", "C", "A" }, records(state))
        assert.is_nil(state.journal.mangas.m.records[3].path)
        plugin:markChapterUnread(manga, chapter("A"))
        plugin:processFinishedChapterCleanup()
        assert.same({ "B", "C" }, records(state))
        assert.same({}, state.removed)
    end)

    it("server read reconciliation never creates completion events", function()
        local state, instance = fixture()
        local plugin = instance()
        plugin:upsertChapterLedgerEntry(manga, chapter("A"), { path = path("A") })
        local remote = chapter("A")
        remote.is_read = true
        plugin:mergeChaptersWithReadLedger(manga, { remote })
        assert.is_true(state.ledger["m:A"].read)
        assert.same({}, records(state))
        plugin:processFinishedChapterCleanup()
        assert.same({}, state.removed)
    end)

    it("persists an explicitly supplied ledger before publishing single completion", function()
        local state, instance = fixture()
        local plugin = instance()
        local ledger = plugin:loadChapterLedger()
        plugin:markChapterRead(manga, chapter("A"), { ledger = ledger })
        assert.same({ "A" }, records(state))
        assert.equals("ledger", state.events[1].kind)
        assert.equals("journal", state.events[2].kind)
        assert.is_true(state.events[2].ledger["m:A"].read)
        assert.equals(path("A"), state.events[2].ledger["m:A"].path)
    end)

    it("metadata and history reconciliation never infer completion events", function()
        local state, instance = fixture()
        local plugin = instance()
        plugin:upsertChapterLedgerEntry(manga, chapter("A"), { path = path("A") })
        plugin:upsertChapterLedgerEntry(manga, chapter("B"), { path = path("B") })
        plugin.isChapterPathFinishedInKoreader = function(_, value) return value == path("A") end
        plugin.loadKoreaderHistoryPaths = function() return { [path("B")] = true } end
        local reconcile = require("suwayomi/downloads/controller").methods.reconcileDownloadedChapterLedger
        assert.equals(2, reconcile(plugin))
        assert.is_true(state.ledger["m:A"].read)
        assert.is_true(state.ledger["m:B"].read)
        assert.same({}, records(state))
    end)
    it("protects the live document then retries from a fresh instance", function()
        local state, instance = fixture(1)
        local plugin = instance()
        require("apps/reader/readerui").instance = { document = { file = path("A") } }
        plugin:markChapterListRead(manga, { chapter("A"), chapter("B") })
        plugin:processFinishedChapterCleanup()
        assert.same({}, state.removed)
        assert.same({ "A", "B" }, records(state))
        require("apps/reader/readerui").instance = nil
        state.now = 500
        instance():processFinishedChapterCleanup()
        assert.same({ path("A"), path("B") }, state.removed)
        assert.same({}, records(state))
    end)
end)
