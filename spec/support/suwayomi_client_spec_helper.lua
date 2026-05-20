local M = {}

local buildImmediateSourceMangaRuntime
local buildImmediateNetworkRequestJob

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
    local shown_loading_messages = {}
    local closed_loading_messages = {}
    local shown_messages = {}
    local opened_manga
    local shown_manga_actions
    local shown_manga_action_options
    local scheduled_sync_credentials
    local shown_onboarding_setup
    local log_events = {}
    local tracked_screens = {}
    local network_requests
    if not options.network_request_job
        and options.api
        and options.api.fetchCategories
        and options.api.fetchLibraryManga
    then
        options.network_request_job, network_requests = buildImmediateNetworkRequestJob(options.api)
    end
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
            showLoadingMessage = function(_, message)
                local loading_message = { message = message }
                table.insert(shown_loading_messages, message)
                return loading_message
            end,
            closeLoadingMessage = function(_, loading_message)
                table.insert(closed_loading_messages, loading_message)
            end,
            showMessage = function(_, message)
                table.insert(shown_messages, message)
            end,
            showOnboardingSetup = function(_, setup_options)
                shown_onboarding_setup = setup_options or {}
            end,
            showChaptersForManga = function(_, manga)
                opened_manga = manga
            end,
            showMangaActions = function(_, manga, action_options)
                shown_manga_actions = manga
                shown_manga_action_options = action_options
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
        network_request_job = options.network_request_job,
        gettext = function(text)
            return text
        end,
    }

    return client, {
        loading_messages = loading_messages,
        shown_loading_messages = shown_loading_messages,
        closed_loading_messages = closed_loading_messages,
        network_requests = network_requests or {},
        shown_messages = shown_messages,
        log_events = log_events,
        opened_manga = function()
            return opened_manga
        end,
        shown_manga_actions = function()
            return shown_manga_actions
        end,
        shown_manga_action_options = function()
            return shown_manga_action_options
        end,
        scheduled_sync_credentials = function()
            return scheduled_sync_credentials
        end,
        shown_onboarding_setup = function()
            return shown_onboarding_setup
        end,
        tracked_screens = tracked_screens,
    }
end

buildImmediateNetworkRequestJob = function(api)
    local started = {}
    local fake = {}

    local function fetchLibraryMangaPages(credentials)
        local page_size = 100
        local offset = 0
        local all_manga = {}
        local total_count

        while true do
            local result = api.fetchLibraryManga(credentials, {
                first = page_size,
                offset = offset,
            })
            if not result.ok then
                return result
end

            local page_manga = result.manga or {}
            for _, manga in ipairs(page_manga) do
                table.insert(all_manga, manga)
            end
            total_count = tonumber(result.total_count) or #all_manga

            if #page_manga == 0 or #page_manga < page_size or #all_manga >= total_count then
                break
            end
            offset = offset + page_size
        end

        return {
            ok = true,
            manga = all_manga,
            total_count = total_count,
        }
    end

    function fake.start(options)
        table.insert(started, options)
        local request = options.request or {}
        local result
        if request.action == "fetch_library_categories" then
            result = api.fetchCategories(options.credentials)
        elseif request.action == "fetch_library_manga_pages" then
            result = fetchLibraryMangaPages(options.credentials)
        else
            result = { ok = false, error = "Unexpected network request." }
        end
        if options.on_finish then
            options.on_finish(result)
        end
        return { pid = 2468 }
    end

    return fake, started
end
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
        active.on_cleanup = options.on_cleanup
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
        active.on_cleanup = options.on_cleanup
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
        active.on_cleanup = options.on_cleanup
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
        active.on_cleanup = options.on_cleanup
        table.insert(started, active)
        return active
    end

    function fake.cancel(active)
        active.canceled = true
        table.insert(canceled, active)
    end

    return fake, started, canceled
end

function M.clearClientModules()
    for _, module_name in ipairs({
        "suwayomi/client",
        "suwayomi/client/util",
        "suwayomi/client/runtime",
        "suwayomi/client/browse_chapter_counts",
        "suwayomi/client/source_manga",
        "suwayomi/client/global_search",
        "suwayomi/client/library",
    }) do
        package.loaded[module_name] = nil
    end
end

M.newClient = newClient
M.buildGlobalSearchSubprocessFake = buildGlobalSearchSubprocessFake
M.buildSourceMangaSubprocessFake = buildSourceMangaSubprocessFake
M.buildChapterCountSubprocessFake = buildChapterCountSubprocessFake
M.buildImmediateNetworkRequestJob = buildImmediateNetworkRequestJob

return M
