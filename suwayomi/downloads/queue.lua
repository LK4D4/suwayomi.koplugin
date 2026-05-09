local _ = require("gettext")
local T = require("ffi/util").template
local JobStore = require("suwayomi/downloads/job_store")
local ProgressFile = require("suwayomi/downloads/progress_file")
local StatusFormatter = require("suwayomi/downloads/status_formatter")

local DownloadQueue = {}
DownloadQueue.__index = DownloadQueue

-- Boundary: public device-local download queue facade.
--
-- Queue states are persisted as "queued", "downloading", "downloaded",
-- "skipped", or "failed". Persisted jobs keep only serializable manga/chapter
-- metadata plus progress/recovery details; runtime-only downloader credentials,
-- callbacks, process ids, and active worker objects stay in memory.
--
-- Active jobs are launched from queued persisted jobs, polled through hidden
-- progress files, then reconciled back into settings so KOReader restarts can
-- recover interrupted work without server-side Suwayomi download mutations.
--
-- Dependencies are injected by the plugin shell: settings, downloader,
-- ui_manager, ffi_util subprocess helpers, credentials callback, clock, and
-- debug/message/status callbacks.

DownloadQueue.POLL_INTERVAL_SECONDS = 0.5
DownloadQueue.WATCHDOG_TIMEOUT_SECONDS = 30 * 60
DownloadQueue.CHAPTER_TITLE_WITH_STATUS_MAX_CHARS = 58
DownloadQueue.MAX_ACTIVE_CHAPTERS = 2
DownloadQueue.MIN_ACTIVE_CHAPTERS = 1
DownloadQueue.MAX_SUPPORTED_ACTIVE_CHAPTERS = 4

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
        debug_logger = options.debug_logger or function() end,
        getCredentials = options.getCredentials,
        items = {},
        statuses = {},
        active_jobs = {},
        poll_scheduled = false,
        max_active_chapters = self:normalizeActiveChapterLimit(options.max_active_chapters),
    }
    setmetatable(queue, self)
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
    local count = 0
    for _ in pairs(self.active_jobs or {}) do
        count = count + 1
    end
    return count
end

function DownloadQueue:getActiveJob(key)
    return self.active_jobs and self.active_jobs[key] or nil
end

function DownloadQueue:setActiveJob(job)
    self.active_jobs = self.active_jobs or {}
    self.active_jobs[job.key or self:getKey(job.manga, job.chapter)] = job
end

function DownloadQueue:removeActiveJob(job)
    if not self.active_jobs then
        return
    end
    self.active_jobs[job.key or self:getKey(job.manga, job.chapter)] = nil
end

function DownloadQueue:schedulePoll()
    if self.poll_scheduled or self:getActiveCount() == 0 then
        return
    end

    self.poll_scheduled = true
    self.ui_manager:scheduleIn(self.POLL_INTERVAL_SECONDS, function()
        self:poll()
    end)
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
    return self.job_store:save(jobs)
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
    self.job_store:upsert(job)
end

function DownloadQueue:upsertPersistentJobs(new_jobs)
    self.job_store:upsertMany(new_jobs)
end

function DownloadQueue:removePersistentJob(key)
    self.job_store:remove(key)
end

function DownloadQueue:copySnapshotJob(job, state)
    return self.job_store:copySnapshotJob(job, state)
end

function DownloadQueue:getSnapshot()
    local snapshot = {
        active = {},
        queued = {},
        failed = {},
    }

    for _, job in pairs(self.active_jobs or {}) do
        table.insert(snapshot.active, self:copySnapshotJob(job, "downloading"))
    end

    for _, job in ipairs(self.items or {}) do
        table.insert(snapshot.queued, self:copySnapshotJob(job, "queued"))
    end

    for _, job in ipairs(self:loadPersistentJobs()) do
        if job.state == "failed" then
            table.insert(snapshot.failed, self:copySnapshotJob(job, "failed"))
        end
    end

    return snapshot
end

function DownloadQueue:findPersistentJob(key, state)
    return self.job_store:find(key, state)
end

function DownloadQueue:retryFailed(key)
    local job = self:findPersistentJob(key, "failed")
    if not job or not job.manga or not job.chapter or not job.download_directory then
        return false, "missing"
    end
    return self:enqueue(job.manga, job.chapter, job.download_directory)
