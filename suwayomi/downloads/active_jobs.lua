-- Boundary: active download subprocess lifecycle.
--
-- Responsibility: own in-memory active jobs, launch downloader workers, poll
-- progress files, handle terminal states, and schedule follow-up polls.
-- Owned state: active job table plus poll-scheduled flag; persisted state still
-- flows through the queue facade and JobStore.
-- Dependencies: queue facade callbacks, KOReader subprocess utilities, progress
-- files, and the plugin i18n facade.
-- External data: worker progress files and subprocess status are treated as
-- untrusted until normalized into queue status and persisted job records.

local I18n = require("suwayomi/i18n")
local ProgressFile = require("suwayomi/downloads/progress_file")

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
    return count
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

function ActiveJobs:writeProgressFallback(progress_path, state, current, total, path, error_message, retryable)
    return ProgressFile.writeFallback(progress_path, state, current, total, path, error_message, retryable)
end

function ActiveJobs:runDownloaderJob(queued)
    if queued.downloader.downloadChapterWithProgress then
        queued.downloader:downloadChapterWithProgress(
            queued.credentials,
            queued.download_directory,
            queued.manga,
            queued.chapter,
            queued.progress_path
        )
        return
    end

    local result = queued.downloader:startChapterDownload(queued.credentials, queued.download_directory, queued.manga, queued.chapter)
    if not result.ok or result.skipped then
        local state = result.skipped and "skipped" or (result.ok and "downloaded" or "failed")
        self:writeProgressFallback(
            queued.progress_path,
            state,
            result.ok and 1 or 0,
            result.ok and 1 or 0,
            result.path,
            result.error,
            result.retryable
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
            result.retryable
        )
    until not result.ok or result.done
end

function ActiveJobs:startQueuedJob(queued)
    local queue = self.queue
    local key = queued.key or queue:getKey(queued.manga, queued.chapter)
    if self:getJob(key) then
        queue:setStatus(queued.manga, queued.chapter, { state = "downloading" })
        return false
    end
    queued.key = key
    queued.started_at = queue.now()
    queued.last_progress_at = queued.started_at
    queued.last_progress_current = nil
    queued.last_progress_state = nil
    queued.progress_path = queue:buildProgressPath(queued.manga, queued.chapter, queued.download_directory)
    os.remove(queued.progress_path)
    queued.credentials = queued.credentials or queue:getCredentialsForJob()
    queue:upsertPersistentJob(queue:buildPersistentJob(queued.manga, queued.chapter, queued.download_directory, "downloading", {
        started_at = queued.started_at,
        last_progress_at = queued.last_progress_at,
        retry_count = queued.retry_count,
        progress = {
            state = "downloading",
            current = 0,
            total = 0,
            updated_at = queued.last_progress_at,
        },
    }))

    local pid, err = queue.ffi_util.runInSubProcess(function()
        self:runDownloaderJob(queued)
    end)

    if not pid then
        queue:setStatus(queued.manga, queued.chapter, { state = "failed" })
        local message = queue:formatFailureMessage(
            queued.manga,
            queued.chapter,
            I18n.f("Could not start chapter download: %1", err or I18n.t("unknown error"))
        )
        queue:upsertPersistentJob(queue:buildPersistentJob(queued.manga, queued.chapter, queued.download_directory, "failed", {
            started_at = queued.started_at,
            last_progress_at = queue.now(),
            progress = {
                state = "failed",
                current = 0,
                total = 0,
                error = message,
                updated_at = queue.now(),
            },
        }))
        queue:notifyDownloadFailure(message)
        return false
    end

    queued.pid = pid
    self:setJob(queued)
    queue:setStatus(queued.manga, queued.chapter, {
        state = "downloading",
        current = 0,
        total = 0,
    })
    return true
end

