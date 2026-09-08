-- Boundary: MangaController.
--
-- Responsibility: Owns manga-level actions, library add/remove, chapter refresh, and first-unread selection.
-- Owned state: Coordinates API/client calls but leaves chapter row/menu state to chapter modules.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and the plugin i18n facade are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local SuwayomiDebug = require("suwayomi/debug")
local NetworkRequestJob = require("suwayomi/network/request_job")
local MangaActionMenu = require("suwayomi/manga/action_menu")
local I18n = require("suwayomi/i18n")

local MangaController = {}
MangaController.__index = MangaController

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function MangaController:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function getLoadedMangaChapterContext(owner, manga)
    if not owner or not owner.current_chapter_context or not manga then
        return nil
    end
    if owner.isCurrentChapterContextForManga and not owner:isCurrentChapterContextForManga(manga) then
        return nil
    end
    if not owner.isCurrentChapterContextForManga and owner.current_chapter_context.manga ~= manga then
        return nil
    end
    return owner.current_chapter_context
end

local function findReturnedChapterItemNumber(chapters, context)
    if type(chapters) ~= "table" or type(context) ~= "table" then
        return nil
    end

    local chapter_id = context.chapter_id
    if chapter_id ~= nil and chapter_id ~= "" then
        chapter_id = tostring(chapter_id)
        for index, chapter in ipairs(chapters) do
            if tostring(chapter and chapter.id) == chapter_id then
                return index
            end
        end
    end

    local chapter_name = context.chapter_name
    if chapter_name ~= nil and chapter_name ~= "" then
        chapter_name = tostring(chapter_name)
        for index, chapter in ipairs(chapters) do
            if tostring(chapter and chapter.name) == chapter_name then
                return index
            end
        end
    end

    return nil
end

local function hasSourceId(source)
    return type(source) == "table" and source.id ~= nil and tostring(source.id):match("%S") ~= nil
end

local function copyOptions(options)
    local copied = {}
    for key, value in pairs(options or {}) do
        copied[key] = value
    end
    return copied
end

local function guardMangaCallback(owner, manga, callback)
    local is_current = owner.captureChapterActionGuard and owner:captureChapterActionGuard()
    local manga_id = manga and tostring(manga.id or manga.title)
    return function(...)
        if owner.suwayomi_host_retired or (is_current and not is_current())
            or (manga and tostring(manga.id or manga.title) ~= manga_id) then return false end
        return callback(...)
    end
end

local function mangaActionCallback(owner, manga, options)
    return guardMangaCallback(owner, manga, function(action)
        if action and action.id then return owner:performMangaAction(manga, action.id, options) end
    end)
end

function Methods:attachSourceToManga(manga, source)
    return self:getClient():attachSourceToManga(manga, source)
end


function Methods:isMangaUninitialized(manga)
    return manga and manga.initialized == false
end


function Methods:applyMangaRefreshResult(manga, refreshed_manga)
    if type(manga) ~= "table" or type(refreshed_manga) ~= "table" then
        return manga
    end
    for key, value in pairs(refreshed_manga) do
        manga[key] = value
    end
    return manga
end


function Methods:refreshUninitializedMangaForChapters(manga)
    return nil, self:isMangaUninitialized(manga) == true
end

