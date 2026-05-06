package.path = "?.lua;" .. package.path

describe("suwayomi_client", function()
    after_each(function()
        package.loaded.suwayomi_client = nil
    end)

    local function newClient(options)
        local Client = require("suwayomi_client")
        options = options or {}
        local loading_messages = {}
        local shown_messages = {}
        local opened_manga
        local scheduled_sync_credentials
        local log_events = {}
        local client = Client:new{
            settings = {
                load = function()
                    return options.credentials or { server_url = "https://suwayomi.example" }
                end,
                loadLibraryCategoryPickerBehavior = function()
                    return options.picker_behavior or "automatic"
                end,
            },
            api = options.api,
            ui = options.ui,
            debug = {
                time = function(_, _, callback)
                    return callback()
                end,
                log = function(event)
                    table.insert(log_events, event)
                end,
            },
            plugin = {
                withLoadingMessage = function(_, key, message, callback)
                    table.insert(loading_messages, key .. ":" .. message)
                    return callback()
                end,
                showMessage = function(_, message)
                    table.insert(shown_messages, message)
                end,
                showChaptersForManga = function(_, manga)
                    opened_manga = manga
                end,
                schedulePendingReadSync = function(_, credentials)
                    scheduled_sync_credentials = credentials
                end,
                getHomeMenuOptions = function()
                    return options.home_menu_options
                end,
            },
            gettext = function(text)
                return text
            end,
        }

        return client, {
            loading_messages = loading_messages,
            shown_messages = shown_messages,
            log_events = log_events,
            opened_manga = function()
                return opened_manga
            end,
            scheduled_sync_credentials = function()
                return scheduled_sync_credentials
            end,
        }
    end

    it("attaches source metadata to selected manga without overwriting existing values", function()
        local Client = require("suwayomi_client")
        local client = Client:new{}
        local manga = {
            id = "m1",
            title = "Sousou no Frieren",
            source = {
                id = "existing",
            },
        }

        client:attachSourceToManga(manga, {
            id = "s1",
            display_name = "MangaDex (EN)",
            raw_name = "MangaDex",
            lang = "en",
        })

        assert.are.same({
            id = "existing",
            displayName = "MangaDex (EN)",
            name = "MangaDex",
            lang = "en",
        }, manga.source)
    end)

    it("loads manga for a source and opens the selected manga through the plugin", function()
        local Client = require("suwayomi_client")
        local opened_manga
        local loading_messages = {}
        local log_events = {}
        local client = Client:new{
            settings = {
                load = function()
                    return { server_url = "https://suwayomi.example" }
                end,
            },
            api = {
                fetchMangaForSource = function(_, options)
                    assert.are.same({
                        source_id = "s1",
                        page = 1,
                        type = "POPULAR",
                    }, options)
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Sousou no Frieren" },
                        },
                    }
                end,
            },
            ui = {
                showMangaMenu = function(manga, onSelect, menu_options)
                    assert.are.equal("Sousou no Frieren", manga[1].title)
                    assert.are.same({ title_bar_left_icon = "appbar.home" }, menu_options)
                    onSelect(manga[1])
                end,
            },
            debug = {
                time = function(_, _, callback)
                    return callback()
                end,
                log = function(event)
                    table.insert(log_events, event)
                end,
            },
            plugin = {
                withLoadingMessage = function(_, key, message, callback)
                    table.insert(loading_messages, key .. ":" .. message)
                    return callback()
                end,
                showMessage = function(_, message)
                    error("unexpected message: " .. tostring(message))
                end,
                showChaptersForManga = function(_, manga)
                    opened_manga = manga
                end,
                getHomeMenuOptions = function()
                    return { title_bar_left_icon = "appbar.home" }
                end,
            },
            gettext = function(text)
                return text
            end,
        }

        client:showMangaForSource({
            id = "s1",
            display_name = "MangaDex (EN)",
            raw_name = "MangaDex",
            lang = "en",
        })

        assert.are.same({ "manga:Loading manga..." }, loading_messages)
        assert.are.same({
            id = "s1",
            displayName = "MangaDex (EN)",
            name = "MangaDex",
            lang = "en",
        }, opened_manga.source)
        assert.are.equal("manga_loaded", log_events[1].event)
        assert.are.equal(1, log_events[1].manga_count)
    end)

    it("formats compact library manga rows", function()
        local Client = require("suwayomi_client")
        local client = Client:new{}

        assert.are.equal(
            "Sousou no Frieren (12 unread / MangaDex EN)",
            client:formatLibraryMangaRow({
                title = "Sousou no Frieren",
                unread_count = 12,
                source = { displayName = "MangaDex EN" },
            })
        )
        assert.are.equal(
            "Chainsaw Man (0 unread / Local source)",
            client:formatLibraryMangaRow({
                title = "Chainsaw Man",
                unread_count = 0,
                source = { name = "Local source" },
            })
        )
    end)

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

        assert.are.same({ "library-categories:Loading library...", "library-manga:Loading library manga..." }, state.loading_messages)
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

    it("skips the category picker for a single category and opens selected library manga", function()
        local shown_manga
        local shown_menu_options
        local client, state = newClient({
            home_menu_options = { title_bar_left_icon = "appbar.home" },
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
                end,
            },
        })

        client:showLibrary()

        assert.are.equal("Sousou no Frieren (12 unread / MangaDex EN)", shown_manga[1].menu_text)
        assert.are.same({ title_bar_left_icon = "appbar.home" }, shown_menu_options)
        assert.are.equal("m1", state.opened_manga().id)
        assert.are.equal("library_manga_loaded", state.log_events[#state.log_events].event)
    end)

    it("shows categories when multiple categories are present and filters selected category manga", function()
        local shown_categories
        local shown_category_menu_options
        local shown_manga
        local client = newClient({
            home_menu_options = { title_bar_left_icon = "appbar.home" },
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
        assert.are.same({ title_bar_left_icon = "appbar.home" }, shown_category_menu_options)
        assert.are.same({ "Reading Manga (3 unread)" }, { shown_manga[1].menu_text })
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
        assert.are.equal("Reading Manga", shown_manga[1].menu_text)
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
end)
