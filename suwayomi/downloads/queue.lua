-- Boundary: public device-local download queue facade.
--
-- Responsibility: enqueue, retry, cancel, recover, snapshot, and format status
-- while delegating persistence and active worker lifecycle to focused modules.
-- Owned state: pending queue items, chapter status map, active lifecycle
-- controller, and settings-backed job store.
-- Dependencies: settings, downloader, UI manager, subprocess helpers, progress
-- files, status formatter, clock, credentials callback, and optional callbacks.
-- External data: queue settings, manga/chapter tables, progress files, and
-- worker results are normalized before callers see snapshots.

local _ = require("gettext")
local ActiveJobs = require("suwayomi/downloads/active_jobs")
local JobStore = require("suwayomi/downloads/job_store")
local ProgressFile = require("suwayomi/downloads/progress_file")
local StatusFormatter = require("suwayomi/downloads/status_formatter")

local DownloadQueue = {}
DownloadQueue.__index = DownloadQueue

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
        onChapterArchiveReady = options.onChapterArchiveReady or function() end,
        debug_logger = options.debug_logger or function() end,
        getCredentials = options.getCredentials,
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

    self.active_job_lifecycle:appendSnapshotJobs(snapshot)

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

function DownloadQueue:getTargetChapterPath(job)
    if not job or not job.download_directory or not job.manga or not job.chapter or not self.downloader.getTargetPath then
        return nil
    end
    local _, chapter_path = self.downloader:getTargetPath(job.download_directory, job.manga, job.chapter)
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
    options = options or {}
    local key = self:getKey(manga, chapter)
    self.statuses[key] = nil
    self:removePersistentJob(key)
    if not options.quiet then
        self.onStatusChanged()
    end
end

function DownloadQueue:jobArchiveExists(job, progress)
    return self:getExistingArchivePath(job, progress) ~= nil
end

function DownloadQueue:cancelPending(manga, chapter)
    local key = self:getKey(manga, chapter)
    local active = self:getActiveJob(key)
    if active then
        self.active_job_lifecycle:finishWithCancel(active)
        return true, "downloading"
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
        if job.state == "queued" and not self:getActiveJob(key) then
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

function DownloadQueue:cancelAll()
    local queued = self:cancelQueued()
    local active = 0
    if self.active_job_lifecycle.cancelAll then
        active = self.active_job_lifecycle:cancelAll()
    end
    return queued + active
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
    if not job or not job.download_directory or not job.manga or not job.chapter then
        return false
    end
    local _, chapter_path = self.downloader:getTargetPath(job.download_directory, job.manga, job.chapter)
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
    local seen_recovered_keys = {}
    local recoverable_active_keys = {}
    for _, job in ipairs(jobs) do
        if job.manga and job.chapter and job.download_directory and (job.state == "queued" or job.state == "downloading") then
            recoverable_active_keys[self:getKey(job.manga, job.chapter)] = true
        end
    end
    for _, job in ipairs(jobs) do
        if job.manga and job.chapter and job.download_directory and (job.state == "queued" or job.state == "downloading") then
            local recovered
            if job.state == "downloading" then
                recovered = self:recoverInterruptedJob(job)
            else
                recovered = self:buildPersistentJob(job.manga, job.chapter, job.download_directory, "queued")
            end
            local key = recovered.key or self:getKey(recovered.manga, recovered.chapter)
            if seen_recovered_keys[key] then
                self:logDebug({
                    operation = "downloadQueue.recover",
                    event = "duplicate",
                    key = key,
                    chapter_id = recovered.chapter and recovered.chapter.id,
                })
            else
                seen_recovered_keys[key] = true
                recovered.key = key
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
            end
        elseif job.manga and job.chapter and job.state == "failed" then
            local key = self:getKey(job.manga, job.chapter)
            if recoverable_active_keys[key] then
                self:logDebug({
                    operation = "downloadQueue.recover",
                    event = "duplicate",
                    key = key,
                    chapter_id = job.chapter and job.chapter.id,
                })
            elseif self:jobArchiveExists(job, job.progress) then
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

function DownloadQueue:process()
    return self.active_job_lifecycle:process()
end

function DownloadQueue:poll()
    return self.active_job_lifecycle:poll()
end

return DownloadQueue