function Methods:startMangaNetworkRequest(manga, request, loading_message, on_finish, timeout_message, slot_key)
    if self.suwayomi_host_retired then return false end
    if not manga or not manga.id then
        self:showMessage(I18n.t("This manga cannot be loaded right now."))
        return false
    end

    local credentials = SuwayomiSettings:load()
    local endpoint_scope = SuwayomiSettings:normalizeEndpointScope(credentials.server_url)
    local active_requests = self.active_manga_network_requests or {}
    self.active_manga_network_requests = active_requests
    slot_key = slot_key or tostring(request and request.action or "manga_request")

    local chapter_request = slot_key == "chapter_menu" or slot_key == "chapter_context"
    if chapter_request then
        self.chapter_request_revision = (self.chapter_request_revision or 0) + 1
        local other_slot = slot_key == "chapter_menu" and "chapter_context" or "chapter_menu"
        local other = active_requests[other_slot]
        active_requests[other_slot] = nil
        if other and other.active then NetworkRequestJob.cancel(other.active) end
        if self.cancelReaderReturnRequest then self:cancelReaderReturnRequest() end
    end

    local previous = active_requests[slot_key]
    if previous and previous.active then
        NetworkRequestJob.cancel(previous.active)
    end

    local request_token = {
        manga_id = tostring(manga.id),
        context = self.current_chapter_context,
    }
    active_requests[slot_key] = request_token

    local active = NetworkRequestJob.start({
        owner = self,
        credentials = credentials,
        request = request,
        loading_message = loading_message,
        result_prefix = "manga_request",
        timeout_seconds = self.manga_network_timeout_seconds or 30,
        timeout_message = timeout_message or I18n.t("Could not load chapters."),
        on_cancel = function()
            if active_requests[slot_key] == request_token then
                active_requests[slot_key] = nil
            end
        end,
        on_finish = function(result)
            if active_requests[slot_key] ~= request_token then
                return
            end
            active_requests[slot_key] = nil
            if self.suwayomi_host_retired or tostring(manga.id) ~= request_token.manga_id
                or (chapter_request and self.current_chapter_context ~= request_token.context)
            then return end
            if chapter_request and result and result.ok and type(result.chapters) == "table" then
                if endpoint_scope ~= SuwayomiSettings:normalizeEndpointScope(SuwayomiSettings:load().server_url) then return end
                manga.endpoint_scope = endpoint_scope
            end
            if on_finish then
                on_finish(result)
            end
        end,
    })
    if not active then
        if active_requests[slot_key] == request_token then
            active_requests[slot_key] = nil
        end
        return false
    end
    if active_requests[slot_key] == request_token then
        request_token.active = active
    end
    return true
end

function Methods:cancelMangaNetworkRequests()
    self.chapter_request_revision = (self.chapter_request_revision or 0) + 1
    local active_requests = self.active_manga_network_requests
    if type(active_requests) ~= "table" then
        return false
    end

    local canceled = false
    for slot_key, request_token in pairs(active_requests) do
        active_requests[slot_key] = nil
        if request_token and request_token.active then
            NetworkRequestJob.cancel(request_token.active)
            canceled = true
        end
    end
    return canceled
end

function Methods:retireChapterHost()
    self.suwayomi_host_retired = true
    self:cancelMangaNetworkRequests()
    if self.cancelReaderReturnRequest then self:cancelReaderReturnRequest() end
end

function Methods:handleRefreshMangaResult(manga, result, options)
    if self.suwayomi_host_retired then return false end
    options = options or {}
    if not result then
        return false
    end
    if not result.ok then
        self:showMessage(result.error)
        return false
    end
    if type(result.chapters) ~= "table" then
        self:showMessage(I18n.t("Suwayomi server did not refresh manga."))
        return false
    end

    self:applyMangaRefreshResult(manga, result.manga)
    if options.onMangaUpdated then
        options.onMangaUpdated(manga)
    end
    return self:showChapterResultForManga(manga, {
        ok = true,
        manga = manga,
        chapters = result.chapters,
    }, options)
end

function Methods:handleChapterContextResult(manga, result, on_ready)
    if self.suwayomi_host_retired then return false end
    if not result then
        return false
    end
    if not result.ok then
        self:showMessage(result.error)
        return false
    end
    if type(result.chapters) ~= "table" then
        self:showMessage(I18n.t("Could not load chapters."))
        return false
    end
    if #result.chapters == 0 then return self:showChapterResultForManga(manga, result) end

    if result.manga then
        self:applyMangaRefreshResult(manga, result.manga)
    end
    local chapters, err = self:mergeChaptersWithReadLedger(manga, result.chapters)
    if not chapters then
        self:showMessage(err or I18n.t("Failed to save settings."))
        return false
    end
    local context = self:setCurrentMangaChapterContext(manga, chapters)
    self:requestMangaRefill(manga)
    if self.current_scanlator_filter and #self:getVisibleChapters(chapters) == 0 then return true end
    if on_ready then
        on_ready(context)
    end
    return true
