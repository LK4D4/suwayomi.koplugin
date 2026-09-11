-- Boundary: process-owned durable download-ahead evaluation in the checked shared document.
-- Only the parent admits work. One read-only helper fetches context; no chapter cache is persisted.
-- Ledger transactions compose enrollLedger with read state and manual intent in one checked save.
local SubprocessJob = require("suwayomi/subprocess/job")
local Archive = require("suwayomi/downloads/archive")
local Refill = {}
local FS = require("suwayomi/fs")
Refill.__index = Refill

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local function equal(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end
local function collection(doc, create)
    local state = doc.download_refill
    if state == nil and create then
        state = { version = 1, next_revision = 1, requests = {}, associations = {} }
        doc.download_refill = state
    end
    if state == nil then return nil end
    if type(state) ~= "table" or state.version ~= 1 or type(state.requests) ~= "table"
        or type(state.associations) ~= "table" then return nil, "unsupported_state" end
    return state
end
local function valid(request, id)
    return type(request) == "table" and request.version == 1 and request.manga_id == id
        and type(request.revision) == "number" and request.revision > 0
        and request.revision < 9007199254740991 and request.revision % 1 == 0
        and (request.state == "pending" or request.state == "waiting" or request.state == "blocked")
        and type(request.manga) == "table" and tostring(request.manga.id) == id
        and type(request.retry_count) == "number" and request.retry_count >= 0 and request.retry_count < math.huge
        and request.retry_count % 1 == 0
        and type(request.next_retry_at) == "number" and request.next_retry_at >= 0 and request.next_retry_at < math.huge
end
local function allocate(state)
    local revision = state.next_revision
    if type(revision) ~= "number" or revision < 1 or revision >= 9007199254740991 or revision % 1 ~= 0 then
        error("unsupported_state", 0)
    end
    for _, request in pairs(state.requests) do
        if type(request) == "table" and type(request.revision) == "number" and request.revision >= revision then
            error("unsupported_state", 0)
        end
    end
    state.next_revision = revision + 1
    return revision
end
local function mangaId(manga)
    return type(manga) == "table" and manga.id ~= nil and tostring(manga.id) ~= "" and tostring(manga.id) or nil
end
local function readState(doc, id)
    local result = {}
    for key, entry in pairs(doc.chapter_ledger or {}) do
        if type(entry) == "table" and tostring(entry.manga_id) == id then
            result[key] = { read = entry.read == true, pending_read_sync = entry.pending_read_sync,
                pending_read_state = entry.pending_read_state }
        end
    end
    return result
end

function Refill:new(options)
    return setmetatable({ queue = options.queue, settings = options.settings,
        ui_manager = options.ui_manager, now = options.now or os.time,
        onChanged = options.onChanged or function() end }, self)
end
function Refill:_document()
    return self.settings:getStore():load()
end
function Refill:_endpoint()
    return self.settings:normalizeEndpointScope(self.settings:load().server_url) or ""
end
function Refill:_save(mutator)
    if self.stopped or self.queue:isStopped() then return nil, "stopped" end
    local store = self.settings:getStore()
    if store:isBlocked() then self.queue:scheduleReconciliation(); return nil, "persistence_failed" end
    local called, ok, err = pcall(store.saveDocument, store, mutator)
    -- Rejected mutations throw; checked storage failures return an error.
    if not called then return nil, ok, true end
    if not ok then self.queue:scheduleReconciliation(); return nil, err end
    return true
end
function Refill:_policy(doc, id)
    local limits = doc.manga_keep_next_unread_downloads
    return self.settings:normalizeMangaKeepNextUnreadDownloads(type(limits) == "table" and limits[id])
end
function Refill:_associate(doc, manga)
    local id, endpoint = mangaId(manga), self:_endpoint()
    if not id or endpoint == "" or manga.endpoint_scope ~= endpoint then return nil, "origin_unknown" end
    local state, err = collection(doc, true)
    if not state then error(err, 0) end
    local previous = state.associations[id]
    if previous ~= nil and (type(previous) ~= "table" or previous.version ~= 1) then error("unsupported_state", 0) end
    state.associations[id] = { version = 1, manga = self.queue:copyMangaMetadata(manga), endpoint_scope = endpoint }
    return true
end
function Refill:associate(manga)
    local accepted, reason
    local ok, err = self:_save(function(doc)
        accepted, reason = self:_associate(doc, manga)
        if not accepted then error(reason, 0) end
        local state = collection(doc)
        if state.requests[mangaId(manga)] then self:enroll(doc, manga, { retry = true }) end
    end)
    if ok then self:wake(); self.onChanged() end
    return ok, err
end
function Refill:enroll(doc, manga, options)
    options = options or {}
    local id = mangaId(manga)
    if not id then return false, "metadata_missing" end
    if self:_policy(doc, id) == 0 then return false, "off" end
    local state, err = collection(doc, true)
    if not state then error(err, 0) end
    local previous = state.requests[id]
    if previous ~= nil and not valid(previous, id) then error("unsupported_state", 0) end
    local association = state.associations[id]
    if association ~= nil and (type(association) ~= "table" or association.version ~= 1) then
        error("unsupported_state", 0)
    end
    local known = type(association) == "table" and association.version == 1
        and type(association.endpoint_scope) == "string"
        and self.settings:normalizeEndpointScope(association.endpoint_scope) == association.endpoint_scope
        and mangaId(association.manga) == id
    local endpoint = known and association.endpoint_scope or nil
    local reason = not known and "origin_unknown" or endpoint ~= self:_endpoint() and "endpoint_changed" or nil
    if manga.require_origin and manga.endpoint_scope == nil then
        endpoint, reason = nil, "origin_unknown"
    elseif manga.endpoint_scope and manga.endpoint_scope ~= endpoint then
        endpoint, reason = self.settings:normalizeEndpointScope(manga.endpoint_scope), "endpoint_changed"
    end
    state.requests[id] = { version = 1, manga_id = id, revision = allocate(state),
        manga = known and copy(association.manga) or self.queue:copyMangaMetadata(manga),
        endpoint_scope = endpoint, state = reason and "blocked" or "pending", reason = reason,
        retry_count = previous and previous.retry_count or 0,
        next_retry_at = previous and previous.state == "waiting" and previous.next_retry_at or 0 }
    if not reason and state.requests[id].next_retry_at > self.now() and not options.retry then
        state.requests[id].state, state.requests[id].reason = "waiting", previous.reason
    elseif options.retry then
        state.requests[id].next_retry_at = 0
    end
    return true
end
function Refill:request(manga, options)
    local ok, err = self:_save(function(doc) self:enroll(doc, manga, options) end)
    if ok then self:wake(); self.onChanged() end
    return ok, err
end
function Refill:enrollLedger(doc, ledger, mangas, options)
    if options and options.skip_keep_policy then return false end
    local affected = {}
    local enrolled = false
    for _, manga in pairs(mangas or {}) do
        local id = mangaId(manga)
        if id then affected[id] = manga end
    end
    for key, entry in pairs(ledger or {}) do
        local old = type(doc.chapter_ledger) == "table" and doc.chapter_ledger[key]
        if type(entry) == "table" and entry.manga_id and entry.read == true
            and (type(old) ~= "table" or old.read ~= true) then
            local id = tostring(entry.manga_id)
            affected[id] = affected[id] or { id = id, title = entry.manga_title,
                endpoint_scope = entry.endpoint_scope, require_origin = entry.path ~= nil }
        end
    end
    for _, manga in pairs(affected) do
        if self:enroll(doc, manga) then enrolled = true end
    end
    return enrolled
end
function Refill:setPolicy(manga, limit)
    local id = mangaId(manga)
    if not id then return nil, "metadata_missing" end
    limit = self.settings:normalizeMangaKeepNextUnreadDownloads(limit)
    local ok, err = self:_save(function(doc)
        if doc.manga_keep_next_unread_downloads ~= nil and type(doc.manga_keep_next_unread_downloads) ~= "table" then
            error("unsupported_state", 0)
        end
        doc.manga_keep_next_unread_downloads = doc.manga_keep_next_unread_downloads or {}
        doc.manga_keep_next_unread_downloads[id] = limit > 0 and limit or nil
        if limit == 0 then self:retire(doc, { [id] = true })
        else
            local associated, reason = self:_associate(doc, manga)
            if not associated then error(reason, 0) end
            self:enroll(doc, manga, { retry = true })
        end
    end)
    if ok then self:wake(); self.onChanged(); return limit end
    return nil, err
end
function Refill:retire(doc, ids)
    local state, err = collection(doc)
    if err then error(err, 0) end
    if not state then return end
    for id, request in pairs(state.requests) do
        if not ids or ids[id] then
            if not valid(request, id) then error("unsupported_state", 0) end
            state.requests[id] = nil
        end
    end
end
function Refill:retry(id, revision)
    id = tostring(id)
    local ok, err = self:_save(function(doc)
        local state = collection(doc)
        local request = state and state.requests[id]
        if not valid(request, id) or request.revision ~= revision then error("stale_request", 0) end
        if not request.endpoint_scope or request.reason == "origin_unknown" then error("origin_unknown", 0) end
        if request.endpoint_scope ~= self:_endpoint() then error("endpoint_changed", 0) end
        self:enroll(doc, request.manga, { retry = true })
    end)
    if ok then self:wake(); self.onChanged() end
    return ok, err
end
function Refill:stop(id, revision)
    id = tostring(id)
    local ok, err = self:_save(function(doc)
        local state = collection(doc)
        local request = state and state.requests[id]
        if not valid(request, id) or request.revision ~= revision then error("stale_request", 0) end
        if type(doc.manga_keep_next_unread_downloads) ~= "table" then error("unsupported_state", 0) end
        doc.manga_keep_next_unread_downloads[id] = nil
        self:retire(doc, { [id] = true })
    end)
    if ok then self:wake(); self.onChanged() end
    return ok, err
end
function Refill:snapshot()
    local state, err = collection(self:_document())
    local result = {}
    if err then return { { state = "blocked", reason = err } } end
    for id, request in pairs(state and state.requests or {}) do
        if valid(request, id) then
            result[#result + 1] = { manga_id = id, manga_title = request.manga and request.manga.title,
                revision = request.revision, state = request.state, reason = request.reason,
                next_retry_at = request.next_retry_at > 0 and request.next_retry_at or nil }
        else result[#result + 1] = { manga_id = id, state = "blocked", reason = "unsupported_state" } end
    end
    table.sort(result, function(a, b) return tostring(a.manga_id) < tostring(b.manga_id) end)
    return result
end
function Refill:_schedule(delay)
    if not self.started or self.stopped then return end
    local at = self.now() + delay
    if self.scheduled and self.scheduled_at <= at then return end
    if self.scheduled then self.ui_manager:unschedule(self.scheduled) end
    local callback
    callback = function()
        if self.scheduled ~= callback then return end
        self.scheduled, self.scheduled_at = nil, nil
        self:process()
    end
    self.scheduled, self.scheduled_at = callback, at
    self.ui_manager:scheduleIn(delay, callback)
end
function Refill:start()
    if self.started or self.stopped then return end
    self.started = true
    self:wake()
end
function Refill:wake()
    self:_schedule(0)
end
function Refill:_transition(request, state_name, reason, transient)
    local ok = self:_save(function(doc)
        local state = collection(doc)
        local current = state and state.requests[request.manga_id]
        if not valid(current, request.manga_id) or current.revision ~= request.revision then return end
        current.state, current.reason = state_name, reason
        if transient then
            current.retry_count = current.retry_count + 1
            current.next_retry_at = self.now() + math.min(300, 5 * 2 ^ math.min(6, current.retry_count - 1))
        else current.next_retry_at = 0 end
    end)
    if ok then self.onChanged()
    else self.storage_retry_at = self.now() + 5; self:_schedule(5) end
    return ok
end
function Refill:_choices(request)
    return { limit = self.settings:loadMangaKeepNextUnreadDownloads(request.manga),
        filter = self.settings:loadMangaScanlatorFilter(request.manga),
        directory = self.settings:loadDownloadDirectory(), endpoint = self:_endpoint(),
        read = readState(self:_document(), request.manga_id) }
end
function Refill:_current(active)
    local state = collection(self:_document())
    local request = state and state.requests[active.request.manga_id]
    return not self.stopped and valid(request, active.request.manga_id)
        and request.revision == active.request.revision and request or nil
end
function Refill:_apply(active, result)
    local request = self:_current(active)
    if not request then return end
    local choices = self:_choices(request)
    if request.endpoint_scope ~= choices.endpoint then
        self:_transition(request, "blocked", "endpoint_changed"); return
    end
    if not equal(choices, active.choices) then
        local saved = self:request(request.manga, { retry = true })
        if not saved then self.storage_retry_at = self.now() + 5 end
        return
    end
    if FS.attributes(choices.directory, "mode") ~= "directory" then
        self:_transition(request, "blocked", "configuration_missing"); return
    end
    if not result or not result.ok then
        local unsupported = result and (result.error_kind == "too_large" or result.error_kind == "unsupported")
        local rejected = result and (result.retryable == false or result.status_code == 401 or result.status_code == 403)
        local blocked = unsupported or rejected
        self:_transition(request, blocked and "blocked" or "waiting",
            unsupported and "unsupported_state" or rejected and "fetch_rejected" or "fetch_failed", not blocked)
        return
    end
    if type(result.chapters) ~= "table" then self:_transition(request, "blocked", "unsupported_state"); return end
    local manga = copy(request.manga)
    if type(result.manga) == "table" then
        if mangaId(result.manga) ~= request.manga_id then self:_transition(request, "blocked", "metadata_missing"); return end
        manga = self.queue:copyMangaMetadata(result.manga)
    end
    manga.endpoint_scope = request.endpoint_scope
    if not manga.title or manga.title == "" or type(manga.source) ~= "table"
        or not (manga.source.name or manga.source.displayName or manga.source.display_name) then
        self:_transition(request, "blocked", "metadata_missing"); return
    end
    local chapters, seen = {}, {}
    for _, chapter in ipairs(result.chapters) do
        if type(chapter) ~= "table" or chapter.id == nil or type(chapter.source_order) ~= "number"
            or not chapter.name or seen[tostring(chapter.id)] then
            self:_transition(request, "blocked", "unsupported_state"); return
        end
        seen[tostring(chapter.id)] = true
        chapters[#chapters + 1] = chapter
    end
    table.sort(chapters, function(a, b)
        if a.source_order == b.source_order then
            local left, right = tonumber(a.id), tonumber(b.id)
            if left and right then return left < right end
            return tostring(a.id) < tostring(b.id)
        end
        return a.source_order < b.source_order
    end)
    local admitted, blocker = {}, nil
    local ok, err, rejected = self:_save(function(doc)
        local state = collection(doc)
        local current = state and state.requests[request.manga_id]
        if not valid(current, request.manga_id) or current.revision ~= request.revision then error("stale_request", 0) end
        if not equal(self:_choices(current), active.choices) then error("choices_changed", 0) end
        local jobs, positions, matches = {}, 0, 0
        if doc.download_queue ~= nil and type(doc.download_queue) ~= "table" then error("unsupported_state", 0) end
        for _, job in pairs(doc.download_queue or {}) do
            if type(job) == "table" and job.key then jobs[job.key] = job end
        end
        local manual = doc.manual_archive_state
        if manual ~= nil and (type(manual) ~= "table" or manual.version ~= 1 or type(manual.requests) ~= "table") then
            blocker = "unsupported_state"
        end
        for _, chapter in ipairs(chapters) do
            if not choices.filter or tostring(chapter.scanlator or "") == choices.filter then
                matches = matches + 1
                local key = self.queue:getKey(manga, chapter)
                local entry = (doc.chapter_ledger or {})[key]
                local is_read = chapter.is_read == true
                if entry and entry.pending_read_sync then
                    if entry.pending_read_state ~= nil then is_read = entry.pending_read_state == true
                    else is_read = entry.read == true end
                end
                if not is_read and positions < choices.limit then
                    positions = positions + 1
                    local job = jobs[key]
                    local deletion = type(manual) == "table" and type(manual.requests) == "table" and manual.requests[key]
                    if deletion and (type(deletion) ~= "table" or deletion.version ~= 1
                        or deletion.state == "pending" or deletion.state == "blocked") then
                        blocker = blocker or "manual_delete_pending"
                    elseif job and (job.version ~= nil or (job.state ~= "queued" and job.state ~= "downloading"
                        and job.state ~= "running" and job.state ~= "stopping" and job.state ~= "finalizing")) then
                        blocker = blocker or (job.state == "failed" and "terminal_failure" or "unsupported_state")
                    elseif not job and blocker ~= "unsupported_state" then
                        local archive = entry and entry.path and FS.attributes(entry.path, "mode") == "file"
                        if not archive then
                            local eligible, reason = self.queue:canEnqueue(manga, chapter, choices.directory)
                            if eligible then
                                admitted[#admitted + 1] = self.queue:buildPersistentJob(manga, chapter, choices.directory, "queued")
                            elseif reason ~= "downloaded" and reason ~= "queued" and reason ~= "downloading"
                                and reason ~= "running" and reason ~= "stopping" and reason ~= "finalizing" then
                                blocker = "ownership_unproved"
                            end
                        end
                    end
                end
            end
        end
        if choices.filter and matches == 0 then blocker = "scanlator_missing" end
        self.queue:admitDocument(doc, admitted, "automatic")
        state.associations[request.manga_id] = { version = 1, manga = copy(manga), endpoint_scope = request.endpoint_scope }
        if blocker then current.state, current.reason, current.next_retry_at = "blocked", blocker, 0
        else state.requests[request.manga_id] = nil end
    end)
    if ok then
        self.queue:reconcile()
        self.queue:process()
        self.onChanged()
    elseif rejected and err ~= "stale_request" then
        self:_transition(request, "blocked", "unsupported_state")
    elseif err ~= "stale_request" then
        self:_transition(request, "waiting", "persistence_failed", true)
    end
end
function Refill:_unblocked(request)
    if request.reason == "endpoint_changed" then return request.endpoint_scope == self:_endpoint() end
    if request.reason == "origin_unknown" or request.reason == "unsupported_state"
        or request.reason == "metadata_missing" or request.reason == "scanlator_missing" then return false end
    if request.reason == "configuration_missing" then
        return FS.attributes(self.settings:loadDownloadDirectory(), "mode") == "directory" and self:_endpoint() ~= ""
    end
    if request.reason == "terminal_failure" then
        for _, job in ipairs(self.queue:loadPersistentJobs()) do
            if job.manga and tostring(job.manga.id) == request.manga_id and job.state == "failed" then return false end
        end
        return true
    end
    if request.reason == "ownership_unproved" then
        for _, job in ipairs(self.queue:loadPersistentJobs()) do
            if job.manga and tostring(job.manga.id) == request.manga_id
                and job.progress and job.progress.archive_state then return false end
        end
        return true
    end
    if request.reason == "manual_delete_pending" then
        local state = self:_document().manual_archive_state
        if type(state) ~= "table" or state.version ~= 1 or type(state.requests) ~= "table" then return false end
        for key, deletion in pairs(state.requests) do
            if tostring(key):sub(1, #request.manga_id + 1) == request.manga_id .. ":"
                and (type(deletion) ~= "table" or deletion.version ~= 1
                    or deletion.state == "pending" or deletion.state == "blocked") then return false end
        end
        return true
    end
    return false
end
function Refill:process()
    if self.stopped then return end
    if self.active then
        if not self:_current(self.active) then SubprocessJob.cancel(self.active) end
        return
    end
    if self.storage_retry_at and self.storage_retry_at > self.now() then
        self:_schedule(self.storage_retry_at - self.now()); return
    end
    if self.queue:isBlocked() or self.queue:isRecovering() then self:_schedule(5); return end
    local state = collection(self:_document())
    local due, deadline = {}, nil
    for id, request in pairs(state and state.requests or {}) do
        if valid(request, id) then
            if request.state ~= "blocked" or self:_unblocked(request) then
                if request.next_retry_at <= self.now() then due[#due + 1] = copy(request)
                else deadline = math.min(deadline or request.next_retry_at, request.next_retry_at) end
            end
        end
    end
    table.sort(due, function(a, b)
        if a.manga_id == self.last_manga then return false end
        if b.manga_id == self.last_manga then return true end
        return a.revision < b.revision
    end)
    local request = due[1]
    if not request then if deadline then self:_schedule(math.max(0, deadline - self.now())) end; return end
    self.last_manga = request.manga_id
    local choices = self:_choices(request)
    if choices.limit == 0 then
        local ok = self:_save(function(doc) self:retire(doc, { [request.manga_id] = true }) end)
        if not ok then self.storage_retry_at = self.now() + 5 end
        self:wake(); return
    end
    if not request.endpoint_scope or request.endpoint_scope ~= choices.endpoint then
        self:_transition(request, "blocked", request.endpoint_scope and "endpoint_changed" or "origin_unknown")
        self:wake(); return
    end
    if choices.directory == "" or FS.attributes(choices.directory, "mode") ~= "directory" or choices.endpoint == "" then
        self:_transition(request, "blocked", "configuration_missing"); self:wake(); return
    end
    local attempt_id = Archive.newAttemptId()
    if not attempt_id then self:_transition(request, "waiting", "fetch_failed", true); self:wake(); return end
    local credentials = self.settings:load()
    local active = { request = request, choices = choices }
    self.active = active
    local worker = require("suwayomi/network/request_worker")
    SubprocessJob.start{
        active = active, prefix = "refill_" .. attempt_id, ffi_util = self.queue.ffi_util,
        ui_manager = self.ui_manager, now = self.now, timeout_seconds = 120, poll_interval_seconds = 0.5,
        run = function(path)
            worker:run(credentials, { action = "fetch_refill_context", manga_id = request.manga_id,
                manga = request.manga }, path)
        end,
        read_result = function(path) return worker:readResult(path) end,
        on_finish = function(_, result)
            if self.active == active then
                local called = pcall(self._apply, self, active, result)
                if not called then self:_transition(request, "waiting", "fetch_failed", true) end
            end
        end,
        on_timeout = function() self:_transition(request, "waiting", "fetch_failed", true) end,
        on_error = function() self:_transition(request, "waiting", "fetch_failed", true) end,
        on_cleanup = function()
            if self.active == active then self.active = nil end
            self:wake()
        end,
    }
end
function Refill:shutdown(deadline, now)
    self.stopped = true
    if self.scheduled then self.ui_manager:unschedule(self.scheduled) end
    self.scheduled, self.scheduled_at = nil, nil
    local active = self.active
    if not active then return end
    active.canceled = true
    if now() < deadline then SubprocessJob.terminate(active) end
    if now() < deadline and active.pid and self.queue.ffi_util.isSubProcessDone(active.pid) then
        SubprocessJob.cleanup(active)
    end
end
return Refill
