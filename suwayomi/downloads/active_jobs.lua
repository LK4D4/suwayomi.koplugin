-- Boundary: active download subprocess lifecycle.
--
-- Responsibility: own in-memory active jobs, launch downloader workers, poll
-- progress files, handle terminal states, and schedule follow-up polls.
-- Owned state: active and stopping jobs, completion retries and timers; persisted state still
-- flows through the queue facade and JobStore.
-- Dependencies: queue facade callbacks, KOReader subprocess utilities, progress
-- files, and the plugin i18n facade.
-- External data: worker progress files and subprocess status are treated as
-- untrusted until normalized into queue status and persisted job records.

local I18n = require("suwayomi/i18n")
local ProgressFile = require("suwayomi/downloads/progress_file")
local Archive = require("suwayomi/downloads/archive")

local ActiveJobs = {}
ActiveJobs.__index = ActiveJobs

local function retryJitterSeconds(key, retry_count)
    local key_text = tostring(key or "")
    local hash = tonumber(retry_count) or 0
    for index = 1, #key_text do
        hash = (hash + key_text:byte(index)) % 5
    end
    return hash
end

function ActiveJobs:new(options)
    options = options or {}
    local active_jobs = {
        queue = options.queue,
        jobs = options.jobs or {},
        poll_scheduled = false,
        retry_wakeup_at = nil,
        terminating_pids = {},
    }
    setmetatable(active_jobs, self)
    return active_jobs
end

function ActiveJobs:getCount()
    local count = 0
    for _ in pairs(self.jobs or {}) do
        count = count + 1
    end
    for _, job in pairs(self.terminating_pids) do
        if not self.jobs[job.key] then count = count + 1 end
    end
    return count
end

function ActiveJobs:getStoppingJob(key)
    for _, job in pairs(self.terminating_pids) do
        if job.key == key then return job end
    end
end

function ActiveJobs:isWorkerDone(job)
    if job.worker_done then return true end
    if not job.pid then job.worker_done = true; return true end
    local ok, done = pcall(self.queue.ffi_util.isSubProcessDone, job.pid)
    if ok and done then job.worker_done = true end
    return job.worker_done == true
end

function ActiveJobs:cleanupStoppedJob(job)
    self.queue:cleanupAttempt(job)
end

function ActiveJobs:reapStoppingJobs()
    for pid, job in pairs(self.terminating_pids) do
        if self:isWorkerDone(job) then
            self:cleanupStoppedJob(job)
            self.terminating_pids[pid] = nil
            self.queue.onStatusChanged()
        end
    end
end

function ActiveJobs:getJob(key)
    return self.jobs and self.jobs[key] or nil
end

function ActiveJobs:setJob(job)
    self.jobs = self.jobs or {}
    self.jobs[job.key or self.queue:getKey(job.manga, job.chapter)] = job
end

function ActiveJobs:removeJob(job)
    if not self.jobs then
        return
    end
    self.jobs[job.key or self.queue:getKey(job.manga, job.chapter)] = nil
end

function ActiveJobs:appendSnapshotJobs(snapshot)
    -- Snapshot construction stays here so queue.lua does not need to know the
    -- active job table shape.
    for _index, job in pairs(self.jobs or {}) do
        table.insert(snapshot.active, self.queue:copySnapshotJob(job, "downloading"))
    end
end

function ActiveJobs:schedulePoll()
    if self.poll_scheduled or self:getCount() == 0 then
        return
    end

    self.poll_scheduled = true
    self.queue.ui_manager:scheduleIn(self.queue.POLL_INTERVAL_SECONDS, function()
        self.queue:poll()
    end)
end

function ActiveJobs:writeProgressFallback(progress_path, state, current, total, path, error_message, retryable, details)
    return ProgressFile.writeFallback(progress_path, state, current, total, path, error_message, retryable, details)
end

function ActiveJobs:runDownloaderJob(queued)
    if queued.downloader.downloadChapterWithProgress then
        queued.downloader:downloadChapterWithProgress(
            queued.credentials,
            queued.download_directory,
            queued.manga,
            queued.chapter,
            queued.progress_path,
            {
                attempt_id = queued.attempt_id, force = queued.repair,
                repair_path = queued.repair and queued.progress and queued.progress.path,
            }
        )
        return
    end

    local result = queued.downloader:startChapterDownload(queued.credentials, queued.download_directory, queued.manga, queued.chapter,
        {
            attempt_id = queued.attempt_id, force = queued.repair,
            repair_path = queued.repair and queued.progress and queued.progress.path,
        })
    if not result.ok or result.skipped then
        local state = result.skipped and "skipped" or (result.ok and "downloaded" or "failed")
        self:writeProgressFallback(
            queued.progress_path,
            state,
            result.ok and 1 or 0,
            result.ok and 1 or 0,
            result.path,
            result.error,
            result.retryable,
            result
        )
        return
    end

    repeat
        result = queued.downloader:downloadNextPage(result.job)
        self:writeProgressFallback(
            queued.progress_path,
            result.ok and (result.done and "downloaded" or "downloading") or "failed",
            result.current,
            result.total,
            result.path,
            result.error,
            result.retryable,
            result
        )
    until not result.ok or result.done
