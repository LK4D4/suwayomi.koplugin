-- Boundary: library and browse orchestration client.
--
-- Responsibility: coordinate API calls, loading messages, browse/library menus,
-- and controller callbacks that are not KOReader plugin lifecycle glue.
-- Owned state: injected API/UI/settings/debug/plugin dependencies.
-- Dependencies: supplied through new() so specs can stub runtime services.
-- External data: API results and settings values are checked before rendering.

local SuwayomiClient = {}
SuwayomiClient.__index = SuwayomiClient

function SuwayomiClient:new(options)
    options = options or {}
    return setmetatable({
        api = options.api,
        ui = options.ui,
        subprocess_job = options.subprocess_job,
        global_search_worker = options.global_search_worker,
        source_manga_worker = options.source_manga_worker,
        chapter_count_worker = options.chapter_count_worker,
        ffi_util = options.ffi_util,
        ui_manager = options.ui_manager,
        settings = options.settings,
        debug = options.debug,
        plugin = options.plugin,
        gettext = options.gettext or function(text) return text end,
    }, self)
end

function SuwayomiClient:translate(text)
    return self.gettext(text)
end

local function copyOptions(target, source)
    for key, value in pairs(source or {}) do
        target[key] = value
    end
    return target
end

function SuwayomiClient:time(operation, context, callback)
    if self.debug and self.debug.time then
        return self.debug.time(operation, context, callback)
    end
    return callback()
end

function SuwayomiClient:log(event)
    if self.debug and self.debug.log then
        self.debug.log(event)
    end
end

function SuwayomiClient:getTitleBarMenuOptions(options)
    if self.plugin and self.plugin.getTitleBarMenuOptions then
        return self.plugin:getTitleBarMenuOptions(options)
    end
    return nil
end

function SuwayomiClient:trackScreen(route_id, widget)
    if widget and self.plugin and self.plugin.trackSuwayomiScreen then
        self.plugin:trackSuwayomiScreen(route_id, widget)
    end
    return widget
end

function SuwayomiClient:attachSourceToManga(manga, source)
    if type(manga) ~= "table" or type(source) ~= "table" then
        return manga
    end

    manga.source = manga.source or {}
    manga.source.id = manga.source.id or source.id
    manga.source.displayName = manga.source.displayName or source.displayName or source.display_name
    manga.source.name = manga.source.name or source.raw_name or source.name
    manga.source.lang = manga.source.lang or source.lang
    return manga
end

function SuwayomiClient:mangaBelongsToCategory(manga, category)
    if not category or not category.id then
        return true
    end
    for _, candidate in ipairs(manga.categories or {}) do
        if tostring(candidate.id) == tostring(category.id) then
            return true
        end
    end
    return false
end

function SuwayomiClient:filterLibraryMangaByCategory(manga_list, category)
    if not category or not category.id then
        return manga_list or {}
    end

    local filtered = {}
    for _, manga in ipairs(manga_list or {}) do
        if self:mangaBelongsToCategory(manga, category) then
            table.insert(filtered, manga)
        end
    end
    return filtered
end

function SuwayomiClient:loadBrowseSettings()
    if self.settings and self.settings.loadBrowseSettings then
        return self.settings:loadBrowseSettings()
    end
    return {
        show_nsfw_sources = false,
        hide_in_library_results = false,
    }
end

function SuwayomiClient:filterBrowseManga(manga_list)
    local browse_settings = self:loadBrowseSettings()
    if not browse_settings.hide_in_library_results then
        return manga_list or {}
    end

    local filtered = {}
    for _, manga in ipairs(manga_list or {}) do
        if manga.in_library ~= true then
            table.insert(filtered, manga)
        end
    end
    return filtered
end

function SuwayomiClient:getSourceDisplayName(source)
    if type(source) ~= "table" then
        return self:translate("Source")
    end
    return source.display_name
        or source.displayName
        or source.name
        or source.raw_name
        or tostring(source.id)
end

function SuwayomiClient:getSourceModeTitle(options)
    local mode = options.type or "POPULAR"
    if mode == "SEARCH" then
        return self:translate("Search") .. ": " .. tostring(options.query or "")
    end
    if mode == "LATEST" then
        return self:translate("Latest")
    end
    return self:translate("Popular")
end

function SuwayomiClient:buildBrowseResultTitle(source, options)
    return self:getSourceDisplayName(source)
        .. " - "
        .. self:getSourceModeTitle(options)
        .. " - "
        .. self:translate("Page")
        .. " "
        .. tostring(options.page or 1)
end

