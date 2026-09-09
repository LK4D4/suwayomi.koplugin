package.path = "?.lua;" .. package.path

local runtime_helper = require("spec/support/plugin_runtime_spec_helper")

-- Public read actions with the real service, checked store, archive identity,
-- and filesystem. Only KOReader host APIs and subprocess execution are stubbed.
describe("issue 46 keep-policy suppression", function()
    local directory, runtime, settings, service, plugin, chapters
    local original_time = os.time
    local clock
    local manga = { id = "m", title = "Manga", source = { id = "s", name = "Source" } }
    local modules = { "suwayomi/settings/store", "suwayomi/chapters/manual_deletion",
        "suwayomi/chapters/archive_identity", "docsettings" }
    local function clear()
        runtime_helper.teardown()
        for _, name in ipairs(modules) do package.loaded[name], package.preload[name] = nil, nil end
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
    local function persisted()
        return require("suwayomi/settings/store"):new{ path = settings.store.path }:load()
    end
    local function enableAhead(target, list)
        local network = require("suwayomi/network/request_job")
        local start = network.start
        network.start = function(options)
            options.on_finish({ ok = true, chapters = list })
            return {}
        end
        local ok = plugin:startFetchChaptersForManga(target)
        network.start = start
        assert(ok)
        assert(plugin:performMangaAction(target, "keep_next_5_unread"))
        assert(service.queue:cancelAll())
        assert.same({}, service.queue:getSnapshot().refills)
    end
    before_each(function()
        clear()
        runtime = runtime_helper.install()
        clock = 100
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
        assert(settings:save({ server_url = "https://suwayomi.example" }))
        assert(settings:saveDownloadDirectory(directory))
        assert(settings:saveDeleteChaptersSettings({
            delete_after_mark_read = true, delete_finished_while_reading = 0,
        }))
        local ui = require("ui/uimanager")
        ui.quit = function() end
        ui.nextTick = function(_, callback) ui:scheduleIn(0, callback) end
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
        chapters = { { id = "A", name = "A", source_order = 1 }, { id = "B", name = "B", source_order = 2 } }
        assert(service.queue:enqueue(manga, chapters[1], directory, { provenance = "explicit" }))
        service.queue:process()
        local active = assert(service.queue:getActiveJob("m:A"))
        write(path("A"), "archive pages")
        write(active.progress_path, "state=downloaded\ncurrent=1\ntotal=1\npath=" .. path("A") .. "\n")
        service.queue:poll()
        write(path("A") .. ".lua.old", "preserved backup")
        enableAhead(manga, chapters)
    end)
    after_each(function()
        os.time = original_time
        if directory then removeTree(directory) end
        clear()
    end)

    it("commits read and guarded deletion without refill, then accepts a later unsuppressed read", function()
        runtime.reader_ui.instance = { document = { file = path("A") } }
        local ok, result = plugin:markChapterRead(manga, chapters[1], {
            skip_keep_policy = true, skip_schedule = true,
        })
        assert.is_true(ok)
        assert.is_true(result.committed)
        local doc = persisted()
        assert.is_true(doc.chapter_ledger["m:A"].read)
        assert.is_true(doc.chapter_ledger["m:A"].pending_read_state)
        assert.equals("pending", doc.manual_archive_state.requests["m:A"].state)
        assert.equals("archive pages", read(path("A")))
        assert.same({}, doc.download_refill.requests)
        assert.equals(5, settings:loadMangaKeepNextUnreadDownloads(manga))
        service.refill:process()
        assert.is_nil(service.refill.active)
        assert.is_nil(service.queue:findPersistentJob("m:B"))
        runtime.reader_ui.instance = nil
        clock = clock + 10
        service.manual_deletion:process()
        assert.is_nil(read(path("A")))
        assert.equals("preserved backup", read(path("A") .. ".lua.old"))
        assert.is_true(plugin:isChapterPathFinishedInKoreader(path("A")))
        assert.is_nil(persisted().chapter_ledger["m:A"].path)
        assert(plugin:markChapterRead(manga, chapters[1], { skip_schedule = true }))
        local requests = service.queue:getSnapshot().refills
        assert.equals(1, #requests)
        assert.equals("m", requests[1].manga_id)
        assert.equals("pending", requests[1].state)
        service.refill:process()
        assert.is_not_nil(service.refill.active)
    end)

    it("suppresses enrollment inferred from another manga in the supplied ledger", function()
        local other = { id = "other", title = "Other", source = manga.source }
        local chapter = { id = "C", name = "C" }
        enableAhead(other, { chapter })
        assert(plugin:upsertChapterLedgerEntry(other, chapter, { read = false }))
        local ledger = plugin:loadChapterLedger()
        ledger["other:C"].read = true
        ledger["other:C"].pending_read_sync = true
        ledger["other:C"].pending_read_state = true
        assert(plugin:markChapterRead(manga, chapters[1], {
            ledger = ledger, skip_keep_policy = true, skip_schedule = true, skip_refresh = true,
        }))
        local doc = persisted()
        assert.is_true(doc.chapter_ledger["m:A"].read)
        assert.is_true(doc.chapter_ledger["other:C"].read)
        assert.same({}, doc.download_refill.requests)
        assert.equals(5, settings:loadMangaKeepNextUnreadDownloads(other))
        service.refill:process()
        assert.is_nil(service.refill.active)
        assert.is_nil(service.queue:findPersistentJob("other:C"))
    end)

    it("preserves existing evaluations and policies when one read suppresses refill", function()
        local other = { id = "other", title = "Other", source = manga.source }
        enableAhead(other, { { id = "C", name = "C" } })
        assert(plugin:performMangaAction(other, "keep_next_5_unread"))
        assert(plugin:performMangaAction(manga, "keep_next_5_unread"))
        local before = persisted()
        assert(plugin:markChapterRead(manga, chapters[1], {
            skip_keep_policy = true, skip_schedule = true, skip_refresh = true,
        }))
        local after = persisted()
        assert.same(before.download_refill, after.download_refill)
        assert.same(before.manga_keep_next_unread_downloads, after.manga_keep_next_unread_downloads)
        assert.is_true(after.chapter_ledger["m:A"].read)
    end)

    it("does not bypass checked persistence when refill is suppressed", function()
        local open = settings.store.io.open
        settings.store.io.open = function() return nil, "injected storage failure" end
        local ok, result = plugin:markChapterRead(manga, chapters[1], {
            skip_keep_policy = true, skip_schedule = true, skip_refresh = true,
        })
        settings.store.io.open = open
        assert.is_false(ok)
        assert.is_false(result.committed)
        local doc = persisted()
        assert.is_not_true(doc.chapter_ledger["m:A"].read)
        assert.is_nil(doc.manual_archive_state.requests["m:A"])
        assert.same({}, doc.download_refill.requests)
        assert.equals("archive pages", read(path("A")))
    end)
end)