end

function Methods:startLoadMangaChapterContext(manga, on_ready)
    local action = self:isMangaUninitialized(manga) and "refresh_manga" or "fetch_chapters_for_manga"
    local message = action == "refresh_manga"
        and I18n.t("Refreshing chapters...")
        or I18n.t("Loading chapters...")
    return self:startMangaNetworkRequest(manga, {
        action = action,
        manga_id = manga and manga.id,
    }, message, function(result)
        self:handleChapterContextResult(manga, result, on_ready)
    end, I18n.t("Could not load chapters."), "chapter_context")
end

function Methods:withMangaChapterContext(manga, on_ready, options)
    if self.suwayomi_host_retired then return false end
    options = options or {}
    local context
    if options.defer_empty_context_warning then
        context = getLoadedMangaChapterContext(self, manga)
    else
        context = self:ensureMangaChapterContext(manga)
    end
    if context and (not context.manga.endpoint_scope
        or context.manga.endpoint_scope ~= SuwayomiSettings:normalizeEndpointScope(SuwayomiSettings:load().server_url)) then
        context = nil
    end
    if context then
        if #(context.chapters or {}) == 0 then
            self:showMessage(I18n.t("This manga has no chapters."))
            return false
        end
        if self.current_scanlator_filter and #self:getVisibleChapters(context.chapters) == 0 then
            self:showMessage(I18n.t("No chapters match the saved scanlator filter. Choose another scanlator or All scanlators."))
            return false
        end
        if on_ready then
            on_ready(context)
        end
        return true
    end
    if not manga or not manga.id then
        self:showMessage(I18n.t("This manga has no chapters loaded."))
        return false
    end
    return self:startLoadMangaChapterContext(manga, on_ready)
end

function Methods:startRefreshMangaForChapters(manga, options)
    return self:startMangaNetworkRequest(manga, {
        action = "refresh_manga",
        manga_id = manga and manga.id,
    }, I18n.t("Refreshing chapters..."), function(result)
        self:handleRefreshMangaResult(manga, result, options)
    end, I18n.t("Could not load chapters."), "chapter_menu")
end

function Methods:startFetchChaptersForManga(manga, options)
    return self:startMangaNetworkRequest(manga, {
        action = "fetch_chapters_for_manga",
        manga_id = manga and manga.id,
    }, I18n.t("Loading chapters..."), function(result)
        self:showChapterResultForManga(manga, result, options)
    end, I18n.t("Could not load chapters."), "chapter_menu")
end

function Methods:buildReaderReturnCloseTarget (_reader, manga)
    if type(manga) ~= "table" then
        return nil
    end
    if manga.in_library == true then
        return { kind = "library" }
    end
    if hasSourceId(manga.source) then
        return { kind = "source", source = manga.source }
    end
    return nil
end

function Methods:openReaderReturnCloseTarget(target)
    if type(target) ~= "table" then
        return nil
    end
    if target.kind == "library" and self.showLibrary then
        return self:showLibrary()
    end
    if target.kind == "source" and hasSourceId(target.source) then
        local client = self.getClient and self:getClient() or nil
        if client and client.showSourceModeMenu then
            return client:showSourceModeMenu(target.source)
        end
    end
    return nil
end