end

function ActiveJobs:startQueuedJob(queued)
    local queue = self.queue
    if queue and queue.checkStoreFence and not queue:checkStoreFence() then
        return false
    end
    local key = queued.key or queue:getKey(queued.manga, queued.chapter)
    if self:getJob(key) then
        queue:setStatus(queued.manga, queued.chapter, { state = "downloading" })
        return false, "already_active"
    end
    local valid, reason = queue:validateJob(queued)
    if not valid then return false, reason end
    if queued.start_failure then
        local saved, save_err = self:finishWithFailure(queued, queued.start_failure)
        return false, saved and "terminal_failure" or save_err
    end
    queued.key = key
    queued.started_at = queue.now()
    queued.last_progress_at = queued.started_at
    queued.last_progress_current = nil
    queued.last_progress_state = nil
    local attempt_id, attempt_error = Archive.newAttemptId()
    if not attempt_id then
        queued.start_failure = attempt_error or I18n.t("Could not start chapter download")
        local saved, save_err = self:finishWithFailure(queued, queued.start_failure)
        return false, saved and "terminal_failure" or save_err
    end
    queued.attempt_id = attempt_id
    queued.progress = queue:withArchiveEvidence(queued, {
        state = "downloading", current = 0, total = 0, updated_at = queued.last_progress_at,
    })
    queued.progress_path = queue:buildProgressPath(queued.manga, queued.chapter, queued.download_directory, attempt_id)
    queued.credentials = queue:getCredentialsForJob()
    local ok, err = queue:upsertPersistentJob(queue:buildPersistentJob(queued.manga, queued.chapter, queued.download_directory, "downloading", {
        started_at = queued.started_at,
        last_progress_at = queued.last_progress_at,
        retry_count = queued.retry_count,
        archive_generation = queued.archive_generation,
        provenance = queued.provenance,
        repair = queued.repair,
        progress = queued.progress,
    }))
    if not ok then
        return false, err
    end
    valid, reason = queue:validateJob(queued)
    if not valid then return false, reason end

    local pid, subproc_err = queue.ffi_util.runInSubProcess(function()
        self:runDownloaderJob(queued)
    end)

    if not pid then
        local message = I18n.f("Could not start chapter download: %1", subproc_err or I18n.t("unknown error"))
        queued.start_failure = message
        local saved, save_err = self:finishWithFailure(queued, message)
        return false, saved and "terminal_failure" or save_err
    end

    queued.pid = pid
    self:setJob(queued)
    queue:setStatus(queued.manga, queued.chapter, queue:statusForJob(queued, "downloading"))
    return true
end

function ActiveJobs:process()
    local queue = self.queue
    if queue and queue.checkStoreFence and not queue:checkStoreFence() then
        return
    end
    local started_at = os.time()
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket and socket.gettime then
        started_at = socket.gettime()
    end
    local started_count = 0
    local earliest_retry_at
    self:reapStoppingJobs()
    -- Stopping workers reserve their own slots, not every available slot.
    if next(self.terminating_pids) then
        earliest_retry_at = queue.now() + 1
    end
    while self:getCount() < queue.max_active_chapters do
        local ready_retry_index
        local ready_fresh_index
        local delayed_retry_at
        local current_time = queue.now()
        for index, item in ipairs(queue.items or {}) do
            local retry_ready = not item.retry_at or item.retry_at <= current_time
            if retry_ready and item.previous_pid and self.terminating_pids[item.previous_pid] then
                item.retry_at = current_time + 1
                retry_ready = false
            elseif retry_ready then
                item.previous_pid = nil
            end
            if (tonumber(item.retry_count) or 0) > 0 then
                if retry_ready and not ready_retry_index then
                    ready_retry_index = index
                elseif not retry_ready and (not delayed_retry_at or item.retry_at < delayed_retry_at) then
                    delayed_retry_at = item.retry_at
                end
            elseif retry_ready and not ready_fresh_index then
                ready_fresh_index = index
            elseif not retry_ready and (not delayed_retry_at or item.retry_at < delayed_retry_at) then
                delayed_retry_at = item.retry_at
            end
        end
        if delayed_retry_at and (not earliest_retry_at or delayed_retry_at < earliest_retry_at) then
            earliest_retry_at = delayed_retry_at
        end
        local ready_index = ready_retry_index or ready_fresh_index
        local queued = ready_index and table.remove(queue.items, ready_index) or nil
        if not queued then
            break
        end

        local ok, err = self:startQueuedJob(queued)
        if ok then
            started_count = started_count + 1
        elseif err ~= "already_active" and err ~= "terminal_failure" then
            table.insert(queue.items, ready_index, queued)
            earliest_retry_at = queue.now() + 1
            break
        end
    end

    if earliest_retry_at then
        self:scheduleRetryWakeup(earliest_retry_at)
    end

    self:schedulePoll()
    local finished_at = os.time()
    if ok_socket and socket and socket.gettime then
        finished_at = socket.gettime()
    end
    queue:logDebug({
        operation = "downloadQueue.process",
        event = "end",
        started_count = started_count,
        active_count = self:getCount(),
        queued_count = #(queue.items or {}),
        elapsed_ms = math.floor(((finished_at - started_at) * 1000) + 0.5),
    })