end

function DownloadQueue:clearFailed()
    local remaining = {}
    local cleared = 0
    for _, job in ipairs(self:loadPersistentJobs()) do
        if job.state == "failed" then
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
        self:savePersistentJobs(remaining)
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

function DownloadQueue:clearStatus(manga, chapter, options)
    options = options or {}
    local key = self:getKey(manga, chapter)
    self.statuses[key] = nil
    self:removePersistentJob(key)
    if not options.quiet then
        self.onStatusChanged()
    end
end

function DownloadQueue:jobArchiveExists(job, progress)
    if not self.downloader or not self.downloader.chapterExists then
        return false
    end

    local path = progress and progress.path
    if path and path ~= "" and self.downloader:chapterExists(path) then
        return true
    end

    if not job or not job.download_directory or not job.manga or not job.chapter or not self.downloader.getTargetPath then
        return false
    end
    local _, chapter_path = self.downloader:getTargetPath(job.download_directory, job.manga, job.chapter)
    return self.downloader:chapterExists(chapter_path) == true
end

function DownloadQueue:cancelPending(manga, chapter)
    local key = self:getKey(manga, chapter)
    if self:getActiveJob(key) then
        return false, "downloading"
    end
    local status = self.statuses[key]

    local removed = false
    local remaining = {}
    for _, item in ipairs(self.items or {}) do
        if (item.key or self:getKey(item.manga, item.chapter)) == key then
            removed = true
        else
            table.insert(remaining, item)
        end
    end
    self.items = remaining

    if removed then
        self:removePersistentJob(key)
        self.statuses[key] = nil
        self.onStatusChanged()
        return true, "queued"
    end

    if status then
        return false, status.state
    end

    return false, nil
end

function DownloadQueue:cancelQueued()
    local canceled_keys = {}
    local remaining_items = {}
    local active_keys = {}

    for key in pairs(self.active_jobs or {}) do
        active_keys[key] = true
    end

    for _, item in ipairs(self.items or {}) do
        local key = item.key or self:getKey(item.manga or {}, item.chapter or {})
        if key and key ~= "" then
            canceled_keys[key] = true
        else
            table.insert(remaining_items, item)
        end
    end
    self.items = remaining_items

    local remaining_jobs = {}
    for _, job in ipairs(self:loadPersistentJobs()) do
        local key = job.key or self:getKey(job.manga or {}, job.chapter or {})
        if job.state == "queued" and not active_keys[key] then
            if key and key ~= "" then
                canceled_keys[key] = true
            end
        else
            table.insert(remaining_jobs, job)
        end
    end

    local canceled = 0
    for key in pairs(canceled_keys) do
        canceled = canceled + 1
        self.statuses[key] = nil
    end

    if canceled > 0 then
        self:savePersistentJobs(remaining_jobs)
        self.onStatusChanged()
    end
    return canceled
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

function DownloadQueue:readProgress(progress_path)
    return ProgressFile.read(progress_path)
end

function DownloadQueue:cleanupInterruptedDownload(job)
    if not job or not job.download_directory or not job.manga or not job.chapter then
        return false
    end
    local _, chapter_path = self.downloader:getTargetPath(job.download_directory, job.manga, job.chapter)
    local partial_path = self.downloader.getPartialPath and self.downloader:getPartialPath(chapter_path) or (chapter_path .. ".part")
    os.remove(partial_path)
    return true
end

function DownloadQueue:cleanupInterruptedProgress(job)
    if not job or not job.download_directory or not job.manga or not job.chapter then
        return false
    end
    os.remove(self:buildProgressPath(job.manga, job.chapter, job.download_directory))
    return true
end

function DownloadQueue:prepareFailedRetry(job)
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