function Methods:showChapterResultForManga(manga, result, options)
    if self.suwayomi_host_retired then return false end
    options = options or {}
    if not result then
        return
    end
    if not result.ok then
        self:showMessage(result.error)
        return
    end

    SuwayomiDebug.log({
        operation = "showChaptersForManga",
        event = "chapters_loaded",
        manga_id = manga and manga.id,
        chapter_count = #(result.chapters or {}),
    })
    if type(result.chapters) ~= "table" then
        self:showMessage(I18n.t("Could not load chapters."))
        return
    end

    local chapters, err = self:mergeChaptersWithReadLedger(manga, result.chapters)
    if not chapters then
        self:showMessage(err or I18n.t("Failed to save settings."))
        return false
    end
    local previous_context, previous_filter = self.current_chapter_context, self.current_scanlator_filter
    local previous_selection, previous_mode = self.selected_chapters, self.selection_mode
    -- Context publication prunes selection; stage a copy until reconciliation commits.
    if previous_selection then
        self.selected_chapters = {}
        for key, selected in pairs(previous_selection) do self.selected_chapters[key] = selected end
    end
    self:setCurrentMangaChapterContext(manga, chapters)
    local chapter_options = self:buildChapterMenuOptions(manga, chapters)
    if not chapter_options then
        self.current_chapter_context, self.current_scanlator_filter = previous_context, previous_filter
        self.selected_chapters, self.selection_mode = previous_selection, previous_mode
        return false
    end

    local previous_chapter_menu = self.current_chapter_menu
    if previous_chapter_menu and self.isSuwayomiScreenActive and self:isSuwayomiScreenActive(previous_chapter_menu) and self.closeMenu then
        self:closeMenu(previous_chapter_menu)
    end

    local chapter_menu
    self.current_chapter_options = chapter_options
    self.current_chapter_options.itemnumber = findReturnedChapterItemNumber(chapters, options.return_context)
    local reader_return_close_target = options.reader_return_close_target
    self.current_chapter_options.close_callback = function()
        local is_current_menu = self.current_chapter_menu == chapter_menu
        if is_current_menu then
            self.current_chapter_menu = nil
        end
        if is_current_menu
            and not self.suwayomi_plugin_closing
            and reader_return_close_target
            and self.openReaderReturnCloseTarget
        then
            return self:openReaderReturnCloseTarget(reader_return_close_target)
        end
        return nil
    end
    chapter_menu = SuwayomiUI.showChapterMenu(self.current_chapter_options, function(chapter)
        self:handleChapterTap(manga, chapter)
    end, function(chapter)
        self:toggleChapterSelection(manga, chapter)
    end)
    self.current_chapter_menu = chapter_menu
    if self.trackSuwayomiScreen then
        self:trackSuwayomiScreen("chapters", chapter_menu)
    end
    if #chapters == 0 then
        self:showMessage(I18n.t("This manga has no chapters."))
    end
    self:requestMangaRefill(manga)
    return true
end


function Methods:showChaptersForManga(manga)
    if self.suwayomi_host_retired then return false end
    return SuwayomiDebug.time("showChaptersForManga", {
        manga_id = manga and manga.id,
    }, function()
        if self:isMangaUninitialized(manga) then
            return self:startRefreshMangaForChapters(manga)
        end
        return self:startFetchChaptersForManga(manga)
    end)
end


function Methods:canOpenFirstUnreadMangaChapter(manga)
    return MangaActionMenu.canOpenFirstUnread(self, manga)
end


function Methods:getMangaActions(manga)
    return MangaActionMenu.buildMainActions(self, manga, {
        include_open_chapters = true,
    })
end


function Methods:getMangaInformationActions(manga)
    local actions = {
        { id = "open_chapters", text = I18n.t("Open chapters") },
    }
    if MangaActionMenu.canOpenFirstUnread(self, manga) then
        table.insert(actions, { id = "open_first_unread", text = I18n.t("Open next unread") })
    end
    if manga and manga.id then
        if manga.in_library == true then
            table.insert(actions, { id = "remove_from_library", text = I18n.t("Remove from library"), destructive = true })
        else
            table.insert(actions, { id = "add_to_library", text = I18n.t("Add to library") })
        end
    end
    return actions
end


