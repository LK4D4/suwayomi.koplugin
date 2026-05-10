-- Boundary: ChapterActions.
--
-- Responsibility: Public chapter action facade composed from focused action modules plus remaining download/bulk orchestration.
-- Owned state: State stays on the plugin instance so KOReader callbacks keep stable method names and return values.
-- Dependencies: Focused chapter action modules, KOReader UI helpers, settings, debug timing, and gettext.
-- External data: API responses, settings values, queue status, worker files, and filesystem paths remain untrusted at module boundaries.

local ChapterDeleteActions = require("suwayomi/chapters/delete_actions")
local ChapterLocalDownloads = require("suwayomi/chapters/local_downloads")
local ChapterReadActions = require("suwayomi/chapters/read_actions")
local SuwayomiDebug = require("suwayomi/debug")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local ChapterActions = {}
ChapterActions.__index = ChapterActions

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function ChapterActions:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function mergeMethods(target, ...)
    for _, method_table in ipairs({...}) do
        for name, method in pairs(method_table or {}) do
            target[name] = method
        end
    end
end

mergeMethods(
    Methods,
    ChapterLocalDownloads.methods,
    ChapterDeleteActions.methods,
    ChapterReadActions.methods
)

function Methods:openChapter(manga, chapter)
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    if not downloaded or not chapter_path then
        self:showMessage(_("Download the chapter first."))
        return false
    end

    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI then
        self:showMessage(_("KOReader could not open this chapter right now."))
        return false
    end

    if self.saveReaderReturnContext then
        self:saveReaderReturnContext(manga, chapter, chapter_path)
    end

    if ReaderUI.instance and ReaderUI.instance.switchDocument then
        ReaderUI.instance:switchDocument(chapter_path)
    elseif ReaderUI.showReader then
        ReaderUI:showReader(chapter_path)
    else
        self:showMessage(_("KOReader could not open this chapter right now."))
        return false
    end

    return true
end


function Methods:performChapterAction(manga, chapter, action_id)
    if action_id == "open" then
        return self:openChapter(manga, chapter)
    end
    if action_id == "download" then
        self:enqueueChapterDownload(manga, chapter)
        return true
    end
    if action_id == "delete" then
        return self:deleteChapterFromDevice(manga, chapter)
    end
    if action_id == "mark_read" then
        return self:markChapterRead(manga, chapter)
    end
    if action_id == "mark_previous_read" then
        return self:markChaptersBeforeRead(manga, chapter)
    end
    if action_id == "mark_through_read" then
        return self:markChaptersReadThrough(manga, chapter)
    end
    if action_id == "mark_unread" then
        return self:markChapterUnread(manga, chapter)
    end
    return false
end


