package.path = "?.lua;" .. package.path

local helper = require("spec/support/suwayomi_client_spec_helper")
local json = require("dkjson")

describe("saved-first Library browsing", function()
    after_each(function()
        helper.clearClientModules()
        package.preload["suwayomi/ui"] = nil
        package.loaded["suwayomi/ui"] = nil
        package.loaded["suwayomi/plugin/title_menu"] = nil
    end)

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
                    if options.itemnumber then menu.page = 1 end
                end,
                showLibraryCategoryMenu = function(rows, select, options)
                    local menu = { rows = rows, select = select, options = options, categories = true,
                        close_callback = options.close_callback }
                    views[#views + 1] = menu
                    return menu
                end,
                updateLibraryCategoryMenu = function(menu, rows, select, options)
                    menu.rows, menu.select, menu.options = rows, select, options
                end,
            },
        })
        client.plugin.showMangaActions = function(_, manga, options) actions = { manga = manga, options = options } end
        client.plugin.showChaptersForManga = function(_, manga) actions = { manga = manga, chapters = true } end
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

    it("orders saved discoveries deterministically without changing membership or cache order", function()
        local listing = { categories = {}, manga = {
            { id = 9, title = "Unknown" },
            { id = 8, title = "Zulu", latest_fetched_at = 1700000000 },
            { id = 7, title = "Alpha", latest_fetched_at = 1700000000 },
            { id = 6, title = "Alpha", latest_fetched_at = 1700000000 },
            { id = 5, title = "Newest", latest_fetched_at = 1800000000 },
            { id = 4, title = "Absent", latest_fetched_at = 0 },
        } }
        local client, requests, views, _, _, _, title = fixture(listing)
        client:showLibrary()
        local function ids()
            local result = {}
            for _, manga in ipairs(views[1].rows) do result[#result + 1] = manga.id end
            return result
        end
        assert.same({ 5, 6, 7, 8, 4, 9 }, ids())
        assert.are.equal(9, listing.manga[1].id)
        title().onSelect({ id = "sort_title" })
        assert.same({ 4, 6, 7, 5, 9, 8 }, ids())
        requests[1].on_finish({ ok = true, categories = {}, manga = listing.manga, arrivals_supported = true })
        assert.same({ 4, 6, 7, 5, 9, 8 }, ids())
        client:showLibrary()
        assert.are.equal(4, views[2].rows[1].id)
        assert.are.equal("title", client.library_session.sort_mode)
    end)

    for _, mode in ipairs({ "title", "latest_arrivals" }) do
        it("loads confirmed " .. mode .. " order on offline reopening without saving it", function()
            local client, requests, views, _, _, _, title = fixture({ categories = {}, manga = {
                { id = 7, title = "Zulu", latest_fetched_at = 1800000000 },
                { id = 8, title = "Alpha", latest_fetched_at = 1700000000 },
            } })
            local writes = 0
            local save = client.settings.saveLibrarySortMode
            client.settings.saveLibrarySortMode = function(settings, value)
                writes = writes + 1
                return save(settings, value)
            end
            client:showLibrary()
            assert.are.equal(0, writes)
            title().onSelect({ id = "sort_" .. mode })
            assert.are.equal(1, writes)
            views[1].close_callback()
            client:showLibrary()
            requests[2].on_finish({ ok = false })
            assert.are.equal(mode, client.library_session.sort_mode)
            assert.are.equal(mode == "title" and 8 or 7, views[2].rows[1].id)
            assert.are.equal(1, writes)
        end)
    end

    for _, error_code in ipairs({ "replacement_failed", "ambiguous_post_replacement" }) do
        it("keeps requested order usable after " .. error_code .. " without claiming persistence", function()
            local client, _, views, messages, _, _, title = fixture({ categories = {}, manga = {
                { id = 7, title = "Zulu", latest_fetched_at = 1800000000 },
                { id = 8, title = "Alpha", latest_fetched_at = 1700000000 },
            } })
            client.settings.saveLibrarySortMode = function() return nil, error_code end
            client:showLibrary()
            title().onSelect({ id = "sort_title" })
            assert.are.equal("title", client.library_session.sort_mode)
            assert.are.equal(8, views[1].rows[1].id)
            assert.matches("could not confirm it was saved", messages[1].text, 1, true)
            assert.is_true(messages[1].options.toast)
            client:showLibrary()
            assert.are.equal("latest_arrivals", client.library_session.sort_mode)
            assert.are.equal(7, views[2].rows[1].id)
        end)
    end

    local function sortChoices(options)
        local result = {}
        for _, action in ipairs(options.actions) do
            if action.id:match("^sort_") then result[#result + 1] = { action.id, action.text, action.checked } end
        end
        return result
    end

    it("checks the effective sort and resets only explicit sort selections to the first page", function()
        local listing = { categories = {}, arrivals_supported = true, manga = {
            { id = 7, title = "Zulu", latest_fetched_at = 1800000000 },
            { id = 8, title = "Alpha", latest_fetched_at = 1700000000 },
        } }
        local client, requests, views, _, _, _, title = fixture(listing)
        local saves = 0
        client.settings.saveLibraryCache = function() saves = saves + 1; return listing end
        client:showLibrary()
        local menu = views[1]
        assert.same({ { "sort_latest_arrivals", "Sort by latest arrivals", true },
            { "sort_title", "Sort by title", false } }, sortChoices(title()))
        for _, id in ipairs({ "sort_latest_arrivals", "sort_title", "sort_title", "sort_latest_arrivals" }) do
            menu.page = 3
            title().onSelect({ id = id })
            assert.are.equal(1, menu.page)
            assert.are.equal(1, menu.options.itemnumber)
            assert.are.equal(id == "sort_title" and 8 or 7, menu.rows[1].id)
            local choices = sortChoices(title())
            assert.are.equal(id == "sort_latest_arrivals", choices[1][3])
            assert.are.equal(id == "sort_title", choices[2][3])
            assert.are.equal(1, #requests)
            assert.are.equal(0, saves)
            assert.are.equal(7, listing.manga[1].id)
        end
        menu.page = 3
        title().onSelect({ id = "refresh" })
        assert.are.equal(3, menu.page)
        assert.is_nil(menu.options.itemnumber)
        requests[2].on_finish({ ok = true, categories = {}, manga = listing.manga, arrivals_supported = true })
        assert.are.equal(3, menu.page)
        assert.is_nil(menu.options.itemnumber)
    end)

    it("omits sort controls from categories and keeps supported unknown dates selectable", function()
        local client, _, views, _, _, _, title = fixture({ categories = { { id = 1, name = "Reading" } },
            manga = { { id = 7, title = "Unknown" } }, arrivals_supported = true })
        client.settings.loadLibraryCategoryPickerBehavior = function() return "always" end
        client:showLibrary()
        assert.same({}, sortChoices(title()))
        assert.are.equal("refresh", title().actions[1].id)
        assert.are.equal("about_library", title().actions[2].id)
        views[1].select(views[1].rows[1])
        assert.same({ { "sort_latest_arrivals", "Sort by latest arrivals", true },
            { "sort_title", "Sort by title", false } }, sortChoices(title()))
        title().onSelect({ id = "sort_title" })
        assert.are.equal("title", client.library_session.sort_mode)
        views[1].select(views[1].rows[2])
        assert.are.equal("title", client.library_session.sort_mode)
    end)

    for _, invalidation in ipairs({ "server", "retired", "closed", "newer", "navigation" }) do
        it("rejects stale sort controls after " .. invalidation, function()
            local client, requests, views, _, credentials, _, title = fixture({ categories = {}, manga = {
                { id = 7, title = "Saved" },
            } })
            client:showLibrary()
            local options, session = title(), client.library_session
            local guard = options.captureActionGuard()
            views[1].page = 3
            if invalidation == "server" then credentials.server_url = "http://other.test"
            elseif invalidation == "retired" then client.plugin.suwayomi_host_retired = true
            elseif invalidation == "closed" then views[1].options.close_callback()
            elseif invalidation == "navigation" then client.plugin.isSuwayomiScreenActive = function() return false end
            else client:showLibrary() end
            assert.is_false(guard())
            options.onSelect({ id = "sort_title" })
            assert.are.equal("latest_arrivals", session.sort_mode)
            assert.are.equal(3, views[1].page)
            assert.are.equal(invalidation == "newer" and 2 or 1, #requests)
        end)
    end

    it("shows request, retained, loaded and unsaved status without losing authoritative emptiness", function()
        local client, requests, views, messages, _, _, title = fixture({ categories = {}, manga = {} })
        client:showLibrary()
        assert.matches("Saved information", views[1].options.library_status, 1, true)
        assert.matches("Refreshing", views[1].options.library_status, 1, true)
        requests[1].on_finish({ ok = false })
        assert.matches("Refresh failed", views[1].options.library_status, 1, true)
        assert.matches("^Refresh failed · Saved information retained", views[1].options.library_status)
        assert.same({}, messages)
        title().onSelect({ id = "refresh" })
        client.settings.saveLibraryCache = function() return nil, "uncertain" end
        requests[2].on_finish({ ok = true, categories = {}, manga = {}, arrivals_supported = true })
        assert.matches("Loaded, not saved for restart", views[1].options.library_status, 1, true)
        assert.are.equal("Your Suwayomi library is empty.", views[1].options.empty_text)
        assert.is_true(client.library_session.saved)
        title().onSelect({ id = "refresh" })
        assert.matches("^Loaded, not saved for restart · Refreshing", views[1].options.library_status)
        requests[3].on_finish({ ok = false })
        assert.matches("^Refresh failed · Loaded, not saved for restart", views[1].options.library_status)
        client.settings.saveLibraryCache = function(_, _, listing) return listing end
        title().onSelect({ id = "refresh" })
        requests[4].on_finish({ ok = true, categories = {}, manga = {} })
        assert.matches("^Loaded information", views[1].options.library_status)
        title().onSelect({ id = "refresh" })
        requests[5].on_finish({ ok = false })
        assert.matches("^Refresh failed · Loaded information retained", views[1].options.library_status)
    end)

    it("opens dismissible About from either title menu without changing the Library session", function()
        local category = { id = 1, name = "Reading" }
        local client, requests, views, messages, _, _, title = fixture({ categories = { category }, manga = {
            { id = 7, title = "Saved", categories = { category } },
        } })
        client.settings.loadLibraryCategoryPickerBehavior = function() return "always" end
        client:showLibrary()
        for index = 1, 2 do
            local menu = views[index]
            if index == 2 then title().onSelect({ id = "sort_title" }) end
            menu.page = 3
            local session, rows = client.library_session, menu.rows
            title().onSelect({ id = "about_library" })
            assert.are.equal(session, client.library_session)
            assert.are.equal(rows, menu.rows)
            assert.are.equal(3, menu.page)
            assert.are.equal(index == 2 and "title" or "latest_arrivals", session.sort_mode)
            assert.are.equal(index == 2 and category or nil, session.category)
            assert.are.equal(1, #requests)
            assert.is_nil(messages[index].options)
            for _, text in ipairs({ "newest server-discovered chapter", "loaded or saved server count",
                "total chapters, downloads", "discovery time", "Imported old chapters", "All scanlators",
                "saved scanlator filter", "local read choices", "does not discover chapters" }) do
                assert.matches(text, messages[index].text, 1, true)
            end
            -- Ordinary help dismissal has no Library callback or reconstruction.
            if index == 1 then menu.select(menu.rows[2]) end
        end
    end)

    local function restrictedFixture(metadata)
        local listing = { categories = {}, manga = {
            { id = 7, title = "Filtered", unread_count = 9, latest_fetched_at = 1900000000,
                scanlator_metadata = metadata },
            { id = 8, title = "Other source", unread_count = 1, latest_fetched_at = 1800000000 },
        } }
        local client, requests, views, messages, credentials, actions, title = fixture(listing)
        local filters = { ["7"] = "A" }
        client.settings.loadMangaScanlatorFilters = function()
            local captured = {}
            for key, value in pairs(filters) do captured[key] = value end
            return captured
        end
        client.settings.loadMangaScanlatorFilter = function(_, manga) return filters[tostring(manga.id)] end
        return client, requests, views, messages, credentials, actions, title, filters, listing
    end

    local function scopedMetadata(count, date, filter, endpoint)
        return { manga_id = "7", filter = filter or "A", endpoint_scope = endpoint or "http://library.test",
            unread_count = count, latest_fetched_at = date }
    end

    it("projects matching metadata without changing aggregate cache or read/download state", function()
        local client, requests, views, _, _, _, title, _, listing = restrictedFixture(scopedMetadata(2, 1700000000))
        local ledger = { pending = { manga_id = 7, endpoint_scope = "http://library.test", pending_read_sync = true } }
        client.settings.loadChapterLedger = function() return ledger end
        client:showLibrary()
        assert.same({ ["7"] = "A" }, requests[1].request.scanlator_filters)
        assert.are.equal(8, views[1].rows[1].id)
        assert.are.equal(2, views[1].rows[2].unread_count)
        assert.is_true(views[1].options.library_pending[views[1].rows[2]])
        title().onSelect({ id = "sort_title" })
        assert.are.equal(7, views[1].rows[1].id)
        assert.are.equal(9, listing.manga[1].unread_count)
        assert.are.equal(1900000000, listing.manga[1].latest_fetched_at)
        assert.is_true(ledger.pending.pending_read_sync)
        assert.are.equal(1, #requests)
    end)

    for name, metadata in pairs({ old_aggregate = false, wrong_filter = scopedMetadata(3, 1800000000, "B"),
        wrong_endpoint = scopedMetadata(3, 1800000000, "A", "http://other.test"),
        wrong_manga = { manga_id = "8", filter = "A", endpoint_scope = "http://library.test", unread_count = 3 },
    }) do
        it("keeps " .. name .. " cache unknown under a saved restriction", function()
            local client, requests, views = restrictedFixture(metadata or nil)
            client:showLibrary()
            requests[1].on_finish({ ok = false })
            assert.are.equal(8, views[1].rows[1].id)
            assert.is_nil(views[1].rows[2].unread_count)
            assert.is_nil(views[1].rows[2].latest_fetched_at)
            assert.matches("Scanlator information unavailable", views[1].options.library_status, 1, true)
        end)
    end

    it("retains matching scoped facts through failed metadata reads and offline reopening", function()
        local client, requests, views = restrictedFixture(scopedMetadata(0, nil))
        client:showLibrary()
        requests[1].on_finish({ ok = true, categories = {}, manga = {
            { id = 7, title = "Filtered", unread_count = 12, latest_fetched_at = 1900000001,
                scanlator_metadata_failed = true }, { id = 8, title = "Other source" },
        } })
        assert.are.equal(0, views[1].rows[1].unread_count)
        assert.is_nil(views[1].rows[1].latest_fetched_at)
        assert.matches("Scanlator information retained", views[1].options.library_status, 1, true)
        views[1].close_callback()
        client:showLibrary()
        requests[2].on_finish({ ok = false })
        assert.are.equal(0, views[2].rows[1].unread_count)
        assert.is_nil(views[2].rows[1].latest_fetched_at)
    end)

    describe("malformed scoped responses", function()
        local modules = { "suwayomi/api", "suwayomi/api/transport", "suwayomi/network/request_worker",
            "suwayomi/subprocess/job" }
        local function clearModules()
            for _, name in ipairs(modules) do
                package.loaded[name], package.preload[name] = nil, nil
            end
        end
        before_each(clearModules)
        after_each(clearModules)

        for name, latest in pairs({
            null_chapter = '{"totalCount":1,"nodes":[null]}',
            scalar_chapter = '{"totalCount":1,"nodes":["bad"]}',
            object_nodes = '{"totalCount":0,"nodes":{}}',
        }) do
            it("retains confirmed count, date and arrival order after " .. name .. " and cache reopening", function()
                package.preload["suwayomi/api/transport"] = function()
                    return { performGraphQLRequest = function(_, _, operation)
                        local body
                        if operation == "fetchCategories" then
                            body = '{"data":{"categories":{"totalCount":0,"nodes":[],"pageInfo":{"hasNextPage":false}}}}'
                        elseif operation == "fetchLibraryManga" then
                            body = json.encode({ data = { mangas = { totalCount = 3,
                                pageInfo = { hasNextPage = false }, nodes = {
                                    { id = 7, title = "Filtered", unreadCount = 12,
                                        latestFetchedChapter = { fetchedAt = "1900000001" } },
                                    { id = 8, title = "Other source", unreadCount = 1,
                                        latestFetchedChapter = { fetchedAt = "1700000000" } },
                                    { id = 9, title = "New member" },
                                } } } })
                        else
                            assert.are.equal("fetchLibraryScanlatorMetadata", operation)
                            body = '{"data":{"unread1":{"totalCount":3},"latest1":' .. latest .. '}}'
                        end
                        return { ok = true, response_body = body }
                    end }
                end
                package.preload["suwayomi/subprocess/job"] = function()
                    return { writeResult = function() return true end }
                end
                local client, requests, views, messages, credentials, actions, title, _, listing =
                    restrictedFixture(scopedMetadata(2, 1800000000))
                listing.manga[2].latest_fetched_at = 1700000000
                listing.manga[3] = { id = 10, title = "Removed member" }
                local cache, writes = json.encode(listing), 0
                client.settings.loadLibraryCache = function() return json.decode(cache) end
                client.settings.saveLibraryCache = function(_, _, value)
                    writes, cache = writes + 1, json.encode(value)
                    return json.decode(cache)
                end
                client:showLibrary()
                title().onSelect({ id = "sort_latest_arrivals" })
                local result = require("suwayomi/network/request_worker"):run(credentials,
                    requests[1].request, "/settings/synthetic-library.json")
                requests[1].on_finish(result)

                local function assertRetained(menu)
                    local ids = {}
                    for _, manga in ipairs(menu.rows) do ids[#ids + 1] = manga.id end
                    assert.same({ "7", "8", "9" }, ids)
                    assert.are.equal(2, menu.rows[1].unread_count)
                    assert.are.equal(1800000000, menu.rows[1].latest_fetched_at)
                    assert.are.equal("latest_arrivals", client.library_session.sort_mode)
                    assert.matches("Scanlator information retained", menu.options.library_status, 1, true)
                    menu.select(menu.rows[1])
                    assert.are.equal("7", actions().manga.id)
                    assert.are.equal("http://library.test", actions().manga.endpoint_scope)
                    assert.is_function(actions().options.onMangaUpdated)
                end
                assertRetained(views[1])
                assert.is_true(result.ok)
                assert.are.equal(1, writes)
                local saved = json.decode(cache).manga[1]
                assert.are.equal(12, saved.unread_count)
                assert.are.equal(1900000001, saved.latest_fetched_at)
                assert.are.equal(2, saved.scanlator_metadata.unread_count)
                assert.are.equal(1800000000, saved.scanlator_metadata.latest_fetched_at)
                assert.is_true(saved.scanlator_metadata.retained)
                views[1].close_callback()
                client:showLibrary()
                requests[2].on_finish({ ok = false })
                assertRetained(views[2])
                assert.are.equal(1, writes)
                assert.same({}, messages)
            end)
        end
    end)

    it("ignores excluded arrivals but ranks matching arrivals including already-read releases", function()
        local client, requests, views, _, _, _, title = restrictedFixture(scopedMetadata(2, 1700000000))
        client:showLibrary()
        requests[1].on_finish({ ok = true, categories = {}, manga = {
            { id = 7, title = "Filtered", unread_count = 10, latest_fetched_at = 1900000001,
                scanlator_metadata = scopedMetadata(2, 1700000000) },
            { id = 8, title = "Other source", latest_fetched_at = 1800000000 },
        } })
        assert.are.equal(8, views[1].rows[1].id)
        assert.are.equal(2, views[1].rows[2].unread_count)
        title().onSelect({ id = "refresh" })
        requests[2].on_finish({ ok = true, categories = {}, manga = {
            { id = 7, title = "Filtered", scanlator_metadata = scopedMetadata(2, 1900000002) },
            { id = 8, title = "Other source", latest_fetched_at = 1800000000 },
        } })
        assert.are.equal(7, views[1].rows[1].id)
        assert.are.equal(2, views[1].rows[1].unread_count)
        assert.are.equal(1900000002, views[1].rows[1].latest_fetched_at)
    end)

    it("rejects stale filter results and removes the restriction without leaking filtered totals", function()
        local client, requests, views, _, _, _, title, filters = restrictedFixture(scopedMetadata(2, 1700000000))
        client:showLibrary()
        title().onSelect({ id = "sort_title" })
        filters["7"] = "B"
        requests[1].on_finish({ ok = true, categories = {}, manga = {
            { id = 7, title = "Filtered", unread_count = 9, latest_fetched_at = 1900000000,
                scanlator_metadata = scopedMetadata(2, 1700000000) },
        } })
        assert.is_nil(views[1].rows[1].unread_count)
        assert.is_nil(client.library_session.listing.manga[1].scanlator_metadata)
        assert.are.equal("title", client.library_session.sort_mode)
        filters["7"] = nil
        title().onSelect({ id = "sort_title" })
        assert.are.equal(9, views[1].rows[1].unread_count)
        assert.are.equal(1900000000, views[1].rows[1].latest_fetched_at)
        assert.are.equal(1, #requests)
    end)

    it("rejects scoped results when endpoint changes during the request", function()
        local client, requests, views, _, credentials = restrictedFixture(scopedMetadata(2, 1700000000))
        client:showLibrary()
        local saves = 0
        client.settings.saveLibraryCache = function() saves = saves + 1 end
        credentials.server_url = "http://other.test"
        requests[1].on_finish({ ok = true, categories = {}, manga = {
            { id = 7, title = "Foreign", scanlator_metadata = scopedMetadata(0, 1900000000) },
        } })
        assert.are.equal(2, views[1].rows[2].unread_count)
        assert.are.equal(0, saves)
    end)

    it("qualifies server counts with only matching pending read choices, even after archive relocation", function()
        local client, _, views = fixture({ categories = {}, manga = {
            { id = 7, title = "Pending unread", unread_count = 12 },
            { id = 8, title = "Foreign pending", unread_count = 0 },
            { id = 9, title = "Legacy pending" },
        } })
        local ledger = {
            one = { manga_id = 7, endpoint_scope = "http://library.test", pending_read_sync = true,
                read = false, path = "/relocated/chapter.cbz" },
            two = { manga_id = 8, endpoint_scope = "http://foreign.test", pending_read_sync = true },
            three = { manga_id = 9, pending_read_sync = true },
        }
        client.settings.loadChapterLedger = function() return ledger end
        client:showLibrary()
        assert.is_true(views[1].options.library_pending[views[1].rows[3]])
        assert.is_nil(views[1].options.library_pending[views[1].rows[1]])
        assert.is_nil(views[1].options.library_pending[views[1].rows[2]])
        assert.are.equal(12, views[1].rows[3].unread_count)
        assert.is_true(ledger.one.pending_read_sync)
        assert.is_false(ledger.one.read)
        assert.are.equal("/relocated/chapter.cbz", ledger.one.path)
        assert.is_nil(views[1].rows[3].sync_pending)
    end)

    it("falls back only for unsupported discovery and restores requested order on supported refresh", function()
        local listing = { categories = {}, manga = {
            { id = 7, title = "Zulu", latest_fetched_at = 1800000000 },
            { id = 8, title = "Alpha", latest_fetched_at = 1700000000 },
        }, arrivals_supported = false }
        local client, requests, views, _, _, _, title = fixture(listing)
        local writes = 0
        client.settings.saveLibrarySortMode = function() writes = writes + 1; return "title" end
        client:showLibrary()
        assert.are.equal(8, views[1].rows[1].id)
        assert.matches("Latest arrivals unavailable", views[1].options.library_status, 1, true)
        assert.same({ { "sort_title", "Sort by title", true } }, sortChoices(title()))
        assert.are.equal("latest_arrivals", client.library_session.sort_mode)
        requests[1].on_finish({ ok = false })
        assert.are.equal(8, views[1].rows[1].id)
        title().onSelect({ id = "refresh" })
        requests[2].on_finish({ ok = true, categories = {}, manga = listing.manga, arrivals_supported = true })
        assert.are.equal(7, views[1].rows[1].id)
        assert.are.equal("latest_arrivals", client.library_session.sort_mode)
        assert.same({ { "sort_latest_arrivals", "Sort by latest arrivals", true },
            { "sort_title", "Sort by title", false } }, sortChoices(title()))
        assert.are.equal(0, writes)
        client:showLibrary()
        assert.are.equal("latest_arrivals", client.library_session.sort_mode)
        assert.are.equal(0, writes)
    end)

    it("retains the session sort across categories and metadata-only nested actions", function()
        local category = { id = 1, name = "Reading" }
        local client, requests, views, _, _, actions, title = fixture({ categories = { category }, manga = {
            { id = 7, title = "Zulu", unread_count = 5, latest_fetched_at = 1800000000 },
            { id = 8, title = "Alpha", latest_fetched_at = 1700000000, categories = { category } },
        } })
        client.settings.loadLibraryCategoryPickerBehavior = function() return "always" end
        local writes = 0
        local save = client.settings.saveLibrarySortMode
        client.settings.saveLibrarySortMode = function(settings, value)
            writes = writes + 1
            return save(settings, value)
        end
        client:showLibrary()
        views[1].select(views[1].rows[1])
        title().onSelect({ id = "sort_title" })
        assert.are.equal(8, views[2].rows[1].id)
        views[1].select(views[1].rows[2])
        assert.are.equal(8, views[2].rows[1].id)
        views[1].select(views[1].rows[1])
        views[2].select(views[2].rows[2])
        actions().options.onMangaUpdated({ id = 7, title = "Zulu", in_library = true })
        assert.are.equal(1800000000, views[2].rows[2].latest_fetched_at)
        assert.are.equal(5, views[2].rows[2].unread_count)
        assert.are.equal("title", client.library_session.sort_mode)
        requests[1].on_finish({ ok = true, categories = { category }, manga = {}, arrivals_supported = true })
        assert.are.equal("title", client.library_session.sort_mode)
        assert.are.equal(1, writes)
    end)

    it("does not lend snapshot scope to unassociated, invalid-ID or empty-scope rows", function()
        local unknown = { id = 7, title = "Unassociated", local_only = true }
        local invalid = { id = -1, title = "Invalid" }
        local foreign = { id = 7, title = "Foreign", endpoint_scope = "http://foreign.test" }
        local client, _, views = fixture({ categories = {}, manga = { unknown, invalid, foreign } })
        client.settings.loadChapterLedger = function() return {
            { manga_id = 7, endpoint_scope = "http://library.test", pending_read_sync = true },
            { manga_id = -1, endpoint_scope = "http://library.test", pending_read_sync = true },
            { manga_id = 7, endpoint_scope = "", pending_read_sync = true },
        } end
        client:showLibrary()
        assert.same({}, views[1].options.library_pending)
        assert.is_nil(unknown.endpoint_scope)
    end)

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
        assert.same({}, messages)
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
        assert.matches("Reconstructed information", views[1].options.library_status, 1, true)
        assert.is_nil(views[1].rows[1].endpoint_scope)
        views[1].select(views[1].rows[1])
        assert.is_true(actions().chapters)
        assert.is_true(actions().manga.local_only)
        requests[1].on_finish({ ok = false })
        assert.matches("^Refresh failed · Reconstructed information retained", views[1].options.library_status)
        assert.same({}, messages)
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

    it("opens a recorded file's manga without descriptions or invented server identifiers", function()
        local path = os.tmpname()
        local client, _, views, _, _, actions = fixture()
        client.settings.loadReaderReturnContexts = function() return { { path = path } } end
        client:showLibrary()
        assert.are.equal(1, #views[1].rows)
        views[1].select(views[1].rows[1])
        assert.is_true(actions().chapters)
        assert.is_true(actions().manga.local_only)
        assert.is_nil(actions().manga.id)
        assert.are.equal(path:match("^(.*)[/\\][^/\\]+$"), actions().manga.local_manga_path)
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

    it("shows all authoritative manga when refresh removes the selected category", function()
        local temporary = { id = 1, name = "Temporary" }
        local remaining = { id = 2, name = "Remaining" }
        local client, requests, views = fixture({
            categories = { temporary, remaining },
            manga = { { id = 7, title = "Beta", categories = { temporary } } },
        })
        client:showLibrary()
        views[1].select(views[1].rows[2])
        assert.are.equal(7, views[2].rows[1].id)

        requests[1].on_finish({ ok = true, categories = { remaining }, manga = {
            { id = 8, title = "Alpha", categories = { remaining } },
            { id = 7, title = "Beta", categories = {} },
        } })

        assert.is_nil(client.library_session.category)
        assert.same({ 8, 7 }, { views[2].rows[1].id, views[2].rows[2].id })
        assert.same({ "All manga", "Remaining" }, { views[1].rows[1].name, views[1].rows[2].name })
        assert.are.equal(2, #client.plugin:getNavigation().entries)
        views[1].select(views[1].rows[2])
        assert.are.equal(8, views[2].rows[1].id)
    end)

    it("keeps Default and All selections on replacement, then accepts a genuinely empty Library", function()
        local client, requests, views, _, _, _, title = fixture({
            categories = { { id = 0, name = "Default" }, { id = 1, name = "Other" } },
            manga = { { id = 7, title = "Old default", categories = {} } },
        })
        client:showLibrary()
        views[1].select(views[1].rows[2])
        requests[1].on_finish({ ok = true,
            categories = { { id = 0, name = "Renamed Default" }, { id = 1, name = "Other" } },
            manga = { { id = 8, title = "New default", categories = {} } },
        })
        assert.are.equal(0, client.library_session.category.id)
        assert.are.equal("Renamed Default", client.library_session.category.name)
        assert.are.equal(8, views[2].rows[1].id)
        views[1].select(views[1].rows[1])
        title().onSelect({ id = "refresh" })
        requests[2].on_finish({ ok = true, categories = {}, manga = {} })
        assert.same({}, views[2].rows)
        assert.is_nil(client.library_session.category.id)
        assert.same({ "All manga" }, { views[1].rows[1].name })
    end)

    it("keeps the selected category after a failed or incomplete refresh", function()
        local client, requests, views, _, _, _, title = fixture({
            categories = { { id = 1, name = "Selected" }, { id = 2, name = "Other" } },
            manga = { { id = 7, title = "Saved", categories = { { id = 1 } } } },
        })
        client:showLibrary()
        views[1].select(views[1].rows[2])
        requests[1].on_finish({ ok = false })
        title().onSelect({ id = "refresh" })
        requests[2].on_finish({ ok = true, categories = {} })
        assert.are.equal(1, client.library_session.category.id)
        assert.are.equal(7, views[2].rows[1].id)
        assert.are.equal("Selected", views[1].rows[2].name)
    end)

    it("shows all current rows after a deleted selection even if cache saving fails", function()
        local client, requests, views, messages = fixture({
            categories = { { id = 1, name = "Selected" }, { id = 2, name = "Other" } },
            manga = { { id = 7, title = "Saved", categories = { { id = 1 } } } },
        })
        client.settings.saveLibraryCache = function() return nil, "rejected" end
        client:showLibrary()
        views[1].select(views[1].rows[2])
        requests[1].on_finish({ ok = true, categories = {}, manga = {
            { id = 8, title = "Current", categories = {} },
        } })
        assert.is_nil(client.library_session.category)
        assert.are.equal(8, views[2].rows[1].id)
        assert.are.equal(1, #messages)
    end)

    it("rebinds a surviving selection to fresh category metadata, including an empty result", function()
        local client, requests, views = fixture({
            categories = { { id = 1, name = "Old name" }, { id = 2, name = "Other" } },
            manga = { { id = 7, title = "Old row", categories = { { id = 1 } } } },
        })
        client:showLibrary()
        views[1].select(views[1].rows[2])
        requests[1].on_finish({ ok = true,
            categories = { { id = 1, name = "New name" }, { id = 2, name = "Other" } },
            manga = { { id = 8, title = "Elsewhere", categories = { { id = 2 } } } },
        })
        assert.are.equal("New name", client.library_session.category.name)
        assert.same({}, views[2].rows)
        assert.are.equal("New name", views[1].rows[2].name)
        views[1].select(views[1].rows[1])
        assert.are.equal(8, views[2].rows[1].id)
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
            assert.same({}, messages)
            client:showLibrary()
            assert.are.equal(7, views[2].rows[1].id)
        end)
    end

    it("reports a failed explicit Refresh even with saved Library rows", function()
        local client, requests, _, messages, _, _, title = fixture({
            categories = {}, manga = { { id = 7, title = "Saved" } },
        })
        client:showLibrary()
        requests[1].on_finish({ ok = false })
        assert.same({}, messages)
        title().onSelect({ id = "refresh" })
        requests[2].on_finish({ ok = false })
        assert.are.equal(1, #messages)
    end)

    it("keeps saved empty Library quiet but reports failure without saved information", function()
        local client, requests, _, messages = fixture({ categories = {}, manga = {} })
        client:showLibrary()
        requests[1].on_finish({ ok = false })
        assert.same({}, messages)
        client.settings.loadLibraryCache = function() return nil end
        client:showLibrary()
        requests[2].on_finish({ ok = false })
        assert.are.equal(1, #messages)
    end)

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

    it("returns to Library through the title action without retaining the old navigation branch", function()
        package.preload["suwayomi/ui"] = function() return {} end
        local client, _, views, _, _, actions = fixture({
            categories = { { id = 1, name = "First" }, { id = 2, name = "Second" } },
            manga = { { id = 7, title = "Saved" } },
        })
        client:showLibrary()
        views[1].select(views[1].rows[1])
        local previous_menu = views[2]
        client.plugin.showLibrary = function() return client:showLibrary() end
        local title_menu = require("suwayomi/plugin/title_menu")
        title_menu.methods.performTitleBarAction(client.plugin, previous_menu, { id = "library" })
        assert.is_true(views[1].closed)
        assert.is_true(views[2].closed)
        assert.is_false(client.plugin:getNavigation():contains(views[1]))
        assert.are.equal(1, #client.plugin:getNavigation().entries)
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

    it("keeps newer Library discovery and aggregate metadata when an older nested action completes", function()
        local client, requests, views, _, _, actions = fixture({ categories = {}, manga = {
            { id = 7, title = "Saved", in_library = true, latest_fetched_at = 1700000000, unread_count = 3 },
        } })
        client:showLibrary()
        views[1].select(views[1].rows[1])
        requests[1].on_finish({ ok = true, categories = {}, manga = {
            { id = 7, title = "Refreshed", in_library = true, latest_fetched_at = 1800000000, unread_count = 8 },
        } })
        actions().options.onMangaUpdated(actions().manga)
        assert.are.equal(1800000000, views[1].rows[1].latest_fetched_at)
        assert.are.equal(8, views[1].rows[1].unread_count)
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