function Methods:showMangaActions(manga, options)
    options = options or {}
    local action_options = copyOptions(options)
    action_options.refresh_action_menu_after_library_update = true

    if SuwayomiUI.showMangaInformation then
        return self:performMangaAction(manga, "manga_information", action_options)
    end

    if not SuwayomiUI.showMangaActionsMenu then
        return self:showChaptersForManga(manga)
    end

    local menu = SuwayomiUI.showMangaActionsMenu({
        title = manga and (manga.title or tostring(manga.id)) or I18n.t("Manga actions"),
        actions = self:getMangaActions(manga),
    }, mangaActionCallback(self, manga, action_options))
    if self.trackSuwayomiScreen then
        self:trackSuwayomiScreen("manga-actions", menu)
    end
    return menu
end


function Methods:updateMangaFromLibraryStateResponse(manga, updated_manga, in_library)
    if type(manga) ~= "table" then
        return
    end
    manga.in_library = in_library == true
    if type(updated_manga) == "table" then
        for key, value in pairs(updated_manga) do
            manga[key] = value
        end
        manga.in_library = updated_manga.in_library
        if manga.in_library == nil then
            manga.in_library = in_library == true
        end
    end
end


function Methods:setMangaLibraryState(manga, in_library, options)
    options = options or {}
    if not manga or not manga.id then
        self:showMessage(I18n.t("This manga cannot be updated right now."))
        return false
    end

    local loading_message = in_library
        and I18n.t("Adding to library...")
        or I18n.t("Removing from library...")
    local result
    result = self:startMangaNetworkRequest(manga, {
        action = "update_manga_library_state",
        manga_id = manga and manga.id,
        in_library = in_library == true,
    }, loading_message, function(response)
        if not response then
            return
        end
        if not response.ok then
            self:showMessage(response.error)
            return
        end

        self:updateMangaFromLibraryStateResponse(manga, response.manga, in_library)
        if options.onMangaUpdated then
            options.onMangaUpdated(manga)
        end
        if options.refresh_action_menu_after_library_update then
            self:showMangaActions(manga, options)
        end
    end, I18n.t("Could not update library."), "library_state:" .. tostring(manga.id))
    if not result then
        return false
    end
    return true
end


function Methods:addMangaToLibrary(manga, options)
    return self:setMangaLibraryState(manga, true, options)
end


function Methods:confirmRemoveMangaFromLibrary(manga, options)
    options = options or {}
    if not manga or not manga.id then
        self:showMessage(I18n.t("This manga cannot be updated right now."))
        return false
    end

    local callback = function()
        self:setMangaLibraryState(manga, false, options)
    end
    if SuwayomiUI.showConfirm then
        SuwayomiUI.showConfirm({
            text = I18n.f("Remove %1 from your Suwayomi library?", manga.title or tostring(manga.id)),
            ok_text = I18n.t("Remove"),
            ok_callback = callback,
            cancel_text = I18n.t("Cancel"),
        })
    else
        callback()
    end
    return true
end


function Methods:refreshMangaChapters(manga, options)
    if not manga or not manga.id then
        self:showMessage(I18n.t("This manga cannot be refreshed right now."))
        return false
    end

    return self:startRefreshMangaForChapters(manga, options)
end


function Methods:showMoreMangaActions(manga, options)
    return self:showBulkDownloadMangaActions(manga, options)
end


function Methods:showBulkDownloadMangaActions(manga, options)
    options = options or {}
    if not SuwayomiUI.showMangaActionsMenu then
        return false
    end
    local menu = SuwayomiUI.showMangaActionsMenu({
        title = I18n.t("Bulk downloads"),
        actions = MangaActionMenu.buildBulkDownloadActions(),
        on_back = guardMangaCallback(self, manga, function()
            self:showMangaActions(manga, options)
        end),
    }, mangaActionCallback(self, manga, options))
    if self.trackSuwayomiScreen then
        self:trackSuwayomiScreen("manga-actions", menu)
    end
    return menu
end


