local _ = require("gettext")
local T = require("ffi/util").template

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
        debug_logger = options.debug_logger or function() end,
        getCredentials = options.getCredentials,
        items = {},
        statuses = {},
        active_jobs = {},
        poll_scheduled = false,
        max_active_chapters = self:normalizeActiveChapterLimit(options.max_active_chapters),
    }
    return setmetatable(queue, self)
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
    local key = self:getKey(manga, chapter):gsub("[^%w%-_%.]", "_")
    return (download_directory or ""):gsub("/+$", "") .. "/.suwayomi_dl_progress_" .. key .. ".txt"
end

function DownloadQueue:loadPersistentJobs()
    if not self.settings or not self.settings.loadDownloadQueue then
        return {}
    end
    return self.settings:loadDownloadQueue() or {}
end

function DownloadQueue:savePersistentJobs(jobs)
    if not self.settings or not self.settings.saveDownloadQueue then
        return jobs or {}
    end
    return self.settings:saveDownloadQueue(jobs or {})
end

function DownloadQueue:normalizeProgress(progress)
    if type(progress) ~= "table" then
        return nil
    end

    local normalized = {}
    if progress.state ~= nil then
        normalized.state = tostring(progress.state)
    end
    if progress.current ~= nil then
        normalized.current = tonumber(progress.current) or 0
    end
    if progress.total ~= nil then
        normalized.total = tonumber(progress.total) or 0
    end
    if progress.path ~= nil then
        normalized.path = tostring(progress.path)
    end
    if progress.error ~= nil then
        normalized.error = tostring(progress.error)
    end
    if progress.updated_at ~= nil then
        normalized.updated_at = tonumber(progress.updated_at) or progress.updated_at
    end

    return normalized
end

function DownloadQueue:normalizeRecovery(recovery)
    if type(recovery) ~= "table" then
        return nil
    end

    local normalized = {}
    if recovery.reason ~= nil then
        normalized.reason = tostring(recovery.reason)
    end
    if recovery.recovered_at ~= nil then
        normalized.recovered_at = tonumber(recovery.recovered_at) or recovery.recovered_at
    end
    if recovery.previous_state ~= nil then
        normalized.previous_state = tostring(recovery.previous_state)
    end
    local progress = self:normalizeProgress(recovery.progress)
    if progress then
        normalized.progress = progress
    end
    return normalized
end

function DownloadQueue:copySourceMetadata(source)
    if type(source) ~= "table" then
        return nil
    end

    local copied = {}
    for _, key in ipairs({ "id", "displayName", "display_name", "name", "raw_name", "lang" }) do
        if source[key] ~= nil then
            copied[key] = source[key]
        end
    end
    if next(copied) then
        return copied
    end
    return nil
end

function DownloadQueue:copyMangaMetadata(manga)
    local copied = {
        id = manga.id,
        title = manga.title,
    }
    local source = self:copySourceMetadata(manga.source)
    if source then
        copied.source = source
    end
    return copied
end

function DownloadQueue:buildPersistentJob(manga, chapter, download_directory, state, details)
    details = details or {}
    local job = {
        key = self:getKey(manga, chapter),
        state = state or "queued",
        download_directory = download_directory,
        manga = self:copyMangaMetadata(manga),
        chapter = {
            id = chapter.id,
            name = chapter.name,
        },
    }
    if details.started_at ~= nil then
        job.started_at = tonumber(details.started_at) or details.started_at
    end
    if details.last_progress_at ~= nil then
        job.last_progress_at = tonumber(details.last_progress_at) or details.last_progress_at
    end
    local progress = self:normalizeProgress(details.progress)
    if progress then
        job.progress = progress
    end
    local recovery = self:normalizeRecovery(details.recovery)
    if recovery then
        job.recovery = recovery
    end
    return job
end

function DownloadQueue:upsertPersistentJob(job)
    local jobs = self:loadPersistentJobs()
    local replaced = false
    for index, existing in ipairs(jobs) do
        if existing.key == job.key then
            jobs[index] = job
            replaced = true
            break
        end
    end

    if not replaced then
        table.insert(jobs, job)
    end

    self:savePersistentJobs(jobs)
end

function DownloadQueue:upsertPersistentJobs(new_jobs)
    local jobs = self:loadPersistentJobs()
    local indexes_by_key = {}
    for index, existing in ipairs(jobs) do
        indexes_by_key[existing.key] = index
    end

    for _, job in ipairs(new_jobs or {}) do
        local existing_index = indexes_by_key[job.key]
        if existing_index then
            jobs[existing_index] = job
        else
            table.insert(jobs, job)
            indexes_by_key[job.key] = #jobs
        end
    end

    self:savePersistentJobs(jobs)
end

function DownloadQueue:removePersistentJob(key)
    local remaining = {}
    for _, job in ipairs(self:loadPersistentJobs()) do
        if job.key ~= key then
            table.insert(remaining, job)
        end
    end
    self:savePersistentJobs(remaining)
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

function DownloadQueue:splitUtf8Chars(text)
    local chars = {}
    text = tostring(text or "")
    local index = 1
    while index <= #text do
        local byte = text:byte(index)
        local length = 1
        if byte and byte >= 0xF0 then
            length = 4
        elseif byte and byte >= 0xE0 then
            length = 3
        elseif byte and byte >= 0xC0 then
            length = 2
        end
        table.insert(chars, text:sub(index, index + length - 1))
        index = index + length
    end
    return chars
