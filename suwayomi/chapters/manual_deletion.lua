-- Boundary: checked, generation-bound manual archive deletion and recovery.
-- The process service owns scheduling; only fresh actions/publications establish identity.
-- Unknown records and uncertain saves preserve files. Metadata is never removed here.

local Identity = require("suwayomi/chapters/archive_identity")
local ManualDeletion = {}
ManualDeletion.__index = ManualDeletion

local MAX_REVISION = 9007199254740991
local owned_states = { queued = true, downloading = true, running = true, stopping = true, finalizing = true }
local request_states = { pending = true, blocked = true, removed = true, revoked = true }
local transient = {
    current_document = true, reader_unavailable = true, stat_failed = true,
    realpath_failed = true, busy = true, remove_failed = true, persistence_failed = true,
}

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


local function integer(value)
    return type(value) == "number" and value >= 1 and value < MAX_REVISION and value == math.floor(value)
end

local function validTarget(target)
    return type(target) == "table" and (target.version == nil or target.version == 1)
        and type(target.key) == "string" and target.key ~= "" and integer(target.generation)
        and type(target.path) == "string" and target.path:sub(-4):lower() == ".cbz"
        and type(target.root) == "string" and target.root ~= ""
        and (target.retired == nil or type(target.retired) == "boolean")
        and (target.reader_context == nil or type(target.reader_context) == "table")
        and Identity.supported(target.evidence)
end

local function sameTarget(left, right)
    return validTarget(left) and validTarget(right) and left.key == right.key
        and left.generation == right.generation and left.path == right.path and left.root == right.root
        and Identity.same(left.evidence, right.evidence)
end

local function validRequest(request, key)
    return type(request) == "table" and request.version == 1 and request.key == key
        and integer(request.revision) and request_states[request.state] == true
        and (request.target == nil or (validTarget(request.target) and request.target.key == key))
        and type(request.retry_count) == "number" and request.retry_count >= 0
        and request.retry_count < MAX_REVISION and request.retry_count == math.floor(request.retry_count)
        and type(request.retry_after) == "number" and request.retry_after >= 0
        and request.retry_after < math.huge
        and ((request.state ~= "pending" and request.state ~= "removed") or request.target ~= nil)
        and (request.archive_removed == nil or type(request.archive_removed) == "boolean")
        and (request.bookkeeping_complete == nil or type(request.bookkeeping_complete) == "boolean")
end

local function collection(doc, create)
    local state = doc.manual_archive_state
    if state == nil and create then
        state = { version = 1, next_revision = 1, archives = {}, requests = {} }
        doc.manual_archive_state = state
    end
    if state == nil then return nil end
    if type(state) ~= "table" or state.version ~= 1 or not integer(state.next_revision)
        or type(state.archives) ~= "table" or type(state.requests) ~= "table" then
        return nil, "unsupported_state"
    end
    return state
end

local function allocate(state)
    local revision = state.next_revision
    if not integer(revision) or revision >= MAX_REVISION - 1 then error("revision_exhausted") end
    -- A corrupt counter must not recycle an identity already present in the document.
    for _, archive in pairs(state.archives) do
        if type(archive) == "table" and type(archive.generation) == "number" and archive.generation >= revision then
            error("invalid_revision")
        end
    end
    for _, request in pairs(state.requests) do
        if type(request) == "table" and type(request.revision) == "number" and request.revision >= revision then
            error("invalid_revision")
        end
    end
    state.next_revision = revision + 1
    return revision
end

local function pending(request)
    return request and (request.state == "pending" or request.state == "blocked")
end

local function keyFor(job)
    if type(job) ~= "table" then return nil end
    return job.key or (type(job.manga) == "table" and type(job.chapter) == "table"
        and tostring(job.manga.id or job.manga.title or "") .. ":" .. tostring(job.chapter.id or job.chapter.name or ""))
end

