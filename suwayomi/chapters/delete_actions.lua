-- Boundary: ChapterDeleteActions.
--
-- Responsibility: Delete device-local chapter archives and coordinate queue/ledger cleanup.
-- Owned state: Mutates plugin queue status and settings-backed read ledger through injected plugin methods.
-- Dependencies: Plugin mixin methods, local download helpers, and gettext.
-- External data: Queue state, ledger entries, and filesystem paths are checked before destructive cleanup.

local _ = require("gettext")

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

    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
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

ChapterDeleteActions.methods = Methods

return ChapterDeleteActions
