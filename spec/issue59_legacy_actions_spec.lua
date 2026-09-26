package.path = "?.lua;" .. package.path
local Fixture = require("spec/support/legacy_chapter_fixture")
describe("issue 59 mixed legacy chapter actions", function()
    local f
    before_each(function() f = Fixture.new() end)
    after_each(Fixture.clear)
    it("fails explicitly if classification or lookup is removed or replaced", function()
        local classifier = f.plugin.isLocalOnlyChapter
        f.plugin.isLocalOnlyChapter = nil
        assert.has_error(function() f:render({ saved = true }) end, "missing or replaced chapter collaborator: isLocalOnlyChapter")
        f.plugin.isLocalOnlyChapter = function() return false end
        assert.has_error(function() f:render({ saved = true }) end, "missing or replaced chapter collaborator: isLocalOnlyChapter")
        f.plugin.isLocalOnlyChapter = classifier
        local lookup = f.plugin.buildChapterDownloadLookup
        f.plugin.buildChapterDownloadLookup = nil
        assert.has_error(function() f:render({ saved = true }) end, "missing or replaced chapter collaborator: buildChapterDownloadLookup")
        f.plugin.buildChapterDownloadLookup = lookup
    end)
    for _, case in ipairs({
        { name = "current pending unread with missing recorded archive", scope = "current", old = "/downloads/old.cbz", unread = true, admitted = true },
        { name = "current pending unread with changed unassociated archive", scope = "current", old = "/downloads/old.cbz", generated = true, unread = true },
        { name = "current pending unread with associated archive", scope = "current", old = "/downloads/1.cbz", keep_old = true, unread = true },
        { name = "current pathless pending unread", scope = "current", unread = true, admitted = true },
        { name = "unknown pending unread with missing recorded archive", old = "/downloads/old.cbz" },
        { name = "foreign pending unread with an archive", scope = "foreign", old = "/downloads/1.cbz", keep_old = true },
    }) do
        it("composes rows, current context, and Download for " .. case.name, function()
            local origin = case.scope == "current" and f.scope
                or case.scope == "foreign" and "https://other.example" or nil
            f:legacy(case.old, origin)
            if case.old and not case.keep_old then f.existing[case.old] = nil end
            if case.generated then f.existing["/downloads/1.cbz"] = true end
            f.chapters[1].is_read = true -- remote Read must not override an applicable pending unread
            local before = f.settings:loadChapterLedger()
            local rows = f:render({ saved = true })
            assert.equals(case.unread ~= true, rows[1].is_read == true)
            assert.equals(rows[1].is_read, f.plugin.current_chapter_context.chapters[1].is_read)
            local candidates = f.plugin:getNextUnreadChaptersForDownload(f.manga, 1)
            assert.equals(case.admitted == true, candidates[1] == f.chapters[1])
            local shown = f.plugin:showChapterActions(f.manga, f.chapters[1])
            if case.scope ~= "current" then
                assert.is_not_true(shown)
            else
                assert.equals(case.admitted == true, f:action("download") ~= nil)
            end
            if case.admitted then
                f:choose("download")
                assert.is_table(f.queue:findPersistentJob("1:1"))
            else
                assert.is_nil(f.queue:findPersistentJob("1:1"))
            end
            assert.same(before, f.settings:loadChapterLedger())
            assert.equals(case.keep_old == true, f.existing[case.old] == true)
        end)
    end
    for _, archive in ipairs({ false, true }) do
        it("offers and executes safe bulk work with " .. (archive and "recorded bytes" or "a pathless legacy choice"), function()
            f:legacy(archive and "/downloads/1.cbz" or nil)
            local before = f.settings:loadChapterLedger()
            assert.is_true(f.plugin:isLocalOnlyChapter(f.manga, f.chapters[1]))
            assert(f.settings:saveMangaScanlatorFilter(f.manga, "A"))
            f.plugin:setCurrentMangaChapterContext(f.manga, f.chapters)
            f.plugin:showBulkChapterActions()
            assert.is_table(f:action("bulk_downloads"))
            assert.is_table(f:action("keep_downloaded"))
            f:choose("bulk_downloads")
            f:choose("download_next_5_unread")
            assert.is_nil(f.queue:findPersistentJob("1:1"))
            assert.is_table(f.queue:findPersistentJob("1:2"))
            assert.is_table(f.queue:findPersistentJob("1:3"))
            assert.is_nil(f.queue:findPersistentJob("1:4"))
            assert.same(before, f.settings:loadChapterLedger())
        end)
    end
    it("reports identity rejection for mixed Mark previous as read without saving", function()
        f:legacy("/downloads/1.cbz")
        local before = f.settings:getStore():load()
        f.plugin:showChapterActions(f.manga, f.chapters[3])
        f:choose("mark_previous_read")
        assert.matches("association with the current server", f.messages[#f.messages], 1, true)
        assert.same(before, f.settings:getStore():load())
        assert.same({}, f.writes)
    end)
    it("shows saved policy and persists changes and Off with a legacy row", function()
        f:legacy("/downloads/1.cbz")
        assert(f.queue.refill:setPolicy(f.manga, 5))
        local before = f.settings:loadChapterLedger()
        f.plugin:showBulkChapterActions()
        f:choose("keep_downloaded")
        assert.is_true(f:action("keep_next_5_unread").checked)
        f:choose("keep_next_10_unread")
        assert.equals(10, f.settings:loadMangaKeepNextUnreadDownloads(f.manga))
        assert.equals(f.scope, f.settings:getStore():load().download_refill.requests["1"].endpoint_scope)
        f.plugin:showKeepDownloadedActions()
        f:choose("keep_next_0_unread")
        assert.equals(0, f.settings:loadMangaKeepNextUnreadDownloads(f.manga))
        assert.same({}, f.queue.refill:snapshot())
        assert.same(before, f.settings:loadChapterLedger())
    end)
    it("downloads selected eligible chapters without granting legacy archive actions", function()
        f:legacy("/downloads/1.cbz")
        f.existing["/downloads/2.cbz"] = true
        assert(f.settings:saveMangaScanlatorFilter(f.manga, "A"))
        local rows = f:render({ saved = true })
        assert.equals(3, #rows)
        assert.equals("1", rows[1].id)
        assert.equals("3", rows[3].id)
        assert.equals(rows[1].is_read, f.plugin.current_chapter_context.chapters[1].is_read)
        f.plugin:selectAllChapters()
        assert.equals(3, f.plugin:getSelectedChapterCount())
        f.plugin:showBulkChapterActions()
        f:choose("download_selected")
        assert.is_nil(f.queue:findPersistentJob("1:1"))
        assert.is_nil(f.queue:findPersistentJob("1:2"))
        assert.is_table(f.queue:findPersistentJob("1:3"))
        assert.is_nil(f.queue:findPersistentJob("1:4"))
        assert.same({}, f.messages)
        f.plugin:showChapterActions(f.manga, f.chapters[1])
        assert.is_table(f:action("open"))
        assert.is_table(f:action("verify_download"))
        assert.is_nil(f:action("mark_read"))
        assert.is_nil(f:action("delete"))
    end)
    it("caps a mixed selected batch at fifty without backfilling hidden or legacy rows", function()
        f:legacy(nil)
        for id = 5, 55 do
            f.chapters[id] = { id = tostring(id), name = "Chapter " .. id, source_order = id,
                scanlator = id == 55 and "B" or "A", is_read = false }
        end
        assert(f.settings:saveMangaScanlatorFilter(f.manga, "A"))
        local before = f.settings:loadChapterLedger()
        local rows = f:render({ saved = true })
        assert.equals(53, #rows)
        f.plugin:selectAllChapters()
        assert.equals(53, f.plugin:getSelectedChapterCount())
        f.plugin:showBulkChapterActions()
        f:choose("download_selected")
        assert.equals(50, #f.settings:loadDownloadQueue())
        assert.is_nil(f.queue:findPersistentJob("1:1"))
        assert.is_table(f.queue:findPersistentJob("1:2"))
        assert.is_table(f.queue:findPersistentJob("1:52"))
        assert.is_nil(f.queue:findPersistentJob("1:53"))
        assert.is_nil(f.queue:findPersistentJob("1:55"))
        assert.same(before, f.settings:loadChapterLedger())
    end)
    it("persists a filter for a complete scoped context with a legacy row", function()
        f:legacy(nil)
        assert.is_true(f.plugin:setScanlatorFilter("B"))
        assert.equals("B", f.settings:loadMangaScanlatorFilter(f.manga))
    end)
    it("keeps foreign and reconstructed contexts restricted", function()
        for _, context in ipairs({
            { id = "1", endpoint_scope = "https://other.example" },
            { id = "1", local_only = true },
            { id = "1", endpoint_scope = f.scope },
        }) do
            local chapters = { { id = "1", local_only = true, local_path = "/downloads/1.cbz" } }
            f.plugin:setCurrentMangaChapterContext(context, chapters)
            f.plugin:showBulkChapterActions()
            assert.is_nil(f:action("bulk_downloads"))
            assert.is_nil(f:action("keep_downloaded"))
            assert.is_false(f.plugin:performBulkChapterAction("download_selected"))
        end
        assert.same({}, f.settings:loadDownloadQueue())
    end)
    it("revalidates origin after capture and preserves failed policy writes", function()
        local batch = f.plugin:captureChapterDownloadBatch(f.manga, { f.chapters[1], f.chapters[2] }, "/downloads")
        f:legacy(nil, "https://other.example")
        assert.equals(1, f.plugin:enqueueSelectedChapterDownloads(f.manga, {}, "/downloads", batch))
        assert.is_nil(f.queue:findPersistentJob("1:1"))
        assert.is_table(f.queue:findPersistentJob("1:2"))
        local before = f.settings:getStore():load()
        local store = f.settings:getStore()
        store.saveDocument = function() return nil, "injected_write_failure" end
        assert.is_false(f.plugin:keepNextUnreadChaptersForManga(f.manga, 10))
        assert.same(before, store:load())
    end)

    it("explains a selected pathless legacy download refusal while admitting safe work", function()
        f:legacy(nil)
        f.plugin:selectAllChapters()
        f.plugin:showBulkChapterActions()
        f:choose("download_selected")
        assert.is_nil(f.queue:findPersistentJob("1:1"))
        assert.is_table(f.queue:findPersistentJob("1:2"))
        assert.matches("server association", f.messages[#f.messages], 1, true)
    end)

end)
