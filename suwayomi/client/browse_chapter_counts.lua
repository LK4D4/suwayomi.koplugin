-- Boundary: browse chapter-count enrichment.
--
-- Responsibility: run bounded background chapter-count workers for browse result rows.
-- Owned state: installed methods only; runtime state remains on SuwayomiClient instances.
-- Dependencies: SuwayomiClient core helpers and injected runtime services.
-- External data: validated by the moved methods before UI rendering or worker use.

local I18n = require("suwayomi/i18n")

local M = {}
local CHAPTER_COUNT_TIMEOUT_ERROR = "Chapter count timed out; open manga to load chapters"

local function getChapterCountCacheKey(manga)
    if type(manga) ~= "table" or manga.id == nil then
        return nil
    end
    local source = type(manga.source) == "table" and manga.source or nil
    local source_id = source and source.id
    if source_id ~= nil then
        return tostring(source_id) .. ":" .. tostring(manga.id)
    end
    return tostring(manga.id)
end

local function clearBrowseChapterCountLoading(manga)
    if type(manga) ~= "table" or manga.chapter_count_loading ~= true then
        return false
    end
    manga.chapter_count_loading = nil
    return true
end

function M.install(SuwayomiClient)
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

function SuwayomiClient:applyBrowseChapterCountCache(manga, cache)
    local key = getChapterCountCacheKey(manga)
    local cached = key and cache and cache[key] or nil
    if not cached then
        return false
    end
    manga.chapter_count_loading = nil
    manga.chapter_count = cached.chapter_count
    manga.chapter_count_verified = true
    manga.chapter_count_error = nil
    return true
end

function SuwayomiClient:rememberBrowseChapterCount(manga, result, cache)
    if not cache or not result or result.ok ~= true then
        return
    end
    local key = getChapterCountCacheKey(manga)
    if not key then
        return
    end
    cache[key] = {
        chapter_count = tonumber(result.chapter_count) or 0,
    }
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
        manga.chapter_count_error = result and result.error or true
    end
end

function SuwayomiClient:startNextBrowseChapterCountJobs(state)
    if not state or state.canceled then
        return
    end

    while (state.active_count or 0) < state.max_active and state.next_index <= #state.queue do
        local manga = state.queue[state.next_index]
        state.next_index = state.next_index + 1
        if not self:applyBrowseChapterCountCache(manga, state.cache)
            and self:shouldFetchBrowseChapterCount(manga)
        then
            manga.chapter_count_error = nil
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
                        self:releaseBrowseChapterCountJob(state, finished_active)
                        self:applyBrowseChapterCountResult(finished_active.manga, result)
                        self:rememberBrowseChapterCount(finished_active.manga, result, state.cache)
                        if state.refresh then
                            state.refresh()
                        end
                        self:startNextBrowseChapterCountJobs(state)
                    end,
                    on_timeout = function(timed_out_active)
                        if state.canceled then
                            return
                        end
                        timed_out_active.canceled = true
                        self:releaseBrowseChapterCountJob(state, timed_out_active)
                        self:applyBrowseChapterCountResult(timed_out_active.manga, {
                            ok = false,
                            error = I18n.t(CHAPTER_COUNT_TIMEOUT_ERROR),
                        })
                        if state.refresh then
                            state.refresh()
                        end
                        self:startNextBrowseChapterCountJobs(state)
                    end,
                    on_cleanup = function(cleaned_active)
                        if state.canceled then
                            return
                        end
                        if self:releaseBrowseChapterCountJob(state, cleaned_active) then
                            self:startNextBrowseChapterCountJobs(state)
                        end
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
                    error = I18n.t("Could not load chapters."),
                })
                if state.refresh then
                    state.refresh()
                end
            end
        end
    end
end

function SuwayomiClient:releaseBrowseChapterCountJob(state, active)
    if not state or not active or active.released then
        return false
    end
    if state.active_jobs and state.active_jobs[active.manga_id] == active then
        state.active_jobs[active.manga_id] = nil
    end
    active.released = true
    state.active_count = math.max((state.active_count or 1) - 1, 0)
    return true
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
        cache = {},
    }
    self:startNextBrowseChapterCountJobs(state)
    return state
end

function SuwayomiClient:appendBrowseChapterCountManga(state, manga_list)
    if not state or state.canceled then
        return
    end

    local added = false
    local applied_cache = false
    for _, manga in ipairs(manga_list or {}) do
        if self:applyBrowseChapterCountCache(manga, state.cache) then
            applied_cache = true
        elseif self:shouldFetchBrowseChapterCount(manga) then
            table.insert(state.queue, manga)
            added = true
        end
    end
    if applied_cache and state.refresh then
        state.refresh()
    end
    if added then
        self:startNextBrowseChapterCountJobs(state)
    end
end

function SuwayomiClient:cancelBrowseChapterCountEnrichment(state)
    if not state or state.canceled then
        return
    end
    state.canceled = true
    local job = state.runtime and state.runtime.job
    local cleared_loading = false
    if job and job.cancel then
        for _, active in pairs(state.active_jobs or {}) do
            job.cancel(active)
            cleared_loading = clearBrowseChapterCountLoading(active and active.manga) or cleared_loading
        end
    end
    for _, manga in ipairs(state.queue or {}) do
        cleared_loading = clearBrowseChapterCountLoading(manga) or cleared_loading
    end
    state.active_jobs = {}
    state.active_count = 0
    if cleared_loading and state.refresh then
        state.refresh()
    end
end
end

return M
