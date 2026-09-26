package.path = "?.lua;" .. package.path
local Fixture = require("spec/support/legacy_chapter_fixture")
describe("issue 61 pending unread display", function()
    local f
    before_each(function() f = Fixture.new() end)
    after_each(Fixture.clear)
    for _, scoped in ipairs({ false, true }) do
        for _, saved in ipairs({ false, true }) do
            it("keeps " .. (scoped and "scoped" or "legacy") .. " pending unread during " .. (saved and "saved render" or "server render"), function()
                f:legacy("/downloads/1.cbz", scoped and f.scope or nil)
                f.finished["/downloads/1.cbz"] = true
                f.chapters[1].is_read = true
                local before = f.settings:loadChapterLedger()
                local merged = assert(f.plugin:mergeChaptersWithReadLedger(f.manga, { f.chapters[1] }, { saved = saved }))
                assert.is_false(merged[1].is_read)
                f.plugin:setCurrentMangaChapterContext(f.manga, merged)
                local items = f.plugin:buildChapterMenuItems(f.manga, merged, nil, { saved = saved })
                assert.is_false(items[1].is_read)
                assert.is_false(f.plugin.current_chapter_context.chapters[1].is_read)
                assert.same(before, f.settings:loadChapterLedger())
                assert.same({}, f.writes)
                assert.same({}, f.queue.refill:snapshot())
                assert.is_true(f.existing["/downloads/1.cbz"])
                assert.is_true(f.finished["/downloads/1.cbz"])
            end)
        end
    end
    for _, scenario in ipairs({ "foreign", "different_path", "foreign_path", "pathless", "reused_ids" }) do
        it("ignores unrelated pending unread from " .. scenario, function()
            f:legacy(scenario == "different_path" and "/downloads/old.cbz" or "/downloads/1.cbz",
                scenario == "foreign" and "https://other.example" or nil)
            if scenario == "pathless" then
                local ledger = f.settings:loadChapterLedger(); ledger["1:1"].path = nil
                assert(f.settings:saveChapterLedger(ledger))
            elseif scenario == "reused_ids" then
                local ledger = f.settings:loadChapterLedger(); ledger["1:1"].chapter_id = "99"
                assert(f.settings:saveChapterLedger(ledger))
            elseif scenario == "foreign_path" then
                assert(f.settings:saveReaderReturnContexts({ ["foreign"] = {
                    manga_id = "99", chapter_id = "99", path = "/downloads/1.cbz", endpoint_scope = "https://other.example",
                } }))
            end
            f.existing["/downloads/1.cbz"], f.finished["/downloads/1.cbz"] = true, true
            f.chapters[1].is_read = true
            local before = f.settings:loadChapterLedger()
            local merged = assert(f.plugin:mergeChaptersWithReadLedger(f.manga, { f.chapters[1] }, { saved = true }))
            assert.is_true(merged[1].is_read)
            local items = f.plugin:buildChapterMenuItems(f.manga, merged, nil, { saved = true })
            assert.is_true(items[1].is_read)
            assert.same(before, f.settings:loadChapterLedger())
            assert.same({}, f.writes)
            assert.same({}, f.queue.refill:snapshot())
        end)
    end
    for _, pending in ipairs({ "none", "read" }) do
        it("retains finished sidecar behavior with " .. pending .. " pending choice", function()
            f:legacy("/downloads/1.cbz")
            local ledger = f.settings:loadChapterLedger()
            ledger["1:1"].pending_read_sync = pending == "read" or nil
            ledger["1:1"].pending_read_state = pending == "read" or nil
            assert(f.settings:saveChapterLedger(ledger))
            f.finished["/downloads/1.cbz"] = true
            local before = f.settings:loadChapterLedger()
            local merged = assert(f.plugin:mergeChaptersWithReadLedger(f.manga, { f.chapters[1] }, { saved = true }))
            local items = f.plugin:buildChapterMenuItems(f.manga, merged, nil, { saved = true })
            assert.is_true(items[1].is_read)
            assert.same(before, f.settings:loadChapterLedger())
            assert.same({}, f.writes)
        end)
    end
    it("keeps the confirmed-read fallback observational", function()
        f:legacy("/downloads/1.cbz")
        local ledger = f.settings:loadChapterLedger()
        ledger["1:1"].pending_read_sync, ledger["1:1"].pending_read_state = nil, nil
        assert(f.settings:saveChapterLedger(ledger))
        f.finished["/downloads/1.cbz"] = true
        local before = f.settings:getStore():load()
        local items = f.plugin:buildChapterMenuItems(f.manga, { f.chapters[1] }, nil,
            { saved = true, confirmed_read_state = true })
        assert.is_false(items[1].is_read)
        assert.same(before, f.settings:getStore():load())
        assert.same({}, f.writes)
    end)

    it("preserves an unknown pathless choice when no archive is involved", function()
        f:legacy(nil)
        f.chapters[1].is_read = true
        local before = f.settings:loadChapterLedger()
        local merged = assert(f.plugin:mergeChaptersWithReadLedger(f.manga, { f.chapters[1] }, { saved = true }))
        local items = f.plugin:buildChapterMenuItems(f.manga, merged, nil, { saved = true })
        assert.is_false(items[1].is_read)
        assert.same(before, f.settings:loadChapterLedger())
        assert.same({}, f.writes)
    end)

    it("keeps a pathless legacy choice with a matching scoped archive record", function()
        f:legacy(nil)
        f.existing["/downloads/1.cbz"], f.finished["/downloads/1.cbz"] = true, true
        assert(f.settings:saveReaderReturnContexts({ ["/downloads/1.cbz"] = {
            manga_id = "1", chapter_id = "1", path = "/downloads/1.cbz", endpoint_scope = f.scope,
        } }))
        f.chapters[1].is_read = true
        local before = f.settings:getStore():load()
        local merged = assert(f.plugin:mergeChaptersWithReadLedger(f.manga, { f.chapters[1] }, { saved = true }))
        local items = f.plugin:buildChapterMenuItems(f.manga, merged, nil, { saved = true })
        assert.is_false(items[1].is_read)
        assert.same(before, f.settings:getStore():load())
        assert.same({}, f.writes)
    end)

    it("rejects a pathless choice when a foreign owner hides the guessed archive", function()
        f:legacy(nil)
        f.existing["/downloads/1.cbz"], f.finished["/downloads/1.cbz"] = true, true
        assert(f.settings:saveReaderReturnContexts({ ["/downloads/1.cbz"] = {
            manga_id = "99", chapter_id = "99", path = "/downloads/1.cbz", endpoint_scope = "https://other.example",
        } }))
        f.chapters[1].is_read = true
        local before = f.settings:getStore():load()
        local merged = assert(f.plugin:mergeChaptersWithReadLedger(f.manga, { f.chapters[1] }, { saved = true }))
        assert.is_true(merged[1].is_read)
        local items = f.plugin:buildChapterMenuItems(f.manga, merged, nil, { saved = true })
        assert.is_true(items[1].is_read)
        assert.same(before, f.settings:getStore():load())
        assert.same({}, f.writes)
    end)

end)