function Methods:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
    local started_at = SuwayomiDebug.now()
    local queued = 0
    local skipped = 0
    local capped = 0
    local queueable = {}
    for _, chapter in ipairs(chapters or {}) do
        local status = self:getDownloadQueue():getStatus(manga, chapter)
        local downloaded = self:isChapterDownloaded(manga, chapter)
        if downloaded or (status and (status.state == "queued" or status.state == "downloading" or status.state == "downloaded" or status.state == "skipped")) then
            skipped = skipped + 1
        elseif #queueable >= self.max_batch_queue_chapters then
            capped = capped + 1
        else
            table.insert(queueable, chapter)
        end
    end

    self:withChapterMenuRefreshSuppressed(function()
        queued = self:getDownloadQueue():enqueueBatch(manga, queueable, download_directory, { quiet_duplicate = true })
    end)
    skipped = skipped + (#queueable - queued)

    self:clearChapterSelection(true)
    self:refreshChapterMenu({ quick = true })

    if capped > 0 then
        self:showMessage(T(
            _("Queued first %1 downloads. Refine the chapter selection to queue more."),
            self.max_batch_queue_chapters
        ))
    elseif queued == 0 and skipped > 0 then
        self:showMessage(self:formatBulkDownloadMessage(queued, skipped))
    end
    SuwayomiDebug.log({
        operation = "enqueueSelectedChapterDownloads",
        event = "end",
        manga_id = manga and manga.id,
        requested_count = #(chapters or {}),
        queueable_count = #queueable,
        queued_count = queued,
        skipped_count = skipped,
        capped_count = capped,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return queued
end


function Methods:confirmNextUnreadChapterDownloads(limit)
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local download_directory = self:getDownloadDirectoryOrChoose(function()
            self:confirmNextUnreadChapterDownloads(limit)
    end)
    if not download_directory then
        return 0
    end

    local chapters = self:getNextUnreadChaptersForDownload(manga, limit)
    if #chapters == 0 then
        self:showMessage(_("No unread chapters available to download."))
        return 0
    end

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


function Methods:enqueueNextUnreadChapterDownloads(limit)
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local download_directory = self:getDownloadDirectoryOrChoose(function()
            self:enqueueNextUnreadChapterDownloads(limit)
    end)
    if not download_directory then
        return 0
    end

    local chapters = self:getNextUnreadChaptersForDownload(manga, limit)
    if #chapters == 0 then
        self:showMessage(_("No unread chapters available to download."))
        return 0
    end

    return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
end


function Methods:downloadSelectedChapters()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getSelectedChapters(manga, self.current_chapter_context.chapters)
    if #chapters == 0 then
        self:showMessage(_("No chapters selected."))
        return 0
    end

    local download_directory = self:getDownloadDirectoryOrChoose(function(saved_path)
            self:enqueueSelectedChapterDownloads(manga, chapters, saved_path)
    end)
    if not download_directory then
        return 0
    end

    return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
end


function Methods:deleteSelectedChapters()
    local started_at = SuwayomiDebug.now()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getSelectedChapters(manga, self.current_chapter_context.chapters)
    if #chapters == 0 then
        self:showMessage(_("No chapters selected."))
        return 0
    end

    local deleted = 0
    local canceled = 0
    local missing = 0
    local active = 0
    self:withChapterMenuRefreshSuppressed(function()
        for _, chapter in ipairs(chapters) do
            local ok, state = self:deleteChapterFromDeviceWithOptions(manga, chapter, {
                quiet_active = true,
                quiet_missing = true,
                skip_refresh = true,
            })
            if ok then
                deleted = deleted + 1
                if state == "queued" then
                    canceled = canceled + 1
                end
            elseif state == "downloading" then
                active = active + 1
            elseif state == "queued" then
                canceled = canceled + 1
            elseif state == "missing" then
                missing = missing + 1
            end
        end
    end)

    self:clearChapterSelection(true)
    self:refreshChapterMenu()

    if missing > 0 or active > 0 then
        self:showMessage(self:formatBulkDeleteMessage(deleted, 0, missing, active))
    end
    SuwayomiDebug.log({
        operation = "deleteSelectedChapters",
        event = "end",
        requested_count = #chapters,
        deleted_count = deleted,
        missing_count = missing,
        active_count = active,
        canceled_count = canceled,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return deleted
end


function Methods:deleteReadChaptersFromDevice()
    local started_at = SuwayomiDebug.now()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local read_chapters = self:getReadChaptersFromCurrentContext()

    if #read_chapters == 0 then
        self:showMessage(_("No read chapters to delete."))
        return 0
    end

    local deleted = 0
    local missing = 0
    local active = 0
    self:withChapterMenuRefreshSuppressed(function()
        for _, chapter in ipairs(read_chapters) do
            local ok, state = self:deleteChapterFromDeviceWithOptions(manga, chapter, {
                quiet_active = true,
                quiet_missing = true,
                skip_refresh = true,
            })
            if ok then
                deleted = deleted + 1
            elseif state == "downloading" then
                active = active + 1
            elseif state == "missing" then
                missing = missing + 1
            end
        end
    end)

    self:refreshChapterMenu()

    if deleted == 0 or active > 0 then
        self:showMessage(self:formatBulkDeleteMessage(deleted, 0, missing, active))
    end
    SuwayomiDebug.log({
        operation = "deleteReadChaptersFromDevice",
        event = "end",
        requested_count = #read_chapters,
        deleted_count = deleted,
        missing_count = missing,
        active_count = active,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return deleted
end


function Methods:confirmDeleteReadChaptersFromDevice()
    if not self.current_chapter_context then
        return 0
    end

    local read_chapters = self:getReadChaptersFromCurrentContext()
    if #read_chapters == 0 then
        self:showMessage(_("No read chapters to delete."))
        return 0
    end

    return self:showBulkActionConfirmation(
        T(
            self:pluralize(
                #read_chapters,
                _("Delete downloaded files for %1 read chapter?"),
                _("Delete downloaded files for %1 read chapters?")
            ),
            #read_chapters
        ),
        _("Delete"),
        function()
            self:deleteReadChaptersFromDevice()
        end
    )
end


function Methods:markSelectedChaptersRead()
    local started_at = SuwayomiDebug.now()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getSelectedChapters(manga, self.current_chapter_context.chapters)
    if #chapters == 0 then
        self:showMessage(_("No chapters selected."))
        return 0
    end

    local ledger = self:loadChapterLedger()
    for _, chapter in ipairs(chapters) do
        self:markChapterRead(manga, chapter, {
            ledger = ledger,
            skip_refresh = true,
            skip_schedule = true,
            skip_keep_policy = true,
        })
    end

    self:clearChapterSelection(true)
    self:refreshChapterMenu({ ledger = ledger })
    self:saveChapterLedger(ledger)
    self:schedulePendingReadSync()
    self:applyKeepNextUnreadDownloadsPolicy()
    SuwayomiDebug.log({
        operation = "markSelectedChaptersRead",
        event = "end",
        manga_id = manga and manga.id,
        chapter_count = #chapters,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return #chapters
end


function Methods:markSelectedChaptersUnread()
    local started_at = SuwayomiDebug.now()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getSelectedChapters(manga, self.current_chapter_context.chapters)
    if #chapters == 0 then
        self:showMessage(_("No chapters selected."))
        return 0
    end

    local ledger = self:loadChapterLedger()
    for _, chapter in ipairs(chapters) do
        self:markChapterUnread(manga, chapter, {
            ledger = ledger,
            skip_refresh = true,
            skip_schedule = true,
        })
    end

    self:clearChapterSelection(true)
    self:refreshChapterMenu({ ledger = ledger })
    self:saveChapterLedger(ledger)
    self:schedulePendingReadSync()
    SuwayomiDebug.log({
        operation = "markSelectedChaptersUnread",
        event = "end",
        manga_id = manga and manga.id,
        chapter_count = #chapters,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return #chapters
end


function Methods:performBulkChapterAction(action_id, menu_context)
    if action_id == "bulk_downloads" then
        self:showBulkDownloadActions(menu_context)
        return true
    end
    if action_id == "scanlator_filter" then
        self:showScanlatorFilterActions(menu_context)
        return true
    end
    local next_unread_count = tostring(action_id or ""):match("^download_next_(%d+)_unread$")
    if next_unread_count then
        local limit = tonumber(next_unread_count)
        if limit >= 50 then
            self:confirmNextUnreadChapterDownloads(limit)
        else
            self:enqueueNextUnreadChapterDownloads(limit)
        end
        return true
    end
    local keep_unread_count = tostring(action_id or ""):match("^keep_next_(%d+)_unread$")
    if keep_unread_count then
        local limit = tonumber(keep_unread_count)
        if limit >= 50 then
            self:confirmKeepNextUnreadChaptersDownloaded(limit)
        else
            self:keepNextUnreadChaptersDownloaded(limit)
        end
        return true
    end
    if action_id == "delete_read_downloaded" then
        self:confirmDeleteReadChaptersFromDevice()
        return true
    end
    if action_id == "download_selected" then
        self:downloadSelectedChapters()
        return true
    end
    if action_id == "delete_selected" then
        self:deleteSelectedChapters()
        return true
    end
    if action_id == "mark_read_selected" then
        self:markSelectedChaptersRead()
        return true
    end
    if action_id == "mark_unread_selected" then
        self:markSelectedChaptersUnread()
        return true
    end
    if action_id == "select_all" then
        self:selectAllChapters()
        return true
    end
    if action_id == "clear_selection" then
        self:clearChapterSelection()
        return true
    end
    return false
end


function Methods:enqueueChapterDownload(manga, chapter)
    local download_directory = self:getDownloadDirectoryOrChoose(function()
        self:enqueueChapterDownload(manga, chapter)
    end, { next_tick = true })
    if not download_directory then
        return
    end

    self:withChapterMenuRefreshSuppressed(function()
        self:getDownloadQueue():enqueue(manga, chapter, download_directory)
    end)
    self:refreshChapterMenu({ quick = true })
end


function Methods:processChapterDownloadQueue()
    self:getDownloadQueue():process()
end


function Methods:pollChapterDownload()
    self:getDownloadQueue():poll()
end


ChapterActions.methods = Methods

return ChapterActions
