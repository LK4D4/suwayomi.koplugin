package.path = "?.lua;" .. package.path

local Fixture = require("spec/support/legacy_chapter_fixture")

describe("issue 65 stale chapter controls", function()
    local f
    before_each(function() f = Fixture.new() end)
    after_each(Fixture.clear)

    it("explains an expired Off selection and reopens current controls after same-manga publication", function()
        assert(f.queue.refill:setPolicy(f.manga, 5))
        local menu = {}
        f.plugin.current_chapter_menu = menu
        f.plugin.isSuwayomiScreenActive = function() return true end
        f.plugin:showKeepDownloadedActions()
        local old = f.menus[#f.menus].callback
        f.plugin:setCurrentMangaChapterContext(f.manga, f.chapters)

        assert.is_false(old({ id = "keep_next_0_unread" }))
        assert.equals(5, f.settings:loadMangaKeepNextUnreadDownloads(f.manga))
        assert.is_table(f.queue.refill:snapshot()[1])
        assert.matches("expired", f.messages[#f.messages], 1, true)
        assert.equals("Chapter downloads", f.menus[#f.menus].options.title)

        f:choose("keep_downloaded")
        f:choose("keep_next_0_unread")
        assert.equals(0, f.settings:loadMangaKeepNextUnreadDownloads(f.manga))
        assert.same({}, f.queue.refill:snapshot())
    end)

    it("explains stale single and bulk actions without dispatching old targets", function()
        local calls = {}
        f.plugin.performChapterAction = function(_, _, _, id) calls[#calls + 1] = id end
        f.plugin.performBulkChapterAction = function(_, id) calls[#calls + 1] = id end
        f.plugin:showChapterActions(f.manga, f.chapters[1])
        local old_single = f.menus[#f.menus].callback
        f.plugin:showBulkChapterActions()
        local old_bulk = f.menus[#f.menus].callback
        f.plugin:setCurrentMangaChapterContext(f.manga, f.chapters)

        assert.is_false(old_single({ id = "mark_read" }))
        assert.is_false(old_bulk({ id = "select_all" }))
        assert.same({}, calls)
        assert.matches("expired", f.messages[#f.messages], 1, true)
    end)

    for _, invalidation in ipairs({ "endpoint", "another manga", "retired host" }) do
        it("never reopens or dispatches an old Off selection after " .. invalidation, function()
            assert(f.queue.refill:setPolicy(f.manga, 5))
            local menu = {}
            f.plugin.current_chapter_menu = menu
            f.plugin.isSuwayomiScreenActive = function() return true end
            f.plugin:showKeepDownloadedActions()
            local old = f.menus[#f.menus].callback
            local menu_count = #f.menus
            if invalidation == "endpoint" then
                assert(f.settings:save{ server_url = "https://other.example" })
            elseif invalidation == "another manga" then
                f.plugin:setCurrentMangaChapterContext({ id = "other", endpoint_scope = f.scope }, f.chapters)
            else
                f.plugin.suwayomi_host_retired = true
            end

            assert.is_false(old({ id = "keep_next_0_unread" }))
            assert.equals(5, f.settings:loadMangaKeepNextUnreadDownloads(f.manga))
            assert.equals(menu_count, #f.menus)
            assert.equals(invalidation == "retired host" and 0 or 1, #f.messages)
        end)
    end

    it("explains a retained-context request revision change but allows a fresh retry", function()
        assert(f.queue.refill:setPolicy(f.manga, 5))
        f.plugin:showKeepDownloadedActions()
        local old = f.menus[#f.menus].callback
        f.plugin.chapter_request_revision = (f.plugin.chapter_request_revision or 0) + 1
        assert.is_false(old({ id = "keep_next_0_unread" }))
        assert.equals(5, f.settings:loadMangaKeepNextUnreadDownloads(f.manga))
        assert.matches("expired", f.messages[#f.messages], 1, true)
        f.plugin:showKeepDownloadedActions()
        f:choose("keep_next_0_unread")
        assert.equals(0, f.settings:loadMangaKeepNextUnreadDownloads(f.manga))
    end)

    it("lets an ordinary settled Off selection persist without expiration feedback", function()
        assert(f.queue.refill:setPolicy(f.manga, 5))
        f.plugin:showKeepDownloadedActions()
        f:choose("keep_next_0_unread")
        assert.equals(0, f.settings:loadMangaKeepNextUnreadDownloads(f.manga))
        assert.same({}, f.queue.refill:snapshot())
        assert.same({}, f.messages)
    end)

    it("keeps a failed fresh Off save visible without retiring the request", function()
        assert(f.queue.refill:setPolicy(f.manga, 5))
        f.settings:getStore().saveDocument = function() return nil, "injected_write_failure" end
        f.plugin:showKeepDownloadedActions()
        f:choose("keep_next_0_unread")
        assert.equals(5, f.settings:loadMangaKeepNextUnreadDownloads(f.manga))
        assert.is_table(f.queue.refill:snapshot()[1])
        assert.is_not_nil(f.messages[#f.messages])
    end)

    it("explains an expired chapter title action and reopens live controls", function()
        local menu = {}
        f.plugin.current_chapter_menu = menu
        f.plugin.isSuwayomiScreenActive = function() return true end
        f.plugin.getTitleBarMenuOptions = function(_, options) return options end
        local options = f.plugin:getChapterTitleBarMenuOptions(f.manga)
        local is_current = options.captureActionGuard()
        f.plugin:setCurrentMangaChapterContext(f.manga, f.chapters)

        assert.is_false(is_current())
        assert.matches("expired", f.messages[#f.messages], 1, true)
        assert.equals("Chapter downloads", f.menus[#f.menus].options.title)
    end)
end)
