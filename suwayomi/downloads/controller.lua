-- Boundary: DownloadsController.
--
-- Responsibility: Owns the Downloads hub UI, retry/cancel actions, download-ahead refills, and downloaded-read reconciliation.
-- Owned state: Uses the device-local queue only; it must not call Suwayomi server download mutations.
-- Dependencies: KOReader UI helpers and Suwayomi runtime modules, including the plugin i18n facade.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local I18n = require("suwayomi/i18n")

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
        return I18n.t("Download is already downloading.")
    end
    return I18n.t("Download is no longer queued.")
end


function Methods:getDownloadsTitleActions(snapshot)
    snapshot = snapshot or {}
    local actions = {}
    if #(snapshot.active or {}) > 0 or #(snapshot.queued or {}) > 0 then
        table.insert(actions, { id = "cancel_all", text = I18n.t("Cancel all downloads"), destructive = true })
    end
    if #(snapshot.failed or {}) > 0 then
        table.insert(actions, { id = "clear_failed", text = I18n.t("Clear failed") })
    end

    return actions
end


function Methods:performDownloadsTitleAction(action, menu)
    if not action then
        return false
    end

    local queue = self:getDownloadQueue()
    if action.id == "cancel_all" then
        local callback = function()
            queue:cancelAll()
            self:closeMenu(menu)
            self:showDownloads()
        end
        if SuwayomiUI.showConfirm then
            SuwayomiUI.showConfirm({
                text = I18n.t("Cancel all downloads?"),
                ok_text = I18n.t("Cancel downloads"),
                ok_callback = callback,
                cancel_text = I18n.t("Keep downloads"),
            })
        else
            callback()
        end
        return true
    elseif action.id == "cancel_queued" then
        queue:cancelQueued()
        self:closeMenu(menu)
        self:showDownloads()
        return true
    elseif action.id == "clear_failed" then
        queue:clearFailed()
        self:closeMenu(menu)
        self:showDownloads()
        return true
    end
    return false
end


function Methods:getDownloadsTitleBarOptions(snapshot)
    if not self.getTitleBarMenuOptions then
        return {}
    end
    return self:getTitleBarMenuOptions({
        title = I18n.t("Downloads"),
        actions = self:getDownloadsTitleActions(snapshot),
        onSelect = function(action, menu)
            return self:performDownloadsTitleAction(action, menu)
        end,
    })
end

function Methods:getDownloadsMenuOptions(snapshot)
    local options = self:getDownloadsTitleBarOptions(snapshot)
    if self.getDownloadDirectorySummary then
        options.download_directory_summary = self:getDownloadDirectorySummary()
    else
        options.download_directory_summary = SuwayomiSettings:loadDownloadDirectory()
        if not options.download_directory_summary or options.download_directory_summary == "" then
            options.download_directory_summary = I18n.t("not set")
        end
    end
    return options
end


function Methods:showFailedDownloadActions(job, menu)
    if not SuwayomiUI.showChapterActionsMenu then
        return
    end

    SuwayomiUI.showChapterActionsMenu({
        title = I18n.t("Download actions"),
        actions = {
            { id = "retry", text = I18n.t("Retry") },
            { id = "close", text = I18n.t("Close") },
        },
    }, function(action)
        if action and action.id == "retry" then
            local ok = self:getDownloadQueue():retryFailed(job.key)
            self:closeMenu(menu)
            if not ok then
                self:showMessage(I18n.t("Could not retry download."))
            end
            self:showDownloads()
        end
    end)
end

function Methods:getDownloadsMenuCallbacks()
    return {
        onSelectActive = function(job, menu)
            self:showActiveDownloadActions(job, menu)
        end,
        onSelectQueued = function(job, menu)
            self:showQueuedDownloadActions(job, menu)
        end,
        onSelectFailed = function(job, menu)
            self:showFailedDownloadActions(job, menu)
        end,
        onClearFailed = function(menu)
            self:getDownloadQueue():clearFailed()
            self:closeMenu(menu)
            self:showDownloads()
        end,
    }
end

function Methods:withDownloadsMenuTracking(options)
    options = options or {}
    local previous_close_callback = options.close_callback
    local tracked_menu
    options.close_callback = function(...)
        if self.current_downloads_menu == tracked_menu then
            self.current_downloads_menu = nil
        end
        if previous_close_callback then
            return previous_close_callback(...)
        end
    end
    return options, function(menu)
        tracked_menu = menu
        self.current_downloads_menu = menu
    end
