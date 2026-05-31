-- Boundary: source manga browse flow.
--
-- Responsibility: render source modes/results, manage saved filters and cancellable source manga loading, and refresh browse rows.
-- Owned state: installed methods only; runtime state remains on SuwayomiClient instances.
-- Dependencies: SuwayomiClient core helpers and injected runtime services.
-- External data: validated by the moved methods before UI rendering or worker use.

local util = require("suwayomi/client/util")
local SourceFilters = require("suwayomi/source_filters")
local I18n = require("suwayomi/i18n")
local json = require("dkjson")
local copyOptions = util.copyOptions
local trim = util.trim
local SAVED_SEARCHES_META_KEY = "webUI_savedSearches"
local SAVED_FILTERS_UNSUPPORTED_MESSAGE = "Saved filters are not supported by this server."
local SAVED_FILTERS_UNSUPPORTED_ERROR = "__suwayomi_saved_filters_unsupported__"
local SAVED_FILTERS_INVALID_METADATA_ERROR = "__suwayomi_saved_filters_invalid_metadata__"

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
        return I18n.t("Source")
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
        if trim(options.query) == "" and type(options.filters) == "table" and #options.filters > 0 then
            return I18n.t("Filter")
        end
        return I18n.cf("source mode", "Search: %1", tostring(options.query or ""))
    end
    if mode == "LATEST" then
        return I18n.c("source mode", "Latest")
    end
    return I18n.c("source mode", "Popular")
end

function SuwayomiClient:buildBrowseResultTitle(source, options)
    return self:getSourceDisplayName(source)
        .. " - "
        .. self:getSourceModeTitle(options)
end

function SuwayomiClient:getSourceModeScreenTitle(options)
    local mode = options.type or "POPULAR"
    if mode == "SEARCH" then
        if trim(options.query) == "" and type(options.filters) == "table" and #options.filters > 0 then
            return I18n.t("Filter")
        end
        return I18n.c("source mode", "Search")
    end
    if mode == "LATEST" then
        return I18n.c("source mode", "Latest")
    end
    return I18n.c("source mode", "Popular")
end

function SuwayomiClient:buildBrowseResultScreenTitle(_, options)
    return self:getSourceModeScreenTitle(options)
end

function SuwayomiClient:buildBrowseResultMenuOptions(source, options)
    local detail_title = self:buildBrowseResultTitle(source, options)
    local menu_options = copyOptions({}, self:getTitleBarMenuOptions({ title = detail_title }))
    menu_options.title = self:buildBrowseResultScreenTitle(source, options)
    return menu_options
end

function SuwayomiClient:isLatestUnsupportedError(error_text)
    local message = tostring(error_text or ""):lower()
    return message:match("unsupported%s+latest") ~= nil
        or message:match("latest%s+not%s+supported") ~= nil
        or message:match("does%s+not%s+support%s+latest") ~= nil
end

