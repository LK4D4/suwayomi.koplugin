package.path = "?.lua;" .. package.path

local helper = require("spec/support/suwayomi_client_spec_helper")

describe("suwayomi/client library flows", function()
    after_each(function()
        helper.clearClientModules()
    end)

    local newClient = helper.newClient

    it("shows an empty library message", function()
        local client, state = newClient({
            api = {
                fetchCategories = function()
                    return { ok = true, categories = {} }
                end,
                fetchLibraryManga = function()
                    return { ok = true, manga = {}, total_count = 0 }
                end,
            },
            ui = {
                showLibraryCategoryMenu = function()
                    error("unexpected category menu")
                end,
                showLibraryMangaMenu = function()
                    error("unexpected manga menu")
                end,
            },
        })

        client:showLibrary()

        assert.are.same({}, state.loading_messages)
        assert.are.same({ "fetch_library_categories", "fetch_library_manga_pages" }, {
            state.network_requests[1].request.action,
            state.network_requests[2].request.action,
        })
        assert.are.equal("Your Suwayomi library is empty.", state.shown_messages[#state.shown_messages])
        assert.are.equal("https://suwayomi.example", state.scheduled_sync_credentials().server_url)
    end)

    it("asks for setup when library credentials are missing", function()
        local client, state = newClient({
            credentials = { server_url = "" },
            api = {
                fetchCategories = function()
                    error("unexpected category fetch")
                end,
            },
            ui = {},
        })

        client:showLibrary()

        assert.are.equal("Set up your Suwayomi server login first.", state.shown_messages[#state.shown_messages])
        assert.is_nil(state.scheduled_sync_credentials())
    end)

    it("skips the category picker for a single category and opens selected library manga actions", function()
        local shown_manga
        local shown_menu_options
        local tracked = {}
        local client, state = newClient({
            title_menu_options = { title_bar_left_icon = "appbar.menu" },
            api = {
                fetchCategories = function()
                    return { ok = true, categories = { { id = "1", name = "Default", manga_count = 1 } } }
                end,
                fetchLibraryManga = function(_, options)
                    assert.are.same({ first = 100, offset = 0 }, options)
                    return {
                        ok = true,
                        manga = {
                            {
                                id = "m1",
                                title = "Sousou no Frieren",
                                unread_count = 12,
                                source = { displayName = "MangaDex EN" },
                                categories = { { id = "1", name = "Default" } },
                            },
                        },
                        total_count = 1,
                    }
                end,
            },
            ui = {
                showLibraryCategoryMenu = function()
                    error("unexpected category menu")
                end,
                showLibraryMangaMenu = function(manga, onSelect, menu_options)
                    shown_manga = manga
                    shown_menu_options = menu_options
                    onSelect(manga[1])
                    return { name = "library-menu" }
                end,
            },
            trackSuwayomiScreen = function(route_id, widget)
                table.insert(tracked, { route_id = route_id, widget = widget })
            end,
        })

        client:showLibrary()

        assert.are.equal("Sousou no Frieren", shown_manga[1].title)
        assert.are.equal(12, shown_manga[1].unread_count)
        assert.is_nil(shown_manga[1].menu_text)
        assert.are.equal("appbar.menu", shown_menu_options.title_bar_left_icon)
        assert.are.equal("https://suwayomi.example", shown_menu_options.thumbnail_credentials.server_url)
        assert.are.equal("m1", state.shown_manga_actions().id)
        assert.are.equal("library_manga_loaded", state.log_events[#state.log_events].event)
        assert.are.equal("library", tracked[1].route_id)
        assert.are.equal("library-menu", tracked[1].widget.name)
    end)

    it("lets manga actions refresh the visible library row after membership changes", function()
        local updated_manga
        local updated_menu
        local client = newClient({
            api = {
                fetchCategories = function()
                    return { ok = true, categories = { { id = "1", name = "Default", manga_count = 1 } } }
                end,
                fetchLibraryManga = function()
                    return {
                        ok = true,
                        manga = {
                            {
                                id = "m1",
                                title = "Sousou no Frieren",
                                in_library = true,
                                unread_count = 12,
                                source = { displayName = "MangaDex EN" },
                                categories = { { id = "1", name = "Default" } },
                            },
                        },
                    }
                end,
            },
            ui = {
                showLibraryCategoryMenu = function()
                    error("unexpected category menu")
                end,
                showLibraryMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                    return { name = "library-menu" }
                end,
                updateLibraryMangaMenu = function(menu, manga)
                    updated_menu = menu
                    updated_manga = manga
                end,
            },
        })

        client.plugin.showMangaActions = function(_, manga, options)
            manga.unread_count = 0
            options.onMangaUpdated(manga)
        end

        client:showLibrary()

        assert.are.equal("library-menu", updated_menu.name)
        assert.are.equal("Sousou no Frieren", updated_manga[1].title)
        assert.are.equal(0, updated_manga[1].unread_count)
        assert.is_nil(updated_manga[1].menu_text)
    end)

    it("removes a manga from the visible library list after library removal", function()
        local updated_manga
        local client = newClient({
            api = {
                fetchCategories = function()
                    return { ok = true, categories = { { id = "1", name = "Default", manga_count = 1 } } }
                end,
                fetchLibraryManga = function()
                    return {
                        ok = true,
                        manga = {
                            {
                                id = "m1",
                                title = "Sousou no Frieren",
                                in_library = true,
                                unread_count = 12,
                                source = { displayName = "MangaDex EN" },
                                categories = { { id = "1", name = "Default" } },
                            },
                        },
                    }
                end,
            },
            ui = {
                showLibraryCategoryMenu = function()
                    error("unexpected category menu")
                end,
                showLibraryMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                    return { name = "library-menu" }
                end,
                updateLibraryMangaMenu = function(_, manga)
                    updated_manga = manga
                end,
            },
        })

        client.plugin.showMangaActions = function(_, manga, options)
            manga.in_library = false
            options.onMangaUpdated(manga)
        end

        client:showLibrary()

        assert.are.equal(0, #updated_manga)
    end)

    it("shows categories when multiple categories are present and filters selected category manga", function()
        local shown_categories
        local shown_category_menu_options
        local shown_manga
        local client = newClient({
            title_menu_options = { title_bar_left_icon = "appbar.menu" },
            api = {
                fetchCategories = function()
                    return {
                        ok = true,
                        categories = {
                            { id = "1", name = "Default", manga_count = 1 },
                            { id = "2", name = "Reading", manga_count = 1 },
                        },
                    }
                end,
                fetchLibraryManga = function()
                    return {
                        ok = true,
                        manga = {
                            {
                                id = "m1",
                                title = "Default Manga",
                                categories = { { id = "1", name = "Default" } },
                            },
                            {
                                id = "m2",
                                title = "Reading Manga",
                                unread_count = 3,
                                categories = { { id = "2", name = "Reading" } },
                            },
                        },
                    }
                end,
            },
            ui = {
                showLibraryCategoryMenu = function(categories, onSelect, menu_options)
                    shown_categories = categories
                    shown_category_menu_options = menu_options
                    onSelect(categories[3])
                end,
                showLibraryMangaMenu = function(manga)
                    shown_manga = manga
                end,
            },
        })

        client:showLibrary()

        assert.are.equal("All manga", shown_categories[1].name)
        assert.are.equal("Default", shown_categories[2].name)
        assert.are.equal("Reading", shown_categories[3].name)
        assert.are.equal("appbar.menu", shown_category_menu_options.title_bar_left_icon)
        assert.are.equal("Reading Manga", shown_manga[1].title)
        assert.are.equal(3, shown_manga[1].unread_count)
        assert.is_nil(shown_manga[1].menu_text)
    end)

    it("can always show the category picker even for a single category", function()
        local shown_categories
        local client = newClient({
            picker_behavior = "always",
            api = {
                fetchCategories = function()
                    return { ok = true, categories = { { id = "1", name = "Default", manga_count = 1 } } }
                end,
                fetchLibraryManga = function()
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Default Manga", categories = { { id = "1", name = "Default" } } },
                        },
                    }
                end,
            },
            ui = {
                showLibraryCategoryMenu = function(categories, onSelect)
                    shown_categories = categories
                    onSelect(categories[2])
                end,
                showLibraryMangaMenu = function() end,
            },
        })

        client:showLibrary()

        assert.are.equal("All manga", shown_categories[1].name)
        assert.are.equal("Default", shown_categories[2].name)
    end)

    it("can skip the category picker even when multiple categories exist", function()
        local shown_manga
        local client = newClient({
            picker_behavior = "never",
            api = {
                fetchCategories = function()
                    return {
                        ok = true,
                        categories = {
                            { id = "1", name = "Default", manga_count = 1 },
                            { id = "2", name = "Reading", manga_count = 1 },
                        },
                    }
                end,
                fetchLibraryManga = function()
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Default Manga", categories = { { id = "1", name = "Default" } } },
                            { id = "m2", title = "Reading Manga", categories = { { id = "2", name = "Reading" } } },
                        },
                    }
                end,
            },
            ui = {
                showLibraryCategoryMenu = function()
                    error("unexpected category menu")
                end,
                showLibraryMangaMenu = function(manga)
                    shown_manga = manga
                end,
            },
        })

        client:showLibrary()

        assert.are.equal(2, #shown_manga)
    end)

    it("paginates library manga before filtering a selected category", function()
        local fetch_offsets = {}
        local first_page = {}
        for index = 1, 100 do
            table.insert(first_page, {
                id = "default-" .. tostring(index),
                title = "Default " .. tostring(index),
                categories = { { id = "1", name = "Default" } },
            })
        end

        local shown_manga
        local client = newClient({
            api = {
                fetchCategories = function()
                    return {
                        ok = true,
                        categories = {
                            { id = "1", name = "Default", manga_count = 100 },
                            { id = "2", name = "Reading", manga_count = 1 },
                        },
                    }
                end,
                fetchLibraryManga = function(_, options)
                    table.insert(fetch_offsets, options.offset)
                    if options.offset == 0 then
                        return { ok = true, manga = first_page, total_count = 101 }
                    end
                    return {
                        ok = true,
                        manga = {
                            {
                                id = "reading-1",
                                title = "Reading Manga",
                                categories = { { id = "2", name = "Reading" } },
                            },
                        },
                        total_count = 101,
                    }
                end,
            },
            ui = {
                showLibraryCategoryMenu = function(categories, onSelect)
                    onSelect(categories[3])
                end,
                showLibraryMangaMenu = function(manga)
                    shown_manga = manga
                end,
            },
        })

        client:showLibrary()

        assert.are.same({ 0, 100 }, fetch_offsets)
        assert.are.equal("Reading Manga", shown_manga[1].title)
        assert.is_nil(shown_manga[1].menu_text)
    end)

    it("shows a selected-category empty message", function()
        local client, state = newClient({
            api = {
                fetchCategories = function()
                    return {
                        ok = true,
                        categories = {
                            { id = "1", name = "Default", manga_count = 1 },
                            { id = "2", name = "Reading", manga_count = 0 },
                        },
                    }
                end,
                fetchLibraryManga = function()
                    return {
                        ok = true,
                        manga = {
                            {
                                id = "m1",
                                title = "Default Manga",
                                categories = { { id = "1", name = "Default" } },
                            },
                        },
                    }
                end,
            },
            ui = {
                showLibraryCategoryMenu = function(categories, onSelect)
                    onSelect(categories[3])
                end,
                showLibraryMangaMenu = function()
                    error("unexpected manga menu")
                end,
            },
        })

        client:showLibrary()

        assert.are.equal("This category has no manga.", state.shown_messages[#state.shown_messages])
    end)

    it("ignores stale library manga loads when a newer category wins", function()
        local requests = {}
        local canceled = {}
        local shown_manga
        local client = newClient({
            api = {},
            network_request_job = {
                start = function(options)
                    table.insert(requests, options)
                    return {
                        pid = #requests,
                        on_cancel = options.on_cancel,
                    }
                end,
                cancel = function(active)
                    table.insert(canceled, active)
                    if active.on_cancel then
                        active.on_cancel()
                    end
                end,
            },
            ui = {
                showLibraryMangaMenu = function(manga)
                    shown_manga = manga
                    return { name = "library-menu" }
                end,
            },
        })

        assert.is_true(client:showLibraryManga({ id = "1", name = "First" }))
        assert.is_true(client:showLibraryManga({ id = "2", name = "Second" }))
        assert.are.equal(1, #canceled)

        requests[1].on_finish({
            ok = true,
            manga = {
                { id = "old", title = "Old Manga", categories = { { id = "1" } } },
            },
        })
        assert.is_nil(shown_manga)

        requests[2].on_finish({
            ok = true,
            manga = {
                { id = "new", title = "New Manga", categories = { { id = "2" } } },
            },
        })

        assert.are.equal("New Manga", shown_manga[1].title)
    end)
end)
