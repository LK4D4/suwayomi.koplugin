-- Boundary: ChapterActions.
--
-- Responsibility: Public chapter action facade composed from focused action modules plus remaining download/bulk orchestration.
-- Owned state: State stays on the plugin instance so KOReader callbacks keep stable method names and return values.
-- Dependencies: Focused chapter action modules, KOReader UI helpers, settings, debug timing, and i18n.
-- External data: API responses, settings values, queue status, worker files, and filesystem paths remain untrusted at module boundaries.

local ChapterDeleteActions = require("suwayomi/chapters/delete_actions")
local ChapterLocalDownloads = require("suwayomi/chapters/local_downloads")
local ChapterReadActions = require("suwayomi/chapters/read_actions")
local MangaActionMenu = require("suwayomi/manga/action_menu")
local SuwayomiDebug = require("suwayomi/debug")
local I18n = require("suwayomi/i18n")

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
    for _index, method_table in ipairs({...}) do
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
        self:showMessage(I18n.t("Download the chapter first."))
        return false
    end

    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI then
        self:showMessage(I18n.t("KOReader could not open this chapter right now."))
        return false
    end

    if self.saveReaderReturnContext then
        self:saveReaderReturnContext(manga, chapter, chapter_path)
    end
    if self.upsertChapterLedgerEntry then
        self:upsertChapterLedgerEntry(manga, chapter, {
            path = chapter_path,
        })
    end

    if ReaderUI.instance and ReaderUI.instance.switchDocument then
        ReaderUI.instance:switchDocument(chapter_path)
    elseif ReaderUI.showReader then
        ReaderUI:showReader(chapter_path)
    else
        self:showMessage(I18n.t("KOReader could not open this chapter right now."))
        return false
    end

    return true
end


function Methods:performChapterAction(manga, chapter, action_id)
    if action_id == "open" then
        return self:openChapter(manga, chapter)
    end
    if action_id == "download" then
        return self:enqueueChapterDownload(manga, chapter)
    end
    if action_id == "retry_download" then
        return self:retryDownloadJob({ key = self:getDownloadQueue():getKey(manga, chapter) })
    end
    if action_id == "cancel_download" then
        return self:cancelChapterDownload(manga, chapter)
    end
    if action_id == "download_error" then
        return self:showChapterDownloadError(manga, chapter)
    end
    if action_id == "delete" then
        return self:confirmDeleteChapterFromDevice(manga, chapter)
    end
    if action_id == "mark_read" then
        return self:markChapterRead(manga, chapter)
    end
    if action_id == "mark_previous_read" then
        return self:markChaptersBeforeRead(manga, chapter)
    end
    if action_id == "mark_unread" then
        return self:markChapterUnread(manga, chapter)
    end
    return false
end


function Methods:cancelChapterDownload(manga, chapter)
    local cancelled, state = self:getDownloadQueue():cancelPending(manga, chapter)
    if cancelled then
        self:refreshChapterMenu({ quick = true })
        return true
    end
    if state == "store_blocked" or (type(state) == "string" and state:match("^ambiguous_post_replacement")) then
        self:showMessage(I18n.t("Cannot cancel download: storage is ambiguous"))
    elseif state and state ~= "missing" and state ~= "queued" and state ~= "downloading"
        and state ~= "downloaded" and state ~= "skipped" and state ~= "failed" then
        self:showMessage(I18n.f("Could not cancel download: %1", state))
    elseif state == "downloading" then
        self:showMessage(I18n.t("Download is no longer active."))
    else
        self:showMessage(I18n.t("Download is no longer queued."))
    end
    return false
end


function Methods:confirmDeleteChapterFromDevice(manga, chapter)
    local chapter_name = chapter and chapter.name or I18n.t("this chapter")
    if self.showBulkActionConfirmation then
        return self:showBulkActionConfirmation(
            I18n.f("Delete downloaded file for %1 from this device?", chapter_name),
            I18n.t("Delete"),
            function()
                self:deleteChapterFromDevice(manga, chapter)
            end
        )
    end
    return self:deleteChapterFromDevice(manga, chapter)
end


