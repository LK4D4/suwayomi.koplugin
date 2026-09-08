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

function DownloadQueue:buildProgressPath(manga, chapter, download_directory)
    return ProgressFile.buildPath(self:getKey(manga, chapter), download_directory)
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
            item.previous_pid = previous_pids[key] or item.previous_pid
            table.insert(remaining_items, item)
            seen[key] = true
        end
    end
    self.items = remaining_items

    local new_statuses = {}
    for key, pjob in pairs(persistent_map) do
        new_statuses[key] = {
            state = pjob.state,
            retry_count = pjob.retry_count,
            retry_at = pjob.retry_at,
            current = pjob.progress and pjob.progress.current or 0,
            total = pjob.progress and pjob.progress.total or 0,
        }
    end
    if self.active_job_lifecycle and self.active_job_lifecycle.jobs then
        for key, active in pairs(self.active_job_lifecycle.jobs) do
            new_statuses[key] = {
                state = "downloading",
                current = active.last_progress_current or 0,
                total = active.last_progress_total or 0,
            }
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
    return self.job_store:copySnapshotJob(job, state)
end

function DownloadQueue:getSnapshot()
    local snapshot = {
        active = {},
        queued = {},
        failed = {},
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
    return self:enqueue(job.manga, job.chapter, job.download_directory, { provenance = "explicit" })
end

function DownloadQueue:clearFailed()
    if not self:checkStoreFence() then return 0, "store_blocked" end
    local remaining = {}
    local cleared = 0
    for _index, job in ipairs(self:loadPersistentJobs()) do
        if job.version == nil and job.state == "failed" then
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
                        self.statuses[key] = { state = "failed" }
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
    return self.statuses[self:getKey(manga, chapter)]
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
    if not job or not job.download_directory or not job.manga or not job.chapter or not self.downloader.getTargetPath then
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

function DownloadQueue:jobArchiveExists(job, progress)
    return self:getExistingArchivePath(job, progress) ~= nil
end

function DownloadQueue:cancelPending(manga, chapter)
    if not self:checkStoreFence() then
        self:notifyDownloadFailure(I18n.t("Cannot cancel download: storage is ambiguous"))
        return false, "store_blocked"
    end
    local key = self:getKey(manga, chapter)
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
        local ok, err = self:removePersistentJob(key)
        if not ok then
            self:notifyDownloadFailure(err or "Failed to remove download job")
            return false, err or "save_failed"
        end
        self.items = remaining
        self.statuses[key] = nil
        self.onStatusChanged()
        return true, "queued"
    end

    if self.active_job_lifecycle:getStoppingJob(key) then return false, "downloading" end
    if status then
        return false, status.state
    end

    return false, nil
end

function DownloadQueue:cancelQueued()
    if not self:checkStoreFence() then
        self:notifyDownloadFailure(I18n.t("Cannot cancel downloads: storage is ambiguous"))
        return 0, "store_blocked"
    end
    local canceled_keys = {}
    local remaining_items = {}

    for _index, item in ipairs(self.items or {}) do
        local key = item.key or self:getKey(item.manga or {}, item.chapter or {})
        if key and key ~= "" then
            canceled_keys[key] = true
        else
            table.insert(remaining_items, item)
        end
    end

    local remaining_jobs = {}
    for _index, job in ipairs(self:loadPersistentJobs()) do
        local key = job.key or self:getKey(job.manga or {}, job.chapter or {})
        if job.version == nil and job.state == "queued" and not self:getActiveJob(key) then
            if key and key ~= "" then
                canceled_keys[key] = true
            end
        else
            table.insert(remaining_jobs, job)
        end
    end

    local canceled = 0
    for _ in pairs(canceled_keys) do
        canceled = canceled + 1
    end

    if canceled > 0 then
        local saved, err = self:savePersistentJobs(remaining_jobs)
        if not saved then
            self:notifyDownloadFailure(err or "Failed to cancel downloads")
            return 0, err or "save_failed"
        end
        self.items = remaining_items
        for key in pairs(canceled_keys) do
            self.statuses[key] = nil
        end
        self.onStatusChanged()
    end
    return canceled
end

function DownloadQueue:cancelAll()
    if not self:checkStoreFence() then
        self:notifyDownloadFailure(I18n.t("Cannot cancel downloads: storage is ambiguous"))
        return 0, "store_blocked"
    end
    local queued, queued_err = self:cancelQueued()
    local active = 0
    local active_err = nil
    if self.active_job_lifecycle.cancelAll then
        active, active_err = self.active_job_lifecycle:cancelAll()
    end
    local total = (queued or 0) + (active or 0)
    local err = active_err or queued_err
    return total, err
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

function DownloadQueue:cleanupInterruptedDownload(job)
    if not job or not job.download_directory or not job.manga or not job.chapter or not self.downloader then
        return false
    end
    local chapter_path = select(2, self.downloader:getTargetPath(job.download_directory, job.manga, job.chapter))
    local partial_path = self.downloader.getPartialPath and self.downloader:getPartialPath(chapter_path) or (chapter_path .. ".part")
    os.remove(partial_path)
    if self.downloader.getDirectPartialPath then
        os.remove(self.downloader:getDirectPartialPath(chapter_path))
    end
    return true
end

function DownloadQueue:cleanupInterruptedProgress(job)
    if not job or not job.download_directory or not job.manga or not job.chapter then
        return false
    end
    local key = self:getKey(job.manga, job.chapter)
    os.remove(ProgressFile.buildPath(key, job.download_directory))
    os.remove(ProgressFile.buildLegacyPath(key, job.download_directory))
    return true
end

function DownloadQueue:prepareFailedRetry(job)
    if self:isChapterBusy(self:getKey(job.manga, job.chapter)) then return false end
    local partial_cleanup_attempted = self:cleanupInterruptedDownload(job)
    local progress_cleanup_attempted = self:cleanupInterruptedProgress(job)
    self:logDebug({
        operation = "downloadQueue.retry",
        event = "failed",
        key = job and job.manga and job.chapter and self:getKey(job.manga, job.chapter) or nil,
        chapter_id = job and job.chapter and job.chapter.id,
        cleanup_attempted = partial_cleanup_attempted or progress_cleanup_attempted,
    })
end

function DownloadQueue:recover()
    if self.recovered then return true end
    self.recovery_pending = true
    self.recovery_completions = self.recovery_completions or {}
    local function retry(err)
        self:scheduleReconciliation()
        return false, err
    end
    if self:isBlocked() then return retry("store_blocked") end
    local jobs = self:loadPersistentJobs()
    for _, job in ipairs(jobs) do
        if job.version == nil and job.manga and job.chapter and job.download_directory
            and (job.state == "queued" or job.state == "downloading") then
            local path = self:getExistingArchivePath(job)
            if path then
                local key = self:getKey(job.manga, job.chapter)
                self.recovery_completions[key] = { job = job, path = path }
            end
        end
    end
    -- Retain these observations across an ambiguous save that removed the job.
    for _, completion in pairs(self.recovery_completions) do
        if not completion.saved then
            local ok, err = self:commitChapterCompletion(completion.job, completion.path)
            if not ok then return retry(err) end
            completion.saved = true
        end
    end
    jobs = self:loadPersistentJobs()
    local statuses, normalized, changed = {}, {}, false
    for _, job in ipairs(jobs) do
        if job.version == nil and job.manga and job.chapter and job.download_directory
            and (job.state == "queued" or job.state == "downloading") then
            local failed = {}
            for key, value in pairs(job) do failed[key] = value end
            failed.state, failed.retry_at = "failed", nil
            failed.progress = self:normalizeProgress(job.progress) or {}
            failed.progress.state = "failed"
            failed.progress.retryable = nil
            failed.progress.error = I18n.t("Interrupted; retry download")
            job, changed = failed, true
        end
        normalized[#normalized + 1] = job
        if job.manga and job.chapter and job.state == "failed" then
            statuses[self:getKey(job.manga, job.chapter)] = { state = "failed" }
        end
    end
    if changed then
        local ok, err = self:savePersistentJobs(normalized)
        if not ok then return retry(err) end
    end
    for key in pairs(self.recovery_completions) do statuses[key] = { state = "downloaded" } end
    self.statuses = statuses
    self.recovery_completions = nil
    self.recovery_pending, self.recovered = nil, true
    self.onStatusChanged()
    return true
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
    -- Terminal status can outlive its archive or configured download directory.
    if self:getExistingArchivePath({ manga = manga, chapter = chapter, download_directory = download_directory }) then
        return false, "downloaded"
    end
    return true
end

function DownloadQueue:enqueue(manga, chapter, download_directory, options)
    if not self:checkStoreFence() then
        self:notifyDownloadFailure(I18n.t("Cannot enqueue download: storage is ambiguous"))
        return false, "store_blocked"
    end
    options = options or {}
    local eligible, state = self:canEnqueue(manga, chapter, download_directory)
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

    local persistent_job = self:buildPersistentJob(manga, chapter, download_directory, "queued")
    local ok, err = self:admitPersistentJobs({ persistent_job }, options.provenance)
    if not ok then
        self:notifyDownloadFailure(err or "Failed to persist queued download")
        return false, err or "save_failed"
    end
    if enqueue_state == "retry" then self:prepareFailedRetry(persistent_job) end

    table.insert(self.items, {
        key = persistent_job.key,
        download_directory = download_directory,
        manga = manga,
        chapter = chapter,
        downloader = self.downloader,
        archive_generation = persistent_job.archive_generation,
        provenance = persistent_job.provenance,
    })
    self:setStatus(manga, chapter, { state = "queued" })

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
        local status = self:getStatus(manga, chapter)
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
                retry = status and status.state == "failed",
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
        if candidate.retry then self:prepareFailedRetry(candidate.persistent_job) end
        candidate.item.archive_generation = candidate.persistent_job.archive_generation
        candidate.item.provenance = candidate.persistent_job.provenance
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