function SuwayomiClient:buildBrowseResultMenuOptions(source, options, has_next_page)
    local title = self:buildBrowseResultTitle(source, options)
    local menu_options = copyOptions({}, self:getTitleBarMenuOptions({ title = title }))
    menu_options.title = title

    if (options.page or 1) > 1 then
        menu_options.on_previous_page = function()
            return self:showMangaForSource(source, {
                type = options.type,
                query = options.query,
                page = (options.page or 1) - 1,
                skip_mode_menu = true,
            })
        end
    end
    if has_next_page == true then
        menu_options.on_next_page = function()
            return self:showMangaForSource(source, {
                type = options.type,
                query = options.query,
                page = (options.page or 1) + 1,
                skip_mode_menu = true,
            })
        end
    end

    return menu_options
end

function SuwayomiClient:shouldFetchBrowseChapterCount(manga)
    if type(manga) ~= "table" or manga.id == nil then
        return false
    end
    if manga.chapter_count_loading == true or manga.chapter_count_verified == true then
        return false
    end
    local count = tonumber(manga.chapter_count)
    return count == nil or count == 0
end

function SuwayomiClient:resolveChapterCountRuntime()
    local ok_job, job = pcall(function()
        return self:getSubprocessJob()
    end)
    local ok_worker, worker = pcall(function()
        return self:getChapterCountWorker()
    end)
    local ok_ffi, ffi_util = pcall(function()
        return self:getFFIUtil()
    end)
    local ok_ui, ui_manager = pcall(function()
        return self:getUIManager()
    end)

    if not ok_job or not ok_worker or not ok_ffi or not ok_ui then
        return nil
    end
    if type(job) ~= "table" or type(worker) ~= "table" then
        return nil
    end
    return {
        job = job,
        worker = worker,
        ffi_util = ffi_util,
        ui_manager = ui_manager,
    }
end

function SuwayomiClient:applyBrowseChapterCountResult(manga, result)
    if type(manga) ~= "table" then
        return
    end
    manga.chapter_count_loading = nil
    if result and result.ok == true then
        manga.chapter_count = tonumber(result.chapter_count) or 0
        manga.chapter_count_verified = true
        manga.chapter_count_error = nil
    else
        manga.chapter_count_error = true
    end
end

function SuwayomiClient:startNextBrowseChapterCountJobs(state)
    if not state or state.canceled then
        return
    end

    while (state.active_count or 0) < state.max_active and state.next_index <= #state.queue do
        local manga = state.queue[state.next_index]
        state.next_index = state.next_index + 1
        if self:shouldFetchBrowseChapterCount(manga) then
            manga.chapter_count_loading = true
            if state.refresh then
                state.refresh()
            end

            local manga_id = tostring(manga.id)
            local ok_start, active = pcall(function()
                return state.runtime.job.start({
                    active = {
                        manga = manga,
                        manga_id = manga_id,
                        result_path = state.runtime.job.buildResultPath
                            and state.runtime.job.buildResultPath("chapter_count")
                            or nil,
                    },
                    ffi_util = state.runtime.ffi_util,
                    ui_manager = state.runtime.ui_manager,
                    poll_interval_seconds = self:getChapterCountPollIntervalSeconds(),
                    timeout_seconds = self:getChapterCountTimeoutSeconds(),
                    run = function(path)
                        state.runtime.worker:run(state.credentials, manga_id, path)
                    end,
                    read_result = function(path)
                        return state.runtime.worker:readResult(path)
                    end,
                    on_finish = function(finished_active, result)
                        if state.canceled then
                            return
                        end
                        state.active_jobs[finished_active.manga_id] = nil
                        state.active_count = math.max((state.active_count or 1) - 1, 0)
                        self:applyBrowseChapterCountResult(finished_active.manga, result)
                        if state.refresh then
                            state.refresh()
                        end
                        self:startNextBrowseChapterCountJobs(state)
                    end,
                    on_timeout = function(timed_out_active)
                        if state.canceled then
                            return
                        end
                        state.active_jobs[timed_out_active.manga_id] = nil
                        state.active_count = math.max((state.active_count or 1) - 1, 0)
                        timed_out_active.canceled = true
                        self:applyBrowseChapterCountResult(timed_out_active.manga, {
                            ok = false,
                            error = self:translate("Could not load chapters."),
                        })
                        if state.refresh then
                            state.refresh()
                        end
                        self:startNextBrowseChapterCountJobs(state)
                    end,
                })
            end)
            if not ok_start then
                active = nil
            end

            if active then
                state.active_jobs[manga_id] = active
                state.active_count = (state.active_count or 0) + 1
            else
                self:applyBrowseChapterCountResult(manga, {
                    ok = false,
                    error = self:translate("Could not load chapters."),
                })
                if state.refresh then
                    state.refresh()
                end
            end
        end
    end
