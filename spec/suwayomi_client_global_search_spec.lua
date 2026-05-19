package.path = "?.lua;" .. package.path

local helper = require("spec/support/suwayomi_client_spec_helper")

describe("suwayomi/client global search flows", function()
    after_each(function()
        helper.clearClientModules()
    end)

    local newClient = helper.newClient
    local buildGlobalSearchSubprocessFake = helper.buildGlobalSearchSubprocessFake

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
            {
                id = "s1",
                display_name = "MangaDex (EN)",
                name = "MangaDex",
                lang = "en",
                icon_url = "/icons/md.png",
            },
            { id = "local", name = "Local source", lang = "localsourcelang", icon_url = "/icons/local.png" },
            { id = "s2", name = "Comick", lang = "en", icon_url = "/icons/comick.png" },
        })

        assert.are.equal("local", shown_summaries[1].source.id)
        assert.are.equal("/icons/local.png", shown_summaries[1].source.icon_url)
        assert.are.equal("searching", shown_summaries[1].status)
        assert.are.equal("s1", shown_summaries[2].source.id)
        assert.are.equal("s2", shown_summaries[3].source.id)
        assert.are.equal("local", started[1].source.id)
        assert.are.equal("s1", started[2].source.id)
        assert.are.equal("s2", started[3].source.id)
        assert.are.equal("appbar.menu", shown_options.title_bar_left_icon)
        assert.are.equal("https://suwayomi.example", shown_options.thumbnail_credentials.server_url)
        assert.is_function(shown_options.close_callback)
        assert.is_function(shown_options.on_cancel_search)
    end)

    it("updates partial global search results and opens successful rows", function()
        local subprocess_job, started = buildGlobalSearchSubprocessFake()
        local updated_summaries
        local updated_options
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
                updateGlobalSearchResultsMenu = function(_, summaries, onSelect, menu_options)
                    updated_summaries = summaries
                    selected_callback = onSelect
                    updated_options = menu_options
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
        assert.are.equal("https://suwayomi.example", updated_options.thumbnail_credentials.server_url)

        selected_callback(updated_summaries[1])
        assert.are.equal("Search", opened_options.title)
        assert.is_nil(opened_options.on_next_page)
        assert.is_function(opened_options.on_page_changed)
    end)

    it("marks a global source error and continues queued sources when subprocess startup throws", function()
        local started = {}
        local shown_summaries
        local update_count = 0
        local subprocess_job = {
            buildResultPath = function(prefix)
                return "/settings/" .. tostring(prefix) .. "_" .. tostring(#started + 1) .. ".json"
            end,
            start = function(options)
                local active = options.active or {}
                if active.source.id == "s1" then
                    error("launcher failed")
                end
                active.on_finish = options.on_finish
                table.insert(started, active)
                return active
            end,
            cancel = function() end,
        }
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
                showGlobalSearchResultsMenu = function(summaries)
                    shown_summaries = summaries
                    return { name = "global-search" }
                end,
                updateGlobalSearchResultsMenu = function(_, summaries)
                    update_count = update_count + 1
                    shown_summaries = summaries
                end,
            },
        })

        assert.has_no.errors(function()
            client:showGlobalSearch({
                { id = "s1", name = "MangaDex", lang = "en" },
                { id = "s2", name = "Comick", lang = "en" },
            })
        end)

        assert.are.equal("error", shown_summaries[1].status)
        assert.are.equal("Could not start search.", shown_summaries[1].error)
        assert.are.equal(1, update_count)
        assert.are.equal("s2", started[1].source.id)
        assert.are.equal("searching", shown_summaries[2].status)

        started[1].on_finish(started[1], {
            ok = true,
            manga = {
                { id = "m1", title = "Frieren" },
            },
            query = "frieren",
        })

        assert.are.equal("ok", shown_summaries[2].status)
        assert.are.equal(1, shown_summaries[2].result_count)
    end)

    it("retries failed global search sources from the results menu", function()
        local started = {}
        local menu_options
        local shown_summaries
        local fail_first_start = true
        local subprocess_job = {
            buildResultPath = function(prefix)
                return "/settings/" .. tostring(prefix) .. "_" .. tostring(#started + 1) .. ".json"
            end,
            start = function(options)
                local active = options.active or {}
                if fail_first_start then
                    fail_first_start = false
                    error("launcher failed")
                end
                active.on_finish = options.on_finish
                table.insert(started, active)
                return active
            end,
            cancel = function() end,
        }
        local client = newClient({
            subprocess_job = subprocess_job,
            global_search_worker = {},
            ffi_util = {},
            ui_manager = {},
            ui = {
                showGlobalSearchPrompt = function(onSearch)
                    onSearch(" frieren ")
                end,
                showGlobalSearchResultsMenu = function(summaries, _, options)
                    shown_summaries = summaries
                    menu_options = options
                    return { name = "global-search" }
                end,
                updateGlobalSearchResultsMenu = function(_, summaries, _, options)
                    shown_summaries = summaries
                    menu_options = options
                end,
            },
        })

        client:showGlobalSearch({
            { id = "s1", name = "ComicK", lang = "en" },
        })

        assert.are.equal("error", shown_summaries[1].status)
        assert.are.equal("Could not start search.", shown_summaries[1].error)

        menu_options.on_retry_summary(shown_summaries[1])

        assert.are.equal(1, #started)
        assert.are.equal("s1", started[1].source.id)
        assert.are.equal("searching", shown_summaries[1].status)
    end)

    it("finishes a global search when retry startup fails again", function()
        local menu_options
        local shown_summaries
        local subprocess_job = {
            buildResultPath = function(prefix)
                return "/settings/" .. tostring(prefix) .. ".json"
            end,
            start = function()
                error("launcher failed")
            end,
            cancel = function() end,
        }
        local client = newClient({
            subprocess_job = subprocess_job,
            global_search_worker = {},
            ffi_util = {},
            ui_manager = {},
            ui = {
                showGlobalSearchPrompt = function(onSearch)
                    onSearch(" frieren ")
                end,
                showGlobalSearchResultsMenu = function(summaries, _, options)
                    shown_summaries = summaries
                    menu_options = options
                    return { name = "global-search" }
                end,
                updateGlobalSearchResultsMenu = function(_, summaries, _, options)
                    shown_summaries = summaries
                    menu_options = options
                end,
            },
        })

        client:showGlobalSearch({
            { id = "s1", name = "ComicK", lang = "en" },
        })
        menu_options.on_retry_summary(shown_summaries[1])

        assert.are.equal("error", shown_summaries[1].status)
        assert.are.equal("Could not start search.", shown_summaries[1].error)
        assert.is_nil(menu_options.on_cancel_search)
    end)

    it("keeps timed out global search slots active until cleanup", function()
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
        assert.are.equal(1, #started)

        started[1].on_cleanup(started[1])

        assert.are.equal("s2", started[2].source.id)
    end)

    it("ignores late global search finish after a source times out", function()
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
        started[1].on_finish(started[1], {
            ok = true,
            manga = {
                { id = "m1", title = "Frieren" },
            },
            query = "frieren",
        })

        assert.are.equal("timed_out", updated_summaries[1].status)
        assert.are.equal(0, updated_summaries[1].result_count)
        assert.are.equal("searching", updated_summaries[2].status)
        assert.are.equal(1, #started)
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
end)