function Methods:showKeepDownloadedMangaActions(manga, options)
    options = options or {}
    if not SuwayomiUI.showMangaActionsMenu then
        return false
    end
    local menu = SuwayomiUI.showMangaActionsMenu({
        title = I18n.t("Download ahead"),
        actions = MangaActionMenu.buildKeepDownloadedActions(),
        on_back = guardMangaCallback(self, manga, function()
            self:showMangaActions(manga, options)
        end),
    }, mangaActionCallback(self, manga, options))
    if self.trackSuwayomiScreen then
        self:trackSuwayomiScreen("manga-actions", menu)
    end
    return menu
end


function Methods:performMangaAction(manga, action_id, options)
    if self.suwayomi_host_retired then return false end
    options = options or {}
    if action_id == "open_chapters" then
        self:showChaptersForManga(manga)
        return true
    end
    if action_id == "manga_information" then
        if SuwayomiUI.showMangaInformation then
            local info_action_options = copyOptions(options)
            info_action_options.refresh_action_menu_after_library_update = true
            local dialog = SuwayomiUI.showMangaInformation(manga, {
                actions = self:getMangaInformationActions(manga),
                onAction = mangaActionCallback(self, manga, info_action_options),
            })
            if dialog and self.trackSuwayomiScreen then
                self:trackSuwayomiScreen("manga-information", dialog)
            end
            return true
        end
        return false
    end
    if action_id == "open_first_unread" then
        if getLoadedMangaChapterContext(self, manga) then
            local chapter = self:getFirstUnreadChapterForManga(manga)
            if chapter then
                return self:openChapter(manga, chapter)
            end
            return false
        end
        return self:withMangaChapterContext(manga, function()
            local resolved_chapter = self:getFirstUnreadChapterForManga(manga)
            if resolved_chapter then
                self:openChapter(manga, resolved_chapter)
            end
        end, {
            defer_empty_context_warning = true,
        })
    end
    if action_id == "refresh_chapters" then
        return self:refreshMangaChapters(manga, options)
    end
    if action_id == "add_to_library" then
        return self:addMangaToLibrary(manga, options)
    end
    if action_id == "remove_from_library" then
        return self:confirmRemoveMangaFromLibrary(manga, options)
    end
    if action_id == "more" then
        self:showBulkDownloadMangaActions(manga, options)
        return true
    end
    if action_id == "bulk_downloads" then
        self:showBulkDownloadMangaActions(manga, options)
        return true
    end
    if action_id == "keep_downloaded" then
        self:showKeepDownloadedMangaActions(manga, options)
        return true
    end
    if action_id == "download_first_unread" then
        return self:downloadNextUnreadChaptersForManga(manga, 1, false)
    end
    local next_unread_count = tostring(action_id or ""):match("^download_next_(%d+)_unread$")
    if next_unread_count then
        local limit = tonumber(next_unread_count)
        return self:downloadNextUnreadChaptersForManga(manga, limit, limit >= 50)
    end
    if action_id == "download_all_unread" then
        return self:confirmDownloadAllUnreadChaptersForManga(manga)
    end
    if action_id == "download_all_chapters" then
        return self:confirmDownloadAllChaptersForManga(manga)
    end
    local keep_unread_count = tostring(action_id or ""):match("^keep_next_(%d+)_unread$")
    if keep_unread_count then
        local limit = tonumber(keep_unread_count)
        return self:keepNextUnreadChaptersForManga(manga, limit)
    end
    if action_id == "delete_read_downloaded" then
        self:withMangaChapterContext(manga, function()
            self:confirmDeleteReadChaptersFromDevice()
        end)
        return true
    end
    return false
end


