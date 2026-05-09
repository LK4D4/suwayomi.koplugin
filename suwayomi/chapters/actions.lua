--[[
ChapterActions
Responsibility: Owns chapter tap/hold actions, downloads, deletes, and bulk mark/read flows.
Owned state: All filesystem and queue mutations stay explicit and continue to use the existing downloader/queue modules.
Dependencies: KOReader UI helpers, Suwayomi runtime modules, and gettext are required at module load to match the original plugin runtime.
External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local SuwayomiAPI = require("suwayomi/api")
local SuwayomiReadSyncWorker = require("suwayomi/readsync/worker")
local SuwayomiSourceFetchWorker = require("suwayomi/browse/source_fetch_worker")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
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

function Methods:getChapterPath(manga, chapter)
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        return nil
    end

    local SuwayomiDownloader = require("suwayomi/downloads/downloader")
    local _, chapter_path = SuwayomiDownloader:getTargetPath(download_directory, manga, chapter)
    return chapter_path
end


function Methods:isChapterDownloaded(manga, chapter)
    local chapter_path = self:getChapterPath(manga, chapter)
    if not chapter_path then
        return false, nil
    end

    local SuwayomiDownloader = require("suwayomi/downloads/downloader")
    return SuwayomiDownloader:chapterExists(chapter_path), chapter_path
end


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


function Methods:deleteChapterFromDevice(manga, chapter)
    return self:deleteChapterFromDeviceWithOptions(manga, chapter)
end


function Methods:deleteChapterFromDeviceWithOptions(manga, chapter, options)
    options = options or {}
    local status = self:getDownloadQueue():getStatus(manga, chapter)
    if status and status.state == "downloading" then
        if not options.quiet_active then
            self:showMessage(_("This chapter is downloading. Wait for it to finish before deleting it."))
        end
        return false, "downloading"
    end

    local cancelled, queue_state = self:getDownloadQueue():cancelPending(manga, chapter)
    if queue_state == "downloading" then
        if not options.quiet_active then
            self:showMessage(_("This chapter is downloading. Wait for it to finish before deleting it."))
        end
        return false, "downloading"
    end

    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    if not downloaded or not chapter_path then
        if not options.quiet_missing then
            self:showMessage(_("This chapter is not downloaded."))
        end
        return false, cancelled and "queued" or "missing"
    end

    local metadata_path = self:getKoreaderMetadataPathForDocument(chapter_path)
    os.remove(chapter_path)
    if metadata_path then
        os.remove(metadata_path)
        os.remove(metadata_path .. ".old")
        local metadata_dir = metadata_path:match("^(.*)/[^/]+$")
        if metadata_dir then
            os.remove(metadata_dir)
        end
    end

    local ledger = options.ledger or self:loadChapterLedger()
    local key = self:getChapterLedgerKey(manga, chapter)
    local entry = ledger[key]
    if not entry then
        for existing_key, existing in pairs(ledger) do
            if tostring(existing.manga_id or "") == tostring(manga.id or "")
                and tostring(existing.chapter_id or "") == tostring(chapter.id or "")
            then
                key = existing_key
                entry = existing
                break
            end
        end
    end
    if entry then
        entry.path = nil
        if entry.read ~= true and entry.pending_read_sync ~= true then
            ledger[key] = nil
        else
            ledger[key] = entry
        end
        if not options.ledger then
            self:saveChapterLedger(ledger)
        end
    end
    self:getDownloadQueue():clearStatus(manga, chapter, { quiet = true })

    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    return true, cancelled and "queued" or "deleted"
end


function Methods:autoDeleteReadLocalDownload(manga, chapter, options)
    options = options or {}
    if self:getKeepNextUnreadDownloadsPolicyLimit() <= 0 then
        return false, "disabled"
    end
    if not chapter or (chapter.is_read ~= true and options.assume_read ~= true) then
        return false, "unread"
    end

    return self:deleteChapterFromDeviceWithOptions(manga, chapter, {
        ledger = options.ledger,
        quiet_active = true,
        quiet_missing = true,
        skip_refresh = options.skip_refresh ~= false,
    })
end


function Methods:autoDeleteReadLocalDownloadFromLedgerEntry(entry, ledger)
    if self:getKeepNextUnreadDownloadsPolicyLimit() <= 0 then
        return false, "disabled"
    end
    if type(entry) ~= "table" or entry.read ~= true then
        return false, "unread"
    end
    local manga = {
        id = entry.manga_id,
        title = entry.manga_title,
    }
    local chapter = {
        id = entry.chapter_id,
        name = entry.chapter_name,
        is_read = true,
    }
    local status = self:getDownloadQueue():getStatus(manga, chapter)
    if status and status.state == "downloading" then
        return false, "downloading"
    end

    local cancelled, queue_state = self:getDownloadQueue():cancelPending(manga, chapter)
    if queue_state == "downloading" then
        return false, "downloading"
    end

    local chapter_path = entry.path
    if type(chapter_path) ~= "string" or chapter_path == "" then
        return false, cancelled and "queued" or "missing"
    end

    local metadata_path = self:getKoreaderMetadataPathForDocument(chapter_path)
    os.remove(chapter_path)
    if metadata_path then
        os.remove(metadata_path)
        os.remove(metadata_path .. ".old")
        local metadata_dir = metadata_path:match("^(.*)/[^/]+$")
        if metadata_dir then
            os.remove(metadata_dir)
        end
    end

    entry.path = nil
    self:getDownloadQueue():clearStatus(manga, chapter, { quiet = true })
    return true, cancelled and "queued" or "deleted"
end


function Methods:markChapterRead(manga, chapter, options)
    local started_at = SuwayomiDebug.now()
    options = options or {}
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    local metadata_updated = false
    if downloaded and chapter_path then
        metadata_updated = self:setKoreaderChapterReadState(chapter_path, true)
    end
    local updates = {
        path = chapter_path,
        read = true,
        pending_read_sync = true,
        pending_read_state = true,
    }
    if options.ledger then
        self:upsertChapterLedgerEntryInLedger(options.ledger, manga, chapter, updates)
    else
        self:upsertChapterLedgerEntry(manga, chapter, updates)
    end

    if self.current_chapter_context and self.current_chapter_context.chapters then
        for _, current in ipairs(self.current_chapter_context.chapters) do
            if tostring(current.id or "") == tostring(chapter.id or "") then
                current.is_read = true
                break
            end
        end
    end
    self:autoDeleteReadLocalDownload(manga, chapter, {
        assume_read = true,
        ledger = options.ledger,
        skip_refresh = true,
    })
    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    if not options.skip_schedule then
        self:schedulePendingReadSync()
    end
    if not options.skip_keep_policy then
        self:applyKeepNextUnreadDownloadsPolicy()
    end
    if not options.skip_refresh or not options.skip_schedule then
        SuwayomiDebug.log({
            operation = "markChapterRead",
            event = "end",
            manga_id = manga and manga.id,
            chapter_id = chapter and chapter.id,
            downloaded = downloaded == true,
            metadata_updated = metadata_updated == true,
            skip_refresh = options.skip_refresh == true,
            skip_schedule = options.skip_schedule == true,
            elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
        })
    end
    return true
end


function Methods:markChapterUnread(manga, chapter, options)
    local started_at = SuwayomiDebug.now()
    options = options or {}
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    local metadata_updated = false
    if downloaded and chapter_path then
        metadata_updated = self:setKoreaderChapterReadState(chapter_path, false)
    end
    local updates = {
        path = chapter_path,
        read = false,
        pending_read_sync = true,
        pending_read_state = false,
    }
    if options.ledger then
        self:upsertChapterLedgerEntryInLedger(options.ledger, manga, chapter, updates)
    else
        self:upsertChapterLedgerEntry(manga, chapter, updates)
    end

    if self.current_chapter_context and self.current_chapter_context.chapters then
        for _, current in ipairs(self.current_chapter_context.chapters) do
            if tostring(current.id or "") == tostring(chapter.id or "") then
                current.is_read = false
                break
            end
        end
    end

    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    if not options.skip_schedule then
        self:schedulePendingReadSync()
    end
    if not options.skip_refresh or not options.skip_schedule then
        SuwayomiDebug.log({
            operation = "markChapterUnread",
            event = "end",
            manga_id = manga and manga.id,
            chapter_id = chapter and chapter.id,
            downloaded = downloaded == true,
            metadata_updated = metadata_updated == true,
            skip_refresh = options.skip_refresh == true,
            skip_schedule = options.skip_schedule == true,
            elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
        })
    end
    return true
end


function Methods:markChapterListRead(manga, chapters)
    local started_at = SuwayomiDebug.now()
    if #chapters == 0 then
        return 0
    end

    local ledger = self:loadChapterLedger()
    for _, current in ipairs(chapters) do
        self:markChapterRead(manga, current, {
            ledger = ledger,
            skip_refresh = true,
            skip_schedule = true,
            skip_keep_policy = true,
        })
    end

    self:refreshChapterMenu({ ledger = ledger })
    self:saveChapterLedger(ledger)
    self:schedulePendingReadSync()
    self:applyKeepNextUnreadDownloadsPolicy()
    SuwayomiDebug.log({
        operation = "markChapterListRead",
        event = "end",
        manga_id = manga and manga.id,
        chapter_count = #chapters,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return #chapters
end


function Methods:markChaptersBeforeRead(manga, chapter)
    return self:markChapterListRead(manga, self:getChaptersBefore(chapter))
end


function Methods:markChaptersReadThrough(manga, chapter)
    return self:markChapterListRead(manga, self:getChaptersThrough(chapter))
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
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        SuwayomiUI.showDirectoryChooser(function(path)
            local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
            self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
            self:confirmNextUnreadChapterDownloads(limit)
        end, self:getDownloadDirectoryChooserStartDir())
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


function Methods:getDownloadDirectoryOrChoose(callback)
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if download_directory and download_directory ~= "" then
        return download_directory
    end

    SuwayomiUI.showDirectoryChooser(function(path)
        local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
        self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
        callback(saved_path)
    end, self:getDownloadDirectoryChooserStartDir())
    return nil
end


function Methods:enqueueNextUnreadChapterDownloads(limit)
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        SuwayomiUI.showDirectoryChooser(function(path)
            local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
            self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
            self:enqueueNextUnreadChapterDownloads(limit)
        end, self:getDownloadDirectoryChooserStartDir())
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

    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        SuwayomiUI.showDirectoryChooser(function(path)
            local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
            self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
            self:enqueueSelectedChapterDownloads(manga, chapters, saved_path)
        end, self:getDownloadDirectoryChooserStartDir())
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


function Methods:performBulkChapterAction(action_id)
    if action_id == "bulk_downloads" then
        self:showBulkDownloadActions()
        return true
    end
    if action_id == "scanlator_filter" then
        self:showScanlatorFilterActions()
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
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        SuwayomiUI.showDirectoryChooser(function(path)
            local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
            self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
            UIManager:nextTick(function()
                self:enqueueChapterDownload(manga, chapter)
            end)
        end, self:getDownloadDirectoryChooserStartDir())
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
