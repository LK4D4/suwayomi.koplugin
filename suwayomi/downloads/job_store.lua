-- Boundary: persisted download queue schema.
--
-- Responsibility: load/save settings-backed jobs, normalize saved data, and
-- build persisted jobs and check their runnable shape without rewriting inert records.
-- Owned state: settings adapter and queue-key callback.
-- Injected dependencies: settings.loadDownloadQueue/saveDownloadQueue and a
-- getKey function supplied by the public queue facade.
-- External data: saved settings are treated as untrusted and normalized at this
-- boundary before snapshot/recovery code consumes them.

local JobStore = {}
JobStore.__index = JobStore

local function copyMetadata(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copyMetadata(item) end
    return result
end

local function hasValidJobKey(job)
    return type(job) == "table" and type(job.key) == "string" and job.key ~= ""
end

local function hasValidIdentity(metadata)
    if type(metadata) ~= "table" then return false end
    local id = metadata.id
    if type(id) == "string" then return id:match("%S") ~= nil end
    return type(id) == "number" and id == id and math.abs(id) < math.huge
end

local function normalizeJobList(jobs)
    local normalized = {}
    if type(jobs) ~= "table" then
        return normalized, jobs ~= nil
    end

    local changed = false
    local numeric_keys = {}
    for key in pairs(jobs) do
        if type(key) == "number" and key > 0 and math.floor(key) == key then
            table.insert(numeric_keys, key)
        else
            changed = true
        end
    end
    table.sort(numeric_keys)

    for index, key in ipairs(numeric_keys) do
        if key ~= index then
            changed = true
        end
        local job = jobs[key]
        if hasValidJobKey(job) then
            table.insert(normalized, job)
        else
            changed = true
        end
    end

    return normalized, changed
end

function JobStore:new(options)
    options = options or {}
    return setmetatable({
        settings = options.settings,
        getKey = options.getKey or function(manga, chapter)
            return tostring(manga.id or manga.title or "") .. ":" .. tostring(chapter.id or chapter.name or "")
        end,
    }, self)
end

function JobStore:isRunnable(job)
    return hasValidJobKey(job) and job.version == nil
        and (job.state == "queued" or job.state == "downloading")
        and hasValidIdentity(job.manga) and hasValidIdentity(job.chapter)
        and type(job.download_directory) == "string" and job.download_directory ~= ""
end

function JobStore:isBlocked()
    if self.settings and self.settings.isBlocked then
        return self.settings:isBlocked()
    end
    return false
end

function JobStore:reconcile()
    if self.settings and self.settings.reconcile then
        return self.settings:reconcile()
    end
    return true
end

function JobStore:load()
    if not self.settings or not self.settings.loadDownloadQueue then
        return {}
    end
    local jobs, changed = normalizeJobList(self.settings:loadDownloadQueue())
    if changed and self.settings.saveDownloadQueue then
        self.settings:saveDownloadQueue(jobs)
    end
    return jobs
end

function JobStore:save(jobs)
    local normalized = normalizeJobList(jobs)
    if not self.settings or not self.settings.saveDownloadQueue then
        return normalized
    end
    local saved, err = self.settings:saveDownloadQueue(normalized)
    if saved == false then
        return nil, err
    end
    return saved or normalized
end

function JobStore:normalizeProgress(progress)
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
    if progress.archive_state == "damaged" or progress.archive_state == "unverified" then
        normalized.archive_state = progress.archive_state
    end
    if type(progress.identity) == "string" then normalized.identity = progress.identity end
    if progress.retryable ~= nil then
        normalized.retryable = progress.retryable == true or progress.retryable == "true"
    end
    if progress.updated_at ~= nil then
        normalized.updated_at = tonumber(progress.updated_at) or progress.updated_at
    end

    return normalized
end

function JobStore:normalizeRecovery(recovery)
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

function JobStore:copySourceMetadata(source)
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

function JobStore:copyMangaMetadata(manga)
    local copied = {
        id = manga.id,
        title = manga.title,
        endpoint_scope = self.settings and self.settings.normalizeEndpointScope
            and self.settings:normalizeEndpointScope(manga.endpoint_scope) or nil,
        in_library = manga.in_library,
    }
    local source = self:copySourceMetadata(manga.source)
    if source then
        copied.source = source
    end
    return copied
end

function JobStore:copyChapterMetadata(chapter)
    local copied = {
        id = chapter.id,
        name = chapter.name,
    }
    for _, key in ipairs({ "chapter_number", "source_order", "scanlator" }) do
        if chapter[key] ~= nil then
            copied[key] = chapter[key]
        end
    end
    return copied
end

function JobStore:buildJob(manga, chapter, download_directory, state, details)
    details = details or {}
    -- Only persisted fields are copied here. Runtime fields such as credentials,
    -- process ids, callbacks, and downloader instances must never reach settings.
    local job = {
        key = self.getKey(manga, chapter),
        state = state or "queued",
        download_directory = download_directory,
        manga = self:copyMangaMetadata(manga),
        chapter = self:copyChapterMetadata(chapter),
    }
    job.archive_generation = details.archive_generation
    job.provenance = details.provenance
    if details.repair == true then job.repair = true end
    if details.started_at ~= nil then
        job.started_at = tonumber(details.started_at) or details.started_at
    end
    if details.last_progress_at ~= nil then
        job.last_progress_at = tonumber(details.last_progress_at) or details.last_progress_at
    end
    if details.retry_count ~= nil then
        job.retry_count = math.max(0, math.floor(tonumber(details.retry_count) or 0))
    end
    if details.retry_at ~= nil then
        job.retry_at = tonumber(details.retry_at)
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

function JobStore:upsert(job)
    local jobs = self:load()
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

    local saved, err = self:save(jobs)
    if not saved then
        return nil, err
    end
    return job
end

function JobStore:upsertMany(new_jobs)
    local jobs = self:load()
    local indexes_by_key = {}
    for index, existing in ipairs(jobs) do
        if hasValidJobKey(existing) then
            indexes_by_key[existing.key] = index
        end
    end

    for _, job in ipairs(new_jobs or {}) do
        if hasValidJobKey(job) then
            local existing_index = indexes_by_key[job.key]
            if existing_index then
                jobs[existing_index] = job
            else
                table.insert(jobs, job)
                indexes_by_key[job.key] = #jobs
            end
        end
    end

    local saved, err = self:save(jobs)
    if not saved then
        return nil, err
    end
    return new_jobs
end

function JobStore:admitDocument(doc, new_jobs, provenance, manual_deletion)
    if doc.download_queue ~= nil and type(doc.download_queue) ~= "table" then
        error("unsupported_download_queue", 0)
    end
    local jobs = doc.download_queue or {}
    local indexes, last_index = {}, 0
    for index, existing in pairs(jobs) do
        if type(index) == "number" and index > last_index and index == math.floor(index) then
            last_index = index
        end
        if hasValidJobKey(existing) then
            if indexes[existing.key] then error("duplicate_download_job", 0) end
            indexes[existing.key] = index
        end
    end
    for _, job in ipairs(new_jobs) do
        local existing = indexes[job.key] and jobs[indexes[job.key]]
        if existing and (provenance ~= "explicit" or existing.state ~= "failed" or existing.version ~= nil) then
            error("download_job_owned_or_unsupported", 0)
        end
    end
    if manual_deletion and #new_jobs > 0 then manual_deletion:admitDownloads(doc, new_jobs, provenance) end
    for _, job in ipairs(new_jobs) do
        job.provenance = provenance
        local index = indexes[job.key]
        if not index then
            last_index = last_index + 1
            index = last_index
            indexes[job.key] = index
        end
        jobs[index] = job
    end
    doc.download_queue = jobs
end

function JobStore:admit(new_jobs, provenance, manual_deletion)
    if not self.settings or not self.settings.getStore then
        return nil, "checked_store_unavailable"
    end
    local call_ok, ok, err = pcall(function()
        return self.settings:getStore():saveDocument(function(doc)
            self:admitDocument(doc, new_jobs, provenance, manual_deletion)
        end)
    end)
    if not call_ok then return nil, ok end
    if not ok then return nil, err end
    return new_jobs
end

function JobStore:remove(key)
    local remaining = {}
    for _, job in ipairs(self:load()) do
        if job.key ~= key then
            table.insert(remaining, job)
        end
    end
    local saved, err = self:save(remaining)
    if not saved then
        return false, err
    end
    return true
end

function JobStore:copySnapshotJob(job, state)
    local snapshot = {
        key = job.key or self.getKey(job.manga or {}, job.chapter or {}),
        state = state or job.state,
        download_directory = job.download_directory,
        manga = copyMetadata(job.manga),
        chapter = copyMetadata(job.chapter),
        retry_count = job.retry_count,
        retry_at = job.retry_at,
        archive_generation = job.archive_generation,
        provenance = job.provenance,
        repair = job.repair,
    }
    local progress = self:normalizeProgress(job.progress)
    if progress then
        snapshot.progress = progress
    elseif job.last_progress_current ~= nil or job.last_progress_total ~= nil or job.last_progress_state ~= nil then
        snapshot.progress = {
            state = job.last_progress_state or state or job.state,
            current = job.last_progress_current or 0,
            total = job.last_progress_total or 0,
        }
    end
    return snapshot
end

function JobStore:find(key, state)
    for _, job in ipairs(self:load()) do
        if job.key == key and (state == nil or job.state == state) then
            return job
        end
    end
    return nil
end

return JobStore
