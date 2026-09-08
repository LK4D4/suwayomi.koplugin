-- Boundary: public device-local download queue facade.
--
-- Responsibility: shared eligibility, checked enqueue results, retry, cancel, recovery, snapshots, and status
-- while delegating persistence and active worker lifecycle to focused modules.
-- Owned state: pending queue items, chapter status map, active lifecycle
-- controller, and settings-backed job store.
-- Dependencies: settings, downloader, UI manager, subprocess helpers, progress
-- files, status formatter, clock, credentials callback, and optional callbacks.
-- External data: queue settings, manga/chapter tables, progress files, and
-- worker results are normalized before callers see snapshots.

local I18n = require("suwayomi/i18n")
local ActiveJobs = require("suwayomi/downloads/active_jobs")
local JobStore = require("suwayomi/downloads/job_store")
local ProgressFile = require("suwayomi/downloads/progress_file")
local StatusFormatter = require("suwayomi/downloads/status_formatter")
local Archive = require("suwayomi/downloads/archive")
local SubprocessJob = require("suwayomi/subprocess/job")

local DownloadQueue = {}
DownloadQueue.__index = DownloadQueue

DownloadQueue.POLL_INTERVAL_SECONDS = 0.5
DownloadQueue.WATCHDOG_TIMEOUT_SECONDS = 35 * 60
DownloadQueue.CHAPTER_TITLE_WITH_STATUS_MAX_CHARS = 58
DownloadQueue.MAX_ACTIVE_CHAPTERS = 2
DownloadQueue.MIN_ACTIVE_CHAPTERS = 1
DownloadQueue.MAX_SUPPORTED_ACTIVE_CHAPTERS = 4
DownloadQueue.RETRY_DELAYS_SECONDS = { 5, 15, 30, 60, 120, 300 }

function DownloadQueue:normalizeActiveChapterLimit(value)
    local limit = tonumber(value) or self.MAX_ACTIVE_CHAPTERS
    limit = math.floor(limit)
    if limit < self.MIN_ACTIVE_CHAPTERS then
        return self.MIN_ACTIVE_CHAPTERS
    end
    if limit > self.MAX_SUPPORTED_ACTIVE_CHAPTERS then
        return self.MAX_SUPPORTED_ACTIVE_CHAPTERS
    end
    return limit
end

function DownloadQueue:new(options)
    options = options or {}
    local queue = {
        settings = options.settings,
        downloader = options.downloader,
        ui_manager = options.ui_manager,
        ffi_util = options.ffi_util,
        now = options.now or os.time,
        onStatusChanged = options.onStatusChanged or function() end,
        onMessage = options.onMessage or function() end,
        onChapterArchiveReady = options.onChapterArchiveReady or function() end,
        commitChapterArchive = options.commitChapterArchive,
        debug_logger = options.debug_logger or function() end,
        getCredentials = options.getCredentials,
        manual_deletion = options.manual_deletion,
        items = {},
        statuses = {},
        max_active_chapters = self:normalizeActiveChapterLimit(options.max_active_chapters),
    }
    setmetatable(queue, self)
    queue.active_job_lifecycle = options.active_job_lifecycle or ActiveJobs:new{
        queue = queue,
    }
    queue.job_store = options.job_store or JobStore:new{
        settings = queue.settings,
        getKey = function(manga, chapter)
            return queue:getKey(manga, chapter)
        end,
    }
    return queue
end

function DownloadQueue:logDebug(event)
    if self.debug_logger then
        pcall(self.debug_logger, event)
    end
end

function DownloadQueue:getActiveCount()
    return self.active_job_lifecycle:getCount()
end

function DownloadQueue:getActiveJob(key)
    return self.active_job_lifecycle:getJob(key)
end

function DownloadQueue:isChapterBusy(key)
    return self:getActiveJob(key) ~= nil or self.active_job_lifecycle:getStoppingJob(key) ~= nil
end

function DownloadQueue:setActiveJob(job)
    self.active_job_lifecycle:setJob(job)
end

function DownloadQueue:removeActiveJob(job)
    self.active_job_lifecycle:removeJob(job)
end

function DownloadQueue:schedulePoll()
    self.active_job_lifecycle:schedulePoll()
end

function DownloadQueue:getKey(manga, chapter)
    return tostring(manga.id or manga.title or "") .. ":" .. tostring(chapter.id or chapter.name or "")
end

function DownloadQueue:buildProgressPath(manga, chapter, download_directory, attempt_id)
    return ProgressFile.buildPath(self:getKey(manga, chapter), download_directory, attempt_id)
end

function DownloadQueue:loadPersistentJobs()
    return self.job_store:load()
end

function DownloadQueue:savePersistentJobs(jobs)
    local ok, err = self.job_store:save(jobs)
    if not ok and self:isBlocked() then self:scheduleReconciliation() end
    return ok, err
end

function DownloadQueue:normalizeProgress(progress)
    return self.job_store:normalizeProgress(progress)
