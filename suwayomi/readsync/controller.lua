-- Boundary: ReadSyncController.
--
-- Responsibility: Owns read-sync worker scheduling, result application, manual sync, and document-close sync.
-- Owned state: Coordinates ledger, KOReader metadata, and subprocess result files.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and plugin i18n facade.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local UIManager = require("ui/uimanager")
local SuwayomiReadSyncWorker = require("suwayomi/readsync/worker")
local SubprocessJob = require("suwayomi/subprocess/job")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiDebug = require("suwayomi/debug")
local I18n = require("suwayomi/i18n")
local FFIUtil = require("ffi/util")

local ReadSyncController = {}
ReadSyncController.__index = ReadSyncController

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function ReadSyncController:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function validId(value)
    return type(value) == "string" and value ~= ""
end

function Methods:getReadSyncResultPath()
    return SubprocessJob.buildResultPath("read_sync")
end


function Methods:schedulePendingReadSyncPoll()
    SubprocessJob.schedulePoll(self.pending_read_sync_active)
end


function Methods:startPendingReadSyncWorker(credentials, max_count)
    if self.pending_read_sync_active then
        return true, 0
    end

    credentials = credentials or SuwayomiSettings:load()
    local ledger = self:loadChapterLedger()
    local batch = self:buildPendingReadSyncBatch(ledger, max_count)
    if #batch == 0 then
        return false, 0
    end
    if not credentials or credentials.server_url == "" then
        return false, #batch
    end

    local result_path = self:getReadSyncResultPath()
    local active = {
        credentials = credentials,
        batch = batch,
        result_path = result_path,
    }

    active = SubprocessJob.start({
        active = active,
        ffi_util = FFIUtil,
        ui_manager = UIManager,
        poll_interval_seconds = self.read_sync_poll_interval_seconds,
        timeout_seconds = self.read_sync_watchdog_timeout_seconds,
        run = function(path)
            SuwayomiReadSyncWorker:run(credentials, batch, path)
        end,
        read_result = function(path)
            return SuwayomiReadSyncWorker:readResult(path)
        end,
        on_finish = function(finished_active, result)
            if finished_active and finished_active.canceled then
                return
            end
            local synced, attempted = self:applyPendingReadSyncResult(finished_active, result)
            self:finishPendingReadSync(finished_active, synced, attempted)
        end,
        on_error = function(err)
            self.pending_read_sync_active = nil
            self:showMessage(I18n.f("Could not start read sync: %1", err or I18n.t("unknown error")))
        end,
        on_cleanup = function(cleaned_active)
            if self.pending_read_sync_active == cleaned_active then
                self.pending_read_sync_active = nil
            end
        end,
    })
    self.pending_read_sync_active = active and not active.cleaned and active or nil
    if not active then
        return false, #batch
    end
    return true, #batch
end

function Methods:cancelPendingReadSync()
    self.pending_read_sync_generation = (self.pending_read_sync_generation or 0) + 1
    self.pending_read_sync_scheduled = nil
    local active = self.pending_read_sync_active
    if not active then
        return false
    end
    active.canceled = true
    self.pending_read_sync_active = nil
    if SubprocessJob.cancel then
        SubprocessJob.cancel(active)
    end
    return true
end


function Methods:applyPendingReadSyncResult(active, result)
    if not active or type(result) ~= "table" then
        return 0, active and #(active.batch or {}) or 0
    end

    local snapshot_by_key = {}
    for _, item in ipairs(active.batch or {}) do
        snapshot_by_key[item.key] = item.desired_read_state == true
    end

    local ledger = self:loadChapterLedger()
    local synced = 0
    local changed = false

    for _, item in ipairs(result.failures or {}) do
        SuwayomiDebug.log({
            operation = "read_sync",
            event = "failure",
            key = item.key,
            chapter_id = item.chapter_id,
            desired_read_state = item.desired_read_state == true,
            error = item.error or "Read sync failed.",
        })
    end

    for _, item in ipairs(result.successes or {}) do
        local key = item.key
        local entry = ledger[key]
        local desired_read_state = item.desired_read_state == true
        if entry
            and entry.pending_read_sync == true
            and snapshot_by_key[key] == desired_read_state
            and self:getDesiredReadStateFromLedgerEntry(entry) == desired_read_state
        then
            entry.pending_read_sync = nil
            entry.pending_read_state = nil
            synced = synced + 1
            changed = true
            if desired_read_state ~= true and not entry.path then
                ledger[key] = nil
            end
        else
            SuwayomiDebug.log({
                operation = "read_sync",
                event = "conflict",
                key = key,
                chapter_id = item.chapter_id,
                worker_desired_read_state = desired_read_state,
                current_desired_read_state = self:getDesiredReadStateFromLedgerEntry(entry),
                pending_read_sync = entry and entry.pending_read_sync == true or false,
            })
        end
    end

    if changed then
        self:saveChapterLedger(ledger)
    end

    return synced, tonumber(result.attempted) or #(active.batch or {})
