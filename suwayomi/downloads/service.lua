-- Boundary: process-owned downloads, durable manual deletion, completion, and disposable views.
-- Dependencies are process modules; no host owns workers or durable completion.

local Queue = require("suwayomi/downloads/queue")
local ManualDeletion = require("suwayomi/chapters/manual_deletion")
local Settings = require("suwayomi/settings")
local UIManager = require("ui/uimanager")
local Debug = require("suwayomi/debug")
local Service = {}
Service.__index = Service
local instance

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

function Service:new(options)
    options = options or {}
    local service = setmetatable({
        settings = options.settings or Settings,
        ui_manager = options.ui_manager or UIManager,
        subscribers = {},
    }, self)
    service.queue = Queue:new{
        settings = service.settings,
        downloader = options.downloader or require("suwayomi/downloads/downloader"),
        ui_manager = service.ui_manager,
        ffi_util = options.ffi_util or require("ffi/util"),
        now = options.now,
        max_active_chapters = service.settings:loadMaxParallelChapterDownloads(),
        getCredentials = function() return service.settings:load() end,
        debug_logger = Debug.log,
        onStatusChanged = function() service:statusChanged() end,
        onMessage = function(message) service:notify(message) end,
        commitChapterArchive = function(job, path) return service:commitCompletion(job, path) end,
    }
    service.manual_deletion = ManualDeletion:new{
        settings = service.settings,
        queue = service.queue,
        ui_manager = service.ui_manager,
        now = options.now,
        onChanged = function() service:notify(nil, true) end,
    }
    service.queue.manual_deletion = service.manual_deletion
    service.cleanup = require("suwayomi/downloads/cleanup_adapter").new(service)
    return service
end

function Service.get()
    if not instance then instance = Service:new() end

    return instance
end

function Service:getQueue()
    self:start()
    return self.queue
end

function Service:start()
    if self.started or self.stopped then return end
    self.started = true
    self:installQuit()
    self.queue:recover()
    self.manual_deletion:start()
    self.cleanup:processFinishedChapterCleanup()
end

function Service:getSnapshot()
    return self.queue:getSnapshot()
end

function Service:deliver(subscription, message, full_refresh, changed_mangas)
    if self.stopped or not subscription.callback then return end
    local ok = pcall(subscription.callback, self:getSnapshot(), message, full_refresh, changed_mangas)
    if not ok then Debug.log({ operation = "downloadService.subscriber", event = "callback_error" }) end
end

function Service:subscribe(callback)
    if self.stopped then return function() end end
    local subscription = { callback = callback }
    self.subscribers[subscription] = true
    -- Attach before startup can report blockers; snapshot after recovery.
    self:start()
    self:deliver(subscription)
    return function()
        self.subscribers[subscription] = nil
        subscription.callback = nil
    end
end

function Service:notify(message, full_refresh, changed_mangas)
    if self.stopped then return end
    for subscription in pairs(self.subscribers) do
        subscription.full_refresh = subscription.full_refresh or full_refresh
        subscription.message = message or subscription.message
        if changed_mangas then
            subscription.changed_mangas = subscription.changed_mangas or {}
            for manga_id in pairs(changed_mangas) do subscription.changed_mangas[manga_id] = true end
        end
        if not subscription.scheduled then
            subscription.scheduled = true
            self.ui_manager:scheduleIn(0, function()
                subscription.scheduled = nil
                local pending_message, pending_full = subscription.message, subscription.full_refresh
                local pending_mangas = subscription.changed_mangas
                subscription.message, subscription.full_refresh = nil, nil
                subscription.changed_mangas = nil
                self:deliver(subscription, pending_message, pending_full, pending_mangas)
            end)
        end
    end
end

function Service:statusChanged()
    if self.stopped then return end
    if self.cleanup then self.cleanup:scheduleFinishedChapterCleanup(0) end
    if self.manual_deletion then self.manual_deletion:wake() end
    self:notify()
end

function Service:commitCompletion(job, path)
    local key = self.queue:getKey(job.manga, job.chapter)
    if job.pending_archive_generation and not self.settings:isBlocked() then
        local state = self.settings:getStore():readKey("manual_archive_state")
        local archive = type(state) == "table" and type(state.archives) == "table" and state.archives[key]
        if type(archive) == "table" and archive.generation == job.pending_archive_generation
            and archive.path == path then
            job.archive_generation = job.pending_archive_generation
        end
    end
    local valid, reason = self.manual_deletion:validateJob(job)
    if not valid then return nil, reason end
    local published_generation
    local call_ok, ok, err = pcall(function()
        return self.settings:getStore():saveDocument(function(doc)
            if doc.download_queue ~= nil and type(doc.download_queue) ~= "table" then
                error("unsupported_download_queue", 0)
            end
            local jobs, remove_indexes = doc.download_queue or {}, {}
            for index, stored in pairs(jobs) do
                if type(stored) == "table" and stored.key == key then
                    if stored.archive_generation ~= job.archive_generation or stored.version ~= nil
                        or type(index) ~= "number" or index < 1 or index ~= math.floor(index) then
                        error("download_job_replaced_or_unsupported", 0)
                    end
                    remove_indexes[#remove_indexes + 1] = index
                end
            end
            if type(doc.chapter_ledger) ~= "table" then doc.chapter_ledger = {} end
            local entry = type(doc.chapter_ledger[key]) == "table" and doc.chapter_ledger[key] or {}
            entry.manga_id, entry.chapter_id = tostring(job.manga.id or ""), tostring(job.chapter.id or "")
            entry.manga_title, entry.chapter_name = job.manga.title, job.chapter.name
            entry.path = path
            doc.chapter_ledger[key] = entry
            if type(doc.reader_return_contexts) ~= "table" then doc.reader_return_contexts = {} end
            local context = type(doc.reader_return_contexts[path]) == "table" and doc.reader_return_contexts[path] or {}
            context.path = path
            context.manga_id, context.manga_title = entry.manga_id, entry.manga_title
            context.chapter_id, context.chapter_name = entry.chapter_id, entry.chapter_name
            context.in_library, context.source = job.manga.in_library, copy(job.manga.source)
            doc.reader_return_contexts[path] = context
            published_generation = self.manual_deletion:publish(doc, job, path)
            table.sort(remove_indexes, function(a, b) return a > b end)
            for _, index in ipairs(remove_indexes) do table.remove(jobs, index) end
            doc.download_queue = jobs
        end)
    end)
    if not call_ok then return nil, ok end
    if ok then
        job.archive_generation = published_generation
        job.pending_archive_generation = nil
    elseif self.settings:isBlocked() then
        job.pending_archive_generation = published_generation
    end
    return ok, err
end

function Service:installQuit()
    if self.quit_installed or type(self.ui_manager.quit) ~= "function" then return end
    self.quit_installed = true
    local previous = self.ui_manager.quit
    self.ui_manager.quit = function(manager, ...)
        -- Quit must reach KOReader even when a helper or cleanup adapter throws.
        local ok = pcall(self.shutdown, self)
        if not ok then pcall(Debug.log, { operation = "downloadService.quit", event = "stop_error" }) end
        return previous(manager, ...)
    end
end

function Service:shutdown()
    if self.stopped then return end
    self.stopped, self.queue.stopped = true, true
    for subscription in pairs(self.subscribers) do subscription.callback = nil end
    self.subscribers = {}
    pcall(self.cleanup.cancelFinishedChapterCleanup, self.cleanup)
    pcall(self.manual_deletion.stop, self.manual_deletion)
    self.queue.active_job_lifecycle:shutdown()
end

return Service
