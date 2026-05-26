-- Boundary: global search flow.
--
-- Responsibility: coordinate partial global source search workers and their live results menu.
-- Owned state: installed methods only; runtime state remains on SuwayomiClient instances.
-- Dependencies: SuwayomiClient core helpers and injected runtime services.
-- External data: validated by the moved methods before UI rendering or worker use.

local util = require("suwayomi/client/util")
local I18n = require("suwayomi/i18n")
local copyOptions = util.copyOptions
local trim = util.trim

local M = {}

function M.install(SuwayomiClient)
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
            error = result and result.error or I18n.t("Could not load manga."),
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
        table.insert(actions, { id = "cancel_search", text = I18n.t("Cancel search") })
    end
    local menu_options = copyOptions({}, self:getTitleBarMenuOptions({
        title = I18n.t("Global search"),
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
    menu_options.on_retry_summary = function(summary)
        return self:retryGlobalSearchSummary(search, summary)
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
        summary.error = result and result.error or I18n.t("Could not load manga.")
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

function SuwayomiClient:findGlobalSearchSummaryIndex(search, summary)
    for index, candidate in ipairs(search and search.summaries or {}) do
        if candidate == summary then
            return index
        end
    end
end

function SuwayomiClient:isGlobalSearchSummaryRetryable(summary)
    return summary and (summary.status == "error" or summary.status == "timed_out")
end

function SuwayomiClient:retryGlobalSearchSummary(search, summary)
    if not search or search.canceled or not self:isGlobalSearchSummaryRetryable(summary) then
        return
    end
    local index = self:findGlobalSearchSummaryIndex(search, summary)
    if not index then
        return
    end

    local active = search.active_jobs and search.active_jobs[index]
    if active then
        local job = self:getSubprocessJob()
        job.cancel(active)
        self:releaseGlobalSearchJob(search, active)
    end

    search.finished = false
    summary.status = "searching"
    summary.error = nil
    summary.manga = {}
    summary.result_count = 0
    summary.has_next_page = nil
    self:updateGlobalSearchMenu(search)
    self:startGlobalSearchJob(search, index)
    self:finishGlobalSearchIfComplete(search)
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

function SuwayomiClient:releaseGlobalSearchJob(search, active)
    if not search or not active or active.released then
        return false
    end
    if search.active_jobs and search.active_jobs[active.summary_index] == active then
        search.active_jobs[active.summary_index] = nil
    end
    active.released = true
    search.active_count = math.max((search.active_count or 1) - 1, 0)
    return true
end

function SuwayomiClient:startGlobalSearchJob(search, index)
    local source = search.sources[index]
    if not source then
        return
    end

    local job = self:getSubprocessJob()
    local worker = self:getGlobalSearchWorker()
    local active
    local start_ok
    start_ok, active = pcall(job.start, {
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
            local summary = search.summaries[finished_active.summary_index]
            if finished_active.canceled or (summary and summary.status ~= "searching") then
                return
            end
            self:releaseGlobalSearchJob(search, finished_active)
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
            timed_out_active.canceled = true
            self:updateGlobalSearchMenu(search)
        end,
        on_cleanup = function(cleaned_active)
            if search.canceled then
                return
            end
            if self:releaseGlobalSearchJob(search, cleaned_active) then
                self:startNextGlobalSearchJobs(search)
            end
        end,
    })
    if not start_ok then
        active = nil
    end
    if active then
        search.active_jobs[index] = active
        search.active_count = (search.active_count or 0) + 1
    else
        local summary = search.summaries[index]
        if summary then
            summary.status = "error"
            summary.error = I18n.t("Could not start search.")
        end
        self:updateGlobalSearchMenu(search)
    end
end

function SuwayomiClient:showGlobalSearch(sources)
    if not self.ui.showGlobalSearchPrompt then
        return
    end

    return self.ui.showGlobalSearchPrompt(function(query)
        local search_query = trim(query)
        if search_query == "" then
            self.plugin:showMessage(I18n.t("Enter a search query."))
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
            query_length = #search_query,
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
end

return M