end

function SuwayomiClient:startBrowseChapterCountEnrichment(credentials, manga_list, refresh, runtime)
    if not self.ui or not self.ui.updateMangaMenu then
        return nil
    end

    runtime = runtime or self:resolveChapterCountRuntime()
    if not runtime then
        return nil
    end

    local queue = {}
    for _, manga in ipairs(manga_list or {}) do
        if self:shouldFetchBrowseChapterCount(manga) then
            table.insert(queue, manga)
        end
    end
    if #queue == 0 then
        return nil
    end

    local state = {
        credentials = credentials,
        queue = queue,
        next_index = 1,
        active_jobs = {},
        active_count = 0,
        max_active = self:getChapterCountMaxActive(),
        runtime = runtime,
        refresh = refresh,
    }
    self:startNextBrowseChapterCountJobs(state)
    return state
end

function SuwayomiClient:cancelBrowseChapterCountEnrichment(state)
    if not state or state.canceled then
        return
    end
    state.canceled = true
    local job = state.runtime and state.runtime.job
    if job and job.cancel then
        for _, active in pairs(state.active_jobs or {}) do
            job.cancel(active)
        end
    end
    state.active_jobs = {}
    state.active_count = 0
end

function SuwayomiClient:isLocalSource(source)
    return source and source.lang == "localsourcelang"
end

function SuwayomiClient:getSubprocessJob()
    if not self.subprocess_job then
        self.subprocess_job = require("suwayomi/subprocess/job")
    end
    return self.subprocess_job
end

function SuwayomiClient:getGlobalSearchWorker()
    if not self.global_search_worker then
        self.global_search_worker = require("suwayomi/browse/global_search_worker")
    end
    return self.global_search_worker
end

function SuwayomiClient:getSourceMangaWorker()
    if not self.source_manga_worker then
        self.source_manga_worker = require("suwayomi/browse/source_manga_worker")
    end
    return self.source_manga_worker
end

function SuwayomiClient:getChapterCountWorker()
    if not self.chapter_count_worker then
        self.chapter_count_worker = require("suwayomi/browse/chapter_count_worker")
    end
    return self.chapter_count_worker
end

function SuwayomiClient:getFFIUtil()
    if not self.ffi_util then
        self.ffi_util = require("ffi/util")
    end
    return self.ffi_util
end

function SuwayomiClient:getUIManager()
    if not self.ui_manager then
        self.ui_manager = require("ui/uimanager")
    end
    return self.ui_manager
end

function SuwayomiClient:getGlobalSearchMaxActiveSources()
    local configured = self.plugin and tonumber(self.plugin.global_search_max_active_sources)
    if configured and configured > 0 then
        return configured
    end
    return 3
end

function SuwayomiClient:getGlobalSearchPollIntervalSeconds()
    return (self.plugin and self.plugin.global_search_poll_interval_seconds) or 0.5
end

function SuwayomiClient:getGlobalSearchSourceTimeoutSeconds()
    return (self.plugin and self.plugin.global_search_source_timeout_seconds) or 15
end

function SuwayomiClient:getSourceMangaPollIntervalSeconds()
    return (self.plugin and self.plugin.source_manga_poll_interval_seconds)
        or self:getGlobalSearchPollIntervalSeconds()
end

function SuwayomiClient:getSourceMangaTimeoutSeconds()
    return (self.plugin and self.plugin.source_manga_timeout_seconds)
        or self:getGlobalSearchSourceTimeoutSeconds()
end

function SuwayomiClient:getChapterCountMaxActive()
    local configured = self.plugin and tonumber(self.plugin.chapter_count_max_active)
    if configured and configured > 0 then
        return configured
    end
    return 2
end

function SuwayomiClient:getChapterCountPollIntervalSeconds()
    return (self.plugin and self.plugin.chapter_count_poll_interval_seconds) or 0.5
end

function SuwayomiClient:getChapterCountTimeoutSeconds()
    return (self.plugin and self.plugin.chapter_count_timeout_seconds) or 15
end

function SuwayomiClient:sortGlobalSearchSources(sources)
    local local_sources = {}
    local remote_sources = {}
    for _, source in ipairs(sources or {}) do
        if self:isLocalSource(source) then
            table.insert(local_sources, source)
        else
            table.insert(remote_sources, source)
        end
    end
    for _, source in ipairs(remote_sources) do
        table.insert(local_sources, source)
    end
    return local_sources
end

