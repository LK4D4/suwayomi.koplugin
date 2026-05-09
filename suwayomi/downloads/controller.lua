--[[
DownloadsController
Responsibility: Owns the Downloads hub UI, retry/cancel actions, and keep-next-unread queue policy.
Owned state: Uses the device-local queue only; it must not call Suwayomi server download mutations.
Dependencies: KOReader UI helpers, Suwayomi runtime modules, and gettext are required at module load to match the original plugin runtime.
External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.
]]

local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local DownloadsController = {}
DownloadsController.__index = DownloadsController

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function DownloadsController:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

function Methods:isDownloadsSnapshotEmpty(snapshot)
    return #(snapshot.active or {}) == 0
        and #(snapshot.queued or {}) == 0
        and #(snapshot.failed or {}) == 0
end


function Methods:getDownloadJobTitle(job)
    local manga_title = job and job.manga and job.manga.title or nil
    local chapter_name = job and job.chapter and job.chapter.name or nil
    if manga_title and manga_title ~= "" and chapter_name and chapter_name ~= "" then
        return manga_title .. " / " .. chapter_name
    end
    return manga_title or chapter_name or tostring(job and job.key or "")
end


function Methods:canOpenDownloadJobChapterList(job)
    return job and job.manga and job.manga.id ~= nil and tostring(job.manga.id) ~= ""
end


function Methods:formatCancelQueuedDownloadMessage(state)
    if state == "downloading" then
        return _("Download is already downloading.")
    end
    return _("Download is no longer queued.")
end


function Methods:showDownloadsActions(menu, snapshot)
    if not SuwayomiUI.showChapterActionsMenu then
        self:closeMenu(menu)
        self:showHome()
        return
    end

    local actions = {
        { id = "home", text = _("Suwayomi home") },
    }
    if #(snapshot.queued or {}) > 0 then
        table.insert(actions, { id = "cancel_queued", text = _("Cancel queued downloads") })
    end
    if #(snapshot.failed or {}) > 0 then
        table.insert(actions, { id = "clear_failed", text = _("Clear failed") })
    end

    SuwayomiUI.showChapterActionsMenu({
        title = _("Suwayomi Downloads"),
        actions = actions,
    }, function(action)
        if not action then
            return
        end
        local queue = self:getDownloadQueue()
        if action.id == "home" then
            self:closeMenu(menu)
            self:showHome()
        elseif action.id == "cancel_queued" then
            queue:cancelQueued()
            self:closeMenu(menu)
            self:showDownloads()
        elseif action.id == "clear_failed" then
            queue:clearFailed()
            self:closeMenu(menu)
            self:showDownloads()
        end
    end)
end


function Methods:showQueuedDownloadActions(job, menu)
    if not SuwayomiUI.showChapterActionsMenu then
        return
    end

    local actions = {
        { id = "cancel_queued", text = _("Cancel queued download") },
    }
    if self:canOpenDownloadJobChapterList(job) then
        table.insert(actions, { id = "open_chapter_list", text = _("Open chapter list") })
    end

    SuwayomiUI.showChapterActionsMenu({
        title = self:getDownloadJobTitle(job),
        actions = actions,
    }, function(action)
        if action and action.id == "cancel_queued" then
            local cancelled, state = self:getDownloadQueue():cancelPending(job.manga, job.chapter)
            self:closeMenu(menu)
            if not cancelled then
                self:showMessage(self:formatCancelQueuedDownloadMessage(state), { timeout = 2 })
            end
            self:showDownloads()
        elseif action and action.id == "open_chapter_list" then
            self:closeMenu(menu)
            self:showMangaActions(job.manga, {
                onMangaUpdated = function()
                    self:showDownloads()
                end,
            })
        end
    end)
end


function Methods:showActiveDownloadActions(job, menu)
    if not SuwayomiUI.showChapterActionsMenu then
        return
    end
    if not self:canOpenDownloadJobChapterList(job) then
        self:showMessage(_("This download cannot be opened right now."), { timeout = 2 })
        return
    end

    SuwayomiUI.showChapterActionsMenu({
        title = self:getDownloadJobTitle(job),
        actions = {
            { id = "open_chapter_list", text = _("Open chapter list") },
        },
    }, function(action)
        if action and action.id == "open_chapter_list" then
            self:closeMenu(menu)
            self:showMangaActions(job.manga, {
                onMangaUpdated = function()
                    self:showDownloads()
                end,
            })
        end
    end)
end