end


function Methods:finishPendingReadSync(_active, synced, attempted)
    self.pending_read_sync_active = nil

    if self:hasPendingReadSync(self:loadChapterLedger()) then
        local next_delay = self.read_sync_delay_seconds
        if attempted and attempted > 0 and synced == 0 then
            next_delay = self.pending_read_sync_failure_delay or self.read_sync_failure_delay_seconds
            self.pending_read_sync_failure_delay = math.min(
                next_delay * 2,
                self.read_sync_max_failure_delay_seconds
            )
        else
            self.pending_read_sync_failure_delay = nil
        end
        self:schedulePendingReadSync(nil, next_delay)
    else
        self.pending_read_sync_failure_delay = nil
    end
end


function Methods:pollPendingReadSync()
    SubprocessJob.poll(self.pending_read_sync_active)
end


function Methods:schedulePendingReadSync(credentials, delay_seconds)
    if self.pending_read_sync_scheduled then
        return
    end

    self.pending_read_sync_scheduled = true
    local scheduled_generation = self.pending_read_sync_generation or 0
    SuwayomiDebug.log({
        operation = "schedulePendingReadSync",
        event = "scheduled",
        delay_seconds = delay_seconds or self.read_sync_delay_seconds,
    })
    UIManager:scheduleIn(delay_seconds or self.read_sync_delay_seconds, function()
        if scheduled_generation ~= (self.pending_read_sync_generation or 0) then
            self.pending_read_sync_scheduled = false
            return
        end
        self.pending_read_sync_scheduled = false
        if self.pending_read_sync_active then
            return
        end
        local sync_credentials = credentials or SuwayomiSettings:load()
        local started, attempted = self:startPendingReadSyncWorker(sync_credentials, self.read_sync_batch_size)
        if not started then
            if self:hasPendingReadSync(self:loadChapterLedger()) then
                if attempted and attempted > 0 then
                    local next_delay = self.pending_read_sync_failure_delay or self.read_sync_failure_delay_seconds
                    self.pending_read_sync_failure_delay = math.min(
                        next_delay * 2,
                        self.read_sync_max_failure_delay_seconds
                    )
                    self:schedulePendingReadSync(nil, next_delay)
                else
                    self.pending_read_sync_failure_delay = nil
                end
            else
                self.pending_read_sync_failure_delay = nil
            end
        end
    end)
end


function Methods:syncReadStateNow()
    if self.pending_read_sync_active then
        self:showMessage(I18n.t("Read state sync is already running."))
        return false
    end

    self:reconcileDownloadedChapterLedger()

    if not self:hasPendingReadSync(self:loadChapterLedger()) then
        self:showMessage(I18n.t("Read state is already synced."))
        return false
    end

    local credentials = SuwayomiSettings:load()
    if not credentials or credentials.server_url == "" then
        self:showMessage(I18n.t("Set up your Suwayomi server login first."))
        return false
    end

    local started = self:startPendingReadSyncWorker(credentials, self.read_sync_batch_size)
    if started then
        self:showMessage(I18n.t("Read state sync started."))
        return true
    end
    return false
end


function Methods:onCloseDocument()
    local document_path = self:getCurrentDocumentPath()
    if type(document_path) ~= "string" or document_path == "" or not self:isCurrentDocumentFinished() then
        return
    end

    local ledger = self:loadChapterLedger()
    for _, entry in pairs(ledger) do
        if entry.path == document_path then
            local already_read = entry.read == true
            local marked = self:markLedgerEntryRead(entry)
            local settings = SuwayomiSettings:loadDeleteChaptersSettings()
            local cleanup_enabled = tonumber(settings and settings.delete_finished_while_reading) or 0
            if (marked or already_read) and cleanup_enabled > 0
                and validId(entry.manga_id) and validId(entry.chapter_id)
                and type(entry.path) == "string" and entry.path ~= ""
                and self.recordFinishedChapter
            then
                self:recordFinishedChapter(entry)
            end
            return
        end
    end
end


ReadSyncController.methods = Methods

return ReadSyncController
