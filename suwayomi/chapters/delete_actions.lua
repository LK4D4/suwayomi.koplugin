-- Boundary: ChapterDeleteActions.
--
-- Responsibility: Delete device-local chapter archives and coordinate queue/ledger cleanup.
-- Owned state: Mutates plugin queue status and settings-backed read ledger through injected plugin methods.
-- Dependencies: Plugin mixin methods, local download helpers, and gettext.
-- External data: Queue state, ledger entries, and filesystem paths are checked before destructive cleanup.

local _ = require("gettext")
local SuwayomiSettings = require("suwayomi/settings")

local ChapterDeleteActions = {}
ChapterDeleteActions.__index = ChapterDeleteActions

function ChapterDeleteActions:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function loadDeleteChaptersSettings()
    if SuwayomiSettings.loadDeleteChaptersSettings then
        return SuwayomiSettings:loadDeleteChaptersSettings()
    end
    return {
        delete_after_mark_read = false,
        delete_finished_while_reading = 0,
    }
end

local function sameId(left, right)
    return tostring(left or "") == tostring(right or "")
end

local function contextMatchesManga(self, manga)
    if not self.current_chapter_context then
        return false
    end
    if self.isCurrentChapterContextForManga then
        return self:isCurrentChapterContextForManga(manga)
    end
    local context_manga = self.current_chapter_context.manga
    return context_manga and manga and sameId(context_manga.id, manga.id)
end

-- Return states are part of the actions facade contract:
-- deleted, queued, missing, and downloading.
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

    local downloaded, chapter_path
    if options.chapter_path then
        chapter_path = options.chapter_path
        downloaded = self:chapterArchiveExists(chapter_path)
    else
        downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    end
    if not downloaded or not chapter_path then
        if not options.quiet_missing then
            self:showMessage(_("This chapter is not downloaded."))
        end
        return false, cancelled and "queued" or "missing"
    end

    local metadata_path = self:getKoreaderMetadataPathForDocument(chapter_path)
    local removed = self:removeChapterArchiveAndSidecars(chapter_path, metadata_path)
    if not removed then
        if not options.quiet_delete_failed then
            self:showMessage(_("Could not delete this chapter from device."))
        end
        return false, "delete_failed"
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
        -- Keep read or pending entries so read-sync can still reconcile them;
        -- remove only entries whose sole useful state was the local file path.
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

function Methods:deleteChaptersAfterManualMarkRead(manga, chapters, options)
    options = options or {}
    local settings = loadDeleteChaptersSettings()
    if settings.delete_after_mark_read ~= true then
        return 0
    end

    local deleted = 0
    for _, chapter in ipairs(chapters or {}) do
        local ok = self:deleteChapterFromDeviceWithOptions(manga, chapter, {
            ledger = options.ledger,
            quiet_active = true,
            quiet_delete_failed = true,
            quiet_missing = true,
            skip_refresh = true,
        })
        if ok then
            deleted = deleted + 1
        end
    end
    return deleted
end

function Methods:getChapterLedgerEntryForDelete(ledger, manga, chapter)
    local key = self:getChapterLedgerKey(manga, chapter)
    local entry = ledger[key]
    if entry then
        return entry
    end

    for _, existing in pairs(ledger or {}) do
        if sameId(existing.manga_id, manga and manga.id)
            and sameId(existing.chapter_id, chapter and chapter.id)
        then
            return existing
        end
    end
    return nil
end

function Methods:getFinishedChapterDeleteCandidate(manga, chapter, offset)
    offset = tonumber(offset) or 0
    if offset <= 0 then
        return nil
    end
    if not self.current_chapter_context or not self.current_chapter_context.chapters then
        return offset == 1 and chapter or nil
    end
    if not contextMatchesManga(self, manga) then
        return offset == 1 and chapter or nil
    end

    local finished_index
    for index, current in ipairs(self.current_chapter_context.chapters) do
        if sameId(current.id, chapter and chapter.id)
            or (chapter and chapter.name and tostring(current.name or "") == tostring(chapter.name))
        then
            finished_index = index
            break
        end
    end
    if not finished_index then
        return offset == 1 and chapter or nil
    end
    return self.current_chapter_context.chapters[finished_index - offset + 1]
end

function Methods:deleteFinishedChaptersWhileReading(manga, chapter)
    local settings = loadDeleteChaptersSettings()
    local offset = settings.delete_finished_while_reading
    local candidate = self:getFinishedChapterDeleteCandidate(manga, chapter, offset)
    if not candidate then
        return 0
    end

    local ledger = self:loadChapterLedger()
    local entry = self:getChapterLedgerEntryForDelete(ledger, manga, candidate)
    local ok = self:deleteChapterFromDeviceWithOptions(manga, candidate, {
        ledger = ledger,
        chapter_path = (entry and entry.path) or candidate.path,
        quiet_active = true,
        quiet_delete_failed = true,
        quiet_missing = true,
        skip_refresh = true,
    })
    if ok then
        self:saveChapterLedger(ledger)
        return 1
    end
    return 0
end

ChapterDeleteActions.methods = Methods

return ChapterDeleteActions