function ManualDeletion:new(options)
    options = options or {}
    return setmetatable({
        settings = assert(options.settings), queue = assert(options.queue),
        ui_manager = assert(options.ui_manager), now = options.now or os.time,
        onChanged = options.onChanged or function() end, batch_size = 25,
    }, self)
end

function ManualDeletion:_document()
    return self.settings:getStore():load()
end

function ManualDeletion:_blocked()
    return self.settings:getStore():isBlocked() or self.queue.stopped == true or self.queue.recovery_pending == true
end

function ManualDeletion:_save(mutator)
    if self:_blocked() then
        if self.queue.scheduleReconciliation then self.queue:scheduleReconciliation() end
        return nil, "persistence_failed"
    end
    local store = self.settings:getStore()
    local called, ok, result = pcall(store.saveDocument, store, mutator)
    if not called then return nil, "invalid_state" end
    if not ok then
        if self.queue.scheduleReconciliation then self.queue:scheduleReconciliation() end
        return nil, result
    end
    return true, result
end

function ManualDeletion:_busy(key, doc)
    if self.queue.isChapterBusy and self.queue:isChapterBusy(key) then return true end
    if self.queue.recovery_completions and self.queue.recovery_completions[key] then return true end
    for _, item in pairs(self.queue.items or {}) do
        if keyFor(item) == key then return true end
    end
    local status = (self.queue.statuses or {})[key]
    if type(status) == "table" and owned_states[status.state] then return true end
    if doc.download_queue ~= nil and type(doc.download_queue) ~= "table" then return true end
    for _, job in pairs(doc.download_queue or {}) do
        if keyFor(job) == key then
            if owned_states[job.state] then return true end
            if job.state ~= "failed" and job.state ~= "completed" and job.state ~= "cancelled" then return true end
        end
    end
    return false
end

local function captureContext(doc, target)
    local context = type(doc.reader_return_contexts) == "table" and doc.reader_return_contexts[target.path]
    if type(context) == "table" and context.path == target.path
        and tostring(context.manga_id or "") .. ":" .. tostring(context.chapter_id or "") == target.key then
        target.reader_context = copy(context)
    end
end

local function stamp(doc, target)
    local entry = type(doc.chapter_ledger) == "table" and doc.chapter_ledger[target.key]
    if type(entry) == "table" and entry.path == target.path then entry.archive_generation = target.generation end
    local context = type(doc.reader_return_contexts) == "table" and doc.reader_return_contexts[target.path]
    if type(context) == "table" and context.path == target.path
        and tostring(context.manga_id or "") .. ":" .. tostring(context.chapter_id or "") == target.key then
        -- Context authority belongs to the exact captured return state, not
        -- merely to its archive: later navigation may refresh that state.
        if target.reader_context and equal(context, target.reader_context) then
            target.reader_context.archive_generation = target.generation
        else
            target.reader_context = nil
        end
        context.archive_generation = target.generation
    end
    local state = collection(doc)
    local archive = state and state.archives[target.key]
    if sameTarget(archive, target) then archive.reader_context = copy(target.reader_context) end
end

function ManualDeletion:capture(key, path, root)
    local result = { key = key }
    if type(key) ~= "string" or key == "" then result.reason = "unsupported_state"; return result end
    if self:_blocked() then result.reason = "persistence_failed"; return result end
    if self:_busy(key, self:_document()) then result.reason = "busy"; return result end
    if not path then result.reason = "missing"; return result end
    local evidence, reason = Identity.inspect(path, root)
    if not evidence then result.reason = reason; return result end
    result.target = { key = key, path = path, root = root, evidence = evidence }
    captureContext(self:_document(), result.target)
    local state, err = collection(self:_document())
    if err then result.reason = err; return result end
    local archive = state and state.archives[key]
    result.observed_generation = archive and archive.generation
    if archive ~= nil and not validTarget(archive) then result.reason = "unsupported_state"; return result end
    if archive and not archive.retired and archive.path == path and archive.root == root
        and Identity.same(archive.evidence, evidence) then result.target.generation = archive.generation end
    return result
end

