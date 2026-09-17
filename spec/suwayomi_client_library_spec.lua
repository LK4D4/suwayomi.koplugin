package.path = "?.lua;" .. package.path

local helper = require("spec/support/suwayomi_client_spec_helper")

describe("saved-first Library browsing", function()
    after_each(function() helper.clearClientModules() end)

    local function fixture(saved)
        local requests, views, messages = {}, {}, {}
        local credentials = { server_url = "http://library.test" }
        local actions, title_options
        local client = helper.newClient({
            credentials = credentials,
            ui_manager = { close = function(_, menu) menu.closed = true end },
            capture_title_options = function(options) title_options = options end,
            network_request_job = {
                start = function(options) requests[#requests + 1] = options; return {} end,
                cancel = function() end,
            },
            ui = {
                showLibraryMangaMenu = function(rows, select, options)
                    local menu = { rows = rows, select = select, options = options, close_callback = options.close_callback }
                    views[#views + 1] = menu
                    return menu
                end,
                updateLibraryMangaMenu = function(menu, rows, select, options)
                    menu.rows, menu.select, menu.options = rows, select, options
                end,
                showLibraryCategoryMenu = function(rows, select, options)
                    local menu = { rows = rows, select = select, options = options, categories = true,
                        close_callback = options.close_callback }
                    views[#views + 1] = menu
                    return menu
                end,
                updateLibraryCategoryMenu = function(menu, rows, select)
                    menu.rows, menu.select = rows, select
                end,
            },
        })
        client.plugin.showMangaActions = function(_, manga, options) actions = { manga = manga, options = options } end
        local navigation = require("suwayomi/navigation").new(client:getUIManager())
        client.plugin.getNavigation = function() return navigation end
        client.plugin.trackSuwayomiScreen = function(_, route, menu) navigation:push(route, menu) end
        client.plugin.isSuwayomiScreenActive = function(_, menu) return navigation:contains(menu) end
        local scope = credentials.server_url
        client.settings.normalizeEndpointScope = function(_, url) return url end
        client.settings.loadLibraryCache = function(_, current)
            return current.server_url == scope and saved or nil
        end
        client.settings.saveLibraryCache = function(_, current, listing)
            scope, saved = current.server_url, listing
            return listing
        end
        client.settings.loadChapterLedger = function() return {} end
        client.settings.loadReaderReturnContexts = function() return {} end
        client.plugin.showMessage = function(_, message, options)
            messages[#messages + 1] = { text = message, options = options }
        end
        return client, requests, views, messages, credentials,
            function() return actions end, function() return title_options end
    end

    it("allows saved row selection before the server completes without a loading modal", function()
        local client, requests, views, messages, _, actions = fixture({
            categories = {}, manga = { { id = 7, title = "Saved" } },
        })
        client:showLibrary()
        assert.are.equal("Saved", views[1].rows[1].title)
        views[1].select(views[1].rows[1])
        assert.are.equal(7, actions().manga.id)
        assert.is_nil(requests[1].loading_message)
        requests[1].on_finish({ ok = false, error = "timeout" })
        assert.are.equal("Saved", views[1].rows[1].title)
        assert.are.equal(1, #views)
        assert.is_true(messages[1].options.toast)
    end)

    it("reconstructs only recorded existing downloads without modifying their data", function()
        local path = os.tmpname()
        local file = assert(io.open(path, "wb")); file:write("preserve archive bytes"); file:close()
        local client, requests, views, messages, _, actions, title = fixture()
        local ledger = {
            one = { manga_id = 7, manga_title = "Recovered", chapter_id = 9, path = path,
                read = true, pending_read_sync = true },
            other = { manga_id = 8, manga_title = "Other server", path = path, endpoint_scope = "http://other.test" },
            absent = { manga_id = 10, manga_title = "Absent", path = path .. "-absent" },
        }
        client.settings.loadChapterLedger = function() return ledger end
        client:showLibrary()
        assert.are.equal(1, #views[1].rows)
        assert.are.equal("Recovered", views[1].rows[1].title)
        assert.is_nil(views[1].rows[1].endpoint_scope)
        views[1].select(views[1].rows[1])
        assert.is_nil(actions())
        assert.is_truthy(messages[1])
        requests[1].on_finish({ ok = false })
        assert.is_true(ledger.one.read)
        assert.is_true(ledger.one.pending_read_sync)
        title().onSelect({ id = "refresh" })
        requests[2].on_finish({ ok = true, categories = {}, manga = { { id = 7, title = "Authoritative" } } })
        views[1].select(views[1].rows[1])
        assert.are.equal("Authoritative", actions().manga.title)
        file = assert(io.open(path, "rb")); local bytes = file:read("*a"); file:close()
        os.remove(path)
        assert.are.equal("preserve archive bytes", bytes)
    end)

    it("never combines unscoped identity metadata with a scoped record sharing its ID", function()
        local path = os.tmpname()
        local client, _, views, _, _, actions = fixture()
        local legacy = { manga_id = 7, manga_title = "Unassociated", path = path,
            source = { name = "Foreign" }, categories = { { id = 1, name = "Legacy" } } }
        local scoped = { manga_id = 7, manga_title = "Associated", path = path,
            endpoint_scope = "http://library.test" }
        client.settings.loadReaderReturnContexts = function() return { legacy } end
        client.settings.loadChapterLedger = function() return { scoped } end
        client:showLibrary()
        views[1].select(views[1].rows[1])
        assert.are.equal("Associated", actions().manga.title)
        assert.is_nil(actions().manga.source)
        assert.same({}, actions().manga.categories)
        client.settings.loadReaderReturnContexts = function() return { scoped } end
        client.settings.loadChapterLedger = function() return { legacy } end
        client:showLibrary()
        views[2].select(views[2].rows[1])
        assert.are.equal("Associated", actions().manga.title)
        assert.is_nil(actions().manga.source)
        assert.same({}, actions().manga.categories)
        os.remove(path)
    end)

    it("shows uncategorized manga in Suwayomi's implicit Default category", function()
        local client, _, views = fixture({
            categories = { { id = 0, name = "Default" }, { id = 1, name = "Reading" } },
            manga = {
                { id = 7, title = "Default row", categories = {} },
                { id = 8, title = "Categorized", categories = { { id = 1 } } },
            },
        })
        client:showLibrary()
        views[1].select(views[1].rows[2])
        assert.are.equal(1, #views[2].rows)
        assert.are.equal(7, views[2].rows[1].id)
    end)

    it("keeps category selection usable during loading and applies a fresh snapshot to that selection", function()
        local categories = { { id = 1, name = "First" }, { id = 2, name = "Second" } }
        local client, requests, views = fixture({ categories = categories, manga = {
            { id = 7, title = "First row", categories = { categories[1] } },
            { id = 8, title = "Second row", categories = { categories[2] } },
        } })
        client:showLibrary()
        views[1].select(views[1].rows[3])
        assert.are.equal(8, views[2].rows[1].id)
        requests[1].on_finish({ ok = true, categories = categories, manga = {
            { id = 9, title = "New second row", categories = { categories[2] } },
        } })
        assert.are.equal(9, views[2].rows[1].id)
        assert.are.equal(2, #views)
        views[1].select(views[1].rows[2])
        assert.same({}, views[2].rows)
    end)

    it("retries through ordinary Refresh and keeps successful empty results on reopening", function()
        local client, requests, views, _, _, _, title = fixture({
            categories = {}, manga = { { id = 7, title = "Old" } },
        })
        client:showLibrary()
        requests[1].on_finish({ ok = false })
        title().onSelect({ id = "refresh" })
        requests[2].on_finish({ ok = true, categories = {}, manga = {} })
        assert.same({}, views[1].rows)
        client:showLibrary()
        assert.same({}, views[2].rows)
    end)

    it("uses a successful response now but retains saved rows after rejected persistence", function()
        local client, requests, views, messages = fixture({
            categories = {}, manga = { { id = 7, title = "Committed" } },
        })
        client.settings.saveLibraryCache = function() return nil, "rejected" end
        client:showLibrary()
        requests[1].on_finish({ ok = true, categories = {}, manga = { { id = 8, title = "Current" } } })
        assert.are.equal(8, views[1].rows[1].id)
        assert.is_truthy(messages[1])
        client:showLibrary()
        assert.are.equal(7, views[2].rows[1].id)
    end)

    for _, failure in ipairs({ "throw", "start", "timeout", "incomplete" }) do
        it("preserves saved navigation after " .. failure .. " failure", function()
            local client, requests, views, messages, _, actions = fixture({
                categories = {}, manga = { { id = 7, title = "Saved" } },
            })
            if failure == "throw" then
                client.network_request_job.start = function() error("start failure") end
            elseif failure == "start" then
                client.network_request_job.start = function() return nil end
            end
            client:showLibrary()
            if requests[1] then requests[1].on_finish({ ok = false, error = failure, manga = {} }) end
            views[1].select(views[1].rows[1])
            assert.are.equal(7, actions().manga.id)
            assert.is_truthy(messages[1])
            client:showLibrary()
            assert.are.equal(7, views[2].rows[1].id)
        end)
    end

    for _, invalidation in ipairs({ "server", "retired", "closed", "cancel", "newer" }) do
        it("rejects obsolete results after " .. invalidation, function()
            local client, requests, views, messages, credentials = fixture({
                categories = {}, manga = { { id = 7, title = "Original" } },
            })
            client:showLibrary()
            if invalidation == "server" then credentials.server_url = "http://other.test"
            elseif invalidation == "retired" then client.plugin.suwayomi_host_retired = true
            elseif invalidation == "closed" then views[1].options.close_callback()
            elseif invalidation == "cancel" then client:cancelLibraryNetworkRequests()
            else client:showLibrary() end
            requests[1].on_finish({ ok = true, categories = {}, manga = { { id = 7, title = "Obsolete" } } })
            assert.are.equal("Original", views[1].rows[1].title)
            assert.same({}, messages)
            client.plugin.suwayomi_host_retired = nil
            client:showLibrary()
            if invalidation == "server" then assert.same({}, views[#views].rows)
            else assert.are.equal("Original", views[#views].rows[1].title) end
        end)
    end

    it("retains the established explicit membership action on a saved row", function()
        local client, _, views, _, _, actions = fixture({
            categories = {}, manga = { { id = 7, title = "Saved", in_library = true } },
        })
        client:showLibrary()
        views[1].select(views[1].rows[1])
        actions().manga.in_library = false
        actions().options.onMangaUpdated()
        assert.same({}, views[1].rows)
    end)

    it("retires superseded Library widgets instead of revealing inert rows on Back", function()
        local client, _, views, _, _, actions = fixture({
            categories = { { id = 1, name = "First" }, { id = 2, name = "Second" } },
            manga = { { id = 7, title = "Saved" } },
        })
        client:showLibrary()
        views[1].select(views[1].rows[1])
        client:showLibrary()
        assert.is_true(views[1].closed)
        assert.is_true(views[2].closed)
        assert.is_false(client.plugin:getNavigation():contains(views[1]))
        views[3].select(views[3].rows[1])
        views[4].select(views[4].rows[1])
        assert.are.equal(7, actions().manga.id)
    end)

    it("does not push a category picker over a manga selected while refreshing", function()
        local client, requests, views, _, _, actions = fixture({
            categories = {}, manga = { { id = 7, title = "Saved" } },
        })
        client:showLibrary()
        views[1].select(views[1].rows[1])
        requests[1].on_finish({ ok = true,
            categories = { { id = 1, name = "First" }, { id = 2, name = "Second" } },
            manga = { { id = 8, title = "Current" } },
        })
        assert.are.equal(1, #views)
        assert.are.equal(7, actions().manga.id)
        assert.are.equal(8, views[1].rows[1].id)
    end)

    it("applies a successful membership action after the selected row was replaced", function()
        local client, requests, views, _, _, actions = fixture({
            categories = {}, manga = { { id = 7, title = "Saved", in_library = true } },
        })
        client:showLibrary()
        views[1].select(views[1].rows[1])
        requests[1].on_finish({ ok = true, categories = {}, manga = {
            { id = 7, title = "Refreshed", in_library = true }, { id = 8, title = "Other", in_library = true },
        } })
        actions().manga.in_library = false
        actions().options.onMangaUpdated(actions().manga)
        assert.are.equal(1, #views[1].rows)
        assert.are.equal(8, views[1].rows[1].id)
    end)

    for _, preference in ipairs({ "always", "never" }) do
        it("honors the " .. preference .. " category picker preference offline", function()
            local client, _, views = fixture({ categories = { { id = 1, name = "Single" } }, manga = {} })
            client.settings.loadLibraryCategoryPickerBehavior = function() return preference end
            client:showLibrary()
            assert.are.equal(preference == "always", views[1].categories == true)
        end)
    end
end)
