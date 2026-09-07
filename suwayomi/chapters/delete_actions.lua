-- Boundary: ChapterDeleteActions.
--
-- Responsibility: Delete device-local archives and coordinate queue/ledger cleanup independently of completion history.
-- Owned state: Mutates plugin queue status and settings-backed read ledger through injected plugin methods.
-- Dependencies: Plugin mixin methods, local download helpers, settings, and i18n.
-- External data: Queue state, ledger entries, and filesystem paths are checked before destructive cleanup.

local I18n = require("suwayomi/i18n")
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

-- Return states are part of the actions facade contract:
-- deleted, queued, missing, downloading, delete_failed, and store_blocked.
function Methods:deleteChapterFromDevice(manga, chapter)
    return self:deleteChapterFromDeviceWithOptions(manga, chapter)
end

function Methods:deleteChapterFromDeviceWithOptions(manga, chapter, options)
    options = options or {}
    local queue = self:getDownloadQueue()
    if queue and queue.checkStoreFence and not queue:checkStoreFence() then
        if not options.quiet_delete_failed then
            self:showMessage(I18n.t("Cannot delete chapter: storage is ambiguous"))
        end
        return false, "store_blocked"
    end
    local function deletionFailed(err)
        if queue and queue.checkStoreFence and not queue:checkStoreFence() then
            if not options.quiet_delete_failed then
                self:showMessage(I18n.t("Cannot delete chapter: storage is ambiguous"))
            end
            return false, "store_blocked", err
        end
        if not options.quiet_delete_failed then
            self:showMessage(I18n.t("Could not delete this chapter from device."))
        end
        return false, "delete_failed", err
    end
    local status = queue and queue:getStatus(manga, chapter)
    if status and status.state == "downloading" then
        if not options.quiet_active then
            self:showMessage(I18n.t("This chapter is downloading. Wait for it to finish before deleting it."))
        end
        return false, "downloading"
    end

    local cancelled, queue_state
    if queue then
        cancelled, queue_state = queue:cancelPending(manga, chapter)
    end
    if queue_state == "store_blocked" or (queue and queue.checkStoreFence and not queue:checkStoreFence()) then
        if not options.quiet_delete_failed then
            self:showMessage(I18n.t("Cannot delete chapter: storage is ambiguous"))
        end
        return false, "store_blocked"
    end
    if queue_state == "downloading" then
        if not options.quiet_active then
            self:showMessage(I18n.t("This chapter is downloading. Wait for it to finish before deleting it."))
        end
        return false, "downloading"
    end
    if not cancelled and queue_state and queue_state ~= "queued" and queue_state ~= "downloaded"
        and queue_state ~= "skipped" and queue_state ~= "failed" then
        return deletionFailed()
    end

    local downloaded, chapter_path, inspection_error
    if options.chapter_path then
        chapter_path = options.chapter_path
        downloaded, inspection_error = self:chapterArchiveExists(chapter_path)
    else
        downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    end
    if inspection_error or downloaded == nil then
        return deletionFailed()
    end
    if not downloaded or not chapter_path then
        if not options.quiet_missing then
            self:showMessage(I18n.t("This chapter is not downloaded."))
        end
        return false, cancelled and "queued" or "missing"
    end

    local resolved, metadata_path, metadata_paths = pcall(self.getKoreaderMetadataPathForDocument, self, chapter_path)
    if not resolved or not metadata_path then
        return deletionFailed()
    end
    local removed = self:removeChapterArchiveAndSidecars(chapter_path, metadata_paths or metadata_path)
    if not removed then
        return deletionFailed()
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
        local staged_ledger, staged_entry = {}, {}
        for entry_key, value in pairs(ledger) do staged_ledger[entry_key] = value end
        for field, value in pairs(entry) do staged_entry[field] = value end
        staged_entry.path = nil
        -- Keep read or pending entries so read-sync can still reconcile them;
        -- remove only entries whose sole useful state was the local file path.
        if staged_entry.read ~= true and staged_entry.pending_read_sync ~= true then
            staged_ledger[key] = nil
        else
            staged_ledger[key] = staged_entry
        end
        local saved, save_err = self:saveChapterLedger(staged_ledger)
        if not saved then
            return deletionFailed(save_err or "save_failed")
        end
        -- Keep the caller's batch draft aligned with the committed deletion.
        if options.ledger then options.ledger[key] = staged_ledger[key] end
    end
    local cleared, clear_err = queue:clearStatus(manga, chapter, { quiet = true })
    if not cleared then
        return deletionFailed(clear_err or "save_failed")
    end

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
    for _index, chapter in ipairs(chapters or {}) do
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

ChapterDeleteActions.methods = Methods

return ChapterDeleteActions
