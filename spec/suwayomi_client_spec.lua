package.path = "?.lua;" .. package.path

describe("suwayomi/client", function()
    after_each(function()
        package.loaded["suwayomi/client"] = nil
    end)

    local buildImmediateSourceMangaRuntime

    local function newClient(options)
        local Client = require("suwayomi/client")
        options = options or {}
        if not options.disable_source_manga_runtime
            and not options.source_manga_worker
            and options.api
            and options.api.fetchMangaForSource
        then
            local source_manga_job, source_manga_worker = buildImmediateSourceMangaRuntime(options.api)
            if options.subprocess_job then
                local original_job = options.subprocess_job
                options.subprocess_job = {
                    buildResultPath = original_job.buildResultPath or source_manga_job.buildResultPath,
                    start = function(job_options)
                        local active = job_options and job_options.active or {}
                        if tostring(active.result_path or ""):match("source_manga") then
                            return source_manga_job.start(job_options)
                        end
                        return original_job.start(job_options)
                    end,
                    cancel = function(active)
                        if tostring(active and active.result_path or ""):match("source_manga") then
                            return source_manga_job.cancel(active)
                        end
                        if original_job.cancel then
                            return original_job.cancel(active)
                        end
                    end,
                }
            else
                options.subprocess_job = source_manga_job
            end
            options.source_manga_worker = source_manga_worker
            options.ffi_util = options.ffi_util or {}
            options.ui_manager = options.ui_manager or {}
            options.chapter_count_worker = options.chapter_count_worker or "disabled"
            if options.ui and options.ui.showMangaMenu then
                local original_show_manga_menu = options.ui.showMangaMenu
                options.ui.showMangaMenu = function(manga, onSelectCallback, menu_options)
                    if manga
                        and #manga == 1
                        and manga[1]
                        and manga[1].title == "Loading manga..."
                    then
                        return { name = "source-manga-loading" }
                    end
                    return original_show_manga_menu(manga, onSelectCallback, menu_options)
                end
                options.ui.updateMangaMenu = options.ui.updateMangaMenu or function(_, manga, onSelectCallback, menu_options)
                    return original_show_manga_menu(manga, onSelectCallback, menu_options)
                end
            end
        end
        local loading_messages = {}
        local shown_messages = {}
        local opened_manga
        local shown_manga_actions
        local scheduled_sync_credentials
        local log_events = {}
        local tracked_screens = {}
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
            subprocess_job = options.subprocess_job,
            global_search_worker = options.global_search_worker,
            source_manga_worker = options.source_manga_worker,
            chapter_count_worker = options.chapter_count_worker,
            ffi_util = options.ffi_util,
            ui_manager = options.ui_manager,
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
                getTitleBarMenuOptions = function(_, menu_options)
                    if options.capture_title_options then
                        options.capture_title_options(menu_options)
                    end
                    return options.title_menu_options
                end,
                trackSuwayomiScreen = function(_, route_id, widget)
                    table.insert(tracked_screens, { route_id = route_id, widget = widget })
                    if options.trackSuwayomiScreen then
                        options.trackSuwayomiScreen(route_id, widget)
                    end
                end,
                global_search_max_active_sources = options.global_search_max_active_sources,
                global_search_poll_interval_seconds = options.global_search_poll_interval_seconds,
                global_search_source_timeout_seconds = options.global_search_source_timeout_seconds,
                chapter_count_max_active = options.chapter_count_max_active,
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
            tracked_screens = tracked_screens,
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
                    assert.are.equal("MangaDex (EN) - Popular - Page 1", menu_options.title)
                    assert.are.equal("appbar.menu", menu_options.title_bar_left_icon)
                    assert.are.equal("https://suwayomi.example", menu_options.thumbnail_credentials.server_url)
                    onSelect(manga[1])
                    return { name = "browse-results-menu" }
                end,
            },
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

    local function buildGlobalSearchSubprocessFake()
        local started = {}
        local canceled = {}
        local fake = {}

        function fake.buildResultPath(prefix)
            return "/settings/" .. tostring(prefix) .. "_" .. tostring(#started + 1) .. ".json"
        end

        function fake.start(options)
            local active = options.active or {}
            active.on_finish = options.on_finish
            active.on_timeout = options.on_timeout
            active.on_cancel = options.on_cancel
            active.read_result = options.read_result
            active.run = options.run
            table.insert(started, active)
            return active
        end

        function fake.cancel(active)
            active.canceled = true
            table.insert(canceled, active)
            if active.on_cancel then
                active.on_cancel(active)
            end
        end

        return fake, started, canceled
    end

    local function buildSourceMangaSubprocessFake()
        local started = {}
        local canceled = {}
        local fake = {}

        function fake.buildResultPath(prefix)
            return "/settings/" .. tostring(prefix) .. "_" .. tostring(#started + 1) .. ".json"
        end

        function fake.start(options)
            local active = options.active or {}
            active.on_finish = options.on_finish
            active.on_timeout = options.on_timeout
            active.read_result = options.read_result
            active.run = options.run
            table.insert(started, active)
            return active
        end

        function fake.cancel(active)
            active.canceled = true
            table.insert(canceled, active)
        end

        return fake, started, canceled
    end

    buildImmediateSourceMangaRuntime = function(api)
        local results = {}
        local fake = {}
        local worker = {}

        function fake.buildResultPath(prefix)
            return "/settings/" .. tostring(prefix) .. ".json"
        end

        function fake.start(options)
            local active = options.active or {}
            active.on_finish = options.on_finish
            active.on_timeout = options.on_timeout
            active.read_result = options.read_result
            active.run = options.run
            if not tostring(active.result_path or ""):match("source_manga") then
                return active
            end
            if options.run then
                options.run(active.result_path, active)
            end
            if options.on_finish then
                options.on_finish(active, options.read_result and options.read_result(active.result_path, active) or nil)
            end
            return active
        end

        function fake.cancel(active)
            if active then
                active.canceled = true
            end
        end

        function worker:run(credentials, source, browse_options, result_path)
            source = type(source) == "table" and source or {}
            browse_options = type(browse_options) == "table" and browse_options or {}
            local request_options = {
                source_id = source.id,
                page = tonumber(browse_options.page) or 1,
                type = browse_options.type or "POPULAR",
            }
            if request_options.type == "SEARCH" then
                request_options.query = browse_options.query
            end
            local api_result = api.fetchMangaForSource(credentials, request_options)
            results[result_path] = {
                ok = api_result and api_result.ok == true,
                source = source,
                browse_options = browse_options,
                manga = api_result and api_result.manga or {},
                has_next_page = api_result and api_result.has_next_page == true,
                error = api_result and api_result.error or nil,
            }
        end

        function worker:readResult(result_path)
            return results[result_path]
        end

        return fake, worker
    end

    local function buildChapterCountSubprocessFake()
        local started = {}
        local canceled = {}
        local fake = {}

        function fake.buildResultPath(prefix)
            return "/settings/" .. tostring(prefix) .. "_" .. tostring(#started + 1) .. ".json"
        end

        function fake.start(options)
            local active = options.active or {}
            active.on_finish = options.on_finish
            active.on_timeout = options.on_timeout
            table.insert(started, active)
            return active
        end

        function fake.cancel(active)
            active.canceled = true
            table.insert(canceled, active)
        end

        return fake, started, canceled
    end

    it("shows global search immediately and starts local source first", function()
        local subprocess_job, started = buildGlobalSearchSubprocessFake()
        local shown_summaries
        local shown_options
        local client = newClient({
            subprocess_job = subprocess_job,
            global_search_worker = {},
            ffi_util = {},
            ui_manager = {},
            ui = {
                showGlobalSearchPrompt = function(onSearch)
                    onSearch(" frieren ")
                end,
                showGlobalSearchResultsMenu = function(summaries, _, menu_options)
                    shown_summaries = summaries
                    shown_options = menu_options
                    return { name = "global-search" }
                end,
            },
            title_menu_options = { title_bar_left_icon = "appbar.menu" },
        })

        client:showGlobalSearch({
            { id = "s1", display_name = "MangaDex (EN)", name = "MangaDex", lang = "en" },
            { id = "local", name = "Local source", lang = "localsourcelang" },
            { id = "s2", name = "Comick", lang = "en" },
        })

        assert.are.equal("local", shown_summaries[1].source.id)
        assert.are.equal("searching", shown_summaries[1].status)
        assert.are.equal("s1", shown_summaries[2].source.id)
        assert.are.equal("s2", shown_summaries[3].source.id)
        assert.are.equal("local", started[1].source.id)
        assert.are.equal("s1", started[2].source.id)
        assert.are.equal("s2", started[3].source.id)
        assert.are.equal("appbar.menu", shown_options.title_bar_left_icon)
        assert.is_function(shown_options.close_callback)
        assert.is_function(shown_options.on_cancel_search)
    end)

    it("updates partial global search results and opens successful rows", function()
        local subprocess_job, started = buildGlobalSearchSubprocessFake()
        local updated_summaries
        local selected_callback
        local opened_options
        local client = newClient({
            subprocess_job = subprocess_job,
            global_search_worker = {},
            ffi_util = {},
            ui_manager = {},
            global_search_max_active_sources = 1,
            api = {
                fetchMangaForSource = function()
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Frieren" },
                        },
                        has_next_page = true,
                    }
                end,
            },
            ui = {
                showGlobalSearchPrompt = function(onSearch)
                    onSearch(" frieren ")
                end,
                showGlobalSearchResultsMenu = function(_, onSelect)
                    selected_callback = onSelect
                    return { name = "global-search" }
                end,
                updateGlobalSearchResultsMenu = function(_, summaries, onSelect)
                    updated_summaries = summaries
                    selected_callback = onSelect
                end,
                showMangaMenu = function(_, _, options)
                    opened_options = options
                end,
            },
        })

        client:showGlobalSearch({
            { id = "local", name = "Local source", lang = "localsourcelang" },
            { id = "s1", display_name = "MangaDex (EN)", name = "MangaDex", lang = "en" },
        })
        started[1].on_finish(started[1], {
            ok = true,
            manga = {
                { id = "m1", title = "Frieren" },
            },
            has_next_page = true,
            query = "frieren",
        })

        assert.are.equal("ok", updated_summaries[1].status)
        assert.are.equal(1, updated_summaries[1].result_count)
        assert.is_true(updated_summaries[1].has_next_page)
        assert.are.equal("searching", updated_summaries[2].status)
        assert.are.equal("s1", started[2].source.id)

        selected_callback(updated_summaries[1])
        assert.are.equal("Local source - Search: frieren - Page 1", opened_options.title)
        assert.is_function(opened_options.on_next_page)
    end)

    it("marks timed out global search sources and starts queued work", function()
        local subprocess_job, started = buildGlobalSearchSubprocessFake()
        local updated_summaries
        local client = newClient({
            subprocess_job = subprocess_job,
            global_search_worker = {},
            ffi_util = {},
            ui_manager = {},
            global_search_max_active_sources = 1,
            ui = {
                showGlobalSearchPrompt = function(onSearch)
                    onSearch(" frieren ")
                end,
                showGlobalSearchResultsMenu = function()
                    return { name = "global-search" }
                end,
                updateGlobalSearchResultsMenu = function(_, summaries)
                    updated_summaries = summaries
                end,
            },
        })

        client:showGlobalSearch({
            { id = "s1", name = "MangaDex", lang = "en" },
            { id = "s2", name = "Comick", lang = "en" },
        })
        started[1].on_timeout(started[1])

        assert.are.equal("timed_out", updated_summaries[1].status)
        assert.are.equal("searching", updated_summaries[2].status)
        assert.are.equal("s2", started[2].source.id)
    end)

    it("cancels active and pending global search work", function()
        local subprocess_job, started, canceled = buildGlobalSearchSubprocessFake()
        local shown_options
        local updated_summaries
        local client = newClient({
            subprocess_job = subprocess_job,
            global_search_worker = {},
            ffi_util = {},
            ui_manager = {},
            global_search_max_active_sources = 1,
            ui = {
                showGlobalSearchPrompt = function(onSearch)
                    onSearch(" frieren ")
                end,
                showGlobalSearchResultsMenu = function(_, _, menu_options)
                    shown_options = menu_options
                    return { name = "global-search" }
                end,
                updateGlobalSearchResultsMenu = function(_, summaries)
                    updated_summaries = summaries
                end,
            },
        })

        client:showGlobalSearch({
            { id = "s1", name = "MangaDex", lang = "en" },
            { id = "s2", name = "Comick", lang = "en" },
        })
        shown_options.close_callback()

        assert.are.equal(started[1], canceled[1])
        assert.are.equal("canceled", updated_summaries[1].status)
        assert.are.equal("canceled", updated_summaries[2].status)
        assert.are.equal(1, #started)
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
        assert.are.equal("MangaDex (EN) - Search: frieren - Page 1", shown_options.title)
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
        assert.are.equal("MangaDex (EN) - Popular - Page 1", updated_options.title)
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
end)