function Methods:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
    local started_at = SuwayomiDebug.now()
    local queued = 0
    local enqueue_err
    local skipped = 0
    local capped = 0
    local queueable = {}
    for _index, chapter in ipairs(chapters or {}) do
        local status = self:getDownloadQueue():getStatus(manga, chapter)
        local downloaded = self:isChapterDownloaded(manga, chapter)
        if self.isChapterInCurrentContext and not self:isChapterInCurrentContext(manga, chapter) then
            skipped = skipped + 1
        elseif downloaded or (status and (status.state == "queued" or status.state == "downloading" or status.state == "downloaded" or status.state == "skipped")) then
            skipped = skipped + 1
        elseif #queueable >= self.max_batch_queue_chapters then
            capped = capped + 1
        else
            table.insert(queueable, chapter)
        end
    end

    self:withChapterMenuRefreshSuppressed(function()
        queued, enqueue_err = self:getDownloadQueue():enqueueBatch(manga, queueable, download_directory, { quiet_duplicate = true })
    end)
    if enqueue_err then
        self:showMessage(I18n.f("Could not queue downloads: %1", enqueue_err))
        return queued, enqueue_err
    end
    skipped = skipped + (#queueable - queued)

    self:clearChapterSelection(true)
    self:refreshChapterMenu({ quick = true })

    if capped > 0 then
        self:showMessage(I18n.f(
            "Queued first %1 downloads. Refine the chapter selection to queue more.",
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
        self:showMessage(I18n.t("No unread chapters available to download."))
        return 0
    end

    return self:showBulkActionConfirmation(
        I18n.count(#chapters, "Queue %1 unread chapter download?", "Queue %1 unread chapter downloads?"),
        I18n.t("Queue"),
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
        self:showMessage(I18n.t("No unread chapters available to download."))
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
        self:showMessage(I18n.t("No chapters selected."))
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
        self:showMessage(I18n.t("No chapters selected."))
        return 0
    end

    local deleted = 0
    local canceled = 0
    local missing = 0
    local active = 0
    self:withChapterMenuRefreshSuppressed(function()
        for _index, chapter in ipairs(chapters) do
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

    if deleted > 0 or canceled > 0 or missing > 0 or active > 0 then
        self:showMessage(self:formatBulkDeleteMessage(deleted, canceled, missing, active))
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


function Methods:confirmDeleteSelectedChapters()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getSelectedChapters(manga, self.current_chapter_context.chapters)
    if #chapters == 0 then
        self:showMessage(I18n.t("No chapters selected."))
        return 0
    end

    if self.showBulkActionConfirmation then
        return self:showBulkActionConfirmation(
            I18n.count(
                #chapters,
                "Delete %1 selected download from device?",
                "Delete %1 selected downloads from device?"
            ),
            I18n.t("Delete"),
            function()
                self:deleteSelectedChapters()
            end
        )
    end

    return self:deleteSelectedChapters()
end



function Methods:deleteReadChaptersFromDevice()
    local started_at = SuwayomiDebug.now()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local read_chapters = self:getReadDownloadedChaptersFromCurrentContext()

    if #read_chapters == 0 then
        self:showMessage(self:formatReadDownloadDeleteMessage(0))
        return 0
    end

    local deleted = 0
    local missing = 0
    local active = 0
    local failed = 0
    self:withChapterMenuRefreshSuppressed(function()
        for _index, chapter in ipairs(read_chapters) do
            local ok, state = self:deleteChapterFromDeviceWithOptions(manga, chapter, {
                quiet_active = true,
                quiet_delete_failed = true,
                quiet_missing = true,
                skip_refresh = true,
            })
            if ok then
                deleted = deleted + 1
            elseif state == "downloading" then
                active = active + 1
            elseif state == "missing" then
                missing = missing + 1
            elseif state == "delete_failed" then
                failed = failed + 1
            end
        end
    end)

    self:refreshChapterMenu()
    self:showMessage(self:formatReadDownloadDeleteMessage(deleted, {
        skipped = missing + active + failed,
        missing = missing,
        active = active,
        failed = failed,
    }))
    SuwayomiDebug.log({
        operation = "deleteReadChaptersFromDevice",
        event = "end",
        requested_count = #read_chapters,
        deleted_count = deleted,
        missing_count = missing,
        active_count = active,
        failed_count = failed,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return deleted
end


function Methods:confirmDeleteReadChaptersFromDevice()
    if not self.current_chapter_context then
        return 0
    end

    local read_chapters = self:getReadDownloadedChaptersFromCurrentContext()
    if #read_chapters == 0 then
        self:showMessage(self:formatReadDownloadDeleteMessage(0))
        return 0
    end

    return self:showBulkActionConfirmation(
        I18n.count(
            #read_chapters,
            "Delete %1 read download from device?",
            "Delete %1 read downloads from device?"
        ),
        I18n.t("Delete"),
        function()
            self:deleteReadChaptersFromDevice()
        end
    )
end

function Methods:getReadDownloadedChaptersFromCurrentContext()
    local manga = self.current_chapter_context and self.current_chapter_context.manga
    local chapters = {}
    for _index, chapter in ipairs(self:getReadChaptersFromCurrentContext()) do
        local downloaded = self:isChapterDownloaded(manga, chapter)
        if downloaded then
            table.insert(chapters, chapter)
        end
    end
    return chapters
end

function Methods:formatReadDownloadDeleteMessage(deleted, details)
    local message = I18n.count(deleted, "Deleted %1 chapter from device.", "Deleted %1 chapters from device.")
    details = details or {}
    local skipped = details.skipped or (details.active or 0) + (details.missing or 0) + (details.failed or 0)
    if skipped > 0 then
        message = message .. " " .. I18n.count(skipped, "Skipped %1 download.", "Skipped %1 downloads.")
    end
    if (details.active or 0) > 0 then
        message = message .. " " .. I18n.count(details.active, "%1 active download.", "%1 active downloads.")
    end
    if (details.missing or 0) > 0 then
        message = message .. " " .. I18n.count(details.missing, "%1 missing download.", "%1 missing downloads.")
    end
    if (details.failed or 0) > 0 then
        message = message .. " " .. I18n.count(
            details.failed,
            "Failed to delete %1 download.",
            "Failed to delete %1 downloads."
        )
    end
    return message
end


function Methods:markSelectedChaptersUnread()
    local started_at = SuwayomiDebug.now()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getSelectedChapters(manga, self.current_chapter_context.chapters)
    if #chapters == 0 then
        self:showMessage(I18n.t("No chapters selected."))
        return 0
    end

    local ledger = self:loadChapterLedger()
    for _index, chapter in ipairs(chapters) do
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
    if action_id == "keep_downloaded" then
        self:showKeepDownloadedActions(menu_context)
        return true
    end
    if action_id == "scanlator_filter" then
        self:showScanlatorFilterActions(menu_context)
        return true
    end
    if MangaActionMenu.isSharedAction(action_id) and self.current_chapter_context and self.performMangaAction then
        return self:performMangaAction(self.current_chapter_context.manga, action_id, {
            menu_context = menu_context,
        })
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
        self:confirmDeleteSelectedChapters()
        return true
    end
    if action_id == "cancel_all_downloads" then
        self:getDownloadQueue():cancelAll()
        self:refreshChapterMenu({ quick = true })
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
    if self.isChapterInCurrentContext and not self:isChapterInCurrentContext(manga, chapter) then return false end
    local download_directory = self:getDownloadDirectoryOrChoose(function()
        self:enqueueChapterDownload(manga, chapter)
    end, { next_tick = true })
    if not download_directory then
        return
    end

    local queued, state
    self:withChapterMenuRefreshSuppressed(function()
        queued, state = self:getDownloadQueue():enqueue(manga, chapter, download_directory)
    end)
    if not queued and state and state ~= "queued" and state ~= "downloading" then
        self:showMessage(I18n.f("Could not queue download: %1", state))
        return false, state
    end
    self:refreshChapterMenu({ quick = true })
    return queued, state
end


function Methods:processChapterDownloadQueue()
    self:getDownloadQueue():process()
end


function Methods:pollChapterDownload()
    self:getDownloadQueue():poll()
end


ChapterActions.methods = Methods

return ChapterActions