function Methods:downloadNextUnreadChaptersForManga(manga, limit, confirm)
    local function queue(download_directory)
        local chapters, skipped = self:getNextUnreadChaptersForDownload(manga, limit, download_directory)
        if #chapters == 0 then
            return self:confirmChapterDownloadBatch(manga, chapters, download_directory, { unread = true, skipped = skipped })
        end

        if confirm or limit >= self.max_batch_queue_chapters then
            return self:confirmChapterDownloadBatch(manga, chapters, download_directory, {
                scope = I18n.f("Download next %1 (up to 50 new)", limit), unread = true, skipped = skipped,
            })
        end

        return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory,
            self:captureChapterDownloadBatch(manga, chapters, download_directory, { unread = true, skipped = skipped }))
    end

    local function queueAfterContext(download_directory)
        return self:withMangaChapterContext(manga, function()
            queue(download_directory)
        end)
    end

    local download_directory = self:getDownloadDirectoryOrChoose(queueAfterContext)
    if not download_directory then
        return true
    end
    return queueAfterContext(download_directory)
end


function Methods:confirmDownloadAllUnreadChaptersForManga(manga)
    local function queue(download_directory)
        local chapters = self:getUnreadChaptersForManga(manga)
        if #chapters == 0 then
            self:showMessage(I18n.t("No unread chapters available to download."))
            return 0
        end

        return self:confirmChapterDownloadBatch(manga, chapters, download_directory, {
            scope = I18n.t("Download all unread (up to 50 new)"), unread = true,
        })
    end

    local function queueAfterContext(download_directory)
        return self:withMangaChapterContext(manga, function()
            queue(download_directory)
        end)
    end

    local download_directory = self:getDownloadDirectoryOrChoose(queueAfterContext)
    if not download_directory then
        return true
    end
    return queueAfterContext(download_directory)
end


function Methods:confirmDownloadAllChaptersForManga(manga)
    local function queue(download_directory)
        local chapters = self:getAllChaptersForManga(manga)
        if #chapters == 0 then
            self:showMessage(I18n.t("This manga has no chapters."))
            return 0
        end

        return self:confirmChapterDownloadBatch(manga, chapters, download_directory, {
            scope = I18n.t("Download all chapters (up to 50 new)"),
        })
    end

    local function queueAfterContext(download_directory)
        return self:withMangaChapterContext(manga, function()
            queue(download_directory)
        end)
    end

    local download_directory = self:getDownloadDirectoryOrChoose(queueAfterContext)
    if not download_directory then
        return true
    end
    return queueAfterContext(download_directory)
end




function Methods:keepNextUnreadChaptersForManga(manga, limit)
    if self.suwayomi_host_retired then return false end
    local requested_limit = SuwayomiSettings:normalizeMangaKeepNextUnreadDownloads(limit)
    if requested_limit == 0 then return self:setMangaDownloadAhead(manga, 0) end
    local function accept(context)
        local current_manga = context.manga
        if requested_limit == 50 then
            return self:showBulkActionConfirmation(
                I18n.t("Keep the first 50 filtered unread chapters available? Existing downloads and queued chapters count toward this buffer."),
                I18n.t("Enable download ahead"),
                function() return self:setMangaDownloadAhead(current_manga, requested_limit) end)
        end
        return self:setMangaDownloadAhead(current_manga, requested_limit)
    end
    -- Policy can be enabled while configuration is incomplete; the durable
    -- evaluation exposes the missing directory rather than losing the request.
    local context = self.current_chapter_context
    if context and self:isCurrentChapterContextForManga(manga)
        and context.manga.endpoint_scope
        and context.manga.endpoint_scope == SuwayomiSettings:normalizeEndpointScope(SuwayomiSettings:load().server_url) then
        return accept(context)
    end
    return self:startMangaNetworkRequest(manga, {
        action = self:isMangaUninitialized(manga) and "refresh_manga" or "fetch_chapters_for_manga",
        manga_id = manga and manga.id,
    }, I18n.t("Loading chapters..."), function(result)
        if self:showChapterResultForManga(manga, result) then accept(self.current_chapter_context) end
    end, I18n.t("Could not load chapters."), "chapter_context")
end


MangaController.methods = Methods

return MangaController