function SuwayomiClient:showSourceSearchPrompt(source, options)
    if not self.ui.showSourceSearchPrompt then
        return
    end
    options = options or {}

    return self.ui.showSourceSearchPrompt(source, function(query)
        local search_query = trim(query)
        if search_query == "" then
            self.plugin:showMessage(I18n.t("Enter a search query."))
            return
        end
        self:showMangaForSource(source, {
            type = "SEARCH",
            query = search_query,
            skip_mode_menu = true,
        })
    end, {
        query = options.query,
    })
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
        if mode == "FILTERS" then
            return self:showSourceFilters(source)
        end
        return self:showMangaForSource(source, {
            type = mode,
            skip_mode_menu = true,
        })
    end, self:getTitleBarMenuOptions({
        title = source and (source.name or source.display_name or source.displayName) or I18n.t("Suwayomi Source"),
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
        request_options.filters = browse_options.filters
    end
    return request_options
end

function SuwayomiClient:resolveSourceFilterRuntime()
    local ok_job, job = pcall(function()
        return self:getSubprocessJob()
    end)
    local ok_worker, worker = pcall(function()
        return self:getSourceFilterWorker()
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

function SuwayomiClient:loadSourceFilterDraft(credentials, source)
    if self.settings and self.settings.loadSourceFilterDraft then
        return self.settings:loadSourceFilterDraft(credentials, source and source.id)
    end
    return { query = "", filters = {} }
end

function SuwayomiClient:saveSourceFilterDraft(credentials, source, draft)
    if self.settings and self.settings.saveSourceFilterDraft then
        return self.settings:saveSourceFilterDraft(credentials, source and source.id, draft)
    end
    return SourceFilters.normalizeDraft(draft)
end

function SuwayomiClient:clearSourceFilterDraft(credentials, source)
    if self.settings and self.settings.clearSourceFilterDraft then
        return self.settings:clearSourceFilterDraft(credentials, source and source.id)
    end
end

local function findSourceMetaValue(meta, key)
    for _, entry in ipairs(type(meta) == "table" and meta or {}) do
        if type(entry) == "table" and entry.key == key then
            return entry.value
        end
    end
    return nil
end

local function decodeSavedSearches(value)
    if type(value) ~= "string" or value == "" then
        return {}
    end
    local decoded, _, err = json.decode(value, 1, nil)
    if err or type(decoded) ~= "table" then
        return nil, SAVED_FILTERS_INVALID_METADATA_ERROR
    end
    return decoded
end

local function sourceSavedFiltersUnsupported(error_text)
    return error_text == SAVED_FILTERS_UNSUPPORTED_ERROR
        or error_text == SAVED_FILTERS_UNSUPPORTED_MESSAGE
end

local function sourceSavedFiltersInvalidMetadata(error_text)
    return error_text == SAVED_FILTERS_INVALID_METADATA_ERROR
end

local function removeSavedFilterByName(entries, name)
    local kept = {}
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
        if entry.name ~= name then
            table.insert(kept, entry)
        end
    end
    return kept
end

local function savedFilterNameExists(entries, name)
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
        if entry.name == name then
            return true
        end
    end
    return false
end

local function redactSavedFilterErrorDetail(detail)
    local secret_value = "[^%s,;]+"
    local header_value = "[^,]+"
    detail = detail:gsub("https?://[^%s]+", "<redacted>")
    detail = detail:gsub("[A-Za-z]:[\\/][^,]+", "<redacted>")
    detail = detail:gsub("/[^,]+", "<redacted>")
    detail = detail:gsub(
        "([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]%s*[:=]%s*)" .. header_value,
        "%1<redacted>"
    )
    detail = detail:gsub("([Cc][Oo][Oo][Kk][Ii][Ee]%s*[:=]%s*)" .. header_value, "%1<redacted>")

    local credential_patterns = {
        "([Tt][Oo][Kk][Ee][Nn]%s*[:=]%s*)" .. secret_value,
        "([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]%s*[:=]%s*)" .. secret_value,
        "([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]%s+)" .. secret_value,
        "([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]%s*:%s*)" .. secret_value,
        "([Cc][Oo][Oo][Kk][Ii][Ee]%s*[:=]%s*)" .. secret_value,
        "([Ss][Ee][Cc][Rr][Ee][Tt]%s*[:=]%s*)" .. secret_value,
        "([Ss][Ee][Cc][Rr][Ee][Tt]%s+)" .. secret_value,
    }
    for _, pattern in ipairs(credential_patterns) do
        detail = detail:gsub(pattern, "%1<redacted>")
    end

    return detail
end

local function normalizeSavedFilterErrorDetail(error_text)
    local detail = trim(error_text)
    if detail == "" then
        return nil
    end
    detail = redactSavedFilterErrorDetail(detail)
    detail = detail:gsub("%s+", " ")
    if #detail > 180 then
        detail = detail:sub(1, 177) .. "..."
    end
    return detail
end

local function appendSavedFilterErrorDetail(fallback, error_text)
    local detail = normalizeSavedFilterErrorDetail(error_text)
    if not detail then
        return fallback
    end
    local prefix = tostring(fallback or ""):gsub("[%.。]$", "")
    if prefix == "" then
        return detail
    end
    return prefix .. ": " .. detail
end

function SuwayomiClient:showSavedFilterFailure(error_text, fallback)
    if sourceSavedFiltersUnsupported(error_text) then
        self.plugin:showMessage(I18n.t("Saved filters are not supported by this server."))
        return
    end
    if sourceSavedFiltersInvalidMetadata(error_text) then
        self.plugin:showMessage(
            appendSavedFilterErrorDetail(fallback, I18n.t("Saved filters metadata is not valid JSON."))
        )
        return
    end
    self.plugin:showMessage(appendSavedFilterErrorDetail(fallback, error_text))
end

function SuwayomiClient:loadSourceSavedFilterState(credentials, source)
    if not self.api or not self.api.fetchSourceMetadata then
        return nil, SAVED_FILTERS_UNSUPPORTED_ERROR
    end
    local result = self.api.fetchSourceMetadata(credentials, source and source.id)
    if not result or not result.ok then
        return nil, result and result.error or I18n.t("Could not load saved filters.")
    end

    local saved_searches, decode_error = decodeSavedSearches(findSourceMetaValue(result.meta, SAVED_SEARCHES_META_KEY))
    if not saved_searches then
        return nil, decode_error
    end
    return {
        entries = SourceFilters.normalizeSavedSearches(saved_searches),
    }
end

function SuwayomiClient:writeSourceSavedFilterEntries(credentials, source, entries, failure_message)
    if not self.api or not self.api.setSourceSavedSearches then
        self:showSavedFilterFailure(SAVED_FILTERS_UNSUPPORTED_ERROR, failure_message)
        return false
    end
    local payload = json.encode(SourceFilters.savedSearchesToMap(entries))
    local result = self.api.setSourceSavedSearches(credentials, source and source.id, payload)
    if not result or not result.ok then
        self:showSavedFilterFailure(result and result.error, failure_message)
        return false
    end
    return true
end

function SuwayomiClient:showSaveSourceFilterPrompt(credentials, source, draft)
    if not self.ui.showSavedFilterNamePrompt then
        self.plugin:showMessage(I18n.t("Could not save saved filter."))
        return
    end
    draft = SourceFilters.normalizeDraft(draft)
    return self.ui.showSavedFilterNamePrompt("", function(name)
        name = trim(name)
        if name == "" then
            self.plugin:showMessage(I18n.t("Filter name"))
            return
        end
        local state, load_error = self:loadSourceSavedFilterState(credentials, source)
        local repaired_invalid_metadata = false
        if not state then
            if sourceSavedFiltersInvalidMetadata(load_error) then
                state = { entries = {} }
                repaired_invalid_metadata = true
            else
                self:showSavedFilterFailure(load_error, I18n.t("Could not save saved filter."))
                return
            end
        end
        local save = function()
            local entries = removeSavedFilterByName(state.entries, name)
            local normalized = SourceFilters.normalizeDraft(draft)
            normalized.name = name
            table.insert(entries, normalized)
            if self:writeSourceSavedFilterEntries(credentials, source, entries, I18n.t("Could not save saved filter.")) then
                if repaired_invalid_metadata then
                    self.plugin:showMessage(
                        I18n.t("Saved filter saved. Invalid saved filters metadata was replaced.")
                    )
                else
                    self.plugin:showMessage(I18n.t("Saved filter saved."))
                end
            end
        end
        if savedFilterNameExists(state.entries, name) and self.ui.showOverwriteSavedFilterConfirm then
            return self.ui.showOverwriteSavedFilterConfirm(name, save)
        end
        return save()
    end)
end

function SuwayomiClient:deleteSourceSavedFilter(credentials, source, schema, entry, menu)
    local state, load_error = self:loadSourceSavedFilterState(credentials, source)
    if not state then
        self:showSavedFilterFailure(load_error, I18n.t("Could not delete saved filter."))
        return
    end
    local entries = removeSavedFilterByName(state.entries, entry and entry.name)
    if self:writeSourceSavedFilterEntries(credentials, source, entries, I18n.t("Could not delete saved filter.")) then
        self.plugin:showMessage(I18n.t("Saved filter deleted."))
        return self:renderSavedSourceFilters(credentials, source, schema, entries, menu)
    end
end

function SuwayomiClient:confirmDeleteSourceSavedFilter(credentials, source, schema, entry, menu)
    if self.ui.showDeleteSavedFilterConfirm then
        return self.ui.showDeleteSavedFilterConfirm(entry, function()
            return self:deleteSourceSavedFilter(credentials, source, schema, entry, menu)
        end)
    end
    return self:deleteSourceSavedFilter(credentials, source, schema, entry, menu)
end

function SuwayomiClient:renderSavedSourceFilters(credentials, source, schema, entries, existing_menu)
    if not self.ui.showSavedFiltersMenu then
        self.plugin:showMessage(I18n.t("Could not load saved filters."))
        return
    end
    local title = self:getSourceDisplayName(source) .. " - " .. I18n.t("Saved filters")
    local menu_options = copyOptions({}, self:getTitleBarMenuOptions({
        title = title,
    }))
    menu_options.title = title
    local menu
    local function selectSavedFilter(entry)
        return self:applySourceFilterDraft(credentials, source, schema, entry)
    end
    menu_options.on_delete = function(entry)
        return self:confirmDeleteSourceSavedFilter(credentials, source, schema, entry, menu)
    end
    if existing_menu and self.ui.updateSavedFiltersMenu then
        menu = existing_menu
        self.ui.updateSavedFiltersMenu(existing_menu, entries, selectSavedFilter, menu_options)
        return existing_menu
    end
    menu = self.ui.showSavedFiltersMenu(entries, selectSavedFilter, menu_options)
    return self:trackScreen("saved-filters", menu)
end

function SuwayomiClient:showSavedSourceFilters(credentials, source, schema)
    local state, load_error = self:loadSourceSavedFilterState(credentials, source)
    if not state then
        self:showSavedFilterFailure(load_error, I18n.t("Could not load saved filters."))
        return
    end
    return self:renderSavedSourceFilters(credentials, source, schema, state.entries)
end

function SuwayomiClient:isCurrentSourceFilterLoad(state)
    return state
        and self._active_source_filter_load == state
        and self._source_filter_load_token == state.token
end

function SuwayomiClient:nextSourceFilterLoadToken()
    self._source_filter_load_token = (self._source_filter_load_token or 0) + 1
    return self._source_filter_load_token
end

function SuwayomiClient:clearSourceFilterLoad(state)
    if self._active_source_filter_load == state then
        self._active_source_filter_load = nil
    end
end

function SuwayomiClient:cancelSourceFilterLoad(state, options)
    if not state or state.canceled or state.finished then
        return
    end
    options = options or {}
    state.canceled = true
    if state.active and state.runtime and state.runtime.job and state.runtime.job.cancel then
        state.runtime.job.cancel(state.active)
    end
    state.active = nil
    self:clearSourceFilterLoad(state)
    if not options.silent then
        self:showSourceMangaStatus(
            state.menu,
            state.title,
            I18n.t("Loading canceled."),
            state.detail_title
        )
    end
end

function SuwayomiClient:supersedeSourceFilterLoad()
    local previous = self._active_source_filter_load
    if previous and not previous.canceled and not previous.finished then
        self:cancelSourceFilterLoad(previous, { silent = true })
    end
end

function SuwayomiClient:buildSourceFilterLoadingMenuOptions(state)
    local cancel = function()
        return self:cancelSourceFilterLoad(state)
    end
    local menu_options = copyOptions({}, self:getTitleBarMenuOptions({
        title = state.detail_title,
        actions = {
            { id = "cancel_source_filters", text = I18n.t("Cancel loading") },
        },
        onSelect = function(action)
            if action and action.id == "cancel_source_filters" then
                return cancel()
            end
        end,
    }))
    menu_options.title = state.title
    menu_options.close_callback = cancel
    menu_options.on_cancel_source_filters = cancel
    return menu_options
end

function SuwayomiClient:showSourceFilterSearchPrompt(source, schema, draft, credentials)
    if not self.ui.showSourceSearchPrompt then
        return self:openSourceFilterEditor(credentials, source, schema, draft)
    end
    return self.ui.showSourceSearchPrompt(source, function(query)
        draft = SourceFilters.normalizeDraft(draft)
        draft.query = trim(query)
        return self:openSourceFilterEditor(credentials, source, schema, draft)
    end, {
        query = draft and draft.query or "",
    })
end

function SuwayomiClient:applySourceFilterDraft(credentials, source, schema, draft)
    local saved_draft = self:saveSourceFilterDraft(credentials, source, draft)
    local filters = SourceFilters.buildFilterChanges(schema, saved_draft and saved_draft.filters)
    return self:showMangaForSource(source, {
        type = "SEARCH",
        query = saved_draft and saved_draft.query or "",
        page = 1,
        filters = filters,
        filter_draft = saved_draft,
        filter_schema = schema,
        skip_mode_menu = true,
    })
end

function SuwayomiClient:openSourceFilterEditor(credentials, source, schema, draft)
    if not self.ui.showSourceFilterEditor then
        self.plugin:showMessage(I18n.t("Source filters are unavailable."))
        return
    end
    draft = SourceFilters.normalizeDraft(draft)
    local editor = self.ui.showSourceFilterEditor(source, schema, draft, {
        title_options = self:getTitleBarMenuOptions({
            title = I18n.f("%1 filters", self:getSourceDisplayName(source)),
            actions = {
                { id = "apply_source_filters", text = I18n.t("Apply filters") },
                { id = "reset_source_filters", text = I18n.t("Reset filters") },
                { id = "source_filter_search_text", text = I18n.t("Search text") },
                { id = "save_source_filter", text = I18n.t("Save filter") },
                { id = "saved_source_filters", text = I18n.t("Saved filters") },
            },
            onSelect = function(action, menu)
                local action_id = action and action.id
                local current_draft = type(menu) == "table" and menu.suwayomi_source_filter_draft or nil
                if type(current_draft) ~= "table" then
                    current_draft = draft
                end
                if action_id == "apply_source_filters" then
                    return self:applySourceFilterDraft(credentials, source, schema, current_draft)
                elseif action_id == "reset_source_filters" then
                    self:clearSourceFilterDraft(credentials, source)
                    return self:openSourceFilterEditor(credentials, source, schema, { query = "", filters = {} })
                elseif action_id == "source_filter_search_text" then
                    return self:showSourceFilterSearchPrompt(source, schema, current_draft, credentials)
                elseif action_id == "save_source_filter" then
                    return self:showSaveSourceFilterPrompt(credentials, source, current_draft)
                elseif action_id == "saved_source_filters" then
                    return self:showSavedSourceFilters(credentials, source, schema)
                end
            end,
        }),
        on_apply = function(next_draft)
            return self:applySourceFilterDraft(credentials, source, schema, next_draft)
        end,
        on_reset = function()
            self:clearSourceFilterDraft(credentials, source)
            return self:openSourceFilterEditor(credentials, source, schema, { query = "", filters = {} })
        end,
        on_search_text = function(next_draft)
            return self:showSourceFilterSearchPrompt(source, schema, next_draft or draft, credentials)
        end,
        on_save_filter = function(next_draft)
            return self:showSaveSourceFilterPrompt(credentials, source, next_draft or draft)
        end,
        on_saved_filters = function()
            return self:showSavedSourceFilters(credentials, source, schema)
        end,
    })
    return self:trackScreen("source-filters", editor)
end

function SuwayomiClient:showSourceFilters(source)
    local credentials = self.settings:load()
    local runtime = self:resolveSourceFilterRuntime()
    if not runtime then
        self.plugin:showMessage(I18n.t("Could not load source filters."))
        return
    end

    self:supersedeSourceFilterLoad()

    local detail_title = self:getSourceDisplayName(source) .. " - " .. I18n.t("Source filters")
    local state = {
        token = self:nextSourceFilterLoadToken(),
        credentials = credentials,
        source = source,
        title = I18n.t("Source filters"),
        detail_title = detail_title,
        runtime = runtime,
    }
    local menu = self.ui.showMangaMenu({
        { title = I18n.t("Loading source filters...") },
    }, nil, self:buildSourceFilterLoadingMenuOptions(state))
    state.menu = menu
    self._active_source_filter_load = state
    self:trackScreen("source-filters-loading", menu)

    local function showStatus(message, options)
        options = options or {}
        local row = {
            text = message,
            raw_menu_row = true,
        }
        if options.retry == true then
            row.subtitle = I18n.t("Tap to retry")
            row.mandatory = I18n.t("Retry")
            row.callback = function()
                return self:showSourceFilters(source)
            end
        else
            row.select_enabled = false
        end
        if menu and self.ui.updateMangaMenu then
            self.ui.updateMangaMenu(menu, { row }, nil, self:getTitleBarMenuOptions({ title = detail_title }))
        else
            self.plugin:showMessage(message)
        end
    end

    local ok, active = pcall(runtime.job.start, {
        active = {
            source = source,
            result_path = runtime.job.buildResultPath and runtime.job.buildResultPath("source_filter") or nil,
        },
        ffi_util = runtime.ffi_util,
        ui_manager = runtime.ui_manager,
        poll_interval_seconds = self:getSourceMangaPollIntervalSeconds(),
        timeout_seconds = self:getSourceMangaTimeoutSeconds(),
        run = function(path)
            runtime.worker:run(credentials, source, path)
        end,
        read_result = function(path)
            return runtime.worker:readResult(path)
        end,
        on_finish = function(finished_active, result)
            if state.canceled or not self:isCurrentSourceFilterLoad(state) then
                return
            end
            state.finished = true
            state.active = nil
            self:clearSourceFilterLoad(state)
            result = result or {
                ok = false,
                error = I18n.t("Could not load source filters."),
                filters = {},
            }
            local result_source = result.source or finished_active.source or source
            if not result.ok then
                showStatus(result.error or I18n.t("Could not load source filters."), { retry = true })
                return
            end
            if type(result.filters) ~= "table" or #result.filters == 0 then
                showStatus(I18n.t("This source has no filters."))
                return
            end
            return self:openSourceFilterEditor(
                credentials,
                result_source,
                result.filters,
                self:loadSourceFilterDraft(credentials, result_source)
            )
        end,
        on_timeout = function()
            if state.canceled or not self:isCurrentSourceFilterLoad(state) then
                return
            end
            state.finished = true
            state.active = nil
            self:clearSourceFilterLoad(state)
            showStatus(I18n.t("Timed out."), { retry = true })
        end,
    })
    if not ok or not active then
        state.finished = true
        self:clearSourceFilterLoad(state)
        showStatus(I18n.t("Could not start source filter loading."), { retry = true })
        return
    end
    if not state.finished then
        state.active = active
    end
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
        title = state.detail_title,
        actions = {
            { id = "cancel_source_manga", text = I18n.t("Cancel loading") },
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

function SuwayomiClient:showSourceMangaStatus(menu, title, message, detail_title, rows)
    if menu and self.ui.updateMangaMenu then
        local menu_options = copyOptions({}, self:getTitleBarMenuOptions({
            title = detail_title or title,
        }))
        menu_options.title = title
        self.ui.updateMangaMenu(menu, rows or {
            { title = message },
        }, nil, menu_options)
        return true
    end
    return false
end

function SuwayomiClient:buildSourceMangaFailureMessage(source, browse_options, error_text)
    if browse_options.type ~= "SEARCH" then
        return tostring(error_text or "")
    end
    local operation = self:getSourceModeScreenTitle(browse_options)
    local source_name = self:getSourceDisplayName(source)
    local prefix = I18n.f("%1 failed for %2", operation, source_name)
    local detail = trim(error_text)
    if detail ~= "" and detail ~= I18n.t("Could not load manga.") then
        return prefix .. ": " .. detail
    end
    return prefix .. "."
end

function SuwayomiClient:buildSourceMangaFailureRows(source, browse_options, message)
    if browse_options.type ~= "SEARCH" then
        return nil
    end
    local retry_options = {
        type = browse_options.type,
        query = browse_options.query,
        page = browse_options.page,
        filters = browse_options.filters,
        filter_draft = browse_options.filter_draft,
        filter_schema = browse_options.filter_schema,
        skip_mode_menu = true,
    }
    local rows = {
        {
            text = message,
            subtitle = I18n.t("Tap to retry"),
            mandatory = I18n.t("Retry"),
            raw_menu_row = true,
            callback = function()
                return self:showMangaForSource(source, retry_options)
            end,
        },
    }
    if type(browse_options.filter_schema) == "table" then
        table.insert(rows, {
            text = I18n.t("Edit filters"),
            raw_menu_row = true,
            callback = function()
                local credentials = self.settings:load()
                return self:openSourceFilterEditor(
                    credentials,
                    source,
                    browse_options.filter_schema,
                    browse_options.filter_draft or { query = browse_options.query, filters = {} }
                )
            end,
        })
    else
        table.insert(rows, {
            text = I18n.t("Edit search"),
            raw_menu_row = true,
            callback = function()
                return self:showSourceSearchPrompt(source, {
                    query = browse_options.query,
                })
            end,
        })
    end
    return rows
end

function SuwayomiClient:showSourceMangaFailureStatus(menu, source, browse_options, error_text)
    local failure_message = self:buildSourceMangaFailureMessage(source, browse_options, error_text)
    return self:showSourceMangaStatus(
        menu,
        self:buildBrowseResultScreenTitle(source, browse_options),
        failure_message,
        self:buildBrowseResultTitle(source, browse_options),
        self:buildSourceMangaFailureRows(source, browse_options, failure_message)
    )
end

function SuwayomiClient:isSourceFilterSearch(browse_options)
    return browse_options
        and browse_options.type == "SEARCH"
        and (type(browse_options.filter_schema) == "table"
            or (type(browse_options.filters) == "table" and #browse_options.filters > 0))
end

function SuwayomiClient:buildSourceMangaEmptyMessage(browse_options)
    if self:isSourceFilterSearch(browse_options) then
        return I18n.t("No manga match these filters.")
    elseif browse_options and browse_options.type == "SEARCH" then
        return I18n.t("No manga match this search.")
    end
    return I18n.t("This source has no manga.")
end

function SuwayomiClient:buildSourceMangaEmptyRows(source, browse_options, message)
    local rows = {
        {
            text = message,
            raw_menu_row = true,
            select_enabled = false,
        },
    }
    if type(browse_options and browse_options.filter_schema) == "table" then
        table.insert(rows, {
            text = I18n.t("Edit filters"),
            raw_menu_row = true,
            callback = function()
                local credentials = self.settings:load()
                return self:openSourceFilterEditor(
                    credentials,
                    source,
                    browse_options.filter_schema,
                    browse_options.filter_draft or { query = browse_options.query, filters = {} }
                )
            end,
        })
    elseif browse_options and browse_options.type == "SEARCH" then
        table.insert(rows, {
            text = I18n.t("Edit search"),
            raw_menu_row = true,
            callback = function()
                return self:showSourceSearchPrompt(source, {
                    query = browse_options.query,
                })
            end,
        })
    end
    return rows
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
        self:showSourceMangaStatus(state.menu, state.title, I18n.t("Loading canceled."), state.detail_title)
    end
end

function SuwayomiClient:shouldAppendSourceMangaPage(session, menu, page)
    if not session
        or session.closed
        or session.loading_more
        or session.has_next_page ~= true
    then
        return false
    end
    local local_page = tonumber(page) or tonumber(menu and menu.page) or 1
    local local_page_count = tonumber(menu and menu.page_num) or local_page
    return local_page >= local_page_count
end

function SuwayomiClient:appendUniqueSourceMangaRows(session, page_manga)
    local seen_ids = {}
    local appended = {}
    for _, manga in ipairs(session.manga_list or {}) do
        if type(manga) == "table" and manga.id ~= nil then
            seen_ids[tostring(manga.id)] = true
        end
    end

    for _, manga in ipairs(page_manga or {}) do
        local manga_id = type(manga) == "table" and manga.id or nil
        if manga_id == nil then
            table.insert(session.manga_list, manga)
            table.insert(appended, manga)
        else
            local dedupe_id = tostring(manga_id)
            if not seen_ids[dedupe_id] then
                seen_ids[dedupe_id] = true
                table.insert(session.manga_list, manga)
                table.insert(appended, manga)
            end
        end
    end
    return appended
end

function SuwayomiClient:getVisibleBrowseChapterCountManga(session, fallback_manga)
    local menu = session and session.menu or nil
    local item_table = type(menu) == "table" and menu.item_table or nil
    if type(item_table) == "table" then
        local visible = {}
        local function appendMenuManga(item_index)
            local item = item_table[item_index]
            local manga = type(item) == "table" and item.manga or nil
            if type(manga) == "table" then
                table.insert(visible, manga)
            end
        end
        local page = tonumber(menu.page) or 1
        local page_items = type(menu.page_items) == "table" and menu.page_items[page] or nil
        if type(page_items) == "table" then
            for _, item_index in ipairs(page_items) do
                appendMenuManga(item_index)
            end
        else
            local perpage = tonumber(menu.perpage)
            if perpage and perpage > 0 then
                local first_index = (math.max(1, page) - 1) * perpage + 1
                local last_index = math.min(#item_table, first_index + perpage - 1)
                for item_index = first_index, last_index do
                    appendMenuManga(item_index)
                end
            end
        end
        if #visible > 0 then
            return visible
        end
    end
    return fallback_manga or {}
end

function SuwayomiClient:queueVisibleBrowseChapterCounts(session, refresh, fallback_manga)
    if not session then
        return
    end
    local visible_manga = self:getVisibleBrowseChapterCountManga(session, fallback_manga)
    if session.chapter_count_enrichment then
        self:appendBrowseChapterCountManga(session.chapter_count_enrichment, visible_manga)
    elseif session.chapter_count_runtime then
        session.chapter_count_enrichment = self:startBrowseChapterCountEnrichment(
            session.credentials,
            visible_manga,
            refresh,
            session.chapter_count_runtime
        )
    end
end

function SuwayomiClient:restartVisibleBrowseChapterCounts(session, refresh)
    if not session then
        return
    end
    if session.chapter_count_enrichment then
        self:cancelBrowseChapterCountEnrichment(session.chapter_count_enrichment)
        session.chapter_count_enrichment = nil
    end
    self:queueVisibleBrowseChapterCounts(session, refresh)
end

function SuwayomiClient:appendSourceMangaResult(session, result, refresh)
    session.loading_more = false
    session.active = nil
    if session.closed or self._source_manga_load_token ~= session.token then
        return
    end
    result = result or {
        ok = false,
        error = I18n.t("Could not load manga."),
    }
    if not result.ok then
        self.plugin:showMessage(self:buildSourceMangaFailureMessage(
            session.source,
            session.next_options or session.browse_options,
            result.error
        ))
        refresh()
        return
    end

    local page_manga = result.manga or {}
    session.current_api_page = tonumber((result.browse_options or session.next_options or {}).page)
        or session.current_api_page
    if #page_manga == 0 then
        session.has_next_page = false
        refresh()
        return
    end
    local appended_manga = self:appendUniqueSourceMangaRows(session, page_manga)
    session.has_next_page = result.has_next_page == true
    refresh()
    local visible_appended_manga = self:filterBrowseManga(appended_manga)
    self:queueVisibleBrowseChapterCounts(session, refresh, visible_appended_manga)
    if self:shouldAppendSourceMangaPage(session, session.menu) then
        self:startSourceMangaAppendLoad(session, refresh)
    end
end

function SuwayomiClient:startSourceMangaAppendLoad(session, refresh)
    local runtime = self:resolveSourceMangaRuntime()
    if not runtime then
        session.has_next_page = false
        self.plugin:showMessage(I18n.t("Could not start manga loading."))
        refresh()
        return
    end
    session.runtime = runtime

    local next_options = {
        type = session.browse_options.type,
        query = session.browse_options.query,
        page = (tonumber(session.current_api_page) or 1) + 1,
        filters = session.browse_options.filters,
        filter_draft = session.browse_options.filter_draft,
        filter_schema = session.browse_options.filter_schema,
    }
    session.loading_more = true
    session.next_options = next_options

    local start_ok, active = pcall(runtime.job.start, {
        active = {
            source = session.source,
            browse_options = next_options,
            result_path = runtime.job.buildResultPath
                and runtime.job.buildResultPath("source_manga_append")
                or nil,
        },
        ffi_util = runtime.ffi_util,
        ui_manager = runtime.ui_manager,
        poll_interval_seconds = self:getSourceMangaPollIntervalSeconds(),
        timeout_seconds = self:getSourceMangaTimeoutSeconds(),
        run = function(path)
            runtime.worker:run(session.credentials, session.source, next_options, path)
        end,
        read_result = function(path)
            return runtime.worker:readResult(path)
        end,
        on_finish = function(finished_active, result)
            if session.closed or session.active ~= finished_active then
                return
            end
            local result_options = result and result.browse_options
                or finished_active.browse_options
                or next_options
            if result then
                result.browse_options = result_options
            end
            self:appendSourceMangaResult(session, result, refresh)
        end,
        on_timeout = function(timed_out_active)
            if session.closed or session.active ~= timed_out_active then
                return
            end
            timed_out_active.canceled = true
            self:appendSourceMangaResult(session, {
                ok = false,
                browse_options = next_options,
                error = I18n.t("Timed out."),
            }, refresh)
        end,
    })
    if not start_ok or not active then
        session.loading_more = false
        session.active = nil
        session.has_next_page = false
        self.plugin:showMessage(I18n.t("Could not start manga loading."))
        refresh()
        return
    end
    session.active = active
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
            self:showSourceMangaStatus(
                existing_menu,
                self:buildBrowseResultScreenTitle(source, browse_options),
                I18n.t("Latest manga is not supported by this source."),
                self:buildBrowseResultTitle(source, browse_options)
            )
            return
        end
        self:showSourceMangaFailureStatus(
            existing_menu,
            source,
            browse_options,
            result.error
        )
        return
    end

    local page = tonumber(browse_options.page) or 1
    local manga_list = result.manga or {}
    local session = {
        token = self._source_manga_load_token,
        credentials = credentials,
        source = source,
        browse_options = browse_options,
        current_api_page = page,
        manga_list = manga_list,
        has_next_page = result.has_next_page == true,
        chapter_count_runtime = self:resolveChapterCountRuntime(),
    }
    local visible_manga = self:filterBrowseManga(manga_list)
    self:log({
        operation = "showMangaForSource",
        event = "manga_loaded",
        source_id = source and source.id,
        type = browse_options.type,
        page = page,
        manga_count = #visible_manga,
    })
    local menu_options = self:buildBrowseResultMenuOptions(source, browse_options)
    menu_options.thumbnail_credentials = credentials
    if existing_menu and menu_options.close_callback == nil then
        menu_options.close_callback = function() end
    end
    if #visible_manga == 0
        and page <= 1
        and session.has_next_page ~= true
    then
        local empty_message = self:buildSourceMangaEmptyMessage(browse_options)
        if not self:showSourceMangaStatus(
            existing_menu,
            menu_options.title,
            empty_message,
            self:buildBrowseResultTitle(source, browse_options),
            self:buildSourceMangaEmptyRows(source, browse_options, empty_message)
        ) then
            self.plugin:showMessage(empty_message)
        end
        return
    end

    local manga_menu = existing_menu
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
        visible_manga = self:filterBrowseManga(session.manga_list)
        if not manga_menu then
            pending_manga_menu_refresh = true
            return
        end
        session.menu = manga_menu
        if self.ui.updateMangaMenu then
            self.ui.updateMangaMenu(manga_menu, visible_manga, selectManga, menu_options)
        end
    end
    menu_options.on_page_changed = function(menu, changed_page)
        session.menu = menu
        self:restartVisibleBrowseChapterCounts(session, refreshMangaMenu)
        if self:shouldAppendSourceMangaPage(session, menu, changed_page) then
            self:startSourceMangaAppendLoad(session, refreshMangaMenu)
        end
    end

    local previous_close_callback = menu_options.close_callback
    menu_options.close_callback = function(...)
        session.closed = true
        if session.active and session.runtime and session.runtime.job and session.runtime.job.cancel then
            session.runtime.job.cancel(session.active)
        end
        if session.chapter_count_enrichment then
            self:cancelBrowseChapterCountEnrichment(session.chapter_count_enrichment)
        end
        if previous_close_callback then
            return previous_close_callback(...)
        end
    end

    if existing_menu and self.ui.updateMangaMenu then
        session.menu = existing_menu
        self.ui.updateMangaMenu(existing_menu, visible_manga, selectManga, menu_options)
    else
        manga_menu = self.ui.showMangaMenu(visible_manga, selectManga, menu_options)
        session.menu = manga_menu
        self:trackScreen("browse-results", manga_menu)
    end
    if pending_manga_menu_refresh then
        refreshMangaMenu()
    end
    if session.chapter_count_runtime then
        self:queueVisibleBrowseChapterCounts(session, refreshMangaMenu, visible_manga)
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

    local title = self:buildBrowseResultScreenTitle(source, browse_options)
    local state = {
        token = self:nextSourceMangaLoadToken(),
        credentials = credentials,
        source = source,
        browse_options = browse_options,
        title = title,
        detail_title = self:buildBrowseResultTitle(source, browse_options),
        runtime = runtime,
    }

    state.menu = self.ui.showMangaMenu({
        { title = I18n.t("Loading manga...") },
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
                error = I18n.t("Could not load manga."),
            }
            local result_source = result and result.source or finished_active.source or source
            local result_options = result and result.browse_options or finished_active.browse_options or browse_options
            if result_options and finished_active.browse_options then
                result_options.filter_draft = result_options.filter_draft or finished_active.browse_options.filter_draft
                result_options.filter_schema = result_options.filter_schema or finished_active.browse_options.filter_schema
            end
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
            self:showSourceMangaFailureStatus(
                state.menu,
                state.source,
                state.browse_options,
                I18n.t("Timed out.")
            )
        end,
    })
    if not start_ok then
        active = nil
    end

    if not active then
        state.finished = true
        self:clearSourceMangaLoad(state)
        self:showSourceMangaFailureStatus(
            state.menu,
            state.source,
            state.browse_options,
            I18n.t("Could not start manga loading.")
        )
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
        if browse_options.type == "SEARCH" then
            browse_options.filters = options.filters
            browse_options.filter_draft = options.filter_draft
            browse_options.filter_schema = options.filter_schema
        end

        if self:startSourceMangaLoad(credentials, source, browse_options) then
            return
        end

        self.plugin:showMessage(I18n.t("Could not start manga loading."))
    end)
end
end

return M
