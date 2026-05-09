--[[
MangaController
Responsibility: Owns manga-level actions, library add/remove, chapter refresh, and first-unread selection.
Owned state: Coordinates API/client calls but leaves chapter row/menu state to chapter modules.
Dependencies: KOReader UI helpers, Suwayomi runtime modules, and gettext are required at module load to match the original plugin runtime.
External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.
]]

local SuwayomiAPI = require("suwayomi/api")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local SuwayomiDebug = require("suwayomi/debug")
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
    if not self:isMangaUninitialized(manga) or not manga.id or not SuwayomiAPI.refreshManga then
        return nil, false
    end

    local credentials = SuwayomiSettings:load()
    local result = self:withLoadingMessage("refresh-manga", _("Refreshing chapters..."), function()
        return SuwayomiAPI.refreshManga(credentials, manga.id)
    end)
    if not result then
        return nil, true
    end
    if not result.ok then
        self:showMessage(_(result.error))
        return nil, true
    end
    if type(result.chapters) ~= "table" then
        self:showMessage(_("Suwayomi server did not refresh manga."))
        return nil, true
    end

    self:applyMangaRefreshResult(manga, result.manga)
    return {
        ok = true,
        manga = manga,
        chapters = result.chapters,
    }, true
end


function Methods:showChapterResultForManga(manga, result)
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

    self.current_chapter_options = self:buildChapterMenuOptions(manga, chapters)
    self.current_chapter_menu = SuwayomiUI.showChapterMenu(self.current_chapter_options, function(chapter)
        self:handleChapterTap(manga, chapter)
    end, function(chapter)
        self:toggleChapterSelection(manga, chapter)
    end)
    return true
end