end

function Methods:refreshDownloadsMenu()
    local menu = self.current_downloads_menu
    if not menu or not SuwayomiUI.updateDownloadsMenu then
        return false
    end
    if self.isSuwayomiScreenActive and not self:isSuwayomiScreenActive(menu) then
        self.current_downloads_menu = nil
        return false
    end

    local queue = self:getDownloadQueue()
    local snapshot = queue:getSnapshot()
    local options = self:getDownloadsMenuOptions(snapshot)
    SuwayomiUI.updateDownloadsMenu(menu, snapshot, self:getDownloadsMenuCallbacks(), options)
    return true
end


function Methods:showQueuedDownloadActions(job, menu)
    if not SuwayomiUI.showChapterActionsMenu then
        return
    end

    local actions = {
        { id = "cancel_queued", text = I18n.t("Cancel queued download") },
    }
    if self:canOpenDownloadJobChapterList(job) then
        table.insert(actions, { id = "open_chapter_list", text = I18n.t("Open chapter list") })
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
            self:showMangaActions(job.manga, {
                onMangaUpdated = function()
                    if not self.isSuwayomiScreenActive or self:isSuwayomiScreenActive(menu) then
                        self:showDownloads()
                    end
                end,
            })
        end
    end)
end


function Methods:showActiveDownloadActions(job, menu)
    if not SuwayomiUI.showChapterActionsMenu then
        return
    end
    local actions = {}
    if self:canOpenDownloadJobChapterList(job) then
        table.insert(actions, { id = "open_chapter_list", text = I18n.t("Open chapter list") })
    end
    table.insert(actions, { id = "cancel_download", text = I18n.t("Cancel download"), destructive = true })

    SuwayomiUI.showChapterActionsMenu({
        title = self:getDownloadJobTitle(job),
        actions = actions,
    }, function(action)
        if action and action.id == "open_chapter_list" then
            self:showMangaActions(job.manga, {
                onMangaUpdated = function()
                    if not self.isSuwayomiScreenActive or self:isSuwayomiScreenActive(menu) then
                        self:showDownloads()
                    end
                end,
            })
        elseif action and action.id == "cancel_download" then
            local cancelled = self:getDownloadQueue():cancelPending(job.manga, job.chapter)
            self:closeMenu(menu)
            if not cancelled then
                self:showMessage(I18n.t("Download is no longer active."), { timeout = 2 })
            end
            self:showDownloads()
        end
    end)
end


function Methods:showDownloads()
    local queue = self:getDownloadQueue()
    local snapshot = queue:getSnapshot()
    local options, trackMenu = self:withDownloadsMenuTracking(self:getDownloadsMenuOptions(snapshot))

    local menu = SuwayomiUI.showDownloadsMenu(snapshot, self:getDownloadsMenuCallbacks(), options)
    trackMenu(menu)
    if self.trackSuwayomiScreen then
        self:trackSuwayomiScreen("downloads", menu)
    end
    return menu
end


function Methods:reconcileDownloadedChapterLedger(ledger)
    ledger = ledger or self:loadChapterLedger()
    local history_paths = self:loadKoreaderHistoryPaths()
    local changed = false
    local current_context_changed = false
    local read_count = 0

    for _index, entry in pairs(ledger or {}) do
        if type(entry) == "table" and type(entry.path) == "string" and entry.path ~= "" then
            local metadata_finished = self:isChapterPathFinishedInKoreader(entry.path)
            local history_read = history_paths[entry.path] == true
            if (metadata_finished or history_read) and entry.read ~= true then
                entry.read = true
                entry.pending_read_sync = true
                entry.pending_read_state = true
                changed = true
                read_count = read_count + 1
                if self:markCurrentContextChapterReadFromLedger(entry) then
                    current_context_changed = true
                end
            end
        end
    end

    if changed then
        self:saveChapterLedger(ledger)
    end
    if current_context_changed then
        self:applyMangaKeepNextUnreadDownloadsPolicy()
    end

    return read_count
end


function Methods:formatActiveDownloadCount(count)
    return I18n.count(count, "1 download is still in progress.", "%1 downloads are still in progress.")
end