function DownloadQueue:recoverInterruptedJob(job)
    local progress = self:normalizeProgress(job.progress)
    local partial_cleanup_attempted = self:cleanupInterruptedDownload(job)
    local progress_cleanup_attempted = self:cleanupInterruptedProgress(job)
    local recovered = self:buildPersistentJob(job.manga, job.chapter, job.download_directory, "queued", {
        started_at = job.started_at,
        last_progress_at = job.last_progress_at,
        recovery = {
            reason = "interrupted",
            recovered_at = self.now(),
            previous_state = "downloading",
            progress = progress,
        },
    })
    self:logDebug({
        operation = "downloadQueue.recover",
        event = "interrupted",
        key = recovered.key,
        chapter_id = recovered.chapter and recovered.chapter.id,
        previous_state = "downloading",
        progress_state = progress and progress.state or nil,
        progress_current = progress and progress.current or nil,
        progress_total = progress and progress.total or nil,
        cleanup_attempted = partial_cleanup_attempted or progress_cleanup_attempted,
    })
    return recovered
end

function DownloadQueue:recover()
    local jobs = self:loadPersistentJobs()
    if #jobs == 0 then
        return
    end

    local recovered_jobs = {}
    local should_process = false
    for _, job in ipairs(jobs) do
        if job.manga and job.chapter and job.download_directory and (job.state == "queued" or job.state == "downloading") then
            local recovered
            if job.state == "downloading" then
                recovered = self:recoverInterruptedJob(job)
            else
                recovered = self:buildPersistentJob(job.manga, job.chapter, job.download_directory, "queued")
            end
            table.insert(recovered_jobs, recovered)
            table.insert(self.items, {
                key = recovered.key,
                download_directory = recovered.download_directory,
                manga = recovered.manga,
                chapter = recovered.chapter,
                downloader = self.downloader,
            })
            self:setStatus(recovered.manga, recovered.chapter, { state = "queued" })
            should_process = true
        elseif job.manga and job.chapter and job.state == "failed" then
            if self:jobArchiveExists(job, job.progress) then
                self.statuses[job.key or self:getKey(job.manga, job.chapter)] = nil
            else
                table.insert(recovered_jobs, job)
                self:setStatus(job.manga, job.chapter, { state = "failed" })
            end
        end
    end

    self:savePersistentJobs(recovered_jobs)
    if should_process then
        self.ui_manager:scheduleIn(0, function()
            self:process()
        end)
    end
end

function DownloadQueue:enqueue(manga, chapter, download_directory, options)
    options = options or {}
    local status = self:getStatus(manga, chapter)
    if status and (status.state == "queued" or status.state == "downloading") then
        if not options.quiet_duplicate then
            self.onMessage(_("Chapter download is already in progress."))
        end
        return false, status.state
    end
    local enqueue_state = "queued"
    if status and status.state == "failed" then
        self:prepareFailedRetry({
            download_directory = download_directory,
            manga = manga,
            chapter = chapter,
        })
        enqueue_state = "retry"
    end

    local persistent_job = self:buildPersistentJob(manga, chapter, download_directory, "queued")
    self:upsertPersistentJob(persistent_job)
    self:setStatus(manga, chapter, { state = "queued" })
    table.insert(self.items, {
        key = persistent_job.key,
        download_directory = download_directory,
        manga = manga,
        chapter = chapter,
        downloader = self.downloader,
    })

    self.ui_manager:scheduleIn(0, function()
        self:process()
    end)
    return true, enqueue_state
end

function DownloadQueue:enqueueBatch(manga, chapters, download_directory, options)
    local started_at = os.time()
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket and socket.gettime then
        started_at = socket.gettime()
    end
    options = options or {}
    local persistent_jobs = {}
    local queued_count = 0

    for _, chapter in ipairs(chapters or {}) do
        local status = self:getStatus(manga, chapter)
        if status and (status.state == "queued" or status.state == "downloading") then
            if not options.quiet_duplicate then
                self.onMessage(_("Chapter download is already in progress."))
            end
        else
            if status and status.state == "failed" then
                self:prepareFailedRetry({
                    download_directory = download_directory,
                    manga = manga,
                    chapter = chapter,
                })
            end

            local persistent_job = self:buildPersistentJob(manga, chapter, download_directory, "queued")
            table.insert(persistent_jobs, persistent_job)
            self.statuses[persistent_job.key] = { state = "queued" }
            table.insert(self.items, {
                key = persistent_job.key,
                download_directory = download_directory,
                manga = manga,
                chapter = chapter,
                downloader = self.downloader,
            })
            queued_count = queued_count + 1
        end
    end

    if queued_count == 0 then
        return 0
    end

    self:upsertPersistentJobs(persistent_jobs)
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
    return queued_count
