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
    if (status and status.state == "downloading")
        or (queue and queue.isChapterBusy and queue:isChapterBusy(queue:getKey(manga, chapter))) then
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

    local removal = queue.manual_deletion
    if not removal then return deletionFailed("identity_unavailable") end
    local target, target_error = removal:prepareRemoval(
        queue:getKey(manga, chapter), chapter_path, SuwayomiSettings:loadDownloadDirectory(),
        options.archive_generation
    )
    if not target then return deletionFailed(target_error) end

    local resolved, metadata_path, metadata_paths = pcall(self.getKoreaderMetadataPathForDocument, self, chapter_path)
    if not resolved or not metadata_path then
        return deletionFailed()
    end
    local removed = self:removeChapterArchiveAndSidecars(chapter_path, metadata_paths or metadata_path, function()
        return removal:validateTarget(target)
    end)
    if not removed then
        return deletionFailed()
    end

    local store = SuwayomiSettings:getStore()
    local called, saved, save_error = pcall(store.saveDocument, store, function(doc)
        if not removal:retire(doc, target) then error("archive_generation_changed") end
    end)
    if not called or not saved then return deletionFailed(save_error or "bookkeeping_failed") end
    if options.ledger then
        local key = queue:getKey(manga, chapter)
        options.ledger[key] = self:loadChapterLedger()[key]
    end
    local current = queue:getStatus(manga, chapter)
    if current and not queue:isChapterBusy(target.key)
        and (current.state == "downloaded" or current.state == "skipped" or current.state == "failed")
        and (current.archive_generation == nil or current.archive_generation == target.generation) then
        queue.statuses[target.key] = nil
    end
    removal:wake()

    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    return true, cancelled and "queued" or "deleted"
end


ChapterDeleteActions.methods = Methods

return ChapterDeleteActions