end

function DownloadQueue:normalizeRecovery(recovery)
    return self.job_store:normalizeRecovery(recovery)
end

function DownloadQueue:copySourceMetadata(source)
    return self.job_store:copySourceMetadata(source)
end

function DownloadQueue:copyMangaMetadata(manga)
    return self.job_store:copyMangaMetadata(manga)
end

function DownloadQueue:copyChapterMetadata(chapter)
    return self.job_store:copyChapterMetadata(chapter)
end

function DownloadQueue:buildPersistentJob(manga, chapter, download_directory, state, details)
    return self.job_store:buildJob(manga, chapter, download_directory, state, details)
end

function DownloadQueue:upsertPersistentJob(job)
    local ok, err = self.job_store:upsert(job)
    if not ok and self:isBlocked() then self:scheduleReconciliation() end
    return ok, err
end

function DownloadQueue:upsertPersistentJobs(new_jobs)
    local ok, err = self.job_store:upsertMany(new_jobs)
    if not ok and self:isBlocked() then self:scheduleReconciliation() end
    return ok, err
end

function DownloadQueue:admitPersistentJobs(jobs, provenance)
    provenance = provenance == "explicit" and "explicit" or "automatic"
    local ok, err = self.job_store:admit(jobs, provenance, self.manual_deletion)
    if not ok and self:isBlocked() then self:scheduleReconciliation() end
    return ok, err
end

function DownloadQueue:validateJob(job)
    if self.manual_deletion then return self.manual_deletion:validateJob(job) end
    return true
end

function DownloadQueue:removePersistentJob(key)
    local ok, err = self.job_store:remove(key)
    if not ok and self:isBlocked() then self:scheduleReconciliation() end
    return ok, err
end

function DownloadQueue:scheduleReconciliation()
    if self.stopped or self.reconciliation_scheduled then return end
    self.reconciliation_scheduled = true
    self.ui_manager:scheduleIn(1, function()
        if self.stopped then return end
        self.reconciliation_scheduled = false
        local ok = self:reconcile()
        if ok then
            self:process()
        else
            self:scheduleReconciliation()
        end
    end)
end

function DownloadQueue:isBlocked()
    if self.job_store and self.job_store.isBlocked then
        return self.job_store:isBlocked()
    end
    if self.settings and self.settings.isBlocked then
        return self.settings:isBlocked()
    end
    return false
end

function DownloadQueue:reconcile()
    if self.stopped then return false, "stopped" end
    local ok, res
    if self.job_store and self.job_store.reconcile then
        ok, res = self.job_store:reconcile()
    elseif self.settings and self.settings.reconcile then
        ok, res = self.settings:reconcile()
    else
        ok, res = true, "reconciled"
    end
    if not ok then
        return false, res
    end
    if self.recovery_pending then return self:recover() end

    local persistent_jobs = self:loadPersistentJobs() or {}
    local persistent_map = {}
    local normalized = false
    for index, job in ipairs(persistent_jobs) do
        local key = job.key or (job.manga and job.chapter and self:getKey(job.manga, job.chapter))
        if key and key ~= "" then
            -- A launch intent can commit before the parent creates its worker.
            if job.version == nil and job.state == "downloading" and not self:getActiveJob(key) then
                local staged_job = {}
                for field, value in pairs(job) do staged_job[field] = value end
                staged_job.state = "queued"
                job = staged_job
                persistent_jobs[index] = staged_job
                normalized = true
            end
            persistent_map[key] = job
        end
    end
    if normalized then
        local saved, save_err = self:savePersistentJobs(persistent_jobs)
        if not saved then
            return false, save_err
        end
    end

    local previous_pids = {}
    if self.active_job_lifecycle and self.active_job_lifecycle.jobs then
        for key, active in pairs(self.active_job_lifecycle.jobs) do
            local pjob = persistent_map[key]
            if (not pjob or pjob.state ~= "downloading") and not active.pending_completion then
                previous_pids[key] = active.pid
                self.active_job_lifecycle:terminateJob(active)
                self.active_job_lifecycle:removeJob(active)
            end
        end
    end

    local existing_items = {}
    for _, item in ipairs(self.items or {}) do
        local key = item.key or (item.manga and item.chapter and self:getKey(item.manga, item.chapter))
        if key then existing_items[key] = item end
    end
    local remaining_items = {}
    local seen = {}
    for _, job in ipairs(persistent_jobs) do
        local key = job.key or (job.manga and job.chapter and self:getKey(job.manga, job.chapter))
        if key and job.version == nil and job.state == "queued" and not seen[key] then
            local item = existing_items[key] or {}
            item.key = key
            item.download_directory = job.download_directory
            item.manga = job.manga
            item.chapter = job.chapter
            item.downloader = self.downloader
            item.retry_count = job.retry_count
            item.retry_at = job.retry_at
            item.progress = job.progress
            item.archive_generation = job.archive_generation
            item.provenance = job.provenance
            item.repair = job.repair == true or nil
            item.previous_pid = previous_pids[key] or item.previous_pid
            table.insert(remaining_items, item)
            seen[key] = true
        end
    end
    self.items = remaining_items

    local new_statuses = {}
    for key, pjob in pairs(persistent_map) do
        new_statuses[key] = self:statusForJob(pjob, pjob.state)
    end
    if self.active_job_lifecycle and self.active_job_lifecycle.jobs then
        for key, active in pairs(self.active_job_lifecycle.jobs) do
            new_statuses[key] = self:statusForJob(active, "downloading")
        end
    end
    self.statuses = new_statuses
    self.onStatusChanged()
    self:schedulePoll()
    if self.manual_deletion then self.manual_deletion:wake() end
    return ok, res