end

function DownloadQueue:getCredentialsForJob()
    if self.getCredentials then
        return self.getCredentials()
    end
    return self.settings and self.settings.load and self.settings:load() or {}
end

function DownloadQueue:writeProgressFallback(progress_path, state, current, total, path, error_message)
    return ProgressFile.writeFallback(progress_path, state, current, total, path, error_message)
end

function DownloadQueue:runDownloaderJob(queued)
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
        self:writeProgressFallback(queued.progress_path, state, result.ok and 1 or 0, result.ok and 1 or 0, result.path, result.error)
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
            result.error
        )
    until not result.ok or result.done
end

local function startQueuedJob(self, queued)
    queued.started_at = self.now()
    queued.last_progress_at = queued.started_at
    queued.last_progress_current = nil
    queued.last_progress_state = nil
    queued.progress_path = self:buildProgressPath(queued.manga, queued.chapter, queued.download_directory)
    os.remove(queued.progress_path)
    queued.credentials = queued.credentials or self:getCredentialsForJob()
    self:upsertPersistentJob(self:buildPersistentJob(queued.manga, queued.chapter, queued.download_directory, "downloading", {
        started_at = queued.started_at,
        last_progress_at = queued.last_progress_at,
        progress = {
            state = "downloading",
            current = 0,
            total = 0,
            updated_at = queued.last_progress_at,
        },
    }))

    local pid, err = self.ffi_util.runInSubProcess(function()
        self:runDownloaderJob(queued)
    end)

    if not pid then
        self:setStatus(queued.manga, queued.chapter, { state = "failed" })
        local message = self:formatFailureMessage(
            queued.manga,
            queued.chapter,
            T(_("Could not start chapter download: %1"), err or _("unknown error"))
        )
        self:upsertPersistentJob(self:buildPersistentJob(queued.manga, queued.chapter, queued.download_directory, "failed", {
            started_at = queued.started_at,
            last_progress_at = self.now(),
            progress = {
                state = "failed",
                current = 0,
                total = 0,
                error = message,
                updated_at = self.now(),
            },
        }))
        self.onMessage(message)
        return false
    end

    queued.pid = pid
    self:setActiveJob(queued)
    self:setStatus(queued.manga, queued.chapter, {
        state = "downloading",
        current = 0,
        total = 0,
    })
    return true
end

function DownloadQueue:process()
    local started_at = os.time()
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket and socket.gettime then
        started_at = socket.gettime()
    end
    local started_count = 0
    while self:getActiveCount() < self.max_active_chapters do
        local queued = table.remove(self.items, 1)
        if not queued then
            break
        end

        if startQueuedJob(self, queued) then
            started_count = started_count + 1
        end
    end

    self:schedulePoll()
    local finished_at = os.time()
    if ok_socket and socket and socket.gettime then
        finished_at = socket.gettime()
    end
    self:logDebug({
        operation = "downloadQueue.process",
        event = "end",
        started_count = started_count,
        active_count = self:getActiveCount(),
        queued_count = #(self.items or {}),
        elapsed_ms = math.floor(((finished_at - started_at) * 1000) + 0.5),
    })
end

function DownloadQueue:finishActiveWithFailure(active, message)
    local failure_message = self:formatFailureMessage(active.manga, active.chapter, message or _("Chapter download failed."))
    self:removeActiveJob(active)
    os.remove(active.progress_path)
    self:setStatus(active.manga, active.chapter, { state = "failed" })
    self:upsertPersistentJob(self:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed", {
        started_at = active.started_at,
        last_progress_at = self.now(),
        progress = {
            state = "failed",
            current = active.last_progress_current or 0,
            total = active.last_progress_total or 0,
            path = active.last_progress_path,
            error = failure_message,
            updated_at = self.now(),
        },
    }))
    self.onMessage(failure_message)
end