local function mergeLedger(doc, ledger, replace_read_state)
    if type(doc.chapter_ledger) ~= "table" then doc.chapter_ledger = {} end
    if replace_read_state then
        for key, entry in pairs(doc.chapter_ledger) do
            if ledger[key] == nil and type(entry) == "table" then
                entry.read, entry.pending_read_sync, entry.pending_read_state = false, nil, nil
            end
        end
    end
    for key, supplied in pairs(ledger or {}) do
        if type(supplied) == "table" then
            local current = doc.chapter_ledger[key]
            local merged = type(current) == "table" and copy(current) or {}
            merged.pending_read_sync, merged.pending_read_state = supplied.pending_read_sync, supplied.pending_read_state
            for field, value in pairs(supplied) do merged[field] = copy(value) end
            merged.read = supplied.read == true
            -- Read reconciliation must not restore a stale archive association.
            if type(current) == "table" and current.archive_generation ~= supplied.archive_generation then
                merged.path, merged.archive_generation = current.path, current.archive_generation
            end
            doc.chapter_ledger[key] = merged
        end
    end
end

function ManualDeletion:commitRead(ledger, captures, unread_keys, mangas, replace_read_state, options)
    local outcomes = {}
    local enrolled = false
    local ok, err = self:_save(function(doc)
        if self.queue.refill then enrolled = self.queue.refill:enrollLedger(doc, ledger, mangas, options) end
        mergeLedger(doc, ledger, replace_read_state)
        local state, state_error = collection(doc, #(captures or {}) > 0)
        if state then
            for key, request in pairs(state.requests) do
                local unread = unread_keys and unread_keys[key]
                if not unread and type(unread_keys) == "table" then
                    for _, candidate in ipairs(unread_keys) do if candidate == key then unread = true; break end end
                end
                local entry = doc.chapter_ledger[key]
                if (unread or (type(entry) == "table" and entry.read ~= true)) and validRequest(request, key)
                    and pending(request) then
                    request.state, request.reason, request.retry_after = "revoked", "unread", 0
                end
            end
        end
        for _, captured in ipairs(captures or {}) do
            local key = captured.key
            local reason = state_error or captured.reason
            local previous = state and state.requests[key]
            local archive = state and state.archives[key]
            if previous ~= nil and not validRequest(previous, key) then reason = "unsupported_state" end
            if archive ~= nil and not validTarget(archive) then reason = "unsupported_state" end
            if not reason and (archive and archive.generation) ~= captured.observed_generation then
                reason = "generation_changed"
            end
            if self:_busy(key, doc) then reason = "busy" end
            if not reason and captured.target then
                local evidence, inspect_error = Identity.inspect(captured.target.path, captured.target.root, captured.target.evidence)
                if not evidence then reason = inspect_error end
            end
            if reason == "busy" or reason == "missing" then
                outcomes[key] = { state = reason, reason = reason }
            elseif reason then
                outcomes[key] = { state = "blocked", reason = reason }
                if state and reason ~= "unsupported_state" and not pending(previous) then
                    local request = { version = 1, key = key, revision = allocate(state), state = "blocked",
                        reason = reason, retry_count = 0, retry_after = 0, metadata_retained = true }
                    request.captured = copy(captured.target)
                    state.requests[key] = request
                    outcomes[key] = copy(request)
                end
            else
                local target = copy(captured.target)
                if archive and not archive.retired and archive.path == target.path and archive.root == target.root
                    and Identity.same(archive.evidence, target.evidence) then
                    target.generation = archive.generation
                else
                    target.generation = allocate(state)
                    state.archives[key] = copy(target)
                end
                stamp(doc, target)
                if validRequest(previous, key) and pending(previous) and sameTarget(previous.target, target) then
                    outcomes[key] = copy(previous)
                else
                    local request = { version = 1, key = key, revision = allocate(state), target = target,
                        state = "pending", retry_count = 0, retry_after = 0,
                        archive_removed = false, bookkeeping_complete = false, metadata_retained = true }
                    state.requests[key] = request
                    outcomes[key] = copy(request)
                end
            end
        end
    end)
    if not ok then return nil, err, {} end
    for _, captured in ipairs(captures or {}) do
        if outcomes[captured.key] and outcomes[captured.key].target then
            captured.target = copy(outcomes[captured.key].target)
        end
    end
    if self.queue.refill then
        self.queue.refill:wake()
        if enrolled then self.queue.refill.onChanged() end
    end
    return true, nil, outcomes
end

function ManualDeletion:admitDownloads(doc, jobs, provenance)
    local state, err = collection(doc, true)
    if not state then error(err) end
    for _, job in ipairs(jobs) do
        local key = keyFor(job)
        local request = state.requests[key]
        local archive = state.archives[key]
        if (request ~= nil and not validRequest(request, key)) or (archive ~= nil and not validTarget(archive)) then
            error("unsupported_state")
        end
        if pending(request) then
            if provenance ~= "explicit" then error("manual_deletion_pending") end
            request.state, request.reason, request.retry_after = "revoked", "deliberate_download", 0
        end
        job.archive_generation = allocate(state)
        job.provenance = provenance
    end
    return true
end

function ManualDeletion:validateJob(job)
    if self.settings:getStore():isBlocked() or self.queue.stopped then return false, "persistence_failed" end
    local doc = self:_document()
    local state, err = collection(doc)
    if err then return false, err end
    local key = keyFor(job)
    local request = state and state.requests[key]
    if request ~= nil and not validRequest(request, key) then return false, "unsupported_state" end
    if pending(request) then return false, "manual_deletion_pending" end
    for _, stored in pairs(doc.download_queue or {}) do
        if keyFor(stored) == key then
            if stored.archive_generation == job.archive_generation then return true end
            return false, "generation_changed"
        end
    end
    local archive = state and state.archives[key]
    if validTarget(archive) and not archive.retired and archive.generation == job.archive_generation then return true end
    local lifecycle = self.queue.active_job_lifecycle
    if lifecycle and lifecycle.getStoppingJob and lifecycle:getStoppingJob(key) == job
        and state and integer(job.archive_generation) and job.archive_generation < state.next_revision
        and (archive == nil or (validTarget(archive) and archive.generation < job.archive_generation)) then
        -- Cancellation retires queue intent, not the exact still-owned child's
        -- publication. A reconstructed/stale callback has no such authority.
        return true
    end
    return false, "job_superseded"
end

function ManualDeletion:publish(doc, job, path)
    local state, err = collection(doc, true)
    if not state then error(err) end
    local key = keyFor(job)
    local request, archive = state.requests[key], state.archives[key]
    if (request ~= nil and not validRequest(request, key)) or (archive ~= nil and not validTarget(archive)) then
        error("unsupported_state")
    end
    if pending(request) then error("manual_deletion_pending") end
    if archive and job.archive_generation and archive.generation > job.archive_generation then error("job_superseded") end
    local evidence, reason = Identity.inspect(path, job.download_directory)
    if not evidence then error(reason) end
    local generation = job.archive_generation
    if not generation then generation = allocate(state) end
    if not integer(generation) then error("unsupported_identity") end
    if archive and archive.generation == generation and (archive.retired or archive.path ~= path
        or not Identity.same(archive.evidence, evidence)) then error("identity_changed") end
    local target = { key = key, generation = generation, path = path, root = job.download_directory, evidence = evidence }
    captureContext(doc, target)
    state.archives[key] = target
    stamp(doc, target)
    return generation
end

function ManualDeletion:getTarget(key, path)
    if self:_blocked() then return nil, "persistence_failed" end
    local state, err = collection(self:_document())
    if err then return nil, err end
    local target = state and state.archives[key]
    if not validTarget(target) or target.retired or target.path ~= path then return nil, "unproved_target" end
    return copy(target)
end
-- ReaderReady follows KOReader's access-time touch. Capture before that window;
-- only its ctime change may refresh an already proved archive generation.
function ManualDeletion:beginReaderAccess(key, path)
    local target, reason = self:getTarget(key, path)
    if not target then return nil, reason end
    if self:_busy(key, self:_document()) then return nil, "busy" end
    local evidence, err = Identity.inspect(path, target.root, target.evidence)
    if not evidence then return nil, err end
    return target
end

function ManualDeletion:finishReaderAccess(target)
    if self:_blocked() then return nil, "persistence_failed" end
    if not validTarget(target) then return nil, "unsupported_identity" end
    local evidence, reason = Identity.inspect(target.path, target.root)
    if not evidence then return nil, reason end
    local ctime = evidence.ctime
    evidence.ctime = target.evidence.ctime
    local unchanged = Identity.same(target.evidence, evidence)
    evidence.ctime = ctime
    if not unchanged then return nil, "identity_changed" end
    if ctime == target.evidence.ctime then return true end
    local saved = self:_save(function(doc)
        local state = collection(doc)
        local archive = state and state.archives[target.key]
        if not sameTarget(archive, target) or archive.retired or self:_busy(target.key, doc) then
            error("generation_changed")
        end
        if not Identity.inspect(target.path, target.root, evidence) then error("identity_changed") end
        archive.evidence = copy(evidence)
        local request = state.requests[target.key]
        if request and sameTarget(request.target, target) then request.target.evidence = copy(evidence) end
        local entry = type(doc.chapter_ledger) == "table" and doc.chapter_ledger[target.key]
        local journal = doc.finished_chapter_cleanup
        local manga = entry and type(journal) == "table" and journal.version == 1
            and type(journal.mangas) == "table" and journal.mangas[tostring(entry.manga_id)]
        for _, record in ipairs(manga and manga.records or {}) do
            if sameTarget(record.archive_target, target) then record.archive_target.evidence = copy(evidence) end
        end
    end)
    if not saved then return nil, "persistence_failed" end
    return true, nil, evidence
end


function ManualDeletion:validateTarget(target, allow_missing)
    if self:_blocked() then return false, "persistence_failed" end
    if not validTarget(target) then return false, "unsupported_identity" end
    local doc = self:_document()
    local state, err = collection(doc)
    if err then return false, err end
    local archive = state and state.archives[target.key]
    if not sameTarget(archive, target) or archive.retired then return false, "generation_changed" end
    if self:_busy(target.key, doc) then return false, "busy" end
    local owns, reader_reason = Identity.readerOwns(target)
    if owns then return false, reader_reason end
    local evidence, reason = Identity.inspect(target.path, target.root, target.evidence)
    if not evidence then
        -- allow_missing documents recovery intent; absence is always explicit,
        -- never a successful authorization to unlink a later file.
        if allow_missing and reason == "missing" then return false, "missing" end
        return false, reason
    end
    return true
end

function ManualDeletion:prepareRemoval(key, path, root)
    local captured = self:capture(key, path, root)
    if captured.reason then return nil, captured.reason end
    local target
    local ok, err = self:_save(function(doc)
        if self:_busy(key, doc) then error("busy") end
        local evidence, reason = Identity.inspect(path, root, captured.target.evidence)
        if not evidence then error(reason) end
        local state, state_error = collection(doc, true)
        if not state then error(state_error) end
        local archive, request = state.archives[key], state.requests[key]
        if (archive ~= nil and not validTarget(archive)) or (request ~= nil and not validRequest(request, key)) then
            error("unsupported_state")
        end
        if (archive and archive.generation) ~= captured.observed_generation then error("generation_changed") end
        target = copy(captured.target)
        if archive and not archive.retired and archive.path == path and archive.root == root
            and Identity.same(archive.evidence, evidence) then target.generation = archive.generation
        else target.generation = allocate(state); state.archives[key] = copy(target) end
        stamp(doc, target)
    end)
    if not ok then return nil, err end
    local valid, reason = self:validateTarget(target, true)
    if not valid and reason ~= "missing" then return nil, reason end
    return target
end

function ManualDeletion:retire(doc, target)
    local state = collection(doc)
    local archive = state and state.archives[target.key]
    if not sameTarget(archive, target) then return false end
    archive.retired = true
    local entry = type(doc.chapter_ledger) == "table" and doc.chapter_ledger[target.key]
    if type(entry) == "table" and entry.path == target.path and entry.archive_generation == target.generation then
        entry.path, entry.archive_generation = nil, nil
    end
    local context = type(doc.reader_return_contexts) == "table" and doc.reader_return_contexts[target.path]
    if type(context) == "table" and context.path == target.path and context.archive_generation == target.generation
        and target.reader_context and equal(context, target.reader_context) then
        doc.reader_return_contexts[target.path] = nil
    end
    local journal = doc.finished_chapter_cleanup
    if type(journal) == "table" and journal.version == 1 and type(journal.mangas) == "table" then
        for _, manga in pairs(journal.mangas) do
            if type(manga) == "table" and type(manga.records) == "table" then
                for _, record in pairs(manga.records) do
                    if type(record) == "table" and sameTarget(record.archive_target, target) then
                        record.archive_retired = true
                    end
                end
            end
        end
    end
    local request = state.requests[target.key]
    if validRequest(request, target.key) and sameTarget(request.target, target) then
        request.archive_removed, request.bookkeeping_complete, request.metadata_retained = true, true, true
        if request.state ~= "revoked" then request.state, request.reason = "removed", "metadata_retained" end
        request.retry_after = 0
    end
    return true
end

function ManualDeletion:_changed(target)
    if target then
        local status = (self.queue.statuses or {})[target.key]
        if type(status) == "table" and not owned_states[status.state]
            and (status.archive_generation == target.generation
                or (status.archive_generation == nil and not self:_busy(target.key, self:_document()))) then
            self.queue.statuses[target.key] = nil
        end
    end
    pcall(self.onChanged)
end

function ManualDeletion:_transition(key, revision, mutate)
    local changed = false
    local ok, err = self:_save(function(doc)
        local state = collection(doc)
        local request = state and state.requests[key]
        if validRequest(request, key) and request.revision == revision and pending(request) then
            mutate(request, doc)
            changed = true
        end
    end)
    if ok and changed then self:_changed() end
    return ok, err
end

function ManualDeletion:_defer(request, reason)
    return self:_transition(request.key, request.revision, function(current)
        current.reason = reason
        if transient[reason] then
            current.state = "pending"
            current.retry_count = math.min(current.retry_count + 1, MAX_REVISION - 1)
            local delay = current.retry_count >= 7 and 300 or math.min(5 * 2 ^ (current.retry_count - 1), 300)
            current.retry_after = self.now() + delay
        else
            current.state, current.retry_after = "blocked", 0
        end
    end)
end

function ManualDeletion:_processRequest(request)
    local entry = (self:_document().chapter_ledger or {})[request.key]
    if type(entry) == "table" and entry.read ~= true then
        return self:_transition(request.key, request.revision, function(current)
            current.state, current.reason, current.retry_after = "revoked", "unread", 0
        end)
    end
    local valid, reason = self:validateTarget(request.target, true)
    if not valid and reason ~= "missing" then return self:_defer(request, reason) end
    if request.archive_removed and valid then return self:_defer(request, "identity_changed") end
    local state = collection(self:_document())
    local current = state and state.requests[request.key]
    if not validRequest(current, request.key) or current.revision ~= request.revision or not pending(current)
        or not sameTarget(current.target, request.target) then return true end
    if valid then
        local called, removed = pcall(os.remove, request.target.path)
        if not called or not removed then
            local _, remove_reason = Identity.inspect(request.target.path, request.target.root, request.target.evidence)
            if remove_reason ~= "missing" then return self:_defer(request, "remove_failed") end
        end
    end
    if not request.archive_removed then
        local saved = self:_transition(request.key, request.revision, function(record)
            record.archive_removed, record.reason, record.retry_after = true, "bookkeeping_pending", 0
        end)
        if not saved then return false end
    end
    local retired = false
    local saved = self:_transition(request.key, request.revision, function(record, doc)
        local evidence, inspection_error = Identity.inspect(record.target.path, record.target.root, record.target.evidence)
        if evidence or inspection_error ~= "missing" then
            record.reason = inspection_error or "identity_changed"
            if transient[record.reason] then
                record.state = "pending"
                record.retry_count = math.min(record.retry_count + 1, MAX_REVISION - 1)
                local delay = record.retry_count >= 7 and 300 or math.min(5 * 2 ^ (record.retry_count - 1), 300)
                record.retry_after = self.now() + delay
            else
                record.state, record.retry_after = "blocked", 0
            end
            return
        end
        retired = self:retire(doc, record.target)
        if not retired then record.state, record.reason, record.retry_after = "blocked", "generation_changed", 0 end
    end)
    if saved and retired then self:_changed(request.target) end
    return saved
end

function ManualDeletion:snapshot()
    local doc = self:_document()
    local state, err = collection(doc)
    local result = {}
    local raw = state or (type(doc.manual_archive_state) == "table" and doc.manual_archive_state)
    if raw and type(raw.requests) == "table" then
        for key, request in pairs(raw.requests) do
            if type(key) == "string" then
                if err or not validRequest(request, key) then
                    result[key] = { key = key, state = "blocked", reason = "unsupported_state" }
                else
                    result[key] = copy(request)
                    if self:_blocked() and pending(request) then result[key].reason = "persistence_failed" end
                end
            end
        end
    end
    return result, err
end

function ManualDeletion:_schedule(delay)
    if not self.started or self.stopped then return end
    local deadline = self.now() + delay
    if self.scheduled and self.scheduled_at <= deadline then return end
    if self.scheduled then self.ui_manager:unschedule(self.scheduled) end
    local callback
    callback = function()
        if self.stopped or self.scheduled ~= callback then return end
        self.scheduled, self.scheduled_at = nil, nil
        self:process()
    end
    self.scheduled, self.scheduled_at = callback, deadline
    self.ui_manager:scheduleIn(math.max(0, delay), callback)
end

function ManualDeletion:start()
    if self.started or self.stopped then return end
    self.started = true
    self:wake()
end

function ManualDeletion:wake()
    self:_schedule(0)
end

function ManualDeletion:stop()
    self.stopped = true
    if self.scheduled then self.ui_manager:unschedule(self.scheduled) end
    self.scheduled, self.scheduled_at = nil, nil
end

function ManualDeletion:process()
    if self.processing or self.stopped then return self:snapshot() end
    self.processing = true
    if self:_blocked() then
        if self.queue.scheduleReconciliation then self.queue:scheduleReconciliation() end
        self.processing = false
        self:_schedule(5)
        return self:snapshot()
    end
    local snapshot = self:snapshot()
    local keys = {}
    for key, request in pairs(snapshot) do
        if request.state == "pending" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local start = 1
    if self.cursor then
        while start <= #keys and keys[start] <= self.cursor do start = start + 1 end
        if start > #keys then start = 1 end
    end
    local visited, failed = 0, false
    while visited < math.min(#keys, self.batch_size) do
        local index = ((start + visited - 1) % #keys) + 1
        local request = snapshot[keys[index]]
        self.cursor = keys[index]
        visited = visited + 1
        if request.retry_after <= self.now() then
            local called, saved = pcall(self._processRequest, self, request)
            if not called or not saved then failed = true end
            if self:_blocked() then break end
        end
    end
    self.processing = false
    local earliest
    for _, request in pairs(self:snapshot()) do
        if request.state == "pending" then
            earliest = math.min(earliest or math.huge, request.retry_after)
        end
    end
    if earliest then
        local delay = math.max(0, earliest - self.now())
        if failed and delay < 5 then delay = 5 end
        -- Yield between bounded passes even when every request is immediately due.
        self:_schedule(delay == 0 and 0.01 or delay)
    end
    return self:snapshot()
end

return ManualDeletion