end

function DownloadQueue:checkStoreFence()
    if self.stopped then return false, "stopped" end
    if self.recovery_pending then return false, "startup_pending" end
    if self:isBlocked() then
        self:scheduleReconciliation()
        return false, "store_blocked_ambiguous_transaction"
    end
    return true
end

function DownloadQueue:copySnapshotJob(job, state)
    local snapshot = self.job_store:copySnapshotJob(job, state)
    if snapshot.progress and snapshot.progress.archive_state then
        self:withArchiveEvidence(job, snapshot.progress)
    end
    if self.verification and self.verification.key == snapshot.key
        and not self.verification.canceled and not self.verification.delivered then
        snapshot.progress = snapshot.progress or {}
        snapshot.progress.verifying = true
    end
    return snapshot
end

function DownloadQueue:getSnapshot()
    local snapshot = {
        active = {},
        queued = {},
        failed = {},
        refills = self.refill and self.refill:snapshot() or {},
        manual_deletion = {},
        manual_deletion_error = "unavailable",
    }
    if self.manual_deletion then
        snapshot.manual_deletion, snapshot.manual_deletion_error = self.manual_deletion:snapshot()
    end

    self.active_job_lifecycle:appendSnapshotJobs(snapshot)

    for _index, job in ipairs(self.items or {}) do
        table.insert(snapshot.queued, self:copySnapshotJob(job, "queued"))
    end

    for _index, job in ipairs(self:loadPersistentJobs()) do
        if job.state == "failed" then
            table.insert(snapshot.failed, self:copySnapshotJob(job, "failed"))
        end
    end

    return snapshot
end

function DownloadQueue:findPersistentJob(key, state)
    return self.job_store:find(key, state)
end

function DownloadQueue:getFailedCount()
    local count = 0
    for _, job in ipairs(self:loadPersistentJobs()) do
        if job.state == "failed" then
            count = count + 1
        end
    end
    return count
end

function DownloadQueue:retryFailed(key)
    local job = self:findPersistentJob(key, "failed")
    if not job or not job.manga or not job.chapter or not job.download_directory then
        return false, "missing"
    end
    local status = self:getStatus(job.manga, job.chapter)
    if self:isChapterBusy(key) or (status and status.state ~= "failed") then
        return false, "missing"
    end
    if job.repair == true then return self:redownload(job.manga, job.chapter, job.download_directory) end
    return self:enqueue(job.manga, job.chapter, job.download_directory, { provenance = "explicit" })
end

function DownloadQueue:clearFailed()
    if not self:checkStoreFence() then return 0, "store_blocked" end
    local remaining = {}
    local cleared = 0
    for _index, job in ipairs(self:loadPersistentJobs()) do
        if job.version == nil and job.state == "failed" and not (job.progress and job.progress.archive_state) then
            cleared = cleared + 1
            if job.manga and job.chapter then
                self.statuses[self:getKey(job.manga, job.chapter)] = nil
            elseif job.key then
                self.statuses[job.key] = nil
            end
        else
            table.insert(remaining, job)
        end
    end

    if cleared > 0 then
        local saved, err = self:savePersistentJobs(remaining)
        if not saved then
            -- Restore previous failed statuses on failure
            for _, job in ipairs(self:loadPersistentJobs()) do
                if job.state == "failed" then
                    local key = job.key or (job.manga and job.chapter and self:getKey(job.manga, job.chapter))
                    if key then
                        self.statuses[key] = self:statusForJob(job, "failed")
                    end
                end
            end
            self:notifyDownloadFailure(err or "Failed to clear downloads")
            return 0, err or "save_failed"
        end
        self.onStatusChanged()
    end
    return cleared
end

function DownloadQueue:getStatus(manga, chapter)
    local key = self:getKey(manga, chapter)
    local status = self.statuses[key]
    if status and status.archive_state then
        local current = {}
        for field, value in pairs(status) do current[field] = value end
        status = self:withArchiveEvidence({ progress = status }, current)
    end
    if self.verification and self.verification.key == key
        and not self.verification.canceled and not self.verification.delivered then
        local result = {}
        for field, value in pairs(status or {}) do result[field] = value end
        result.verifying = true
        return result
    end
    return status
