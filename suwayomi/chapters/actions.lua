-- Boundary: ChapterActions.
--
-- Responsibility: Public chapter actions, captured bulk download confirmations, and checked admission results, composed with focused read/delete modules.
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

function Methods:verifyChapterDownload(manga, chapter, open_when_valid)
    if self.isChapterInCurrentContext and not self:isChapterInCurrentContext(manga, chapter) then return false end
    local request = {}
    local completed = false
    self.chapter_archive_request = request
    local context_current = self.captureChapterActionGuard and self:captureChapterActionGuard()
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    if not downloaded or not chapter_path then
        self:showMessage(I18n.t("Download the chapter first."))
        return false
    end
    local function is_current()
        return not self.suwayomi_host_retired
            and self.chapter_archive_request == request
            and (not context_current or context_current())
            and (not self.isChapterInCurrentContext or self:isChapterInCurrentContext(manga, chapter))
            and self:getChapterPath(manga, chapter) == chapter_path
    end
    local accepted, err = self:getDownloadQueue():verifyArchive(manga, chapter, chapter_path, function(result)
        if completed or not is_current() then return end
        completed = true
        if self.refreshChapterMenu then self:refreshChapterMenu() end
        if result.state ~= "valid" then
            self:showChapterDownloadError(manga, chapter)
            return
        end
        if not open_when_valid then
            return
        end
        local ok, ReaderUI = pcall(require, "apps/reader/readerui")
        if not ok or not ReaderUI
            or not ((ReaderUI.instance and ReaderUI.instance.switchDocument) or ReaderUI.showReader)
        then
            self:showMessage(I18n.t("KOReader could not open this chapter right now."))
            return
        end
        if not is_current() then return end
        local associated, association_err = self:getDownloadQueue().refill:associate(manga)
        if not associated then
            self:showMessage(association_err or I18n.t("Failed to save settings."))
            return
        end
        if self.saveReaderReturnContext then
            self:saveReaderReturnContext(manga, chapter, chapter_path)
        end
        if self.upsertChapterLedgerEntry then
            local saved, save_err = self:upsertChapterLedgerEntry(manga, chapter, {
                path = chapter_path, endpoint_scope = manga.endpoint_scope,
            })
            if not saved then
                self:showMessage(save_err or I18n.t("Failed to save settings."))
                return
            end
        end
        if ReaderUI.instance and ReaderUI.instance.switchDocument then
            ReaderUI.instance:switchDocument(chapter_path)
        else
            ReaderUI:showReader(chapter_path)
        end
    end, { is_current = is_current })
    if not accepted then
        self:showMessage(err == "verification_busy" and I18n.t("Another download is being verified.")
            or I18n.t("Could not verify download"))
    end
    return accepted, err
end

function Methods:openChapter(manga, chapter)
    return self:verifyChapterDownload(manga, chapter, true)
end


function Methods:performChapterAction(manga, chapter, action_id)
    if self.isChapterInCurrentContext and not self:isChapterInCurrentContext(manga, chapter) then return false end
    self.chapter_archive_request = nil
    if action_id == "open" then
        return self:openChapter(manga, chapter)
    end
    if action_id == "download" then
        return self:enqueueChapterDownload(manga, chapter)
    end
    if action_id == "verify_download" then
        return self:verifyChapterDownload(manga, chapter)
    end
    if action_id == "redownload" then
        return self:redownloadDownloadJob({
            key = self:getDownloadQueue():getKey(manga, chapter),
            manga = manga,
            chapter = chapter,
        })
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


function Methods:captureChapterDownloadBatch(manga, chapters, download_directory, options)
    options = options or {}
    local queue = self:getDownloadQueue()
    local batch = {
        manga = queue:copyMangaMetadata(manga), chapters = {},
        download_directory = download_directory,
        skipped = options.skipped or 0, capped = 0, scope = options.scope,
        limit = self.max_batch_queue_chapters,
        context = self.current_chapter_context, unread = options.unread,
        menu = self.current_chapter_menu, filter = self.current_scanlator_filter,
        saved_filter = self:loadMangaScanlatorFilter(manga),
        is_current = self.captureChapterActionGuard and self:captureChapterActionGuard(),
    }
    batch.manga.endpoint_scope = manga.endpoint_scope
    local current_ids
    local context_allowed = not self.suwayomi_host_retired
    if self.isChapterInCurrentContext and batch.context then
        context_allowed = context_allowed and self:isCurrentChapterContextForManga(manga)
        current_ids = {}
        for _, chapter in ipairs(self:getVisibleChapters(batch.context.chapters)) do
            current_ids[tostring(chapter.id)] = true
        end
    end
    local seen = {}
    local scanlator_filter = batch.saved_filter or batch.filter
    for _index, chapter in ipairs(chapters or {}) do
        local key = queue:getKey(manga, chapter)
        if not seen[key] and (not scanlator_filter or self:getChapterScanlator(chapter) == scanlator_filter)
            and not (batch.unread and chapter.is_read == true) then
            seen[key] = true
            if not context_allowed or (current_ids and not current_ids[tostring(chapter.id)])
                or not queue:canEnqueue(manga, chapter, download_directory) then
                batch.skipped = batch.skipped + 1
            elseif #batch.chapters >= batch.limit then
                batch.capped = batch.capped + 1
            else
                table.insert(batch.chapters, queue:copyChapterMetadata(chapter))
            end
        end
    end
    return batch