end

function DownloadQueue:shortenChapterTitle(title, reserved_chars)
    local max_chars = self.CHAPTER_TITLE_WITH_STATUS_MAX_CHARS - (reserved_chars or 0)
    if max_chars < 12 then
        max_chars = 12
    end

    local chars = self:splitUtf8Chars(title)
    if #chars <= max_chars then
        return title
    end

    local shortened = {}
    for index = 1, max_chars - 1 do
        table.insert(shortened, chars[index])
    end
    table.insert(shortened, "…")
    return table.concat(shortened)
end

function DownloadQueue:joinChapterStatusSymbols(symbols)
    if not symbols or #symbols == 0 then
        return nil
    end
    return table.concat(symbols, "")
end

function DownloadQueue:formatChapterStatusSymbols(chapter, symbols)
    if not symbols or #symbols == 0 then
        return chapter.name
    end
    local suffix = table.concat(symbols, " ")
    local title = self:shortenChapterTitle(chapter.name, #self:splitUtf8Chars(suffix) + 2)
    return title .. "  " .. suffix
end

function DownloadQueue:buildChapterStatusSymbols(chapter, status)
    local symbols = {}
    if chapter and chapter.is_read == true then
        table.insert(symbols, "✓")
    end

    if not status then
        return symbols
    end
    if status.state == "queued" then
        table.insert(symbols, "⌛")
        return symbols
    end
    if status.state == "downloading" then
        if status.total and status.total > 0 and status.current then
            table.insert(symbols, T(_("↓ %1/%2"), status.current, status.total))
            return symbols
        end
        table.insert(symbols, "⌛")
        return symbols
    end
    if status.state == "downloaded" or status.state == "skipped" then
        table.insert(symbols, "↓")
        return symbols
    end
    if status.state == "read" then
        if #symbols == 0 then
            table.insert(symbols, "✓")
        end
        return symbols
    end
    if status.state == "failed" then
        table.insert(symbols, "⚠")
        return symbols
    end
    return symbols
end

function DownloadQueue:formatChapterMenuStatus(chapter, status)
    return self:joinChapterStatusSymbols(self:buildChapterStatusSymbols(chapter, status))
end

function DownloadQueue:formatChapterMenuText(chapter, status)
    local symbols = self:buildChapterStatusSymbols(chapter, status)
    return self:formatChapterStatusSymbols(chapter, symbols)
end

function DownloadQueue:formatFailureMessage(manga, chapter, detail)
    local label_parts = {}
    if manga and manga.title and manga.title ~= "" then
        table.insert(label_parts, manga.title)
    end
    if chapter and chapter.name and chapter.name ~= "" then
        table.insert(label_parts, chapter.name)
    end

    local label = table.concat(label_parts, " / ")
    if label == "" then
        label = self:getKey(manga or {}, chapter or {})
    end

    local chapter_suffix = ""
    if chapter and chapter.id and chapter.id ~= "" then
        chapter_suffix = T(_(" (chapter %1)"), chapter.id)
    end

    local failure_detail = tostring(detail or "")
    if failure_detail == "" then
        failure_detail = _("Chapter download failed.")
    end

    return T(_("Could not download \"%1\"%2: %3"), label, chapter_suffix, failure_detail)
end

function DownloadQueue:readProgress(progress_path)
    local handle = io.open(progress_path, "r")
    if not handle then
        return nil
    end

    local status = {}
    for line in handle:lines() do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then
            status[key] = value
        end
    end
    handle:close()

    if status.current then
        status.current = tonumber(status.current)
    end
    if status.total then
        status.total = tonumber(status.total)
    end
    return status
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
            table.insert(recovered_jobs, job)
            self:setStatus(job.manga, job.chapter, { state = "failed" })
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
    local tmp_path = tostring(progress_path or "") .. ".tmp"
    local handle = io.open(tmp_path, "w")
    if not handle then
        return
    end
    handle:write("state=", tostring(state or ""), "\n")
    handle:write("current=", tostring(current or 0), "\n")
    handle:write("total=", tostring(total or 0), "\n")
    handle:write("path=", tostring(path or ""), "\n")
    if error_message then
        handle:write("error=", tostring(error_message), "\n")
    end
    handle:close()
    if not os.rename(tmp_path, progress_path) then
        os.remove(tmp_path)
    end
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
        else
            queued.pid = pid
            self:setActiveJob(queued)
            self:setStatus(queued.manga, queued.chapter, {
                state = "downloading",
                current = 0,
                total = 0,
            })
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
        if progress and progress.state then
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

        if self.now() - (active.last_progress_at or active.started_at or self.now()) > self.WATCHDOG_TIMEOUT_SECONDS then
            self:finishActiveWithFailure(active, _("Chapter download timed out."))
        else
            local done = self.ffi_util.isSubProcessDone(active.pid)
            local terminal = progress and (progress.state == "downloaded" or progress.state == "skipped" or progress.state == "failed")
            if terminal or done then
                self:removeActiveJob(active)
                os.remove(active.progress_path)
                if progress and (progress.state == "downloaded" or progress.state == "skipped") then
                    self:removePersistentJob(active.key or self:getKey(active.manga, active.chapter))
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
                else
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