end

function DownloadQueue:statusForJob(job, state)
    local progress = job.progress or {}
    local evidence = progress.archive_state and self:withArchiveEvidence(job, {})
    return {
        state = state or job.state,
        repair = job.repair,
        retry_count = job.retry_count,
        retry_at = job.retry_at,
        current = progress.current or job.last_progress_current or 0,
        total = progress.total or job.last_progress_total or 0,
        archive_state = evidence and evidence.archive_state,
        identity = progress.identity,
        path = progress.path,
        error = progress.error,
    }
end

-- Only retain evidence while it still describes the inspected archive. This is
-- an observation, not a deletion-generation proof or a pathname lock.
function DownloadQueue:withArchiveEvidence(job, progress)
    local previous = job.progress or {}
    if job.repair and not progress.path then progress.path = previous.path end
    local evidence = progress.archive_state and progress or previous
    if evidence.archive_state then
        local identity = evidence.path and Archive.identity(evidence.path)
        if not evidence.identity or identity == evidence.identity then
            progress.archive_state = evidence.archive_state
            progress.identity = evidence.identity
            progress.path = evidence.path
            if progress.error == nil then progress.error = evidence.error end
        else
            progress.archive_state, progress.identity = nil, nil
        end
    end
    return progress
end

function DownloadQueue:setStatus(manga, chapter, status)
    self.statuses[self:getKey(manga, chapter)] = status
    self.onStatusChanged()
end

function DownloadQueue:notifyDownloadFailure(message)
    -- Background downloads expose failures in the Downloads screen. Avoid
    -- interrupting reading with one dialog per failed chapter.
    self:logDebug({
        operation = "downloadQueue.failure",
        event = "recorded",
        error = message,
    })
end

function DownloadQueue:getTargetChapterPath(job)
    if not job or not job.download_directory or not job.manga or not job.chapter
        or not self.downloader or not self.downloader.getTargetPath then
        return nil
    end
    local chapter_path = select(2, self.downloader:getTargetPath(job.download_directory, job.manga, job.chapter))
    return chapter_path
end

function DownloadQueue:getCompletedArchivePath(job, progress)
    local path = progress and progress.path
    if path and path ~= "" then
        return path
    end
    return self:getTargetChapterPath(job)
end

function DownloadQueue:getExistingArchivePath(job, progress)
    if not self.downloader or not self.downloader.chapterExists then
        return nil
    end

    local path = progress and progress.path
    if path and path ~= "" and self.downloader:chapterExists(path) then
        return path
    end

    local chapter_path = self:getTargetChapterPath(job)
    if chapter_path and self.downloader:chapterExists(chapter_path) == true then
        return chapter_path
    end
    if self.downloader.findExistingChapterPath and job and job.download_directory and job.manga and job.chapter then
        return self.downloader:findExistingChapterPath(job.download_directory, job.manga, job.chapter)
    end
    return nil
end

function DownloadQueue:notifyChapterArchiveReady(manga, chapter, path)
    if not path or path == "" or not self.onChapterArchiveReady then
        return false
    end

    local ok, err = pcall(self.onChapterArchiveReady, manga, chapter, path)
    if not ok then
        self:logDebug({
            operation = "downloadQueue.archiveReady",
            event = "callback_error",
            error = tostring(err),
        })
        return false
    end
    return true
end

function DownloadQueue:clearStatus(manga, chapter, options)
    if not self:checkStoreFence() then
        return false, "store_blocked"
    end
    options = options or {}
    local key = self:getKey(manga, chapter)
    self:invalidateVerification(key)
    local ok, err = self:removePersistentJob(key)
    if not ok then
        return false, err
    end
    self.statuses[key] = nil
    if not options.quiet then
        self.onStatusChanged()
    end
    return true
end

function DownloadQueue:commitChapterCompletion(active, path)
    active.pending_completion = path
    local ok, err
    if self.commitChapterArchive then
        ok, err = self.commitChapterArchive(active, path)
    else
        ok, err = self:removePersistentJob(active.key or self:getKey(active.manga, active.chapter))
    end
    if not ok and self:isBlocked() then self:scheduleReconciliation() end
    return ok, err
end

