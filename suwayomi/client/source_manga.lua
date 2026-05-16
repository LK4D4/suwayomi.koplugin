-- Boundary: source manga browse flow.
--
-- Responsibility: render source modes/results, manage cancellable source manga loading, and refresh browse rows.
-- Owned state: installed methods only; runtime state remains on SuwayomiClient instances.
-- Dependencies: SuwayomiClient core helpers and injected runtime services.
-- External data: validated by the moved methods before UI rendering or worker use.

local util = require("suwayomi/client/util")
local copyOptions = util.copyOptions
local trim = util.trim

local M = {}

function M.install(SuwayomiClient)
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

function SuwayomiClient:isLatestUnsupportedError(error_text)
    local message = tostring(error_text or ""):lower()
    return message:match("unsupported%s+latest") ~= nil
        or message:match("latest%s+not%s+supported") ~= nil
        or message:match("does%s+not%s+support%s+latest") ~= nil
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

function SuwayomiClient:isCurrentSourceMangaLoad(state)
    return state
        and self._active_source_manga_load == state
        and self._source_manga_load_token == state.token
end

function SuwayomiClient:nextSourceMangaLoadToken()
    self._source_manga_load_token = (self._source_manga_load_token or 0) + 1
    return self._source_manga_load_token
end

function SuwayomiClient:supersedeSourceMangaLoad()
    local previous = self._active_source_manga_load
    if previous and not previous.canceled and not previous.finished then
        self:cancelSourceMangaLoad(previous, { silent = true })
    end
end

function SuwayomiClient:clearSourceMangaLoad(state)
    if self._active_source_manga_load == state then
        self._active_source_manga_load = nil
    end
end

function SuwayomiClient:cancelSourceMangaLoad(state, options)
    if not state or state.canceled or state.finished then
        return
    end
    options = options or {}
    state.canceled = true
    if state.active and state.runtime and state.runtime.job and state.runtime.job.cancel then
        state.runtime.job.cancel(state.active)
    end
    state.active = nil
    self:clearSourceMangaLoad(state)
    if not options.silent then
        self:showSourceMangaStatus(state.menu, state.title, self:translate("Loading canceled."))
    end
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

    self:supersedeSourceMangaLoad()

    local runtime = self:resolveSourceMangaRuntime()
    if not runtime then
        return false
    end

    local title = self:buildBrowseResultTitle(source, browse_options)
    local state = {
        token = self:nextSourceMangaLoadToken(),
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
    self._active_source_manga_load = state

    local start_ok, active = pcall(runtime.job.start, {
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
            if state.canceled or not self:isCurrentSourceMangaLoad(state) then
                return
            end
            state.finished = true
            state.active = nil
            self:clearSourceMangaLoad(state)
            result = result or {
                ok = false,
                error = self:translate("Could not load manga."),
            }
            local result_source = result and result.source or finished_active.source or source
            local result_options = result and result.browse_options or finished_active.browse_options or browse_options
            self:renderMangaForSourceResult(credentials, result_source, result_options, result, state.menu)
        end,
        on_timeout = function(timed_out_active)
            if state.canceled or not self:isCurrentSourceMangaLoad(state) then
                return
            end
            state.finished = true
            state.active = nil
            self:clearSourceMangaLoad(state)
            timed_out_active.canceled = true
            self.plugin:showMessage(self:translate("Could not load manga."))
            self:showSourceMangaStatus(state.menu, title, self:translate("Could not load manga."))
        end,
    })
    if not start_ok then
        active = nil
    end

    if not active then
        state.finished = true
        self:clearSourceMangaLoad(state)
        self:showSourceMangaStatus(state.menu, title, self:translate("Could not start manga loading."))
        return true
    end

    if not state.finished then
        state.active = active
    end
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
end

return M