end

function ActiveJobs:scheduleRetryWakeup(retry_at)
    if self.retry_wakeup_at and self.retry_wakeup_at <= retry_at then
        return
    end
    self.retry_wakeup_at = retry_at
    local delay = math.max(0, retry_at - self.queue.now())
    self.queue.ui_manager:scheduleIn(delay, function()
        if self.retry_wakeup_at ~= retry_at then
            return
        end
        self.retry_wakeup_at = nil
        self:process()
    end)
end

function ActiveJobs:scheduleTransientRetry(active, progress)
    local queue = self.queue
    if queue and queue.checkStoreFence and not queue:checkStoreFence() then
        return false, "store_blocked"
    end
    local valid, reason = queue:validateJob(active)
    if not valid then return false, reason end
    local retry_count = (tonumber(active.retry_count) or 0) + 1
    local base_retry_delay = queue.RETRY_DELAYS_SECONDS[retry_count]
    local retry_delay = base_retry_delay and (base_retry_delay + retryJitterSeconds(active.key, retry_count))
    if not retry_delay then
        return false
    end

    local retry_at = queue.now() + retry_delay
    local persistent_job = active.pending_retry or queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, "queued", {
        retry_count = retry_count,
        retry_at = retry_at,
        archive_generation = active.archive_generation,
        provenance = active.provenance,
        repair = active.repair,
        progress = queue:withArchiveEvidence(active, {
            state = "queued",
            current = progress and progress.current or active.last_progress_current or 0,
            total = progress and progress.total or active.last_progress_total or 0,
            error = progress and progress.error or active.last_progress_error,
            retryable = true,
            updated_at = queue.now(),
        }),
    })
    active.pending_retry = persistent_job
    retry_at = persistent_job.retry_at
    local ok, err = queue:upsertPersistentJob(persistent_job)
    if not ok then
        return false, err or "save_failed"
    end

    self:terminateJob(active)
    self:removeJob(active)

    local queued = {
        key = active.key,
        download_directory = active.download_directory,
        manga = active.manga,
        chapter = active.chapter,
        downloader = active.downloader,
        retry_count = retry_count,
        retry_at = retry_at,
        previous_pid = active.pid,
        progress = persistent_job.progress,
        archive_generation = active.archive_generation,
        provenance = active.provenance,
        repair = active.repair,
    }
    table.insert(queue.items, queued)
    queue:setStatus(active.manga, active.chapter, queue:statusForJob(persistent_job, "queued"))
    queue:logDebug({
        operation = "downloadQueue.retry",
        event = "scheduled",
        key = active.key,
        retry_count = retry_count,
        retry_delay_seconds = retry_delay,
    })
    return true
end

function ActiveJobs:terminateJob(active)
    local queue = self.queue
    if not active or not active.pid then
        return
    end
    self.terminating_pids[active.pid] = active
    if not self:isWorkerDone(active) and queue and queue.ffi_util and queue.ffi_util.terminateSubProcess then
        pcall(queue.ffi_util.terminateSubProcess, active.pid)
    end
end