function DownloadQueue:cancelRecords(targets, retire_all)
    if not self.settings or not self.settings.getStore then return nil, "checked_store_unavailable" end
    local called, ok, err = pcall(function()
        return self.settings:getStore():saveDocument(function(doc)
            if doc.download_queue ~= nil and type(doc.download_queue) ~= "table" then
                error("unsupported_download_queue", 0)
            end
            local jobs, remove_indexes, mangas = doc.download_queue or {}, {}, {}
            for key, job in pairs(targets) do
                if job.manga and job.manga.id then mangas[tostring(job.manga.id)] = true end
                for index, stored in pairs(jobs) do
                    if type(stored) == "table" and stored.key == key then
                        if stored.version ~= nil or type(index) ~= "number" or index < 1 or index % 1 ~= 0
                            or stored.archive_generation ~= job.archive_generation then
                            error("download_job_replaced_or_unsupported", 0)
                        end
                        local progress = self:withArchiveEvidence(stored, { state = "failed" })
                        if progress.archive_state then
                            progress.error = stored.progress.error
                            jobs[index] = self:buildPersistentJob(stored.manga, stored.chapter, stored.download_directory, "failed", {
                                repair = stored.repair, retry_count = stored.retry_count, progress = progress,
                                archive_generation = stored.archive_generation, provenance = stored.provenance,
                            })
                        else remove_indexes[#remove_indexes + 1] = index end
                    end
                end
            end
            table.sort(remove_indexes, function(a, b) return a > b end)
            for _, index in ipairs(remove_indexes) do table.remove(jobs, index) end
            doc.download_queue = jobs
            if self.refill then self.refill:retire(doc, not retire_all and mangas or nil) end
        end)
    end)
    if not called then return nil, ok end
    if not ok then self:scheduleReconciliation(); return nil, err end
    for key in pairs(targets) do
        local job = self:findPersistentJob(key)
        self.statuses[key] = job and self:statusForJob(job, job.state) or nil
        self:invalidateVerification(key)
    end
    if self.refill then self.refill:wake() end
    return true
end

function DownloadQueue:cancelJobRecord(job)
    local key = job.key or self:getKey(job.manga, job.chapter)
    return self:cancelRecords({ [key] = job })
end

function DownloadQueue:cancelPending(manga, chapter)
    if not self:checkStoreFence() then
        self:notifyDownloadFailure(I18n.t("Cannot cancel download: storage is ambiguous"))
        return false, "store_blocked"
    end
    local key = self:getKey(manga, chapter)
    self:invalidateVerification(key)
    local active = self:getActiveJob(key)
    if active then
        local ok, err = self.active_job_lifecycle:finishWithCancel(active)
        if not ok then
            self:notifyDownloadFailure(err or "Failed to cancel active download")
            return false, err or "save_failed"
        end
        return true, "downloading"
    end
    local status = self.statuses[key]

    local removed = false
    local remaining = {}
    for _index, item in ipairs(self.items or {}) do
        if (item.key or self:getKey(item.manga, item.chapter)) == key then
            removed = true
        else
            table.insert(remaining, item)
        end
    end

    if removed then
        local job = self:findPersistentJob(key) or { key = key, manga = manga, chapter = chapter }
        local ok, err = self:cancelJobRecord(job)
        if not ok then
            self:notifyDownloadFailure(err or "Failed to remove download job")
            return false, err or "save_failed"
        end
        self.items = remaining
        self.onStatusChanged()
        return true, "queued"
    end

    if self.active_job_lifecycle:getStoppingJob(key) then return false, "downloading" end
    if status then
        return false, status.state
    end

    return false, nil
end

function DownloadQueue:cancelDownloads(include_active)
    if not self:checkStoreFence() then
        self:notifyDownloadFailure(I18n.t("Cannot cancel downloads: storage is ambiguous"))
        return 0, "store_blocked"
    end
    local targets, count = {}, 0
    for _, job in ipairs(self:loadPersistentJobs()) do
        if job.version == nil and (job.state == "queued" or include_active and job.state == "downloading")
            and (include_active or not self:getActiveJob(job.key)) then
            targets[job.key] = job
        end
    end
    if include_active then
        for key, active in pairs(self.active_job_lifecycle.jobs or {}) do targets[key] = active end
    end
    for _ in pairs(targets) do count = count + 1 end
    if count == 0 and not include_active then return 0 end
    local ok, err = self:cancelRecords(targets, include_active)
    if not ok then return 0, err end
    local remaining = {}
    for _, item in ipairs(self.items) do
        if not targets[item.key or self:getKey(item.manga, item.chapter)] then remaining[#remaining + 1] = item end
    end
    self.items = remaining
    if include_active then
        for key in pairs(targets) do
            local active = self:getActiveJob(key)
            if active then
                self.active_job_lifecycle:terminateJob(active)
                self.active_job_lifecycle:removeJob(active)
            end
        end
    end
    self.onStatusChanged()
    return count
end

function DownloadQueue:cancelQueued()
    return self:cancelDownloads(false)
end

function DownloadQueue:cancelAll()
    return self:cancelDownloads(true)
end

function DownloadQueue:splitUtf8Chars(text)
    return StatusFormatter.splitUtf8Chars(text)
end

function DownloadQueue:shortenChapterTitle(title, reserved_chars)
    return StatusFormatter.shortenChapterTitle(title, reserved_chars, self.CHAPTER_TITLE_WITH_STATUS_MAX_CHARS)
end

function DownloadQueue:joinChapterStatusSymbols(symbols)
    return StatusFormatter.joinChapterStatusSymbols(symbols)
end

function DownloadQueue:formatChapterStatusSymbols(chapter, symbols)
    return StatusFormatter.formatChapterStatusSymbols(chapter, symbols, self.CHAPTER_TITLE_WITH_STATUS_MAX_CHARS)
end

function DownloadQueue:buildChapterStatusSymbols(chapter, status)
    return StatusFormatter.buildChapterStatusSymbols(chapter, status)
end

function DownloadQueue:formatChapterMenuStatus(chapter, status)
    return StatusFormatter.formatChapterMenuStatus(chapter, status)
end

function DownloadQueue:formatChapterMenuText(chapter, status)
    return StatusFormatter.formatChapterMenuText(chapter, status, self.CHAPTER_TITLE_WITH_STATUS_MAX_CHARS)
end

function DownloadQueue:formatChapterNumber(value)
    return StatusFormatter.formatChapterNumber(value)
end

function DownloadQueue:formatFailureMessage(manga, chapter, detail)
    return StatusFormatter.formatFailureMessage(manga, chapter, detail, self:getKey(manga or {}, chapter or {}))
end

function DownloadQueue:cleanupAttempt(job)
    if not job or not job.attempt_id or not job.worker_done then return end
    local paths = self.downloader and self.downloader.getChapterPathCandidates
        and self.downloader:getChapterPathCandidates(job.download_directory, job.manga, job.chapter)
        or { self:getTargetChapterPath(job) }
    for _, path in ipairs(paths) do
        if self.downloader.getPartialPath then os.remove(self.downloader:getPartialPath(path, job.attempt_id)) end
        if self.downloader.getDirectPartialPath then os.remove(self.downloader:getDirectPartialPath(path, job.attempt_id)) end
    end
    if job.progress_path then
        os.remove(job.progress_path)
        os.remove(job.progress_path .. ".tmp")
    end
end

function DownloadQueue:invalidateVerification(key)
    local active = self.verification
    if active and (not key or active.key == key) then
        active.canceled = true
        if active.pid and not active.worker_done then
            pcall(self.ffi_util.terminateSubProcess, active.pid)
        end
    end
end

function DownloadQueue:verificationIsCurrent(active)
    if self.stopped or active.canceled or self.verification ~= active then return false end
    if active.is_current then
        local ok, current = pcall(active.is_current)
        if not ok or not current then return false end
    end
    local identity = Archive.identity(active.path)
    local inspected = active.result and active.result.identity or active.identity
    return identity == inspected
end

function DownloadQueue:pollVerification()
    local active = self.verification
    if not active then return end
    if self.stopped then
        self:invalidateVerification()
        return -- Unknown worker files are intentionally retained on shutdown.
    end
    if not active.worker_done then
        local ok, done = pcall(self.ffi_util.isSubProcessDone, active.pid)
        active.worker_done = ok and done == true
    end
    if not self:verificationIsCurrent(active) then active.canceled = true end
    if active.canceled and not active.worker_done and not active.terminating then
        active.terminating = true
        pcall(self.ffi_util.terminateSubProcess, active.pid)
    end
    if not active.result and not active.canceled then
        if active.worker_done then
            active.result = SubprocessJob.readResult(active.result_path)
            if type(active.result) ~= "table"
                or (active.result.state ~= "valid" and active.result.state ~= "damaged"
                    and active.result.state ~= "unverified") then
                active.result = { state = "unverified", identity = active.identity,
                    error = I18n.t("Could not verify download") }
            end
        elseif self.now() - active.started_at > self.WATCHDOG_TIMEOUT_SECONDS then
            active.result = { state = "unverified", identity = active.identity,
                error = I18n.t("Could not verify download") }
            active.terminating = true
            pcall(self.ffi_util.terminateSubProcess, active.pid)
        end
    end
    if active.result and not active.delivered and not active.canceled then
        if not self:verificationIsCurrent(active) then
            active.canceled = true
        elseif self:checkStoreFence() then
            local result = active.result
            result.path = active.path
            local ok
            if result.state == "valid" then
                ok = self:commitChapterCompletion(active, active.path)
            else
                local failed = self:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed", {
                    repair = active.repair,
                    archive_generation = active.archive_generation,
                    provenance = active.provenance,
                    progress = { state = "failed", archive_state = result.state, identity = result.identity,
                        path = active.path, error = result.error },
                })
                ok = self:upsertPersistentJob(failed)
            end
            if ok then
                active.delivered = true
                self.statuses[active.key] = result.state == "valid"
                    and { state = "downloaded", path = active.path }
                    or { state = "failed", archive_state = result.state, identity = result.identity,
                        path = active.path, error = result.error }
                self.onStatusChanged()
                local current = self:verificationIsCurrent(active)
                if active.worker_done then
                    if not active.retain_files then SubprocessJob.cleanup(active) end
                    self.verification = nil
                end
                if current and active.callback then pcall(active.callback, result) end
            end
        end
    end
    if active.worker_done and (active.canceled or active.delivered) then
        if not active.retain_files then SubprocessJob.cleanup(active) end
        if self.verification == active then self.verification = nil end
        if active.canceled then self.onStatusChanged() end
    elseif self.verification == active then
        self.ui_manager:scheduleIn(self.POLL_INTERVAL_SECONDS, function() self:pollVerification() end)
    end