local function recordActiveProgress(self, active, progress)
    if not progress or not progress.state then
        return
    end

    if progress.current ~= active.last_progress_current or progress.state ~= active.last_progress_state then
        active.last_progress_at = self.now()
        active.last_progress_current = progress.current
        active.last_progress_total = progress.total
        active.last_progress_path = progress.path
        active.last_progress_error = progress.error
        active.last_progress_state = progress.state
        self:upsertPersistentJob(self:buildPersistentJob(active.manga, active.chapter, active.download_directory, progress.state, {
            started_at = active.started_at,
            last_progress_at = active.last_progress_at,
            progress = {
                state = progress.state,
                current = progress.current,
                total = progress.total,
                path = progress.path,
                error = progress.error,
                updated_at = active.last_progress_at,
            },
        }))
    end
    self:setStatus(active.manga, active.chapter, {
        state = progress.state,
        current = progress.current,
        total = progress.total,
    })
end

local function finishActiveFromProgress(self, active, progress)
    self:removeActiveJob(active)
    os.remove(active.progress_path)
    if progress and (progress.state == "downloaded" or progress.state == "skipped") then
        self:removePersistentJob(active.key or self:getKey(active.manga, active.chapter))
    elseif progress and progress.state == "failed" and self:jobArchiveExists(active, progress) then
        -- A downloader may report failure after writing a valid CBZ. Keep the
        -- user-facing state aligned with the archive that now exists on disk.
        self:removePersistentJob(active.key or self:getKey(active.manga, active.chapter))
        self:setStatus(active.manga, active.chapter, {
            state = "downloaded",
            current = progress.current,
            total = progress.total,
        })
    elseif progress and progress.state == "failed" then
        local message = self:formatFailureMessage(
            active.manga,
            active.chapter,
            progress.error or _("Chapter download failed.")
        )
        self:upsertPersistentJob(self:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed", {
            started_at = active.started_at,
            last_progress_at = active.last_progress_at or self.now(),
            progress = {
                state = "failed",
                current = progress.current,
                total = progress.total,
                path = progress.path,
                error = message,
                updated_at = active.last_progress_at or self.now(),
            },
        }))
        self.onMessage(message)
    end
end

local function finishActiveWithoutProgress(self, active)
    self:removeActiveJob(active)
    os.remove(active.progress_path)
    self:setStatus(active.manga, active.chapter, { state = "failed" })
    local message = self:formatFailureMessage(active.manga, active.chapter, _("Chapter download failed."))
    self:upsertPersistentJob(self:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed", {
        started_at = active.started_at,
        last_progress_at = self.now(),
        progress = {
            state = "failed",
            current = active.last_progress_current or 0,
            total = active.last_progress_total or 0,
            path = active.last_progress_path,
            error = message,
            updated_at = self.now(),
        },
    }))
    self.onMessage(message)
end

function DownloadQueue:poll()
    local started_at = os.time()
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket and socket.gettime then
        started_at = socket.gettime()
    end
    self.poll_scheduled = false
    if self:getActiveCount() == 0 then
        return
    end

    local active_jobs = {}
    for _, active in pairs(self.active_jobs or {}) do
        table.insert(active_jobs, active)
    end

    for index = 1, #active_jobs do
        local active = active_jobs[index]
        local progress = self:readProgress(active.progress_path)
        recordActiveProgress(self, active, progress)

        if self.now() - (active.last_progress_at or active.started_at or self.now()) > self.WATCHDOG_TIMEOUT_SECONDS then
            -- The worker may have died without writing terminal progress. The
            -- watchdog converts that silent active state into a recoverable
            -- failed job instead of leaving a permanent "downloading" row.
            self:finishActiveWithFailure(active, _("Chapter download timed out."))
        else
            local done = self.ffi_util.isSubProcessDone(active.pid)
            local terminal = progress and (progress.state == "downloaded" or progress.state == "skipped" or progress.state == "failed")
            if terminal or done then
                if terminal then
                    finishActiveFromProgress(self, active, progress)
                else
                    finishActiveWithoutProgress(self, active)
                end
            end
        end
    end

    self:process()
    local finished_at = os.time()
    if ok_socket and socket and socket.gettime then
        finished_at = socket.gettime()
    end
    self:logDebug({
        operation = "downloadQueue.poll",
        event = "end",
        polled_count = #active_jobs,
        active_count = self:getActiveCount(),
        queued_count = #(self.items or {}),
        elapsed_ms = math.floor(((finished_at - started_at) * 1000) + 0.5),
    })
end

return DownloadQueue