function Methods:formatBulkDeleteMessage(deleted, canceled, missing, active)
    local parts = {}
    if deleted > 0 then
        table.insert(parts, I18n.count(deleted, "Deleted %1 selected chapter from device.", "Deleted %1 selected chapters from device."))
    end
    if canceled > 0 then
        table.insert(parts, I18n.count(canceled, "Canceled %1 queued download.", "Canceled %1 queued downloads."))
    end
    if missing > 0 then
        table.insert(parts, I18n.count(missing, "Skipped %1 chapter not downloaded.", "Skipped %1 chapters not downloaded."))
    end
    if active > 0 then
        table.insert(parts, self:formatActiveDownloadCount(active))
    end
    if #parts == 0 then
        return I18n.t("No selected chapters were deleted.")
    end
    return I18n.join(parts, " ")
end


function Methods:getUnreadDownloadBufferCandidates(manga, limit)
    local missing = {}
    local unread_count = 0

    for _index, chapter in ipairs(self:getVisibleChapters((self.current_chapter_context and self.current_chapter_context.chapters) or {})) do
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


function Methods:getMangaKeepNextUnreadDownloadsLimit(manga)
    if not SuwayomiSettings.loadMangaKeepNextUnreadDownloads then
        return 0
    end
    return tonumber(SuwayomiSettings:loadMangaKeepNextUnreadDownloads(manga)) or 0
end


function Methods:saveMangaKeepNextUnreadDownloadsLimit(manga, limit)
    if not SuwayomiSettings.saveMangaKeepNextUnreadDownloads then
        return tonumber(limit) or 0
    end
    return SuwayomiSettings:saveMangaKeepNextUnreadDownloads(manga, limit)
end


function Methods:normalizeMangaKeepNextUnreadDownloadsLimit(limit)
    if SuwayomiSettings.normalizeMangaKeepNextUnreadDownloads then
        return SuwayomiSettings:normalizeMangaKeepNextUnreadDownloads(limit)
    end
    return tonumber(limit) or 0
end


function Methods:getQueueableKeepNextUnreadDownloads(manga, chapters)
    local queueable = {}
    local max_chapters = tonumber(self.max_batch_queue_chapters) or 50
    for _index, chapter in ipairs(chapters or {}) do
        local status = self:getDownloadQueue():getStatus(manga, chapter)
        local downloaded = self:isChapterDownloaded(manga, chapter)
        if not downloaded and not (status and (
            status.state == "queued"
                or status.state == "downloading"
                or status.state == "downloaded"
                or status.state == "skipped"
        )) then
            if #queueable >= max_chapters then
                break
            end
            table.insert(queueable, chapter)
        end
    end
    return queueable
end


function Methods:enqueueKeepNextUnreadDownloads(manga, chapters, download_directory)
    local queueable = self:getQueueableKeepNextUnreadDownloads(manga, chapters)
    if #queueable == 0 then
        return 0
    end

    local queued = 0
    self:withChapterMenuRefreshSuppressed(function()
        queued = self:getDownloadQueue():enqueueBatch(manga, queueable, download_directory, { quiet_duplicate = true })
    end)
    if queued > 0 then
        self:refreshChapterMenu({ quick = true })
    end
    return queued
end


function Methods:applyMangaKeepNextUnreadDownloadsPolicy(manga)
    if not self.current_chapter_context then
        return 0
    end

    manga = manga or self.current_chapter_context.manga
    if not manga then
        return 0
    end
    if self.isCurrentChapterContextForManga and not self:isCurrentChapterContextForManga(manga) then
        return 0
    end

    local limit = self:getMangaKeepNextUnreadDownloadsLimit(manga)
    if limit <= 0 then
        return 0
    end

    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        return 0
    end

    local chapters = self:getUnreadDownloadBufferCandidates(manga, limit)
    if #chapters == 0 then
        return 0
    end

    return self:enqueueKeepNextUnreadDownloads(manga, chapters, download_directory)
end


function Methods:keepNextUnreadChaptersDownloaded(limit)
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local requested_limit = self:normalizeMangaKeepNextUnreadDownloadsLimit(limit)
    if requested_limit <= 0 then
        return 0
    end

    local download_directory = self:getDownloadDirectoryOrChoose(function()
            self:keepNextUnreadChaptersDownloaded(requested_limit)
    end)
    if not download_directory then
        return 0
    end

    self:saveMangaKeepNextUnreadDownloadsLimit(manga, requested_limit)
    local chapters = self:getUnreadDownloadBufferCandidates(manga, requested_limit)
    if #chapters == 0 then
        self:showMessage(I18n.t("Download-ahead buffer is already downloaded or queued."))
        return 0
    end

    return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory)
end


DownloadsController.methods = Methods

return DownloadsController
