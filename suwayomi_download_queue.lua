local _ = require("gettext")
local T = require("ffi/util").template

local DownloadQueue = {}
DownloadQueue.__index = DownloadQueue

DownloadQueue.POLL_INTERVAL_SECONDS = 0.5
DownloadQueue.WATCHDOG_TIMEOUT_SECONDS = 30 * 60
DownloadQueue.CHAPTER_TITLE_WITH_STATUS_MAX_CHARS = 58

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
        getCredentials = options.getCredentials,
        items = {},
        statuses = {},
        active = false,
    }
    return setmetatable(queue, self)
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

function DownloadQueue:buildPersistentJob(manga, chapter, download_directory, state)
    return {
        key = self:getKey(manga, chapter),
        state = state or "queued",
        download_directory = download_directory,
        manga = {
            id = manga.id,
            title = manga.title,
        },
        chapter = {
            id = chapter.id,
            name = chapter.name,
        },
    }
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
    if self.active and (self.active.key or self:getKey(self.active.manga, self.active.chapter)) == key then
        return false, "downloading"
    end

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

function DownloadQueue:formatChapterStatusSymbols(chapter, symbols)
    symbols = symbols or {}
    if #symbols == 0 then
        return chapter.name
    end
    local suffix = table.concat(symbols, " ")
    local title = self:shortenChapterTitle(chapter.name, #self:splitUtf8Chars(suffix) + 2)
    return title .. "  " .. suffix
end

function DownloadQueue:formatChapterMenuText(chapter, status)
    local symbols = {}
    if chapter and chapter.is_read == true then
        table.insert(symbols, "✓")
    end

    if not status then
        return self:formatChapterStatusSymbols(chapter, symbols)
    end
    if status.state == "queued" then
        table.insert(symbols, "⏳")
        return self:formatChapterStatusSymbols(chapter, symbols)
    end
    if status.state == "downloading" then
        if status.total and status.total > 0 and status.current then
            table.insert(symbols, T(_("↓ %1/%2"), status.current, status.total))
            return self:formatChapterStatusSymbols(chapter, symbols)
        end
        table.insert(symbols, "⏳")
        return self:formatChapterStatusSymbols(chapter, symbols)
    end
    if status.state == "downloaded" or status.state == "skipped" then
        table.insert(symbols, "↓")
        return self:formatChapterStatusSymbols(chapter, symbols)
    end
    if status.state == "read" then
        if #symbols == 0 then
            table.insert(symbols, "✓")
        end
        return self:formatChapterStatusSymbols(chapter, symbols)
    end
    if status.state == "failed" then
        table.insert(symbols, "⚠")
        return self:formatChapterStatusSymbols(chapter, symbols)
    end
    return self:formatChapterStatusSymbols(chapter, symbols)
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
        return
    end
    local _, chapter_path = self.downloader:getTargetPath(job.download_directory, job.manga, job.chapter)
    local partial_path = self.downloader.getPartialPath and self.downloader:getPartialPath(chapter_path) or (chapter_path .. ".part")
    os.remove(partial_path)
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
            if job.state == "downloading" then
                self:cleanupInterruptedDownload(job)
            end
            local recovered = self:buildPersistentJob(job.manga, job.chapter, job.download_directory, "queued")
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
        return false
    end
    if status and status.state == "failed" then
        self:cleanupInterruptedDownload({
            download_directory = download_directory,
            manga = manga,
            chapter = chapter,
        })
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
    return true
end

function DownloadQueue:getCredentialsForJob()
    if self.getCredentials then
        return self.getCredentials()
    end
    return self.settings and self.settings.load and self.settings:load() or {}
end

function DownloadQueue:writeProgressFallback(progress_path, state, current, total, path, error_message)
    local handle = io.open(progress_path, "w")
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
    if self.active then
        return
    end

    local queued = table.remove(self.items, 1)
    if not queued then
        return
    end

    self.active = queued
    queued.started_at = self.now()
    queued.progress_path = self:buildProgressPath(queued.manga, queued.chapter, queued.download_directory)
    os.remove(queued.progress_path)
    queued.credentials = queued.credentials or self:getCredentialsForJob()
    self:upsertPersistentJob(self:buildPersistentJob(queued.manga, queued.chapter, queued.download_directory, "downloading"))

    local pid, err = self.ffi_util.runInSubProcess(function()
        self:runDownloaderJob(queued)
    end)

    if not pid then
        self.active = false
        self:setStatus(queued.manga, queued.chapter, { state = "failed" })
        self:upsertPersistentJob(self:buildPersistentJob(queued.manga, queued.chapter, queued.download_directory, "failed"))
        self.onMessage(T(_("Could not start chapter download: %1"), err or _("unknown error")))
        self.ui_manager:scheduleIn(0, function()
            self:process()
        end)
        return
    end

    queued.pid = pid
    self:setStatus(queued.manga, queued.chapter, {
        state = "downloading",
        current = 0,
        total = 0,
    })
    self.ui_manager:scheduleIn(self.POLL_INTERVAL_SECONDS, function()
        self:poll()
    end)
end

function DownloadQueue:finishActiveWithFailure(active, message)
    self.active = false
    os.remove(active.progress_path)
    self:setStatus(active.manga, active.chapter, { state = "failed" })
    self:upsertPersistentJob(self:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed"))
    self.onMessage(message or _("Chapter download failed."))
    self.ui_manager:scheduleIn(0, function()
        self:process()
    end)
end

function DownloadQueue:poll()
    local active = self.active
    if not active then
        return
    end

    local progress = self:readProgress(active.progress_path)
    if progress and progress.state then
        self:setStatus(active.manga, active.chapter, {
            state = progress.state,
            current = progress.current,
            total = progress.total,
        })
    end

    if self.now() - (active.started_at or self.now()) > self.WATCHDOG_TIMEOUT_SECONDS then
        self:finishActiveWithFailure(active, _("Chapter download timed out."))
        return
    end

    local done = self.ffi_util.isSubProcessDone(active.pid)
    local terminal = progress and (progress.state == "downloaded" or progress.state == "skipped" or progress.state == "failed")
    if terminal or done then
        self.active = false
        os.remove(active.progress_path)
        if progress and (progress.state == "downloaded" or progress.state == "skipped") then
            self:removePersistentJob(active.key or self:getKey(active.manga, active.chapter))
        elseif progress and progress.state == "failed" then
            self:upsertPersistentJob(self:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed"))
            self.onMessage(_(progress.error or _("Chapter download failed.")))
        else
            self:setStatus(active.manga, active.chapter, { state = "failed" })
            self:upsertPersistentJob(self:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed"))
            self.onMessage(_("Chapter download failed."))
        end
        self.ui_manager:scheduleIn(0, function()
            self:process()
        end)
        return
    end

    self.ui_manager:scheduleIn(self.POLL_INTERVAL_SECONDS, function()
        self:poll()
    end)
end

return DownloadQueue