end

function DownloadQueue:verifyArchive(manga, chapter, path, callback, options)
    if not self:checkStoreFence() then return false, "store_blocked" end
    if self.verification then return false, "verification_busy" end
    local key = self:getKey(manga, chapter)
    local status = self.statuses[key]
    if self:isChapterBusy(key) or status and (status.state == "queued" or status.state == "downloading") then
        return false, "downloading"
    end
    local attempt_id, err = Archive.newAttemptId()
    if not attempt_id then return false, err end
    local stored = self:findPersistentJob(key)
    local directory = stored and stored.download_directory
        or self.settings and self.settings.loadDownloadDirectory and self.settings:loadDownloadDirectory()
    local active = {
        key = key, manga = manga, chapter = chapter, path = path,
        download_directory = directory, repair = stored and stored.repair,
        archive_generation = stored and stored.archive_generation,
        provenance = stored and stored.provenance,
        identity = Archive.identity(path), callback = callback,
        is_current = options and options.is_current, started_at = self.now(),
        result_path = SubprocessJob.buildResultPath("verify_" .. attempt_id),
    }
    self.verification = active
    local ok, pid, launch_error = pcall(self.ffi_util.runInSubProcess, function()
        local valid, result = pcall(Archive.validate, path)
        if not valid then result = { state = "unverified", identity = active.identity, error = tostring(result) } end
        SubprocessJob.writeResult(active.result_path, result)
    end)
    if ok and pid then
        active.pid = pid
    else
        active.worker_done = true
        -- An exception supplies no PID/exit proof; never unlink files a
        -- possibly launched child could still be writing.
        active.retain_files = not ok
        active.result = { state = "unverified", identity = active.identity, error = tostring(ok and launch_error or pid) }
    end
    self.onStatusChanged()
    self.ui_manager:scheduleIn(0, function() self:pollVerification() end)
    return true