function Methods:showDownloads()
    local queue = self:getDownloadQueue()
    local snapshot = queue:getSnapshot()
    if self:isDownloadsSnapshotEmpty(snapshot) then
        self:showMessage(_("No active downloads."))
        return
    end

    return SuwayomiUI.showDownloadsMenu(snapshot, {
        onSelectActive = function(job, menu)
            self:showActiveDownloadActions(job, menu)
        end,
        onSelectQueued = function(job, menu)
            self:showQueuedDownloadActions(job, menu)
        end,
        onRetryFailed = function(job, menu)
            local ok = queue:retryFailed(job.key)
            self:closeMenu(menu)
            if ok then
                self:showMessage(_("Download queued."), { timeout = 2 })
            else
                self:showMessage(_("Could not retry download."))
            end
            self:showDownloads()
        end,
        onClearFailed = function(menu)
            local cleared = queue:clearFailed()
            self:closeMenu(menu)
            self:showMessage(T(_("Cleared %1 failed downloads."), cleared), { timeout = 2 })
            self:showDownloads()
        end,
    }, {
        title_bar_left_icon = "appbar.menu",
        on_title_bar_left_tap = function(menu)
            self:showDownloadsActions(menu, snapshot)
            return true
        end,
    })
end


function Methods:getKeepNextUnreadDownloadsPolicyLimit()
    if not SuwayomiSettings.loadKeepNextUnreadDownloads then
        return 0
    end
    local limit = tonumber(SuwayomiSettings:loadKeepNextUnreadDownloads()) or 0
    if limit == 5 or limit == 10 or limit == 50 then
        return limit
    end
    return 0
end


function Methods:applyKeepNextUnreadDownloadsPolicy()
    if not self.current_chapter_context then
        return 0
    end

    local limit = self:getKeepNextUnreadDownloadsPolicyLimit()
    if limit <= 0 then
        return 0
    end

    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getUnreadDownloadBufferCandidates(manga, limit)
    if #chapters == 0 then
        return 0
    end

    return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
end


function Methods:reconcileDownloadedChapterLedger(ledger)
    ledger = ledger or self:loadChapterLedger()
    local history_paths = self:loadKoreaderHistoryPaths()
    local changed = false
    local read_count = 0

    for _, entry in pairs(ledger or {}) do
        if type(entry) == "table" and type(entry.path) == "string" and entry.path ~= "" then
            local metadata_finished = self:isChapterPathFinishedInKoreader(entry.path)
            local history_read = history_paths[entry.path] == true
            if (metadata_finished or history_read) and entry.read ~= true then
                entry.read = true
                entry.pending_read_sync = true
                entry.pending_read_state = true
                changed = true
                read_count = read_count + 1
                self:markCurrentContextChapterReadFromLedger(entry)
                self:autoDeleteReadLocalDownloadFromLedgerEntry(entry, ledger)
            end
        end
    end

    if changed then
        self:saveChapterLedger(ledger)
        self:applyKeepNextUnreadDownloadsPolicy()
    end

    return read_count
end


function Methods:formatActiveDownloadCount(count)
    if count == 1 then
        return _("1 download is still in progress.")
    end
    return T(_("%1 downloads are still in progress."), count)
end


function Methods:formatBulkDeleteMessage(deleted, canceled, missing, active)
    local parts = {}
    if deleted > 0 then
        table.insert(parts, T(
            self:pluralize(deleted, _("Deleted %1 selected chapter from device."), _("Deleted %1 selected chapters from device.")),
            deleted
        ))
    end
    if canceled > 0 then
        table.insert(parts, T(
            self:pluralize(canceled, _("Canceled %1 queued download."), _("Canceled %1 queued downloads.")),
            canceled
        ))
    end
    if missing > 0 then
        table.insert(parts, T(
            self:pluralize(missing, _("Skipped %1 not downloaded."), _("Skipped %1 not downloaded.")),
            missing
        ))
    end
    if active > 0 then
        table.insert(parts, self:formatActiveDownloadCount(active))
    end
    if #parts == 0 then
        return _("No selected chapters were deleted.")
    end
    return table.concat(parts, " ")
end


function Methods:getUnreadDownloadBufferCandidates(manga, limit)
    local missing = {}
    local unread_count = 0

    for _, chapter in ipairs(self:getVisibleChapters((self.current_chapter_context and self.current_chapter_context.chapters) or {})) do
        if chapter.is_read ~= true then
            unread_count = unread_count + 1
            if not self:isChapterDownloadAvailable(manga, chapter) then
                table.insert(missing, chapter)
            end
            if unread_count >= limit then
                break
            end
        end
    end

    return missing, unread_count
end


function Methods:keepNextUnreadChaptersDownloaded(limit)
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        SuwayomiUI.showDirectoryChooser(function(path)
            local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
            self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
            self:keepNextUnreadChaptersDownloaded(limit)
        end, self:getDownloadDirectoryChooserStartDir())
        return 0
    end

    local chapters = self:getUnreadDownloadBufferCandidates(manga, limit)
    if #chapters == 0 then
        self:showMessage(_("Next unread chapter buffer is already downloaded or queued."))
        return 0
    end

    return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
end


DownloadsController.methods = Methods

return DownloadsController