function ActiveJobs:finishWithFailure(active, message)
    local queue = self.queue
    if queue and queue.checkStoreFence and not queue:checkStoreFence() then
        return false, "store_blocked"
    end
    local failure_message = queue:formatFailureMessage(active.manga, active.chapter, message or I18n.t("Chapter download failed."))
    local ok, err = queue:upsertPersistentJob(queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed", {
        started_at = active.started_at,
        last_progress_at = queue.now(),
        archive_generation = active.archive_generation,
        provenance = active.provenance,
        retry_count = active.retry_count,
        repair = active.repair,
        progress = queue:withArchiveEvidence(active, {
            state = "failed",
            current = active.last_progress_current or 0,
            total = active.last_progress_total or 0,
            path = active.last_progress_path,
            error = failure_message,
            updated_at = queue.now(),
        }),
    }))
    if not ok then
        return false, err
    end
    self:terminateJob(active)
    self:removeJob(active)
    local failed = queue:findPersistentJob(active.key)
    queue:setStatus(active.manga, active.chapter, queue:statusForJob(failed, "failed"))
    queue:notifyDownloadFailure(failure_message)
    return true
end

function ActiveJobs:finishWithCancel(active, options)
    options = options or {}
    local queue = self.queue
    local key = active.key or queue:getKey(active.manga, active.chapter)
    queue:invalidateVerification(key)
    local ok, err = queue:cancelJobRecord(active)
    if not ok then
        return false, err
    end
    self:terminateJob(active)
    self:removeJob(active)
    if not options.quiet then
        queue.onStatusChanged()
    end
    if options.process ~= false then
        self:process()
    end
    return true
end

function ActiveJobs:cancelAll()
    local active_jobs = {}
    for _index, active in pairs(self.jobs or {}) do
        table.insert(active_jobs, active)
    end

    local canceled = 0
    local last_err = nil
    for _index, active in ipairs(active_jobs) do
        local ok, err = self:finishWithCancel(active, { process = false, quiet = true })
        if ok then
            canceled = canceled + 1
        else
            last_err = last_err or err
        end
    end
    self:process()
    if canceled > 0 and self.queue then
        self.queue.onStatusChanged()
    end
    if canceled == 0 and last_err then
        return 0, last_err
    end
    return canceled, last_err
end

function ActiveJobs:recordProgress(active, progress)
    local queue = self.queue
    if not progress or not progress.state then
        return
    end

    local changed = progress.current ~= active.last_progress_current
        or progress.total ~= active.last_progress_total
        or progress.state ~= active.last_progress_state
    if changed then
        active.last_progress_at = queue.now()
        active.last_progress_current = progress.current
        active.last_progress_total = progress.total
        active.last_progress_path = progress.path
        active.last_progress_error = progress.error
        active.last_progress_state = progress.state
        progress.updated_at = active.last_progress_at
        active.progress = queue:withArchiveEvidence(active, progress)
        -- Terminal progress is only an observation until finishFromProgress
        -- validates the archive and finalizes active and persistent state.
        if progress.state ~= "downloaded" and progress.state ~= "skipped" and progress.state ~= "failed" then
            queue:upsertPersistentJob(queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, progress.state, {
                started_at = active.started_at,
                last_progress_at = active.last_progress_at,
                retry_count = active.retry_count,
                archive_generation = active.archive_generation,
                provenance = active.provenance,
                repair = active.repair,
                progress = active.progress,
            }))
            queue:setStatus(active.manga, active.chapter, queue:statusForJob(active, progress.state))
        end
    end
end