end

function DownloadQueue:recover()
    if self.recovered then return true end
    self.recovery_pending = true
    if self:isBlocked() then
        self:scheduleReconciliation()
        return false, "store_blocked"
    end
    local jobs = self:loadPersistentJobs()
    local normalized, changed = {}, false
    for _, job in ipairs(jobs) do
        if job.version == nil and job.manga and job.chapter and job.download_directory and job.state == "downloading" then
            local queued = {}
            for key, value in pairs(job) do queued[key] = value end
            queued.state = "queued"
            job, changed = queued, true
        end
        normalized[#normalized + 1] = job
    end
    if changed then
        local ok, err = self:savePersistentJobs(normalized)
        if not ok then
            self:scheduleReconciliation()
            return false, err
        end
    end
    self.recovery_pending, self.recovered = nil, true
    local ok, err = self:reconcile()
    if ok and #self.items > 0 then self.ui_manager:scheduleIn(0, function() self:process() end) end
    return ok, err
end

function DownloadQueue:canEnqueue(manga, chapter, download_directory)
    local status = self:getStatus(manga, chapter)
    if self:isChapterBusy(self:getKey(manga, chapter)) then
        return false, "downloading"
    end
    if status and (status.state == "queued" or status.state == "downloading"
        or status.state == "running" or status.state == "stopping" or status.state == "finalizing") then
        return false, status.state
    end
    local persisted = self:findPersistentJob(self:getKey(manga, chapter))
    local archive_state = status and status.archive_state
        or persisted and self:withArchiveEvidence(persisted, {}).archive_state
    if archive_state then return false, archive_state end
    -- Terminal status can outlive its archive or configured download directory.
    if self:getExistingArchivePath({ manga = manga, chapter = chapter, download_directory = download_directory }) then
        return false, "downloaded"
    end
    return true
end

function DownloadQueue:enqueue(manga, chapter, download_directory, options)
    return self:admit(manga, chapter, download_directory, options, false)
end

function DownloadQueue:redownload(manga, chapter, download_directory)
    local job = self:findPersistentJob(self:getKey(manga, chapter))
    return self:admit(manga, chapter, job and job.download_directory or download_directory,
        { provenance = "explicit" }, true)
end

function DownloadQueue:admit(manga, chapter, download_directory, options, repair)
    if not self:checkStoreFence() then
        self:notifyDownloadFailure(I18n.t("Cannot enqueue download: storage is ambiguous"))
        return false, "store_blocked"
    end
    options = options or {}
    local eligible, state = self:canEnqueue(manga, chapter, download_directory)
    if repair and (state == "downloaded" or state == "damaged" or state == "unverified") then eligible = true end
    if not eligible then
        if not options.quiet_duplicate then
            self.onMessage(I18n.t("Chapter download is already in progress."))
        end
        return false, state
    end
    local status = self:getStatus(manga, chapter)
    local enqueue_state = "queued"
    if status and status.state == "failed" then
        enqueue_state = "retry"
    end

    local previous = self:findPersistentJob(self:getKey(manga, chapter))
    local persistent_job = self:buildPersistentJob(manga, chapter, download_directory, "queued", {
        repair = repair,
        progress = previous and previous.progress and (previous.progress.archive_state or repair)
            and self:withArchiveEvidence(previous, { state = "queued" }) or nil,
    })
    local ok, err = self:admitPersistentJobs({ persistent_job }, options.provenance)
    if not ok then
        self:notifyDownloadFailure(err or "Failed to persist queued download")
        return false, err or "save_failed"
    end
    self:invalidateVerification(persistent_job.key)

    table.insert(self.items, {
        key = persistent_job.key,
        download_directory = download_directory,
        manga = manga,
        chapter = chapter,
        downloader = self.downloader,
        archive_generation = persistent_job.archive_generation,
        provenance = persistent_job.provenance,
        repair = persistent_job.repair,
        progress = persistent_job.progress,
    })
    self:setStatus(manga, chapter, self:statusForJob(persistent_job, "queued"))

    self.ui_manager:scheduleIn(0, function()
        self:process()
    end)
    return true, enqueue_state
end

local function batchOutcome(attempted, skipped, err)
    local uncertain = type(err) == "string" and err:match("^ambiguous_post_replacement")
    return {
        skipped = skipped,
        failed = err and not uncertain and attempted or 0,
        unconfirmed = uncertain and attempted or 0,
    }
end

function DownloadQueue:enqueueBatch(manga, chapters, download_directory, options)
    if not self:checkStoreFence() then
        self:notifyDownloadFailure(I18n.t("Cannot enqueue downloads: storage is ambiguous"))
        return 0, "store_blocked", batchOutcome(#(chapters or {}), 0, "store_blocked")
    end
    local started_at = os.time()
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket and socket.gettime then
        started_at = socket.gettime()
    end
    options = options or {}
    local persistent_jobs = {}
    local candidates = {}
    local queued_count = 0
    local seen = {}

    for _index, chapter in ipairs(chapters or {}) do
        local key = self:getKey(manga, chapter)
        if seen[key] or not self:canEnqueue(manga, chapter, download_directory) then
            if not options.quiet_duplicate then
                self.onMessage(I18n.t("Chapter download is already in progress."))
            end
        else
            seen[key] = true
            local persistent_job = self:buildPersistentJob(manga, chapter, download_directory, "queued")
            table.insert(persistent_jobs, persistent_job)
            table.insert(candidates, {
                persistent_job = persistent_job,
                item = {
                    key = persistent_job.key,
                    download_directory = download_directory,
                    manga = manga,
                    chapter = chapter,
                    downloader = self.downloader,
                },
            })
            queued_count = queued_count + 1
        end
    end

    if queued_count == 0 then
        return 0, nil, batchOutcome(0, #(chapters or {}))
    end

    local ok, err = self:admitPersistentJobs(persistent_jobs, options.provenance)
    if not ok then
        self:notifyDownloadFailure(err or "Failed to persist queued batch")
        err = err or "save_failed"
        return 0, err, batchOutcome(queued_count, #(chapters or {}) - queued_count, err)
    end

    for _, candidate in ipairs(candidates) do
        candidate.item.archive_generation = candidate.persistent_job.archive_generation
        candidate.item.provenance = candidate.persistent_job.provenance
        self:invalidateVerification(candidate.persistent_job.key)
        self.statuses[candidate.persistent_job.key] = { state = "queued" }
        table.insert(self.items, candidate.item)
    end

    self.onStatusChanged()
    self.ui_manager:scheduleIn(0, function()
        self:process()
    end)
    local finished_at = os.time()
    if ok_socket and socket and socket.gettime then
        finished_at = socket.gettime()
    end
    self:logDebug({
        operation = "downloadQueue.enqueueBatch",
        event = "end",
        manga_id = manga and manga.id,
        requested_count = #(chapters or {}),
        queued_count = queued_count,
        elapsed_ms = math.floor(((finished_at - started_at) * 1000) + 0.5),
    })
    return queued_count, nil, batchOutcome(queued_count, #(chapters or {}) - queued_count)
end

function DownloadQueue:getCredentialsForJob()
    if self.getCredentials then
        return self.getCredentials()
    end
    return self.settings and self.settings.load and self.settings:load() or {}
end

function DownloadQueue:process()
    if not self:checkStoreFence() then
        return
    end
    return self.active_job_lifecycle:process()
end

function DownloadQueue:poll()
    return self.active_job_lifecycle:poll()
end

return DownloadQueue
