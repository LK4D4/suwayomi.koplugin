package.path = "?.lua;" .. package.path

describe("suwayomi/client", function()
    after_each(function()
        package.loaded["suwayomi/client"] = nil
    end)

    local function newClient(options)
        local Client = require("suwayomi/client")
        options = options or {}
        local loading_messages = {}
        local shown_messages = {}
        local opened_manga
        local shown_manga_actions
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
                loadBrowseSettings = function()
                    return options.browse_settings or {
                        show_nsfw_sources = false,
                        hide_in_library_results = false,
                    }
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
                showMangaActions = function(_, manga)
                    shown_manga_actions = manga
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
            shown_manga_actions = function()
                return shown_manga_actions
            end,
            scheduled_sync_credentials = function()
                return scheduled_sync_credentials
            end,
        }
    end

    it("attaches source metadata to selected manga without overwriting existing values", function()
        local Client = require("suwayomi/client")
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

    it("loads manga for a source and opens the selected manga actions through the plugin", function()
        local Client = require("suwayomi/client")
        local shown_manga_actions
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
                    assert.are.same({
                        title = "MangaDex (EN) - Popular - Page 1",
                        title_bar_left_icon = "appbar.filebrowser",
                    }, menu_options)
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
                showMangaActions = function(_, manga)
                    shown_manga_actions = manga
                end,
                getHomeMenuOptions = function()
                    return { title_bar_left_icon = "appbar.filebrowser" }
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
        }, shown_manga_actions.source)
        assert.are.equal("manga_loaded", log_events[1].event)
        assert.are.equal(1, log_events[1].manga_count)
    end)

    it("opens a source mode menu for non-local sources and fetches popular manga from it", function()
        local fetched_options
        local client, state = newClient({
            api = {
                fetchMangaForSource = function(_, options)
                    fetched_options = options
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Sousou no Frieren" },
                        },
                    }
                end,
            },
            ui = {
                showSourceModeMenu = function(source, onSelect, menu_options)
                    assert.are.equal("s1", source.id)
                    assert.are.same({ title_bar_left_icon = "appbar.filebrowser" }, menu_options)
                    onSelect("POPULAR")
                end,
                showMangaMenu = function() end,
            },
            home_menu_options = { title_bar_left_icon = "appbar.filebrowser" },
        })

        client:showMangaForSource({ id = "s1", name = "MangaDex", lang = "en" })

        assert.are.same({ source_id = "s1", page = 1, type = "POPULAR" }, fetched_options)
        assert.are.same({ "manga:Loading manga..." }, state.loading_messages)
    end)

    it("keeps local sources on the direct manga listing flow", function()
        local mode_menu_shown = false
        local fetched_options
        local client = newClient({
            api = {
                fetchMangaForSource = function(_, options)
                    fetched_options = options
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Local Manga" },
                        },
                    }
                end,
            },
            ui = {
                showSourceModeMenu = function()
                    mode_menu_shown = true
                end,
                showMangaMenu = function() end,
            },
        })

        client:showMangaForSource({ id = "local", name = "Local source", lang = "localsourcelang" })

        assert.is_false(mode_menu_shown)
        assert.are.same({ source_id = "local", page = 1, type = "POPULAR" }, fetched_options)
    end)

    it("searches a source with user text and rejects blank searches without calling the API", function()
        local fetched_options
        local client, state = newClient({
            api = {
                fetchMangaForSource = function(_, options)
                    fetched_options = options
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Sousou no Frieren" },
                        },
                    }
                end,
            },
            ui = {
                showSourceSearchPrompt = function(_, onSearch)
                    onSearch("  ")
                    onSearch(" frieren ")
                end,
                showMangaMenu = function() end,
            },
        })

        client:showSourceSearchPrompt({ id = "s1", name = "MangaDex", lang = "en" })

        assert.are.equal("Enter a search query.", state.shown_messages[1])
        assert.are.same({
            source_id = "s1",
            page = 1,
            type = "SEARCH",
            query = "frieren",
        }, fetched_options)
    end)

    it("rejects blank global searches without calling source APIs", function()
        local api_called = false
        local client, state = newClient({
            api = {
                fetchMangaForSource = function()
                    api_called = true
                    return { ok = true, manga = {} }
                end,
            },
            ui = {
                showGlobalSearchPrompt = function(onSearch)
                    onSearch("  ")
                end,
            },
        })

        client:showGlobalSearch({
            { id = "s1", name = "MangaDex", lang = "en" },
        })

        assert.is_false(api_called)
        assert.are.same({ "Enter a search query." }, state.shown_messages)
    end)

    it("shows one global search summary per visible source and isolates source errors", function()
        local fetched_options = {}
        local shown_summaries
        local opened_options
        local client = newClient({
            api = {
                fetchMangaForSource = function(_, options)
                    table.insert(fetched_options, options)
                    if options.source_id == "s1" then
                        return {
                            ok = true,
                            manga = {
                                { id = "m1", title = "Frieren Beyond Journey's End" },
                                { id = "m2", title = "Frieren Side Story" },
                            },
                            has_next_page = true,
                        }
                    end
                    if options.source_id == "s2" then
                        return { ok = true, manga = {} }
                    end
                    return { ok = false, error = "Timed out" }
                end,
            },
            ui = {
                showGlobalSearchPrompt = function(onSearch)
                    onSearch(" frieren ")
                end,
                showGlobalSearchResultsMenu = function(summaries, onSelect, menu_options)
                    shown_summaries = summaries
                    assert.are.same({ title_bar_left_icon = "appbar.filebrowser" }, menu_options)
                    onSelect(summaries[1])
                    onSelect(summaries[2])
                    onSelect(summaries[3])
                end,
                showMangaMenu = function(_, _, options)
                    opened_options = options
                end,
            },
            home_menu_options = { title_bar_left_icon = "appbar.filebrowser" },
        })

        client:showGlobalSearch({
            { id = "s1", display_name = "MangaDex (EN)", name = "MangaDex", lang = "en" },
            { id = "s2", display_name = "ComicK (EN)", name = "ComicK", lang = "en" },
            { id = "s3", name = "Some Source", lang = "en" },
        })

        assert.are.same({
            { source_id = "s1", page = 1, type = "SEARCH", query = "frieren" },
            { source_id = "s2", page = 1, type = "SEARCH", query = "frieren" },
            { source_id = "s3", page = 1, type = "SEARCH", query = "frieren" },
            { source_id = "s1", page = 1, type = "SEARCH", query = "frieren" },
        }, fetched_options)
        assert.are.equal("ok", shown_summaries[1].status)
        assert.are.equal("Frieren Beyond Journey's End", shown_summaries[1].first_match.title)
        assert.are.equal("empty", shown_summaries[2].status)
        assert.are.equal("error", shown_summaries[3].status)
        assert.are.equal("Timed out", shown_summaries[3].error)
        assert.are.equal("MangaDex (EN) - Search: frieren - Page 1", opened_options.title)
        assert.are.equal("appbar.filebrowser", opened_options.title_bar_left_icon)
        assert.is_function(opened_options.on_next_page)
    end)

    it("lets global search drill into hidden first-page results when later pages exist", function()
        local fetched_options = {}
        local shown_summaries
        local opened_options
        local client = newClient({
            browse_settings = {
                hide_in_library_results = true,
            },
            api = {
                fetchMangaForSource = function(_, options)
                    table.insert(fetched_options, options)
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Already Added", in_library = true },
                        },
                        has_next_page = true,
                    }
                end,
            },
            ui = {
                showGlobalSearchPrompt = function(onSearch)
                    onSearch(" frieren ")
                end,
                showGlobalSearchResultsMenu = function(summaries, onSelect)
                    shown_summaries = summaries
                    onSelect(summaries[1])
                end,
                showMangaMenu = function(_, _, options)
                    opened_options = options
                end,
            },
        })

        client:showGlobalSearch({
            { id = "s1", display_name = "MangaDex (EN)", name = "MangaDex", lang = "en" },
        })

        assert.are.same({
            { source_id = "s1", page = 1, type = "SEARCH", query = "frieren" },
            { source_id = "s1", page = 1, type = "SEARCH", query = "frieren" },
        }, fetched_options)
        assert.are.equal("pageable_empty", shown_summaries[1].status)
        assert.is_true(shown_summaries[1].has_next_page)
        assert.are.equal("frieren", shown_summaries[1].query)
        assert.are.equal("MangaDex (EN) - Search: frieren - Page 1", opened_options.title)
        assert.is_function(opened_options.on_next_page)
    end)

    it("shows a friendly latest message when unknown support is rejected as unsupported", function()
        local messages
        local latest_options
        local client, state = newClient({
            api = {
                fetchMangaForSource = function(_, options)
                    latest_options = options
                    return { ok = false, error = "GraphQL error: latest not supported" }
                end,
            },
            ui = {},
        })

        client:showMangaForSource({ id = "s1", name = "MangaDex", lang = "en" }, { type = "LATEST" })
        messages = state.shown_messages

        assert.are.same({ source_id = "s1", page = 1, type = "LATEST" }, latest_options)
        assert.are.equal("Latest manga is not supported by this source.", messages[#messages])
    end)

    it("preserves unrelated latest errors when support is unknown", function()
        local errors = {
            "Authentication failed: invalid token",
            "Network error: connection timed out",
            "Could not parse Suwayomi response.",
        }

        for _, error_message in ipairs(errors) do
            local client, state = newClient({
                api = {
                    fetchMangaForSource = function()
                        return { ok = false, error = error_message }
                    end,
                },
                ui = {},
            })

            client:showMangaForSource({ id = "s1", name = "MangaDex", lang = "en" }, { type = "LATEST" })

            assert.are.equal(error_message, state.shown_messages[#state.shown_messages])
        end
    end)

    it("detects only latest unsupported error text", function()
        local Client = require("suwayomi/client")
        local client = Client:new{}

        assert.is_true(client:isLatestUnsupportedError("Source returned unsupported latest mode"))
        assert.is_true(client:isLatestUnsupportedError("GraphQL error: latest not supported"))
        assert.is_true(client:isLatestUnsupportedError("This source does not support latest"))

        assert.is_false(client:isLatestUnsupportedError("Authentication failed: invalid token"))
        assert.is_false(client:isLatestUnsupportedError("Network error: connection timed out"))
        assert.is_false(client:isLatestUnsupportedError("Could not parse Suwayomi response."))
    end)

    it("hides in-library browse results when browse settings request it", function()
        local shown_manga
        local client, state = newClient({
            browse_settings = {
                hide_in_library_results = true,
            },
            api = {
                fetchMangaForSource = function(_, options)
                    assert.are.same({ source_id = "s1", page = 1, type = "POPULAR" }, options)
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Already Added", in_library = true },
                            { id = "m2", title = "New Find", in_library = false },
                            { id = "m3", title = "Unknown State" },
                        },
                    }
                end,
            },
            ui = {
                showMangaMenu = function(manga)
                    shown_manga = manga
                end,
            },
        })

        client:showMangaForSource({ id = "s1" })

        assert.are.same({
            { id = "m2", title = "New Find", in_library = false },
            { id = "m3", title = "Unknown State" },
        }, shown_manga)
        assert.are.equal(2, state.log_events[1].manga_count)
    end)

    it("passes browse result title and paging callbacks that preserve source context", function()
        local fetched_options = {}
        local menu_options = {}
        local client = newClient({
            api = {
                fetchMangaForSource = function(_, options)
                    table.insert(fetched_options, options)
                    return {
                        ok = true,
                        manga = {
                            { id = "m" .. tostring(options.page), title = "Page " .. tostring(options.page) },
                        },
                        has_next_page = options.page < 2,
                    }
                end,
            },
            ui = {
                showMangaMenu = function(_, _, options)
                    table.insert(menu_options, options)
                end,
            },
        })

        client:showMangaForSource({
            id = "s1",
            display_name = "MangaDex (EN)",
            raw_name = "MangaDex",
            lang = "en",
        }, {
            type = "SEARCH",
            query = "frieren",
            skip_mode_menu = true,
        })
        menu_options[1].on_next_page()
        menu_options[2].on_previous_page()

        assert.are.same({
            { source_id = "s1", page = 1, type = "SEARCH", query = "frieren" },
            { source_id = "s1", page = 2, type = "SEARCH", query = "frieren" },
            { source_id = "s1", page = 1, type = "SEARCH", query = "frieren" },
        }, fetched_options)
        assert.are.equal("MangaDex (EN) - Search: frieren - Page 1", menu_options[1].title)
        assert.are.equal("MangaDex (EN) - Search: frieren - Page 2", menu_options[2].title)
        assert.is_nil(menu_options[1].on_previous_page)
        assert.is_function(menu_options[1].on_next_page)
        assert.is_function(menu_options[2].on_previous_page)
        assert.is_nil(menu_options[2].on_next_page)
    end)

    it("shows a next-page-only menu when hide-in-library filters all visible rows", function()
        local shown_manga
        local shown_options
        local client, state = newClient({
            browse_settings = {
                hide_in_library_results = true,
            },
            api = {
                fetchMangaForSource = function(_, options)
                    assert.are.same({ source_id = "s1", page = 1, type = "POPULAR" }, options)
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Already Added", in_library = true },
                        },
                        has_next_page = true,
                    }
                end,
            },
            ui = {
                showMangaMenu = function(manga, _, options)
                    shown_manga = manga
                    shown_options = options
                end,
            },
        })

        client:showMangaForSource({
            id = "s1",
            display_name = "MangaDex (EN)",
        }, {
            skip_mode_menu = true,
        })

        assert.are.equal(0, #shown_manga)
        assert.are.equal("MangaDex (EN) - Popular - Page 1", shown_options.title)
        assert.is_nil(shown_options.on_previous_page)
        assert.is_function(shown_options.on_next_page)
        assert.are.equal(0, #state.shown_messages)
    end)

    it("shows a previous-page-only menu when page greater than one filters all visible rows", function()
        local shown_manga
        local shown_options
        local client, state = newClient({
            browse_settings = {
                hide_in_library_results = true,
            },
            api = {
                fetchMangaForSource = function(_, options)
                    assert.are.same({ source_id = "s1", page = 2, type = "SEARCH", query = "frieren" }, options)
                    return {
                        ok = true,
                        manga = {
                            { id = "m2", title = "Already Added Too", in_library = true },
                        },
                        has_next_page = false,
                    }
                end,
            },
            ui = {
                showMangaMenu = function(manga, _, options)
                    shown_manga = manga
                    shown_options = options
                end,
            },
        })

        client:showMangaForSource({
            id = "s1",
            display_name = "MangaDex (EN)",
        }, {
            type = "SEARCH",
            query = "frieren",
            page = 2,
            skip_mode_menu = true,
        })

        assert.are.equal(0, #shown_manga)
        assert.are.equal("MangaDex (EN) - Search: frieren - Page 2", shown_options.title)
        assert.is_function(shown_options.on_previous_page)
        assert.is_nil(shown_options.on_next_page)
        assert.are.equal(0, #state.shown_messages)
    end)

    it("formats compact library manga rows", function()
        local Client = require("suwayomi/client")
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

    it("skips the category picker for a single category and opens selected library manga actions", function()
        local shown_manga
        local shown_menu_options
        local client, state = newClient({
            home_menu_options = { title_bar_left_icon = "appbar.filebrowser" },
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
        assert.are.same({ title_bar_left_icon = "appbar.filebrowser" }, shown_menu_options)
        assert.are.equal("m1", state.shown_manga_actions().id)
        assert.are.equal("library_manga_loaded", state.log_events[#state.log_events].event)
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
        assert.are.equal("Sousou no Frieren (0 unread / MangaDex EN)", updated_manga[1].menu_text)
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

    it("keeps browsed manga visible and refreshes row state after library changes", function()
        local updated_manga
        local client = newClient({
            api = {
                fetchMangaForSource = function()
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Sousou no Frieren", in_library = false },
                        },
                    }
                end,
            },
            ui = {
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                    return { name = "browse-menu" }
                end,
                updateMangaMenu = function(_, manga)
                    updated_manga = manga
                end,
            },
        })

        client.plugin.showMangaActions = function(_, manga, options)
            manga.in_library = true
            options.onMangaUpdated(manga)
        end

        client:showMangaForSource({ id = "s1", display_name = "MangaDex (EN)" })

        assert.are.equal(1, #updated_manga)
        assert.is_true(updated_manga[1].in_library)
    end)

    it("opens browse result manga actions without changing the action surface", function()
        local shown_manga_action_options
        local client = newClient({
            home_menu_options = {
                title_bar_left_icon = "appbar.filebrowser",
                on_title_bar_left_tap = function() end,
            },
            api = {
                fetchMangaForSource = function()
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Sousou no Frieren", in_library = false },
                        },
                    }
                end,
            },
            ui = {
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                    return { name = "browse-menu" }
                end,
            },
        })

        client.plugin.showMangaActions = function(_, _, options)
            shown_manga_action_options = options
        end

        client:showMangaForSource({ id = "s1", display_name = "MangaDex (EN)" })

        assert.is_function(shown_manga_action_options.onMangaUpdated)
        assert.is_nil(shown_manga_action_options.title_bar_left_icon)
        assert.is_nil(shown_manga_action_options.on_title_bar_left_tap)
    end)

    it("shows categories when multiple categories are present and filters selected category manga", function()
        local shown_categories
        local shown_category_menu_options
        local shown_manga
        local client = newClient({
            home_menu_options = { title_bar_left_icon = "appbar.filebrowser" },
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
        assert.are.same({ title_bar_left_icon = "appbar.filebrowser" }, shown_category_menu_options)
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
