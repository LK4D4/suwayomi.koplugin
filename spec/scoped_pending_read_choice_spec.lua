package.path = "?.lua;" .. package.path

local Fixture = require("spec/support/legacy_chapter_fixture")

describe("scoped pending chapter choices", function()
    local f
    before_each(function() f = Fixture.new() end)
    after_each(Fixture.clear)

    local function publish(saved)
        local merged = assert(f.plugin:mergeChaptersWithReadLedger(f.manga, { f.chapters[1] }, { saved = saved }))
        f.plugin:setCurrentMangaChapterContext(f.manga, merged)
        local rows = assert(f.plugin:buildChapterMenuOptions(f.manga, merged, nil, { saved = saved })).chapters
        return merged, rows
    end

    for _, saved in ipairs({ true, false }) do
        for _, desired in ipairs({ false, true }) do
            for _, archive in ipairs({ "recorded", "absent", "replacement" }) do
                it("keeps pending " .. (desired and "read" or "unread") .. " in "
                    .. (saved and "saved" or "fresh") .. " context with " .. archive .. " bytes", function()
                    f:legacy("/downloads/old.cbz", f.scope)
                    local ledger = f.settings:loadChapterLedger()
                    ledger["1:1"].read, ledger["1:1"].pending_read_state = desired, desired
                    assert(f.settings:saveChapterLedger(ledger))
                    f.existing["/downloads/old.cbz"] = archive == "recorded"
                    f.existing["/downloads/1.cbz"] = archive ~= "absent"
                    f.finished["/downloads/old.cbz"], f.finished["/downloads/1.cbz"] = true, true
                    f.chapters[1].is_read = not desired
                    local before = f.settings:loadChapterLedger()
                    local merged, rows = publish(saved)
                    assert.equals(desired, merged[1].is_read)
                    assert.equals(desired, rows[1].is_read)
                    assert.equals(desired, f.plugin.current_chapter_context.chapters[1].is_read)
                    assert.equals(desired and 0 or 1, #f.plugin:getUnreadChaptersForManga(f.manga))
                    assert.same(before, f.settings:loadChapterLedger())
                    assert.same({}, f.writes)
                    assert.same({}, f.queue.refill:snapshot())
                    if archive == "recorded" then
                        assert.equals("/downloads/old.cbz", f.plugin:getChapterPath(f.manga, merged[1]))
                    else
                        local lookup = f.plugin:buildChapterDownloadLookup(f.manga)
                        assert.is_false(f.plugin:hasChapterArchiveReadAssociation(f.manga, merged[1], "/downloads/1.cbz", lookup))
                    end
                    assert.equals(archive == "recorded", f.existing["/downloads/old.cbz"])
                    assert.equals(archive ~= "absent", f.existing["/downloads/1.cbz"])
                    assert.is_true(f.finished["/downloads/1.cbz"])
                end)
            end
        end
    end

    for _, saved in ipairs({ true, false }) do
        it("uses the " .. (saved and "saved" or "fresh") .. " read flag without a pending choice at a missing path", function()
            f:legacy("/downloads/old.cbz", f.scope)
            f.existing["/downloads/old.cbz"] = false
            local ledger = f.settings:loadChapterLedger()
            ledger["1:1"].pending_read_sync, ledger["1:1"].pending_read_state = nil, nil
            assert(f.settings:saveChapterLedger(ledger))
            f.chapters[1].is_read = true
            local before = f.settings:loadChapterLedger()
            local merged, rows = publish(saved)
            assert.is_true(merged[1].is_read)
            assert.is_true(rows[1].is_read)
            assert.is_true(f.plugin.current_chapter_context.chapters[1].is_read)
            assert.same(before, f.settings:loadChapterLedger())
            assert.same({}, f.writes)
        end)
    end

    for _, scenario in ipairs({ "foreign_endpoint", "foreign_manga", "foreign_chapter", "old_foreign_path",
        "generated_foreign_path", "unknown_origin" }) do
        it("does not borrow pending unread from " .. scenario, function()
            f:legacy("/downloads/old.cbz", scenario ~= "unknown_origin" and f.scope or nil)
            f.existing["/downloads/old.cbz"] = false
            local ledger = f.settings:loadChapterLedger()
            if scenario == "foreign_endpoint" then ledger["1:1"].endpoint_scope = "https://other.example"
            elseif scenario == "foreign_manga" then ledger["1:1"].manga_id = "99"
            elseif scenario == "foreign_chapter" then ledger["1:1"].chapter_id = "99"
            end
            assert(f.settings:saveChapterLedger(ledger))
            if scenario == "old_foreign_path" or scenario == "generated_foreign_path" then
                local path = scenario == "old_foreign_path" and "/downloads/old.cbz" or "/downloads/1.cbz"
                assert(f.settings:saveReaderReturnContexts({ foreign = {
                    manga_id = "99", chapter_id = "99", path = path, endpoint_scope = "https://other.example",
                } }))
            end
            f.chapters[1].is_read = true
            local before = f.settings:getStore():load()
            local merged, rows = publish(true)
            assert.is_true(merged[1].is_read)
            assert.is_true(rows[1].is_read)
            assert.is_true(f.plugin.current_chapter_context.chapters[1].is_read)
            assert.same(before, f.settings:getStore():load())
            assert.same({}, f.writes)
        end)
    end

    it("supplies pending unread to the normal next-unread download action", function()
        f:legacy("/downloads/old.cbz", f.scope)
        f.existing["/downloads/old.cbz"] = false
        f.chapters[1].is_read = true
        publish(true)
        f.plugin:showBulkChapterActions()
        f:choose("bulk_downloads")
        f:choose("download_next_5_unread")
        assert.is_table(f.queue:findPersistentJob("1:1"))
        assert.same({}, f.writes)
    end)
end)