function ActiveJobs:process()
    local queue = self.queue
    local started_at = os.time()
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket and socket.gettime then
        started_at = socket.gettime()
    end
    local started_count = 0
    local earliest_retry_at
    local terminating_pending = false
    for pid in pairs(self.terminating_pids) do
        if queue.ffi_util.isSubProcessDone(pid) then
            self.terminating_pids[pid] = nil
        else
            earliest_retry_at = queue.now() + 1
            terminating_pending = true
        end
    end
    while self:getCount() < queue.max_active_chapters do
        if terminating_pending then
            break
        end
        local active_retry = false
        for _key, active in pairs(self.jobs or {}) do
            if (tonumber(active.retry_count) or 0) > 0 then
                active_retry = true
                break
            end
        end
        if active_retry then
            break
        end

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
            end
        end
        if delayed_retry_at and (not earliest_retry_at or delayed_retry_at < earliest_retry_at) then
            earliest_retry_at = delayed_retry_at
        end
        local ready_index = ready_retry_index or (not delayed_retry_at and ready_fresh_index)
        local queued = ready_index and table.remove(queue.items, ready_index) or nil
        if not queued then
            break
        end

        if self:startQueuedJob(queued) then
            started_count = started_count + 1
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
    local retry_count = (tonumber(active.retry_count) or 0) + 1
    local base_retry_delay = queue.RETRY_DELAYS_SECONDS[retry_count]
    local retry_delay = base_retry_delay and (base_retry_delay + retryJitterSeconds(active.key, retry_count))
    if not retry_delay then
        return false
    end

    self:terminateJob(active)
    self:removeJob(active)
    if queue.cleanupInterruptedDownload then
        queue:cleanupInterruptedDownload(active)
    end
    os.remove(active.progress_path)

    local retry_at = queue.now() + retry_delay
    local queued = {
        key = active.key,
        download_directory = active.download_directory,
        manga = active.manga,
        chapter = active.chapter,
        downloader = active.downloader,
        retry_count = retry_count,
        retry_at = retry_at,
        previous_pid = active.pid,
    }
    table.insert(queue.items, queued)
    queue:setStatus(active.manga, active.chapter, {
        state = "queued",
        retry_count = retry_count,
        retry_at = retry_at,
    })
    queue:upsertPersistentJob(queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, "queued", {
        retry_count = retry_count,
        retry_at = retry_at,
        progress = {
            state = "queued",
            current = progress and progress.current or active.last_progress_current or 0,
            total = progress and progress.total or active.last_progress_total or 0,
            error = progress and progress.error or active.last_progress_error,
            retryable = true,
            updated_at = queue.now(),
        },
    }))
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
    if queue and queue.ffi_util and queue.ffi_util.terminateSubProcess then
        pcall(queue.ffi_util.terminateSubProcess, active.pid)
    end
    self.terminating_pids[active.pid] = true
end

function ActiveJobs:finishWithFailure(active, message)
    local queue = self.queue
    local failure_message = queue:formatFailureMessage(active.manga, active.chapter, message or I18n.t("Chapter download failed."))
    self:terminateJob(active)
    self:removeJob(active)
    if queue.cleanupInterruptedDownload then
        queue:cleanupInterruptedDownload(active)
    end
    os.remove(active.progress_path)
    queue:setStatus(active.manga, active.chapter, { state = "failed" })
    queue:upsertPersistentJob(queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed", {
        started_at = active.started_at,
        last_progress_at = queue.now(),
        progress = {
            state = "failed",
            current = active.last_progress_current or 0,
            total = active.last_progress_total or 0,
            path = active.last_progress_path,
            error = failure_message,
            updated_at = queue.now(),
        },
    }))
    queue:notifyDownloadFailure(failure_message)
end

function ActiveJobs:finishWithCancel(active, options)
    options = options or {}
    local queue = self.queue
    self:terminateJob(active)
    self:removeJob(active)
    if queue.cleanupInterruptedDownload then
        queue:cleanupInterruptedDownload(active)
    end
    os.remove(active.progress_path)
    queue:clearStatus(active.manga, active.chapter)
    if options.process ~= false then
        self:process()
    end
end

function ActiveJobs:cancelAll()
    local active_jobs = {}
    for _index, active in pairs(self.jobs or {}) do
        table.insert(active_jobs, active)
    end

    for _index, active in ipairs(active_jobs) do
        self:finishWithCancel(active, { process = false })
    end
    self:process()
    return #active_jobs
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
        if not (progress.state == "failed" and progress.retryable == true) then
            queue:upsertPersistentJob(queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, progress.state, {
                started_at = active.started_at,
                last_progress_at = active.last_progress_at,
                retry_count = active.retry_count,
                progress = {
                    state = progress.state,
                    current = progress.current,
                    total = progress.total,
                    path = progress.path,
                    error = progress.error,
                    retryable = progress.retryable,
                    updated_at = active.last_progress_at,
                },
            }))
            queue:setStatus(active.manga, active.chapter, {
                state = progress.state,
                current = progress.current,
                total = progress.total,
            })
        end
    end
end