function ActiveJobs:completeArchive(active, path, progress)
    local queue = self.queue
    active.pending_completion = path
    active.pending_identity = active.pending_identity or progress and progress.identity or Archive.identity(path)
    if not self:isWorkerDone(active) then return false, "worker_stopping" end
    local ok, err = queue:commitChapterCompletion(active, path)
    if not ok then return false, err end
    self:removeJob(active)
    if active.pid then self.terminating_pids[active.pid] = nil end
    local remaining = {}
    for _, item in ipairs(queue.items) do
        if item.key ~= active.key then remaining[#remaining + 1] = item end
    end
    queue.items = remaining
    self:cleanupStoppedJob(active)
    queue:setStatus(active.manga, active.chapter, {
        state = progress and progress.state == "skipped" and "skipped" or "downloaded",
        current = progress and progress.current or active.last_progress_current,
        total = progress and progress.total or active.last_progress_total,
    })
    queue:notifyChapterArchiveReady(active.manga, active.chapter, path)
    return true
end

function ActiveJobs:finishFromProgress(active, progress)
    local queue = self.queue
    if not queue:checkStoreFence() then return false, "store_blocked" end
    local successful = progress and (progress.state == "downloaded" or progress.state == "skipped")
    local path
    if successful then
        path = queue:getCompletedArchivePath(active, progress)
        if not path or not queue.downloader.chapterExists or not queue.downloader:chapterExists(path) then
            path = nil
        elseif progress.identity and Archive.identity(path) ~= progress.identity then
            path = nil
        end
    else
        path = queue:getExistingArchivePath(active, progress)
        if not (path and self:isWorkerDone(active) and active.attempt_id
            and Archive.attemptId(path) == active.attempt_id) then path = nil end
    end
    if path then return self:completeArchive(active, path, progress) end
    if progress and progress.state == "failed" and progress.retryable == true then
        local retried, err = self:scheduleTransientRetry(active, progress)
        if retried or err then return retried, err end
    end
    local message = progress and progress.error
    if progress and (progress.state == "downloaded" or progress.state == "skipped") then
        message = I18n.t("Chapter download finished but the archive is missing.")
    end
    return self:finishWithFailure(active, message)
end

function ActiveJobs:finishWithoutProgress(active)
    return self:finishFromProgress(active)
end

function ActiveJobs:poll()
    local queue = self.queue
    self.poll_scheduled = false
    if queue and queue.checkStoreFence and not queue:checkStoreFence() then
        return
    end
    local started_at = os.time()
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket and socket.gettime then
        started_at = socket.gettime()
    end
    if self:getCount() == 0 then
        return
    end

    local active_jobs = {}
    for _index, active in pairs(self.jobs or {}) do
        table.insert(active_jobs, active)
    end

    for index = 1, #active_jobs do
        if queue and queue.checkStoreFence and not queue:checkStoreFence() then
            break
        end
        local active = active_jobs[index]
        local progress = active.pending_completion and {
            state = active.last_progress_state == "skipped" and "skipped" or "downloaded",
            current = active.last_progress_current,
            total = active.last_progress_total,
            path = active.pending_completion,
            identity = active.pending_identity,
        } or active.pending_retry and {
            state = "failed",
            retryable = true,
        } or ProgressFile.read(active.progress_path)
        self:recordProgress(active, progress)
        if queue and queue.checkStoreFence and not queue:checkStoreFence() then
            break
        end

        if active.pending_completion then
            -- Storage retries cannot turn a completed transfer into a network timeout.
            self:finishFromProgress(active, progress)
        elseif queue.now() - (active.last_progress_at or active.started_at or queue.now()) > queue.WATCHDOG_TIMEOUT_SECONDS then
            -- The worker may have died without writing terminal progress. The
            -- watchdog converts that silent active state into a recoverable
            -- failed job instead of leaving a permanent "downloading" row.
            local retried, retry_err = self:scheduleTransientRetry(active, {
                state = "failed",
                current = active.last_progress_current or 0,
                total = active.last_progress_total or 0,
                path = active.last_progress_path,
                error = I18n.t("Chapter download timed out."),
                retryable = true,
            })
            if not retried and not retry_err then
                self:finishWithFailure(active, I18n.t("Chapter download timed out."))
            end
        else
            local done = self:isWorkerDone(active)
            local terminal = progress and (progress.state == "downloaded" or progress.state == "skipped" or progress.state == "failed")
            if terminal or done then
                if terminal then
                    self:finishFromProgress(active, progress)
                else
                    self:finishWithoutProgress(active)
                end
            end
        end
    end

    self:process()
    local finished_at = os.time()
    if ok_socket and socket and socket.gettime then
        finished_at = socket.gettime()
    end
    queue:logDebug({
        operation = "downloadQueue.poll",
        event = "end",
        polled_count = #active_jobs,
        active_count = self:getCount(),
        queued_count = #(queue.items or {}),
        elapsed_ms = math.floor(((finished_at - started_at) * 1000) + 0.5),
    })
end

function ActiveJobs:shutdown(deadline, now)
    self.retry_wakeup_at, self.poll_scheduled = nil, false
    now = now or require("socket").gettime
    deadline = deadline or now() + 2
    local workers = {}
    for _, job in pairs(self.jobs) do if job.pid then workers[job.pid] = job end end
    for pid, job in pairs(self.terminating_pids) do workers[pid] = job end
    -- Both helpers are nonblocking without isSubProcessDone's optional wait flag.
    -- One pass shares the entire budget; no file IO or final save is required.
    for pid, job in pairs(workers) do
        if now() >= deadline then break end
        if not self:isWorkerDone(job) then
            pcall(self.queue.ffi_util.terminateSubProcess, pid)
            if now() < deadline then self:isWorkerDone(job) end
        end
    end
end

return ActiveJobs
