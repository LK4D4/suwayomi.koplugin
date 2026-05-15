-- Boundary: MangaController.
--
-- Responsibility: Owns manga-level actions, library add/remove, chapter refresh, and first-unread selection.
-- Owned state: Coordinates API/client calls but leaves chapter row/menu state to chapter modules.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and gettext are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local SuwayomiDebug = require("suwayomi/debug")
local NetworkRequestJob = require("suwayomi/network/request_job")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template

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
    if not manga or not manga.id then
        self:showMessage(_("This manga cannot be loaded right now."))
        return false
    end

    local credentials = SuwayomiSettings:load()
    local active_requests = self.active_manga_network_requests or {}
    self.active_manga_network_requests = active_requests
    slot_key = slot_key or tostring(request and request.action or "manga_request")

    local previous = active_requests[slot_key]
    if previous and previous.active then
        NetworkRequestJob.cancel(previous.active)
    end

    local request_token = {
        manga_id = tostring(manga.id),
    }
    active_requests[slot_key] = request_token

    local active = NetworkRequestJob.start({
        owner = self,
        credentials = credentials,
        request = request,
        loading_message = loading_message,
        result_prefix = "manga_request",
        timeout_seconds = self.manga_network_timeout_seconds or 30,
        timeout_message = timeout_message or _("Could not load chapters."),
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

function Methods:handleRefreshMangaResult(manga, result, options)
    options = options or {}
    if not result then
        return false
    end
    if not result.ok then
        self:showMessage(_(result.error))
        return false
    end
    if type(result.chapters) ~= "table" then
        self:showMessage(_("Suwayomi server did not refresh manga."))
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
    if not result then
        return false
    end
    if not result.ok then
        self:showMessage(_(result.error))
        return false
    end
    if type(result.chapters) ~= "table" or #result.chapters == 0 then
        self:showMessage(_("This manga has no chapters."))
        return false
    end

    if result.manga then
        self:applyMangaRefreshResult(manga, result.manga)
    end
    local chapters = self:mergeChaptersWithReadLedger(manga, result.chapters)
    local context = self:setCurrentMangaChapterContext(manga, chapters)
    if on_ready then
        on_ready(context)
    end
    return true
end

function Methods:startLoadMangaChapterContext(manga, on_ready)
    local action = self:isMangaUninitialized(manga) and "refresh_manga" or "fetch_chapters_for_manga"
    local message = action == "refresh_manga" and _("Refreshing chapters...") or _("Loading chapters...")
    return self:startMangaNetworkRequest(manga, {
        action = action,
        manga_id = manga and manga.id,
    }, message, function(result)
        self:handleChapterContextResult(manga, result, on_ready)
    end, _("Could not load chapters."), "chapter_context")
end

function Methods:withMangaChapterContext(manga, on_ready)
    local context = self:ensureMangaChapterContext(manga)
    if context then
        if on_ready then
            on_ready(context)
        end
        return true
    end
    if not manga or not manga.id then
        self:showMessage(_("This manga has no chapters loaded."))
        return false
    end
    return self:startLoadMangaChapterContext(manga, on_ready)
end

function Methods:startRefreshMangaForChapters(manga, options)
    return self:startMangaNetworkRequest(manga, {
        action = "refresh_manga",
        manga_id = manga and manga.id,
    }, _("Refreshing chapters..."), function(result)
        self:handleRefreshMangaResult(manga, result, options)
    end, _("Could not load chapters."), "chapter_menu")
end

function Methods:startFetchChaptersForManga(manga, options)
    return self:startMangaNetworkRequest(manga, {
        action = "fetch_chapters_for_manga",
        manga_id = manga and manga.id,
    }, _("Loading chapters..."), function(result)
        self:showChapterResultForManga(manga, result, options)
    end, _("Could not load chapters."), "chapter_menu")
end


function Methods:showChapterResultForManga(manga, result, options)
    options = options or {}
    if not result then
        return
    end
    if not result.ok then
        self:showMessage(_(result.error))
        return
    end

    SuwayomiDebug.log({
        operation = "showChaptersForManga",
        event = "chapters_loaded",
        manga_id = manga and manga.id,
        chapter_count = #(result.chapters or {}),
    })
    if not result.chapters or #result.chapters == 0 then
        self:showMessage(_("This manga has no chapters."))
        return
    end

    local chapters = self:mergeChaptersWithReadLedger(manga, result.chapters)
    self:setCurrentMangaChapterContext(manga, chapters)

    local previous_chapter_menu = self.current_chapter_menu
    if previous_chapter_menu and self.isSuwayomiScreenActive and self:isSuwayomiScreenActive(previous_chapter_menu) and self.closeMenu then
        self:closeMenu(previous_chapter_menu)
    end

    local chapter_menu
    self.current_chapter_options = self:buildChapterMenuOptions(manga, chapters)
    self.current_chapter_options.itemnumber = findReturnedChapterItemNumber(chapters, options.return_context)
    self.current_chapter_options.close_callback = function()
        if self.current_chapter_menu == chapter_menu then
            self.current_chapter_menu = nil
        end
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
    return true
end


function Methods:showChaptersForManga(manga)
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
    local chapter = manga and manga.first_unread_chapter
    if not chapter then
        return false
    end

    return self:isChapterDownloaded(manga, chapter) == true
end


function Methods:getMangaActions(manga)
    local actions = {
        { id = "open_chapters", text = _("Open chapters") },
    }
    local destructive_action

    if self:canOpenFirstUnreadMangaChapter(manga) then
        table.insert(actions, { id = "open_first_unread", text = _("Open first unread") })
    end

    table.insert(actions, { id = "refresh_chapters", text = _("Refresh chapters") })
    if manga and manga.in_library == true then
        destructive_action = { id = "remove_from_library", text = _("Remove from library"), destructive = true }
    else
        table.insert(actions, { id = "add_to_library", text = _("Add to library") })
    end
    table.insert(actions, { id = "download_first_unread", text = _("Download first unread") })
    table.insert(actions, { id = "download_next_10_unread", text = _("Download next 10") })
    table.insert(actions, { id = "more", text = _("More..."), submenu = true })
    if destructive_action then
        table.insert(actions, destructive_action)
    end

    return actions
end


function Methods:showMangaActions(manga, options)
    options = options or {}
    if not SuwayomiUI.showMangaActionsMenu then
        return self:showChaptersForManga(manga)
    end

    local action_options = {}
    for key, value in pairs(options) do
        action_options[key] = value
    end
    action_options.refresh_action_menu_after_library_update = true

    local menu = SuwayomiUI.showMangaActionsMenu({
        title = manga and (manga.title or tostring(manga.id)) or _("Manga actions"),
        actions = self:getMangaActions(manga),
    }, function(action)
        if action then
            self:performMangaAction(manga, action.id, action_options)
        end
    end)
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
        self:showMessage(_("This manga cannot be updated right now."))
        return false
    end

    local loading_message = in_library and _("Adding to library...") or _("Removing from library...")
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
            self:showMessage(_(response.error))
            return
        end

        self:updateMangaFromLibraryStateResponse(manga, response.manga, in_library)
        if options.onMangaUpdated then
            options.onMangaUpdated(manga)
        end
        if in_library then
            self:showMessage(_("Added to library."))
        else
            self:showMessage(_("Removed from library."))
        end
        if options.refresh_action_menu_after_library_update then
            self:showMangaActions(manga, options)
        end
    end, _("Could not update library."), "library_state:" .. tostring(manga.id))
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
        self:showMessage(_("This manga cannot be updated right now."))
        return false
    end

    local callback = function()
        self:setMangaLibraryState(manga, false, options)
    end
    if SuwayomiUI.showConfirm then
        SuwayomiUI.showConfirm({
            text = T(_("Remove %1 from your Suwayomi library?"), manga.title or tostring(manga.id)),
            ok_text = _("Remove"),
            ok_callback = callback,
            cancel_text = _("Cancel"),
        })
    else
        callback()
    end
    return true
end


function Methods:refreshMangaChapters(manga, options)
    if not manga or not manga.id then
        self:showMessage(_("This manga cannot be refreshed right now."))
        return false
    end

    return self:startRefreshMangaForChapters(manga, options)
end


function Methods:showMoreMangaActions(manga, options)
    options = options or {}
    if not SuwayomiUI.showMangaActionsMenu then
        return false
    end
    local menu = SuwayomiUI.showMangaActionsMenu({
        title = _("More..."),
        actions = {
            { id = "download_next_5_unread", text = _("Download next 5") },
            { id = "download_next_50_unread", text = _("Download next 50") },
            { id = "download_all_unread", text = _("Download all unread") },
            { id = "download_all_chapters", text = _("Download all chapters") },
            { id = "keep_downloaded", text = _("Download ahead"), submenu = true },
            { id = "delete_read_downloaded", text = _("Delete read downloads"), destructive = true },
        },
        on_back = function()
            self:showMangaActions(manga, options)
        end,
    }, function(action)
        if action then
            self:performMangaAction(manga, action.id, options)
        end
    end)
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
        title = _("Download ahead"),
        actions = {
            { id = "keep_next_5_unread", text = _("Keep next 5 downloaded") },
            { id = "keep_next_10_unread", text = _("Keep next 10 downloaded") },
            { id = "keep_next_50_unread", text = _("Keep next 50 downloaded") },
            { id = "keep_next_0_unread", text = _("Stop download ahead") },
        },
        on_back = function()
            self:showMoreMangaActions(manga, options)
        end,
    }, function(action)
        if action then
            self:performMangaAction(manga, action.id, options)
        end
    end)
    if self.trackSuwayomiScreen then
        self:trackSuwayomiScreen("manga-actions", menu)
    end
    return menu