function ActiveJobs:finishFromProgress(active, progress)
    local queue = self.queue
    if progress and progress.state == "failed" and progress.retryable == true
        and self:scheduleTransientRetry(active, progress)
    then
        return
    end
    if active.pid then
        self.terminating_pids[active.pid] = true
    end
    self:removeJob(active)
    os.remove(active.progress_path)
    if progress and (progress.state == "downloaded" or progress.state == "skipped") then
        local archive_path = queue:getExistingArchivePath(active, progress)
        if not archive_path then
            local message = queue:formatFailureMessage(
                active.manga,
                active.chapter,
                I18n.t("Chapter download finished but the archive is missing.")
            )
            queue:setStatus(active.manga, active.chapter, { state = "failed" })
            queue:upsertPersistentJob(queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed", {
                started_at = active.started_at,
                last_progress_at = active.last_progress_at or queue.now(),
                progress = {
                    state = "failed",
                    current = progress.current,
                    total = progress.total,
                    path = progress.path,
                    error = message,
                    updated_at = active.last_progress_at or queue.now(),
                },
            }))
            queue:notifyDownloadFailure(message)
            return
        end
        queue:removePersistentJob(active.key or queue:getKey(active.manga, active.chapter))
        queue:notifyChapterArchiveReady(
            active.manga,
            active.chapter,
            archive_path
        )
    elseif progress and progress.state == "failed" and queue:jobArchiveExists(active, progress) then
        -- A downloader may report failure after writing a valid CBZ. Keep the
        -- user-facing state aligned with the archive that now exists on disk.
        local archive_path = queue:getExistingArchivePath(active, progress)
        queue:removePersistentJob(active.key or queue:getKey(active.manga, active.chapter))
        queue:setStatus(active.manga, active.chapter, {
            state = "downloaded",
            current = progress.current,
            total = progress.total,
        })
        queue:notifyChapterArchiveReady(active.manga, active.chapter, archive_path)
    elseif progress and progress.state == "failed" then
        local message = queue:formatFailureMessage(
            active.manga,
            active.chapter,
            progress.error or I18n.t("Chapter download failed.")
        )
        queue:setStatus(active.manga, active.chapter, {
            state = "failed",
            current = progress.current,
            total = progress.total,
        })
        queue:upsertPersistentJob(queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed", {
            started_at = active.started_at,
            last_progress_at = active.last_progress_at or queue.now(),
            progress = {
                state = "failed",
                current = progress.current,
                total = progress.total,
                path = progress.path,
                error = message,
                updated_at = active.last_progress_at or queue.now(),
            },
        }))
        queue:notifyDownloadFailure(message)
    end
end

function ActiveJobs:finishWithoutProgress(active)
    local queue = self.queue
    self:removeJob(active)
    os.remove(active.progress_path)
    local archive_path = queue:getExistingArchivePath(active)
    if archive_path then
        queue:removePersistentJob(active.key or queue:getKey(active.manga, active.chapter))
        queue:setStatus(active.manga, active.chapter, {
            state = "downloaded",
            current = active.last_progress_current,
            total = active.last_progress_total,
        })
        queue:notifyChapterArchiveReady(active.manga, active.chapter, archive_path)
        return
    end

    queue:setStatus(active.manga, active.chapter, { state = "failed" })
    local message = queue:formatFailureMessage(active.manga, active.chapter, I18n.t("Chapter download failed."))
    queue:upsertPersistentJob(queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed", {
        started_at = active.started_at,
        last_progress_at = queue.now(),
        progress = {
            state = "failed",
            current = active.last_progress_current or 0,
            total = active.last_progress_total or 0,
            path = active.last_progress_path,
            error = message,
            updated_at = queue.now(),
        },
    }))
    queue:notifyDownloadFailure(message)
end

function ActiveJobs:poll()
    local queue = self.queue
    local started_at = os.time()
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket and socket.gettime then
        started_at = socket.gettime()
    end
    self.poll_scheduled = false
    if self:getCount() == 0 then
        return
    end

    local active_jobs = {}
    for _index, active in pairs(self.jobs or {}) do
        table.insert(active_jobs, active)
    end

    for index = 1, #active_jobs do
        local active = active_jobs[index]
        local progress = ProgressFile.read(active.progress_path)
        self:recordProgress(active, progress)

        if queue.now() - (active.last_progress_at or active.started_at or queue.now()) > queue.WATCHDOG_TIMEOUT_SECONDS then
            -- The worker may have died without writing terminal progress. The
            -- watchdog converts that silent active state into a recoverable
            -- failed job instead of leaving a permanent "downloading" row.
            if not self:scheduleTransientRetry(active, {
                state = "failed",
                current = active.last_progress_current or 0,
                total = active.last_progress_total or 0,
                path = active.last_progress_path,
                error = I18n.t("Chapter download timed out."),
                retryable = true,
            }) then
                self:finishWithFailure(active, I18n.t("Chapter download timed out."))
            end
        else
            local done = queue.ffi_util.isSubProcessDone(active.pid)
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

return ActiveJobs