end


local function noDownloadCandidatesMessage(batch)
    if batch.skipped > 0 then
        return I18n.t("No new downloads available: chapters are already downloaded or in the download queue.")
    end
    if batch.saved_filter then
        return I18n.t("No eligible chapters match the saved scanlator filter.")
    end
    return I18n.t("No chapters available to download.")
end

function Methods:confirmChapterDownloadBatch(manga, chapters, download_directory, options, batch)
    batch = batch or self:captureChapterDownloadBatch(manga, chapters, download_directory, options)
    if #batch.chapters == 0 then
        self:showMessage(noDownloadCandidatesMessage(batch))
        return 0
    end
    local parts = {
        batch.scope or I18n.t("Download selected (up to 50 new)"),
        manga.title or I18n.t("Manga"),
        I18n.count(#batch.chapters, "Queue up to %1 new chapter download?", "Queue up to %1 new chapter downloads?"),
    }
    if batch.capped > 0 then
        parts[#parts + 1] = I18n.count(batch.capped,
            "%1 more chapter is available. Run this action again to download it.",
            "%1 more chapters are available. Run this action again to download them.")
    end
    if batch.saved_filter or batch.filter then
        table.insert(parts, 3, I18n.f("Scanlator: %1", batch.saved_filter or batch.filter))
    end
    local function accept()
        return self:enqueueSelectedChapterDownloads(batch.manga, batch.chapters, batch.download_directory, batch)
    end
    -- Stale batch admission reports zero without persisting or changing selection.
    return self:showBulkActionConfirmation(table.concat(parts, "\n"), I18n.t("Queue"), accept, accept)
end

function Methods:enqueueSelectedChapterDownloads(manga, chapters, download_directory, batch)
    if not batch then
        batch = self:captureChapterDownloadBatch(manga, chapters, download_directory)
        if #batch.chapters == 0 then
            self:showMessage(noDownloadCandidatesMessage(batch))
            return 0
        end
        if batch.capped > 0 then
            return self:confirmChapterDownloadBatch(manga, chapters, download_directory, nil, batch)
        end
    end
    if batch.accepted then return 0 end
    batch.accepted = true
    local queue = self:getDownloadQueue()
    local stale = batch.context ~= self.current_chapter_context
        or (batch.is_current and not batch.is_current())
        or batch.menu ~= self.current_chapter_menu
        or batch.filter ~= self.current_scanlator_filter
        or batch.saved_filter ~= self:loadMangaScanlatorFilter(batch.manga)
        or (batch.context and queue:getKey(batch.context.manga, {}) ~= queue:getKey(batch.manga, {}))
    local current_chapters = {}
    for _, chapter in ipairs(batch.context and batch.context.chapters or {}) do
        current_chapters[queue:getKey(batch.context.manga, chapter)] = chapter
    end
    local candidates = {}
    for _, chapter in ipairs(batch.chapters) do
        local current = current_chapters[queue:getKey(batch.manga, chapter)]
        local scanlator_filter = batch.saved_filter or batch.filter
        if not stale and (not batch.context or current) and not (batch.unread and current and current.is_read == true)
            and (not scanlator_filter or self:getChapterScanlator(current or chapter) == scanlator_filter) then
            table.insert(candidates, chapter)
        end
    end
    local queued, enqueue_err, outcome = 0, nil, { skipped = 0, failed = 0, unconfirmed = 0 }
    if not stale and #candidates > 0 then
        local associated
        associated, enqueue_err = queue.refill:associate(batch.manga)
        if not associated then
            self:showMessage(enqueue_err or I18n.t("Failed to save settings."))
            return 0, enqueue_err
        end
    end
    if not stale then
        self:withChapterMenuRefreshSuppressed(function()
            queued, enqueue_err, outcome = queue:enqueueBatch(batch.manga, candidates, batch.download_directory,
                { quiet_duplicate = true, provenance = "explicit" })
        end)
    end
    if not enqueue_err and not stale then
        self:clearChapterSelection(true)
        self:refreshChapterMenu({ quick = true })
    end
    SuwayomiDebug.log({
        operation = "enqueueSelectedChapterDownloads", event = "end",
        queued_count = queued, skipped_count = batch.skipped + #batch.chapters - #candidates + outcome.skipped,
        capped_count = batch.capped, failed_count = outcome.failed, unconfirmed_count = outcome.unconfirmed,
        status = stale and "stale" or (enqueue_err and "failed" or "accepted"),
        code = enqueue_err and tostring(enqueue_err):match("^([%w_]+)"),
    })
    if not enqueue_err and not stale and outcome.failed == 0 and outcome.unconfirmed == 0 then
        return queued, enqueue_err
    end
    local parts = {}
    if outcome.failed > 0 then
        table.insert(parts, I18n.count(outcome.failed, "Failed to queue %1 chapter download.", "Failed to queue %1 chapter downloads."))
    end
    if outcome.unconfirmed > 0 then
        table.insert(parts, I18n.count(outcome.unconfirmed, "Could not confirm %1 chapter download.", "Could not confirm %1 chapter downloads."))
    end
    if outcome.failed > 0 or outcome.unconfirmed > 0 then
        parts[#parts + 1] = I18n.t("Reopen the chapter list and try again.")
    end
    if enqueue_err and outcome.failed == 0 and outcome.unconfirmed == 0 then
        table.insert(parts, I18n.t("Could not queue downloads. Reopen the chapter list and try again."))
    end
    if stale then
        table.insert(parts, I18n.t("Chapter view changed. Run this download action again."))
    end
    if #parts > 0 then self:showMessage(table.concat(parts, "\n")) end
    return queued, enqueue_err
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

    local chapters, skipped = self:getNextUnreadChaptersForDownload(manga, limit, download_directory)
    if #chapters == 0 then
        self:showMessage(noDownloadCandidatesMessage({ skipped = skipped or 0, saved_filter = self:loadMangaScanlatorFilter(manga) }))
        return 0
    end

    return self:confirmChapterDownloadBatch(manga, chapters, download_directory, {
        scope = I18n.f("Download next %1 (up to 50 new)", limit), unread = true, skipped = skipped,
    })
end


function Methods:enqueueNextUnreadChapterDownloads(limit)
    if limit >= self.max_batch_queue_chapters then
        return self:confirmNextUnreadChapterDownloads(limit)
    end
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

    local chapters, skipped = self:getNextUnreadChaptersForDownload(manga, limit, download_directory)
    if #chapters == 0 then
        self:showMessage(noDownloadCandidatesMessage({ skipped = skipped or 0, saved_filter = self:loadMangaScanlatorFilter(manga) }))
        return 0
    end

    return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory,
        self:captureChapterDownloadBatch(manga, chapters, download_directory, { unread = true, skipped = skipped }))
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


local function reportDeletionProblems(self, active, failed)
    if active == 0 and failed == 0 then return end
    local parts = {}
    if active > 0 then
        parts[#parts + 1] = I18n.count(active,
            "%1 download is busy. Delete it after it finishes.",
            "%1 downloads are busy. Delete them after they finish.")
    end
    if failed > 0 then
        parts[#parts + 1] = I18n.count(failed,
            "Could not delete %1 download. Reopen the chapter list and try again.",
            "Could not delete %1 downloads. Reopen the chapter list and try again.")
    end
    if #parts > 0 then self:showMessage(table.concat(parts, "\n")) end
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
    local failed = 0
    self:withChapterMenuRefreshSuppressed(function()
        for _index, chapter in ipairs(chapters) do
            local ok, state = self:deleteChapterFromDeviceWithOptions(manga, chapter, {
                quiet_active = true,
                quiet_missing = true,
                quiet_delete_failed = true,
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
            else
                failed = failed + 1
            end
        end
    end)

    self:clearChapterSelection(true)
    self:refreshChapterMenu()

    reportDeletionProblems(self, active, failed)
    SuwayomiDebug.log({
        operation = "deleteSelectedChapters",
        event = "end",
        requested_count = #chapters,
        deleted_count = deleted,
        missing_count = missing,
        active_count = active,
        canceled_count = canceled,
        failed_count = failed,
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
        self:showMessage(I18n.t("No read downloads to delete."))
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
            elseif state ~= "queued" then
                failed = failed + 1
            end
        end
    end)

    self:refreshChapterMenu()
    reportDeletionProblems(self, active, failed)
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
        self:showMessage(I18n.t("No read downloads to delete."))
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



function Methods:markSelectedChaptersUnread()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getSelectedChapters(manga, self.current_chapter_context.chapters)
    if #chapters == 0 then
        self:showMessage(I18n.t("No chapters selected."))
        return 0
    end

    return self:markChapterListUnread(manga, chapters, true)
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
        return self:keepNextUnreadChaptersDownloaded(tonumber(keep_unread_count))
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
        local _, err = self:getDownloadQueue():cancelAll()
        if err then self:showMessage(err) end
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

    local associated, association_err = self:getDownloadQueue().refill:associate(manga)
    if not associated then
        self:showMessage(association_err or I18n.t("Failed to save settings."))
        return false, association_err
    end
    local queued, state
    self:withChapterMenuRefreshSuppressed(function()
        queued, state = self:getDownloadQueue():enqueue(manga, chapter, download_directory, { provenance = "explicit" })
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