function Methods:showChaptersForManga(manga)
    return SuwayomiDebug.time("showChaptersForManga", {
        manga_id = manga and manga.id,
    }, function()
        local result, refresh_attempted = self:refreshUninitializedMangaForChapters(manga)
        if not result and refresh_attempted then
            return
        end
        if not result and not refresh_attempted then
            local credentials = SuwayomiSettings:load()
            result = self:withLoadingMessage("chapters", _("Loading chapters..."), function()
                return SuwayomiAPI.fetchChaptersForManga(credentials, manga.id)
            end)
        end
        if not result then
            return
        end
        return self:showChapterResultForManga(manga, result)
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

    if self:canOpenFirstUnreadMangaChapter(manga) then
        table.insert(actions, { id = "open_first_unread", text = _("Open first unread") })
    end

    table.insert(actions, { id = "refresh_chapters", text = _("Refresh chapters") })
    if manga and manga.in_library == true then
        table.insert(actions, { id = "remove_from_library", text = _("Remove from library") })
    else
        table.insert(actions, { id = "add_to_library", text = _("Add to library") })
    end
    table.insert(actions, { id = "download_first_unread", text = _("Download first unread") })
    table.insert(actions, { id = "download_next_10_unread", text = _("Download next 10 unread") })
    table.insert(actions, { id = "more", text = _("More...") })

    return actions
end


function Methods:showMangaActions(manga, options)
    options = options or {}
    if not SuwayomiUI.showMangaActionsMenu then
        return self:showChaptersForManga(manga)
    end

    return SuwayomiUI.showMangaActionsMenu({
        title = manga and (manga.title or tostring(manga.id)) or _("Manga actions"),
        actions = self:getMangaActions(manga),
    }, function(action)
        if action then
            self:performMangaAction(manga, action.id, options)
        end
    end)
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
    if self.getClient then
        local client = self:getClient()
        if client and client.formatLibraryMangaRow then
            manga.menu_text = client:formatLibraryMangaRow(manga)
        end
    end
end


function Methods:setMangaLibraryState(manga, in_library, options)
    options = options or {}
    if not manga or not manga.id then
        self:showMessage(_("This manga cannot be updated right now."))
        return false
    end

    local credentials = SuwayomiSettings:load()
    local loading_key = in_library and "add-manga-library" or "remove-manga-library"
    local loading_message = in_library and _("Adding to library...") or _("Removing from library...")
    local result = self:withLoadingMessage(loading_key, loading_message, function()
        return SuwayomiAPI.updateMangaLibraryState(credentials, manga.id, in_library)
    end)
    if not result then
        return false
    end
    if not result.ok then
        self:showMessage(_(result.error))
        return false
    end

    self:updateMangaFromLibraryStateResponse(manga, result.manga, in_library)
    if options.onMangaUpdated then
        options.onMangaUpdated(manga)
    end
    if in_library then
        self:showMessage(_("Added to library."))
    else
        self:showMessage(_("Removed from library."))
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


function Methods:refreshMangaChapters(manga)
    if not manga or not manga.id then
        self:showMessage(_("This manga cannot be refreshed right now."))
        return false
    end

    local credentials = SuwayomiSettings:load()
    local result = self:withLoadingMessage("refresh-manga", _("Refreshing chapters..."), function()
        return SuwayomiAPI.refreshManga(credentials, manga.id)
    end)
    if result and not result.ok then
        self:showMessage(_(result.error))
        return false
    end
    if result and type(result.manga) == "table" then
        for key, value in pairs(result.manga) do
            manga[key] = value
        end
    end
    if result and type(result.chapters) == "table" then
        return self:showChapterResultForManga(manga, result)
    end
    return self:showChaptersForManga(manga)
end


function Methods:showMoreMangaActions(manga, options)
    if not SuwayomiUI.showMangaActionsMenu then
        return false
    end
    return SuwayomiUI.showMangaActionsMenu({
        title = _("More..."),
        actions = {
            { id = "download_next_5_unread", text = _("Download next 5 unread") },
            { id = "download_next_50_unread", text = _("Download next 50 unread") },
            { id = "download_all_unread", text = _("Download all unread") },
            { id = "download_all_chapters", text = _("Download all chapters") },
            { id = "keep_downloaded", text = _("Keep downloaded") },
            { id = "delete_read_downloaded", text = _("Delete read downloads") },
        },
    }, function(action)
        if action then
            self:performMangaAction(manga, action.id, options)
        end
    end)
end


function Methods:showKeepDownloadedMangaActions(manga, options)
    if not SuwayomiUI.showMangaActionsMenu then
        return false
    end
    return SuwayomiUI.showMangaActionsMenu({
        title = _("Keep downloaded"),
        actions = {
            { id = "keep_next_5_unread", text = _("Keep next 5 unread") },
            { id = "keep_next_10_unread", text = _("Keep next 10 unread") },
            { id = "keep_next_50_unread", text = _("Keep next 50 unread") },
            { id = "stop_keep_unread", text = _("Stop keeping unread") },
        },
    }, function(action)
        if action then
            self:performMangaAction(manga, action.id, options)
        end
    end)
end


function Methods:performMangaAction(manga, action_id, options)
    options = options or {}
    if action_id == "open_chapters" then
        self:showChaptersForManga(manga)
        return true
    end
    if action_id == "open_first_unread" then
        local chapter = self:getFirstUnreadChapterForManga(manga)
            or (manga and manga.first_unread_chapter)
        if chapter then
            return self:openChapter(manga, chapter)
        end
        return false
    end
    if action_id == "refresh_chapters" then
        return self:refreshMangaChapters(manga)
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
        return self:keepNextUnreadChaptersForManga(manga, tonumber(keep_unread_count))
    end
    if action_id == "stop_keep_unread" then
        SuwayomiSettings:saveKeepNextUnreadDownloads(0)
        self:showMessage(_("Stopped keeping unread chapters downloaded."))
        return true
    end
    if action_id == "delete_read_downloaded" then
        if self:ensureMangaChapterContext(manga) then
            self:confirmDeleteReadChaptersFromDevice()
        end
        return true
    end
    return false
end


function Methods:downloadNextUnreadChaptersForManga(manga, limit, confirm)
    if not self:ensureMangaChapterContext(manga) then
        return false
    end

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

    local download_directory = self:getDownloadDirectoryOrChoose(queue)
    if not download_directory then
        return true
    end
    queue(download_directory)
    return true
end


function Methods:confirmDownloadAllUnreadChaptersForManga(manga)
    if not self:ensureMangaChapterContext(manga) then
        return false
    end

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

    local download_directory = self:getDownloadDirectoryOrChoose(queue)
    if not download_directory then
        return true
    end
    queue(download_directory)
    return true
end


function Methods:confirmDownloadAllChaptersForManga(manga)
    if not self:ensureMangaChapterContext(manga) then
        return false
    end

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

    local download_directory = self:getDownloadDirectoryOrChoose(queue)
    if not download_directory then
        return true
    end
    queue(download_directory)
    return true
end


function Methods:confirmKeepNextUnreadChaptersDownloaded(limit)
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        SuwayomiUI.showDirectoryChooser(function(path)
            local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
            self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
            self:confirmKeepNextUnreadChaptersDownloaded(limit)
        end, self:getDownloadDirectoryChooserStartDir())
        return 0
    end

    local chapters = self:getUnreadDownloadBufferCandidates(manga, limit)
    if #chapters == 0 then
        self:showMessage(_("Next unread chapter buffer is already downloaded or queued."))
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
            limit
        ),
        _("Queue"),
        function()
            self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
        end
    )
end


function Methods:keepNextUnreadChaptersForManga(manga, limit)
    if not self:ensureMangaChapterContext(manga) then
        return false
    end

    local requested_limit = tonumber(limit) or 0
    local saved_limit

    local function savePolicy()
        saved_limit = SuwayomiSettings:saveKeepNextUnreadDownloads(requested_limit)
        self:showMessage(T(_("Keep next unread downloaded: %1 chapters"), saved_limit))
        return saved_limit
    end

    if requested_limit <= 0 then
        savePolicy()
        return true
    end

    local function queue(download_directory)
        local chapters = self:getUnreadDownloadBufferCandidates(manga, requested_limit)
        if #chapters == 0 then
            savePolicy()
            self:showMessage(_("Next unread chapter buffer is already downloaded or queued."))
            return 0
        end

        if requested_limit >= 50 then
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
                    savePolicy()
                    self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
                end
            )
        end

        savePolicy()
        return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
    end

    local download_directory = self:getDownloadDirectoryOrChoose(queue)
    if not download_directory then
        return true
    end
    queue(download_directory)
    return true
end


MangaController.methods = Methods

return MangaController
