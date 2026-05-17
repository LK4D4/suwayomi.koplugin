package.path = "?.lua;" .. package.path

local helper = require("spec/support/suwayomi_client_spec_helper")

describe("suwayomi/client source manga flows", function()
    after_each(function()
        helper.clearClientModules()
    end)

    local newClient = helper.newClient
    local buildSourceMangaSubprocessFake = helper.buildSourceMangaSubprocessFake
    local buildChapterCountSubprocessFake = helper.buildChapterCountSubprocessFake

    it("loads manga for a source and opens the selected manga actions through the plugin", function()
        local captured_title_options
        local client, state = newClient({
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
                    assert.are.equal("Popular - Page 1", menu_options.title)
                    assert.are.equal("appbar.menu", menu_options.title_bar_left_icon)
                    assert.are.equal("https://suwayomi.example", menu_options.thumbnail_credentials.server_url)
                    onSelect(manga[1])
                    return { name = "browse-results-menu" }
                end,
            },
            capture_title_options = function(menu_options)
                captured_title_options = menu_options
            end,
            title_menu_options = { title_bar_left_icon = "appbar.menu" },
        })

        client:showMangaForSource({
            id = "s1",
            display_name = "MangaDex (EN)",
            raw_name = "MangaDex",
            lang = "en",
        })

        assert.are.same({}, state.loading_messages)
        assert.are.same({
            id = "s1",
            displayName = "MangaDex (EN)",
            name = "MangaDex",
            lang = "en",
        }, state.shown_manga_actions().source)
        assert.are.equal("manga_loaded", state.log_events[1].event)
        assert.are.equal(1, state.log_events[1].manga_count)
        assert.are.equal("browse-results", state.tracked_screens[1].route_id)
        assert.are.equal("source-manga-loading", state.tracked_screens[1].widget.name)
        assert.are.equal("MangaDex (EN) - Popular - Page 1", captured_title_options.title)
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
                    assert.are.same({ title_bar_left_icon = "appbar.menu" }, menu_options)
                    onSelect("POPULAR")
                end,
                showMangaMenu = function() end,
            },
            title_menu_options = { title_bar_left_icon = "appbar.menu" },
        })

        client:showMangaForSource({ id = "s1", name = "MangaDex", lang = "en" })

        assert.are.same({ source_id = "s1", page = 1, type = "POPULAR" }, fetched_options)
        assert.are.same({}, state.loading_messages)
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

    it("starts source search in a cancellable subprocess without blocking the UI", function()
        local subprocess_job, started, canceled = buildSourceMangaSubprocessFake()
        local api_called = false
        local shown_manga
        local shown_options
        local client = newClient({
            subprocess_job = subprocess_job,
            source_manga_worker = {},
            ffi_util = {},
            ui_manager = {},
            api = {
                fetchMangaForSource = function()
                    api_called = true
                    return { ok = true, manga = {} }
                end,
            },
            ui = {
                showMangaMenu = function(manga, _, menu_options)
                    shown_manga = manga
                    shown_options = menu_options
                    return { name = "source-search-menu" }
                end,
            },
            title_menu_options = { title_bar_left_icon = "appbar.menu" },
        })

        client:showMangaForSource({
            id = "s1",
            display_name = "MangaDex (EN)",
            lang = "en",
        }, {
            type = "SEARCH",
            query = "frieren",
            skip_mode_menu = true,
        })

        assert.is_false(api_called)
        assert.are.equal("Loading manga...", shown_manga[1].title)
        assert.are.equal("Search - Page 1", shown_options.title)
        assert.is_function(shown_options.close_callback)
        assert.is_function(shown_options.on_cancel_source_manga)
        assert.are.equal("s1", started[1].source.id)
        assert.are.same({
            type = "SEARCH",
            query = "frieren",
            page = 1,
        }, started[1].browse_options)

        shown_options.close_callback()

        assert.are.equal(started[1], canceled[1])
    end)

    it("does not fall back to UI-thread source manga requests when the worker cannot start", function()
        local api_called = false
        local client, state = newClient({
            disable_source_manga_runtime = true,
            api = {
                fetchMangaForSource = function()
                    api_called = true
                    return { ok = true, manga = {} }
                end,
            },
            ui = {
                showMangaMenu = function()
                    error("unexpected manga menu")
                end,
            },
        })

        client:showMangaForSource({
            id = "s1",
            display_name = "MangaDex (EN)",
            lang = "en",
        }, {
            skip_mode_menu = true,
        })

        assert.is_false(api_called)
        assert.are.same({ "Could not start manga loading." }, state.shown_messages)
    end)

    it("does not fall back to UI-thread source manga requests when subprocess startup fails", function()
        local api_called = false
        local updated_manga
        local updated_options
        local client, state = newClient({
            api = {
                fetchMangaForSource = function()
                    api_called = true
                    return { ok = true, manga = {} }
                end,
            },
            subprocess_job = {
                buildResultPath = function(prefix)
                    return "/settings/" .. tostring(prefix) .. ".json"
                end,
                start = function()
                    return nil
                end,
            },
            source_manga_worker = {
                run = function()
                    api_called = true
                end,
                readResult = function()
                    return { ok = true, manga = {} }
                end,
            },
            ffi_util = {},
            ui_manager = {},
            ui = {
                showMangaMenu = function()
                    return { name = "source-manga-loading" }
                end,
                updateMangaMenu = function(_, manga, _, menu_options)
                    updated_manga = manga
                    updated_options = menu_options
                end,
            },
        })

        client:showMangaForSource({
            id = "s1",
            display_name = "MangaDex (EN)",
            lang = "en",
        }, {
            skip_mode_menu = true,
        })

        assert.is_false(api_called)
        assert.are.same({}, state.shown_messages)
        assert.are.equal("Could not start manga loading.", updated_manga[1].title)
        assert.are.equal("Popular - Page 1", updated_options.title)
    end)

    it("shows a source manga start error when subprocess startup throws", function()
        local api_called = false
        local updated_manga
        local updated_options
        local client, state = newClient({
            subprocess_job = {
                buildResultPath = function(prefix)
                    return "/settings/" .. tostring(prefix) .. ".json"
                end,
                start = function()
                    error("launcher failed")
                end,
            },
            source_manga_worker = {
                run = function()
                    api_called = true
                end,
                readResult = function()
                    return { ok = true, manga = {} }
                end,
            },
            ffi_util = {},
            ui_manager = {},
            ui = {
                showMangaMenu = function()
                    return { name = "source-manga-loading" }
                end,
                updateMangaMenu = function(_, manga, _, menu_options)
                    updated_manga = manga
                    updated_options = menu_options
                end,
            },
        })

        assert.has_no.errors(function()
            client:showMangaForSource({
                id = "s1",
                display_name = "MangaDex (EN)",
                lang = "en",
            }, {
                skip_mode_menu = true,
            })
        end)

        assert.is_false(api_called)
        assert.are.same({}, state.shown_messages)
        assert.are.equal("Could not start manga loading.", updated_manga[1].title)
        assert.are.equal("Popular - Page 1", updated_options.title)
    end)

    it("updates the source search menu when the subprocess returns manga", function()
        local subprocess_job, started = buildSourceMangaSubprocessFake()
        local updated_manga
        local updated_options
        local client = newClient({
            subprocess_job = subprocess_job,
            source_manga_worker = {},
            ffi_util = {},
            ui_manager = {},
            ui = {
                showMangaMenu = function()
                    return { name = "source-search-menu" }
                end,
                updateMangaMenu = function(_, manga, _, menu_options)
                    updated_manga = manga
                    updated_options = menu_options
                end,
            },
        })

        client:showMangaForSource({
            id = "s1",
            display_name = "MangaDex (EN)",
            lang = "en",
        }, {
            type = "SEARCH",
            query = "frieren",
            skip_mode_menu = true,
        })
        started[1].on_finish(started[1], {
            ok = true,
            manga = {
                { id = "m1", title = "Frieren" },
            },
            has_next_page = true,
        })

        assert.are.equal("Frieren", updated_manga[1].title)
        assert.is_function(updated_options.on_next_page)
        assert.is_nil(updated_options.on_cancel_source_manga)
    end)

    it("shows source search failures with retry and edit actions", function()
        local subprocess_job, started = buildSourceMangaSubprocessFake()
        local updated_rows
        local search_prompt_options
        local client, state = newClient({
            subprocess_job = subprocess_job,
            source_manga_worker = {},
            ffi_util = {},
            ui_manager = {},
            ui = {
                showMangaMenu = function()
                    return { name = "source-search-menu" }
                end,
                updateMangaMenu = function(_, manga)
                    updated_rows = manga
                end,
                showSourceSearchPrompt = function(_, _, options)
                    search_prompt_options = options
                end,
            },
        })

        client:showMangaForSource({
            id = "s1",
            display_name = "ComicK",
            lang = "en",
        }, {
            type = "SEARCH",
            query = "frieren",
            skip_mode_menu = true,
        })
        started[1].on_finish(started[1], {
            ok = false,
            source = { id = "s1", display_name = "ComicK", lang = "en" },
            browse_options = { type = "SEARCH", query = "frieren", page = 1 },
            error = "HTTP 403 from ComicK.",
        })

        assert.are.same({ "Search failed for ComicK: HTTP 403 from ComicK." }, state.shown_messages)
        assert.are.equal("Search failed for ComicK: HTTP 403 from ComicK.", updated_rows[1].text)
        assert.are.equal("Retry", updated_rows[2].text)
        assert.are.equal("Edit search", updated_rows[3].text)

        updated_rows[2].callback()
        assert.are.equal(2, #started)
        assert.are.equal("frieren", started[2].browse_options.query)

        updated_rows[3].callback()
        assert.are.equal("frieren", search_prompt_options.query)
    end)

    it("shows source search timeout failures with retry and edit actions", function()
        local subprocess_job, started = buildSourceMangaSubprocessFake()
        local updated_rows
        local client, state = newClient({
            subprocess_job = subprocess_job,
            source_manga_worker = {},
            ffi_util = {},
            ui_manager = {},
            ui = {
                showMangaMenu = function()
                    return { name = "source-search-menu" }
                end,
                updateMangaMenu = function(_, manga)
                    updated_rows = manga
                end,
            },
        })

        client:showMangaForSource({
            id = "s1",
            display_name = "ComicK",
            lang = "en",
        }, {
            type = "SEARCH",
            query = "frieren",
            skip_mode_menu = true,
        })
        started[1].on_timeout(started[1])

        assert.are.same({ "Search failed for ComicK: Timed out." }, state.shown_messages)
        assert.are.equal("Search failed for ComicK: Timed out.", updated_rows[1].text)
        assert.are.equal("Retry", updated_rows[2].text)
        assert.are.equal("Edit search", updated_rows[3].text)
    end)

    it("shows source search start failures with retry and edit actions", function()
        local updated_rows
        local client = newClient({
            disable_source_manga_runtime = true,
            subprocess_job = {
                buildResultPath = function()
                    return "/settings/source_manga.json"
                end,
                start = function()
                    return nil
                end,
                cancel = function() end,
            },
            source_manga_worker = {},
            ffi_util = {},
            ui_manager = {},
            ui = {
                showMangaMenu = function()
                    return { name = "source-search-menu" }
                end,
                updateMangaMenu = function(_, manga)
                    updated_rows = manga
                end,
            },
        })

        client:showMangaForSource({
            id = "s1",
            display_name = "ComicK",
            lang = "en",
        }, {
            type = "SEARCH",
            query = "frieren",
            skip_mode_menu = true,
        })

        assert.are.equal("Search failed for ComicK: Could not start manga loading.", updated_rows[1].text)
        assert.are.equal("Retry", updated_rows[2].text)
        assert.are.equal("Edit search", updated_rows[3].text)
    end)

    it("ignores stale source manga results after a newer source load starts", function()
        local subprocess_job, started, canceled = buildSourceMangaSubprocessFake()
        local menus = {}
        local updates = {}
        local client = newClient({
            subprocess_job = subprocess_job,
            source_manga_worker = {},
            chapter_count_worker = "disabled",
            ffi_util = {},
            ui_manager = {},
            ui = {
                showMangaMenu = function()
                    local menu = { name = "source-search-menu-" .. tostring(#menus + 1) }
                    table.insert(menus, menu)
                    return menu
                end,
                updateMangaMenu = function(menu, manga, _, menu_options)
                    table.insert(updates, {
                        menu = menu,
                        manga = manga,
                        menu_options = menu_options,
                    })
                end,
            },
        })

        client:showMangaForSource({
            id = "s1",
            display_name = "MangaDex (EN)",
            lang = "en",
        }, {
            type = "SEARCH",
            query = "old",
            skip_mode_menu = true,
        })
        client:showMangaForSource({
            id = "s2",
            display_name = "OtherDex",
            lang = "en",
        }, {
            type = "SEARCH",
            query = "new",
            skip_mode_menu = true,
        })

        started[2].on_finish(started[2], {
            ok = true,
            manga = {
                { id = "m2", title = "New Result" },
            },
        })
        started[1].on_finish(started[1], {
            ok = true,
            manga = {
                { id = "m1", title = "Old Result" },
            },
        })

        assert.are.equal(started[1], canceled[1])
        assert.are.equal(1, #updates)
        assert.are.equal(menus[2], updates[1].menu)
        assert.are.equal("New Result", updates[1].manga[1].title)
        assert.are.equal("Search - Page 1", updates[1].menu_options.title)
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
            ui = {
                showMangaMenu = function()
                    return { name = "source-manga-loading" }
                end,
                updateMangaMenu = function() end,
            },
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
                ui = {
                    showMangaMenu = function()
                        return { name = "source-manga-loading" }
                    end,
                    updateMangaMenu = function() end,
                },
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
        assert.are.equal("Search - Page 1", menu_options[1].title)
        assert.are.equal("Search - Page 2", menu_options[2].title)
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
        assert.are.equal("Popular - Page 1", shown_options.title)
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
        assert.are.equal("Search - Page 2", shown_options.title)
        assert.is_function(shown_options.on_previous_page)
        assert.is_nil(shown_options.on_next_page)
        assert.are.equal(0, #state.shown_messages)
    end)

    it("keeps browsed manga visible and refreshes row state after library changes", function()
        local updated_manga
        local selected = false
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
                updateMangaMenu = function(_, manga, onSelect)
                    updated_manga = manga
                    if not selected then
                        selected = true
                        onSelect(manga[1])
                    end
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

    it("fetches zero and unknown browse chapter counts in the background", function()
        local subprocess_job, started = buildChapterCountSubprocessFake()
        local shown_manga
        local updated_manga = {}
        local client = newClient({
            subprocess_job = subprocess_job,
            chapter_count_worker = {},
            ffi_util = {},
            ui_manager = {},
            chapter_count_max_active = 1,
            api = {
                fetchMangaForSource = function()
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Unknown Count", chapter_count = 0 },
                            { id = "m2", title = "Known Count", chapter_count = 7 },
                            { id = "m3", title = "Missing Count" },
                        },
                    }
                end,
            },
            ui = {
                showMangaMenu = function(manga)
                    shown_manga = manga
                    return { name = "browse-menu" }
                end,
                updateMangaMenu = function(_, manga)
                    shown_manga = manga
                    table.insert(updated_manga, {
                        m1 = {
                            loading = manga[1].chapter_count_loading,
                            count = manga[1].chapter_count,
                            verified = manga[1].chapter_count_verified,
                        },
                        m2 = {
                            loading = manga[2].chapter_count_loading,
                            count = manga[2].chapter_count,
                        },
                        m3 = {
                            loading = manga[3].chapter_count_loading,
                            count = manga[3].chapter_count,
                            verified = manga[3].chapter_count_verified,
                        },
                    })
                end,
            },
        })

        client:showMangaForSource({ id = "s1", display_name = "MangaDex (EN)" }, {
            type = "SEARCH",
            query = "frieren",
            skip_mode_menu = true,
        })

        assert.are.equal(3, #shown_manga)
        assert.are.equal("m1", started[1].manga_id)
        assert.are.equal(1, #started)
        assert.is_true(updated_manga[2].m1.loading)
        assert.are.equal(0, updated_manga[2].m1.count)
        assert.is_nil(updated_manga[2].m2.loading)
        assert.are.equal(7, updated_manga[2].m2.count)
        assert.is_nil(updated_manga[2].m3.loading)

        started[1].on_finish(started[1], {
            ok = true,
            manga_id = "m1",
            chapter_count = 5,
        })

        assert.are.equal(5, updated_manga[3].m1.count)
        assert.is_true(updated_manga[3].m1.verified)
        assert.is_nil(updated_manga[3].m1.loading)
        assert.are.equal("m3", started[2].manga_id)
        assert.is_true(updated_manga[4].m3.loading)

        started[2].on_finish(started[2], {
            ok = true,
            manga_id = "m3",
            chapter_count = 0,
        })

        assert.are.equal(0, updated_manga[5].m3.count)
        assert.is_true(updated_manga[5].m3.verified)
        assert.is_nil(updated_manga[5].m3.loading)
    end)

    it("keeps timed out browse chapter count slots active until cleanup", function()
        local subprocess_job, started = buildChapterCountSubprocessFake()
        local updated_manga = {}
        local client = newClient({
            subprocess_job = subprocess_job,
            chapter_count_worker = {},
            ffi_util = {},
            ui_manager = {},
            chapter_count_max_active = 1,
            api = {
                fetchMangaForSource = function()
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Unknown Count", chapter_count = 0 },
                            { id = "m2", title = "Missing Count" },
                        },
                    }
                end,
            },
            ui = {
                showMangaMenu = function()
                    return { name = "browse-menu" }
                end,
                updateMangaMenu = function(_, manga)
                    table.insert(updated_manga, {
                        first_error = manga[1].chapter_count_error,
                        second_loading = manga[2].chapter_count_loading,
                    })
                end,
            },
        })

        client:showMangaForSource({ id = "s1", display_name = "MangaDex (EN)" }, {
            skip_mode_menu = true,
        })

        assert.are.equal("m1", started[1].manga_id)
        started[1].on_timeout(started[1])

        assert.is_true(updated_manga[#updated_manga].first_error)
        assert.is_nil(updated_manga[#updated_manga].second_loading)
        assert.are.equal(1, #started)

        started[1].on_cleanup(started[1])

        assert.are.equal("m2", started[2].manga_id)
        assert.is_true(updated_manga[#updated_manga].second_loading)
    end)

    it("opens browse result manga actions without changing the action surface", function()
        local shown_manga_action_options
        local client = newClient({
            title_menu_options = {
                title_bar_left_icon = "appbar.menu",
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
end)
