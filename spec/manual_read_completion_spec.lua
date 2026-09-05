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
            },
            ["suwayomi/readsync/worker"] = {},
            ["suwayomi/network/request_job"] = {},
            ["suwayomi/ui"] = {},
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
            "suwayomi/reader_return",
        }) do mixins[#mixins + 1] = require(name).methods end
        local function instance(chapters)
            local plugin = {}
            for _, methods in ipairs(mixins) do
                for name, method in pairs(methods) do plugin[name] = method end
            end
            plugin.current_chapter_context = { manga = manga, chapters = chapters or {} }
            plugin.refreshChapterMenu = noop
            plugin.schedulePendingReadSync = noop
            plugin.showMessage = noop
            plugin.getChapterDownloadKey = function(_, m, c) return m.id .. ":" .. c.id end
            plugin.isChapterDownloaded = function(_, _, c)
                return state.existing[path(c.id)] == true, path(c.id)
            end
            plugin.chapterArchiveExists = function(_, value) return state.existing[value] == true end
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
            plugin.getDownloadQueue = function()
                return { getStatus = noop, cancelPending = function() return false end, clearStatus = noop }
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

    it("moves repeated explicit completion newest without duplicate records", function()
        local state, instance = fixture()
        local plugin = instance()
        for _, id in ipairs({ "A", "B", "C", "A" }) do plugin:markChapterRead(manga, chapter(id)) end
        assert.same({ "B", "C", "A" }, records(state))
        plugin:processFinishedChapterCleanup()
        assert.same({ path("B") }, state.removed)
    end)

    it("immediate deletion wins and cancels an older completion record", function()
        local state, instance = fixture()
        local plugin = instance()
        plugin:markChapterRead(manga, chapter("A"))
        assert.same({ "A" }, records(state))
        state.immediate = true
        plugin:markChapterRead(manga, chapter("A"))
        assert.same({ path("A") }, state.removed)
        assert.same({}, records(state))
        assert.is_nil(state.ledger["m:A"].path)
        assert.is_true(state.ledger["m:A"].pending_read_sync)
    end)

    it("immediate bulk deletion leaves no completion records or downloaded ledger paths", function()
        local state, instance = fixture()
        local plugin = instance()
        plugin:markChapterListRead(manga, { chapter("A"), chapter("B") })
        assert.same({ "A", "B" }, records(state))
        state.immediate = true
        plugin:markChapterListRead(manga, { chapter("A"), chapter("B") })
        assert.same({ path("A"), path("B") }, state.removed)
        assert.same({}, records(state))
        assert.is_nil(state.ledger["m:A"].path)
        assert.is_nil(state.ledger["m:B"].path)
        assert.is_true(state.ledger["m:A"].read)
        assert.is_true(state.ledger["m:B"].read)
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

    it("does not enroll disabled or non-downloaded chapters and cancels unread", function()
        local state, instance = fixture(0)
        local plugin = instance()
        plugin:markChapterRead(manga, chapter("A"))
        assert.same({}, records(state))
        state.setting = 3
        plugin:markChapterRead(manga, chapter("missing"))
        assert.same({}, records(state))
        plugin:markChapterRead(manga, chapter("B"))
        assert.same({ "B" }, records(state))
        plugin:markChapterUnread(manga, chapter("B"))
        assert.same({}, records(state))
        assert.is_false(state.ledger["m:B"].read)
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