end


function Methods:performMangaAction(manga, action_id, options)
    options = options or {}
    if action_id == "open_chapters" then
        self:showChaptersForManga(manga)
        return true
    end
    if action_id == "open_first_unread" then
        if self:ensureMangaChapterContext(manga) then
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
        end)
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
        self:showMoreMangaActions(manga, options)
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
        if limit == 0 then
            SuwayomiSettings:saveMangaKeepNextUnreadDownloads(manga, 0)
            self:showMessage(_("Download ahead disabled."))
            return true
        end
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
        local chapters = self:getNextUnreadChaptersForDownload(manga, limit)
        if #chapters == 0 then
            self:showMessage(_("No unread chapters available to download."))
            return 0
        end

        if confirm then
            return self:showBulkActionConfirmation(
                T(
                    self:pluralize(#chapters, _("Queue %1 unread chapter download?"), _("Queue %1 unread chapter downloads?")),
                    #chapters
                ),
                _("Queue"),
                function()
                    self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
                end
            )
        end

        return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
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
            self:showMessage(_("No unread chapters available to download."))
            return 0
        end

        return self:showBulkActionConfirmation(
            T(
                self:pluralize(#chapters, _("Queue downloads for all %1 unread chapter?"), _("Queue downloads for all %1 unread chapters?")),
                #chapters
            ),
            _("Queue"),
            function()
                self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
            end
        )
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
            self:showMessage(_("This manga has no chapters."))
            return 0
        end

        return self:showBulkActionConfirmation(
            T(
                self:pluralize(#chapters, _("Queue downloads for all %1 chapter?"), _("Queue downloads for all %1 chapters?")),
                #chapters
            ),
            _("Queue"),
            function()
                self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
            end
        )
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


function Methods:confirmKeepNextUnreadChaptersDownloaded(limit)
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local requested_limit = SuwayomiSettings:normalizeMangaKeepNextUnreadDownloads(limit)
    if requested_limit <= 0 then
        return 0
    end

    local download_directory = self:getDownloadDirectoryOrChoose(function()
            self:confirmKeepNextUnreadChaptersDownloaded(requested_limit)
    end)
    if not download_directory then
        return 0
    end

    local chapters = self:getUnreadDownloadBufferCandidates(manga, requested_limit)
    if #chapters == 0 then
        SuwayomiSettings:saveMangaKeepNextUnreadDownloads(manga, requested_limit)
        self:showMessage(_("Download-ahead buffer is already downloaded or queued."))
        return 0
    end

    return self:showBulkActionConfirmation(
        T(
            self:pluralize(
                #chapters,
                _("Queue %1 missing download to keep the next %2 unread chapters available?"),
                _("Queue %1 missing downloads to keep the next %2 unread chapters available?")
            ),
            #chapters,
            requested_limit
        ),
        _("Queue"),
        function()
            SuwayomiSettings:saveMangaKeepNextUnreadDownloads(manga, requested_limit)
            self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
        end
    )
end


function Methods:keepNextUnreadChaptersForManga(manga, limit)
    local requested_limit = SuwayomiSettings:normalizeMangaKeepNextUnreadDownloads(limit)
    if requested_limit <= 0 then
        return true
    end

    local function queue(download_directory)
        local chapters = self:getUnreadDownloadBufferCandidates(manga, requested_limit)
        if requested_limit >= 50 and #chapters > 0 then
            return self:showBulkActionConfirmation(
                T(
                    self:pluralize(
                        #chapters,
                        _("Queue %1 missing download to keep the next %2 unread chapters available?"),
                        _("Queue %1 missing downloads to keep the next %2 unread chapters available?")
                    ),
                    #chapters,
                    requested_limit
                ),
                _("Queue"),
                function()
                    SuwayomiSettings:saveMangaKeepNextUnreadDownloads(manga, requested_limit)
                    self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
                end
            )
        end

        SuwayomiSettings:saveMangaKeepNextUnreadDownloads(manga, requested_limit)
        if #chapters == 0 then
            self:showMessage(_("Download-ahead buffer is already downloaded or queued."))
            return 0
        end

        return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
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


MangaController.methods = Methods

return MangaController