local function trim(text)
    return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function SuwayomiClient:isLatestUnsupportedError(error_text)
    local message = tostring(error_text or ""):lower()
    return message:match("unsupported%s+latest") ~= nil
        or message:match("latest%s+not%s+supported") ~= nil
        or message:match("does%s+not%s+support%s+latest") ~= nil
end

function SuwayomiClient:buildLibraryCategoryChoices(categories)
    local choices = {
        {
            id = nil,
            name = self:translate("All manga"),
        },
    }
    for _, category in ipairs(categories or {}) do
        table.insert(choices, category)
    end
    return choices
end

function SuwayomiClient:fetchLibraryMangaPages(credentials)
    local page_size = 100
    local offset = 0
    local all_manga = {}
    local total_count

    while true do
        local result = self.api.fetchLibraryManga(credentials, {
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

function SuwayomiClient:showLibraryManga(category, credentials)
    credentials = credentials or self.settings:load()
    local result = self.plugin:withLoadingMessage("library-manga", self:translate("Loading library manga..."), function()
        return self:fetchLibraryMangaPages(credentials)
    end)
    if not result then
        return
    end
    if not result.ok then
        self.plugin:showMessage(self:translate(result.error))
        return
    end

    local manga = self:filterLibraryMangaByCategory(result.manga or {}, category)
    self:log({
        operation = "showLibrary",
        event = "library_manga_loaded",
        category_id = category and category.id,
        manga_count = #manga,
        total_count = result.total_count,
    })

    if #manga == 0 then
        if category and category.id then
            self.plugin:showMessage(self:translate("This category has no manga."))
        else
            self.plugin:showMessage(self:translate("Your Suwayomi library is empty."))
        end
        return
    end

    local library_manga = manga
    local menu_options = self:getTitleBarMenuOptions({
        title = self:translate("Suwayomi Library"),
    }) or {}
    menu_options.thumbnail_credentials = credentials
    local library_menu
    local pending_library_menu_refresh = false
    local function refreshLibraryMangaMenu()
        for index = #library_manga, 1, -1 do
            if type(library_manga[index]) == "table" and library_manga[index].in_library == false then
                table.remove(library_manga, index)
            end
        end
        if not library_menu then
            pending_library_menu_refresh = true
            return
        end
        if self.ui.updateLibraryMangaMenu then
            self.ui.updateLibraryMangaMenu(library_menu, library_manga, function(selected_manga)
                if self.plugin.showMangaActions then
                    self.plugin:showMangaActions(selected_manga, {
                        onMangaUpdated = refreshLibraryMangaMenu,
                    })
                else
                    self.plugin:showChaptersForManga(selected_manga)
                end
            end, menu_options)
        end
    end

    library_menu = self.ui.showLibraryMangaMenu(library_manga, function(selected_manga)
        if self.plugin.showMangaActions then
            self.plugin:showMangaActions(selected_manga, {
                onMangaUpdated = refreshLibraryMangaMenu,
            })
        else
            self.plugin:showChaptersForManga(selected_manga)
        end
    end, menu_options)
    self:trackScreen("library", library_menu)
    if pending_library_menu_refresh then
        refreshLibraryMangaMenu()
    end
end

function SuwayomiClient:showLibrary()
    return self:time("showLibrary", {}, function()
        local credentials = self.settings:load()
        if not credentials.server_url or credentials.server_url == "" then
            self.plugin:showMessage(self:translate("Set up your Suwayomi server login first."))
            return
        end
        if self.plugin.schedulePendingReadSync then
            self.plugin:schedulePendingReadSync(credentials)
        end

        local result = self.plugin:withLoadingMessage("library-categories", self:translate("Loading library..."), function()
            return self.api.fetchCategories(credentials)
        end)
        if not result then
            return
        end
        if not result.ok then
            self.plugin:showMessage(self:translate(result.error))
            return
        end

        local categories = result.categories or {}
        local picker_behavior = self.settings.loadLibraryCategoryPickerBehavior
            and self.settings:loadLibraryCategoryPickerBehavior()
            or "automatic"
        local should_show_category_picker = picker_behavior == "always"
            or (picker_behavior == "automatic" and #categories > 1)

        if should_show_category_picker and #categories > 0 then
            local category_menu = self.ui.showLibraryCategoryMenu(self:buildLibraryCategoryChoices(categories), function(category)
                self:showLibraryManga(category, credentials)
            end, self:getTitleBarMenuOptions({
                title = self:translate("Suwayomi Library"),
            }))
            self:trackScreen("library-categories", category_menu)
            return
        end

        self:showLibraryManga(nil, credentials)
    end)
end

function SuwayomiClient:showSourceSearchPrompt(source)
    if not self.ui.showSourceSearchPrompt then
        return
    end

    return self.ui.showSourceSearchPrompt(source, function(query)
        local search_query = trim(query)
        if search_query == "" then
            self.plugin:showMessage(self:translate("Enter a search query."))
            return
        end
        self:showMangaForSource(source, {
            type = "SEARCH",
            query = search_query,
            skip_mode_menu = true,
        })
    end)
end

function SuwayomiClient:searchSourceForSummary(credentials, source, query)
    local ok, result = pcall(function()
        return self.api.fetchMangaForSource(credentials, {
            source_id = source.id,
            page = 1,
            type = "SEARCH",
            query = query,
        })
    end)
    if not ok then
        return {
            source = source,
            status = "error",
            error = tostring(result),
        }
    end
    if not result or not result.ok then
        return {
            source = source,
            status = "error",
            error = result and result.error or self:translate("Could not load manga."),
        }
    end

    local manga = self:filterBrowseManga(result.manga or {})
    if #manga == 0 then
        return {
            source = source,
            status = result.has_next_page and "pageable_empty" or "empty",
            manga = manga,
            has_next_page = result.has_next_page,
            query = query,
        }
    end
    return {
        source = source,
        status = "ok",
        first_match = manga[1],
        manga = manga,
        has_next_page = result.has_next_page,
        query = query,
    }
end

function SuwayomiClient:isGlobalSearchComplete(search)
    return search
        and not search.canceled
        and (search.active_count or 0) == 0
        and (search.next_index or 1) > #(search.sources or {})
end

function SuwayomiClient:buildGlobalSearchMenuOptions(search)
    local actions = {}
    local cancel
    if not search.finished and not search.canceled then
        cancel = function()
            self:cancelGlobalSearch(search)
        end
        table.insert(actions, { id = "cancel_search", text = self:translate("Cancel search") })
    end
    local menu_options = copyOptions({}, self:getTitleBarMenuOptions({
        title = self:translate("Global search"),
        actions = actions,
        onSelect = function(action)
            if action and action.id == "cancel_search" and cancel then
                return cancel()
            end
        end,
    }))
    if cancel then
        menu_options.close_callback = cancel
        menu_options.on_cancel_search = cancel
    end
    menu_options.thumbnail_credentials = search and search.credentials
    return menu_options
end

function SuwayomiClient:updateGlobalSearchMenu(search)
    if not search or not search.menu or not self.ui.updateGlobalSearchResultsMenu then
        return
    end
    self.ui.updateGlobalSearchResultsMenu(search.menu, search.summaries, function(summary)
        return self:openGlobalSearchSummary(summary, search.query)
    end, self:buildGlobalSearchMenuOptions(search))
end

function SuwayomiClient:finishGlobalSearchIfComplete(search)
    if self:isGlobalSearchComplete(search) then
        search.finished = true
        self:updateGlobalSearchMenu(search)
    end
end

function SuwayomiClient:applyGlobalSearchResult(search, index, result)
    local summary = search.summaries[index]
    if not summary then
        return
    end
    if not result or result.ok ~= true then
        summary.status = "error"
        summary.error = result and result.error or self:translate("Could not load manga.")
        summary.manga = {}
        summary.result_count = 0
        return
    end

    local manga = self:filterBrowseManga(result.manga or {})
    summary.manga = manga
    summary.first_match = manga[1]
    summary.result_count = #manga
    summary.has_next_page = result.has_next_page == true
    summary.query = result.query or search.query
    if #manga == 0 then
        summary.status = summary.has_next_page and "pageable_empty" or "empty"
    else
        summary.status = "ok"
    end
end

function SuwayomiClient:openGlobalSearchSummary(summary, fallback_query)
    if summary and (summary.status == "ok" or summary.status == "pageable_empty") then
        return self:showMangaForSource(summary.source, {
            type = "SEARCH",
            query = summary.query or fallback_query,
            page = 1,
            skip_mode_menu = true,
        })
    end
end

function SuwayomiClient:markGlobalSearchCanceled(search)
    for _, summary in ipairs(search.summaries or {}) do
        if summary.status == "searching" then
            summary.status = "canceled"
        end
    end
end

function SuwayomiClient:cancelGlobalSearch(search)
    if not search or search.canceled or search.finished then
        return
    end
    search.canceled = true
    local job = self:getSubprocessJob()
    for _, active in pairs(search.active_jobs or {}) do
        job.cancel(active)
    end
    search.active_jobs = {}
    search.active_count = 0
    self:markGlobalSearchCanceled(search)
    self:updateGlobalSearchMenu(search)
end

function SuwayomiClient:startNextGlobalSearchJobs(search)
    if not search or search.canceled then
        return
    end
    local max_active = self:getGlobalSearchMaxActiveSources()
    while (search.active_count or 0) < max_active and search.next_index <= #(search.sources or {}) do
        local index = search.next_index
        search.next_index = search.next_index + 1
        self:startGlobalSearchJob(search, index)
    end
    self:finishGlobalSearchIfComplete(search)
end

function SuwayomiClient:startGlobalSearchJob(search, index)
    local source = search.sources[index]
    if not source then
        return
    end

    local job = self:getSubprocessJob()
    local worker = self:getGlobalSearchWorker()
    local active
    active = job.start({
        active = {
            source = source,
            summary_index = index,
            result_path = job.buildResultPath and job.buildResultPath("global_search") or nil,
        },
        ffi_util = self:getFFIUtil(),
        ui_manager = self:getUIManager(),
        poll_interval_seconds = self:getGlobalSearchPollIntervalSeconds(),
        timeout_seconds = self:getGlobalSearchSourceTimeoutSeconds(),
        run = function(path)
            worker:run(search.credentials, source, search.query, path)
        end,
        read_result = function(path)
            return worker:readResult(path)
        end,
        on_finish = function(finished_active, result)
            if search.canceled then
                return
            end
            search.active_jobs[finished_active.summary_index] = nil
            search.active_count = math.max((search.active_count or 1) - 1, 0)
            self:applyGlobalSearchResult(search, finished_active.summary_index, result)
            self:updateGlobalSearchMenu(search)
            self:startNextGlobalSearchJobs(search)
        end,
        on_timeout = function(timed_out_active)
            if search.canceled then
                return
            end
            local summary = search.summaries[timed_out_active.summary_index]
            if summary and summary.status == "searching" then
                summary.status = "timed_out"
                summary.result_count = 0
                summary.manga = {}
            end
            search.active_jobs[timed_out_active.summary_index] = nil
            search.active_count = math.max((search.active_count or 1) - 1, 0)
            timed_out_active.canceled = true
            self:updateGlobalSearchMenu(search)
            self:startNextGlobalSearchJobs(search)
        end,
    })
    if active then
        search.active_jobs[index] = active
        search.active_count = (search.active_count or 0) + 1
    else
        local summary = search.summaries[index]
        if summary then
            summary.status = "error"
            summary.error = self:translate("Could not start search.")
        end
    end
end

function SuwayomiClient:showGlobalSearch(sources)
    if not self.ui.showGlobalSearchPrompt then
        return
    end

    return self.ui.showGlobalSearchPrompt(function(query)
        local search_query = trim(query)
        if search_query == "" then
            self.plugin:showMessage(self:translate("Enter a search query."))
            return
        end

        local credentials = self.settings:load()
        local ordered_sources = self:sortGlobalSearchSources(sources)
        local summaries = {}
        for _, source in ipairs(ordered_sources) do
            table.insert(summaries, {
                source = source,
                status = "searching",
                manga = {},
                result_count = 0,
                query = search_query,
            })
        end

        self:log({
            operation = "globalSearch",
            event = "global_search_started",
            source_count = #ordered_sources,
            query = search_query,
        })

        if self.ui.showGlobalSearchResultsMenu then
            local search = {
                credentials = credentials,
                query = search_query,
                sources = ordered_sources,
                summaries = summaries,
                active_jobs = {},
                active_count = 0,
                next_index = 1,
            }
            local results_menu = self.ui.showGlobalSearchResultsMenu(summaries, function(summary)
                return self:openGlobalSearchSummary(summary, search_query)
            end, self:buildGlobalSearchMenuOptions(search))
            search.menu = results_menu
            self:trackScreen("browse-global-search", results_menu)
            self:startNextGlobalSearchJobs(search)
        end
    end)
end

function SuwayomiClient:showSourceModeMenu(source)
    if self:isLocalSource(source) or not self.ui.showSourceModeMenu then
        return self:showMangaForSource(source, {
            type = "POPULAR",
            skip_mode_menu = true,
        })
    end

    local mode_menu = self.ui.showSourceModeMenu(source, function(mode)
        if mode == "SEARCH" then
            return self:showSourceSearchPrompt(source)
        end
        return self:showMangaForSource(source, {
            type = mode,
            skip_mode_menu = true,
        })
    end, self:getTitleBarMenuOptions({
        title = source and (source.name or source.display_name or source.displayName) or self:translate("Suwayomi Source"),
    }))
    return self:trackScreen("browse-source", mode_menu)
end

function SuwayomiClient:buildSourceMangaRequestOptions(source, browse_options)
    local request_options = {
        source_id = source.id,
        page = browse_options.page,
        type = browse_options.type,
    }
    if request_options.type == "SEARCH" then
        request_options.query = browse_options.query
    end
    return request_options
end

function SuwayomiClient:resolveSourceMangaRuntime()
    local ok_job, job = pcall(function()
        return self:getSubprocessJob()
    end)
    local ok_ffi, ffi_util = pcall(function()
        return self:getFFIUtil()
    end)
    local ok_ui, ui_manager = pcall(function()
        return self:getUIManager()
    end)
    if not self.source_manga_worker
        and (not ok_ffi or type(ffi_util) ~= "table" or type(ffi_util.runInSubProcess) ~= "function")
    then
        return nil
    end
    local ok_worker, worker = pcall(function()
        return self:getSourceMangaWorker()
    end)

    if not ok_job or not ok_worker or not ok_ffi or not ok_ui then
        return nil
    end
    if type(job) ~= "table" or type(worker) ~= "table" then
        return nil
    end
    return {
        job = job,
        worker = worker,
        ffi_util = ffi_util,
        ui_manager = ui_manager,
    }
end

function SuwayomiClient:buildSourceMangaLoadingMenuOptions(state)
    local cancel = function()
        return self:cancelSourceMangaLoad(state)
    end
    local menu_options = copyOptions({}, self:getTitleBarMenuOptions({
        title = state.title,
        actions = {
            { id = "cancel_source_manga", text = self:translate("Cancel loading") },
        },
        onSelect = function(action)
            if action and action.id == "cancel_source_manga" then
                return cancel()
            end
        end,
    }))
    menu_options.title = state.title
    menu_options.close_callback = cancel
    menu_options.on_cancel_source_manga = cancel
    return menu_options
end

function SuwayomiClient:showSourceMangaStatus(menu, title, message)
    if menu and self.ui.updateMangaMenu then
        local menu_options = copyOptions({}, self:getTitleBarMenuOptions({
            title = title,
        }))
        menu_options.title = title
        self.ui.updateMangaMenu(menu, {
            { title = message },
        }, nil, menu_options)
        return true
    end
    return false
end

function SuwayomiClient:cancelSourceMangaLoad(state)
    if not state or state.canceled or state.finished then
        return
    end
    state.canceled = true
    if state.active and state.runtime and state.runtime.job and state.runtime.job.cancel then
        state.runtime.job.cancel(state.active)
    end
    state.active = nil
    self:showSourceMangaStatus(state.menu, state.title, self:translate("Loading canceled."))
end

function SuwayomiClient:renderMangaForSourceResult(credentials, source, browse_options, result, existing_menu)
    if not result then
        return
    end
    if not result.ok then
        if browse_options.type == "LATEST"
            and source
            and source.supports_latest == nil
            and self:isLatestUnsupportedError(result.error)
        then
            self.plugin:showMessage(self:translate("Latest manga is not supported by this source."))
            self:showSourceMangaStatus(
                existing_menu,
                self:buildBrowseResultTitle(source, browse_options),
                self:translate("Latest manga is not supported by this source.")
            )
            return
        end
        self.plugin:showMessage(self:translate(result.error))
        self:showSourceMangaStatus(
            existing_menu,
            self:buildBrowseResultTitle(source, browse_options),
            self:translate(result.error)
        )
        return
    end

    local page = tonumber(browse_options.page) or 1
    local manga_list = result.manga or {}
    local visible_manga = self:filterBrowseManga(manga_list)
    self:log({
        operation = "showMangaForSource",
        event = "manga_loaded",
        source_id = source and source.id,
        type = browse_options.type,
        page = page,
        manga_count = #visible_manga,
    })
    local menu_options = self:buildBrowseResultMenuOptions(source, browse_options, result.has_next_page)
    menu_options.thumbnail_credentials = credentials
    if existing_menu and menu_options.close_callback == nil then
        menu_options.close_callback = function() end
    end
    if #visible_manga == 0
        and not menu_options.on_previous_page
        and not menu_options.on_next_page
    then
        if not self:showSourceMangaStatus(
            existing_menu,
            menu_options.title,
            self:translate("This source has no manga.")
        ) then
            self.plugin:showMessage(self:translate("This source has no manga."))
        end
        return
    end

    local manga_menu = existing_menu
    local chapter_count_enrichment
    local pending_manga_menu_refresh = false
    local refreshMangaMenu
    local function selectManga(manga)
        self:attachSourceToManga(manga, source)
        if self.plugin.showMangaActions then
            self.plugin:showMangaActions(manga, {
                onMangaUpdated = refreshMangaMenu,
            })
        else
            self.plugin:showChaptersForManga(manga)
        end
    end
    refreshMangaMenu = function()
        visible_manga = self:filterBrowseManga(manga_list)
        if not manga_menu then
            pending_manga_menu_refresh = true
            return
        end
        if self.ui.updateMangaMenu then
            self.ui.updateMangaMenu(manga_menu, visible_manga, selectManga, menu_options)
        end
    end

    local chapter_count_runtime = self:resolveChapterCountRuntime()
    if chapter_count_runtime then
        local previous_close_callback = menu_options.close_callback
        menu_options.close_callback = function(...)
            if chapter_count_enrichment then
                self:cancelBrowseChapterCountEnrichment(chapter_count_enrichment)
            end
            if previous_close_callback then
                return previous_close_callback(...)
            end
        end
    end

    if existing_menu and self.ui.updateMangaMenu then
        self.ui.updateMangaMenu(existing_menu, visible_manga, selectManga, menu_options)
    else
        manga_menu = self.ui.showMangaMenu(visible_manga, selectManga, menu_options)
        self:trackScreen("browse-results", manga_menu)
    end
    if pending_manga_menu_refresh then
        refreshMangaMenu()
    end
    if chapter_count_runtime then
        chapter_count_enrichment = self:startBrowseChapterCountEnrichment(
            credentials,
            visible_manga,
            refreshMangaMenu,
            chapter_count_runtime
        )
    end
    return manga_menu
end

function SuwayomiClient:startSourceMangaLoad(credentials, source, browse_options)
    if not self.ui.showMangaMenu then
        return false
    end

    local runtime = self:resolveSourceMangaRuntime()
    if not runtime then
        return false
    end

    local title = self:buildBrowseResultTitle(source, browse_options)
    local state = {
        credentials = credentials,
        source = source,
        browse_options = browse_options,
        title = title,
        runtime = runtime,
    }

    state.menu = self.ui.showMangaMenu({
        { title = self:translate("Loading manga...") },
    }, nil, self:buildSourceMangaLoadingMenuOptions(state))
    self:trackScreen("browse-results", state.menu)

    local active = runtime.job.start({
        active = {
            source = source,
            browse_options = browse_options,
            result_path = runtime.job.buildResultPath
                and runtime.job.buildResultPath("source_manga")
                or nil,
        },
        ffi_util = runtime.ffi_util,
        ui_manager = runtime.ui_manager,
        poll_interval_seconds = self:getSourceMangaPollIntervalSeconds(),
        timeout_seconds = self:getSourceMangaTimeoutSeconds(),
        run = function(path)
            runtime.worker:run(credentials, source, browse_options, path)
        end,
        read_result = function(path)
            return runtime.worker:readResult(path)
        end,
        on_finish = function(finished_active, result)
            if state.canceled then
                return
            end
            state.finished = true
            state.active = nil
            result = result or {
                ok = false,
                error = self:translate("Could not load manga."),
            }
            local result_source = result and result.source or finished_active.source or source
            local result_options = result and result.browse_options or finished_active.browse_options or browse_options
            self:renderMangaForSourceResult(credentials, result_source, result_options, result, state.menu)
        end,
        on_timeout = function(timed_out_active)
            if state.canceled then
                return
            end
            state.finished = true
            state.active = nil
            timed_out_active.canceled = true
            self.plugin:showMessage(self:translate("Could not load manga."))
            self:showSourceMangaStatus(state.menu, title, self:translate("Could not load manga."))
        end,
    })

    if not active then
        state.finished = true
        self:showSourceMangaStatus(state.menu, title, self:translate("Could not start manga loading."))
        return true
    end

    state.active = active
    return true
end

function SuwayomiClient:showMangaForSource(source, options)
    options = options or {}
    if not options.skip_mode_menu and not self:isLocalSource(source) and self.ui.showSourceModeMenu then
        return self:showSourceModeMenu(source)
    end

    return self:time("showMangaForSource", {
        source_id = source and source.id,
        type = options.type or "POPULAR",
    }, function()
        local credentials = self.settings:load()
        local browse_options = {
            type = options.type or "POPULAR",
            query = options.query,
            page = tonumber(options.page) or 1,
        }

        if self:startSourceMangaLoad(credentials, source, browse_options) then
            return
        end

        self.plugin:showMessage(self:translate("Could not start manga loading."))
    end)
end

return SuwayomiClient
