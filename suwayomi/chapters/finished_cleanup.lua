-- Boundary: FinishedChapterCleanup.
--
-- Responsibility: Persist finished-chapter order, process retention-based local cleanup, and refresh changed download views per batch.
-- Owned state: Processing, scheduling, retry, and notification state on a process-owned receiver in production.
-- Dependencies: Receiver ledger/delete methods, settings, UIManager, filesystem path resolution, debug, and i18n.
-- External data: Journal, ledger, queue, and filesystem paths are revalidated before deletion.

local UIManager = require("ui/uimanager")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiDebug = require("suwayomi/debug")
local I18n = require("suwayomi/i18n")
local FFIUtil = require("ffi/util")

local FinishedChapterCleanup = {}
FinishedChapterCleanup.__index = FinishedChapterCleanup

function FinishedChapterCleanup:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function cleanupSetting()
    local settings = SuwayomiSettings:loadDeleteChaptersSettings()
    return tonumber(settings and settings.delete_finished_while_reading) or 0
end

local function validId(value)
    return type(value) == "string" and value ~= ""
end

local function sortRecords(records)
    table.sort(records, function(left, right)
        if left.sequence == right.sequence then
            return left.chapter_id < right.chapter_id
        end
        return left.sequence < right.sequence
    end)
end

local function removeRecord(journal, manga_id, chapter_id)
    local manga = journal.mangas and journal.mangas[manga_id]
    if not manga then
        return false
    end
    for index = #(manga.records or {}), 1, -1 do
        if manga.records[index].chapter_id == chapter_id then
            table.remove(manga.records, index)
            if #manga.records == 0 then
                journal.mangas[manga_id] = nil
            end
            return true
        end
    end
    return false
end

local function findLedgerEntry(ledger, manga_id, chapter_id)
    for key, entry in pairs(ledger or {}) do
        if type(entry) == "table"
            and tostring(entry.manga_id or "") == manga_id
            and tostring(entry.chapter_id or "") == chapter_id
        then
            return entry, key
        end
    end
    return nil
end

local function resolvedPath(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local ok, resolved = pcall(FFIUtil.realpath, path)
    if not ok or type(resolved) ~= "string" or resolved == "" then
        return nil
    end
    resolved = resolved:gsub("\\", "/")
    if #resolved > 1 then
        resolved = resolved:gsub("/+$", "")
    end
    return resolved
end

local function isStrictDescendant(root, candidate)
    if not root or not candidate or root == candidate then
        return false
    end
    if root:match("^%a:") and candidate:match("^%a:") then
        root = root:lower()
        candidate = candidate:lower()
    end
    return candidate:sub(1, #root + 1) == root .. "/"
end

local function convergeMissingDownload(self, ledger, _entry, manga_id, chapter_id, path, changed_mangas, target)
    local queue = self:getDownloadQueue()
    local removal = queue.manual_deletion
    if not removal or type(target) ~= "table" or target.path ~= path
        or target.key ~= manga_id .. ":" .. chapter_id then return false end
    local valid, reason = removal:validateTarget(target, true)
    if valid or reason ~= "missing" then return false end
    local saved = SuwayomiSettings:getStore():saveDocument(function(doc)
        removal:retire(doc, target)
    end)
    if not saved then return false end
    local key = manga_id .. ":" .. chapter_id
    ledger[key] = self:loadChapterLedger()[key]
    local status = queue:getStatus({ id = manga_id }, { id = chapter_id })
    if status and status.archive_generation == target.generation and not queue:isChapterBusy(key) then
        queue.statuses[key] = nil
    end
    changed_mangas[manga_id] = true
    return true
end

local function refreshChangedDownloadViews(self, changed_mangas)
    if not next(changed_mangas) then return end
    local context = self.current_chapter_context
    local menu = self.current_chapter_menu
    if menu and context and context.manga and changed_mangas[tostring(context.manga.id)]
        and (not self.isSuwayomiScreenActive or self:isSuwayomiScreenActive(menu))
    then
        -- Full rebuild replaces cached download status. Never reuse the batch ledger:
        -- rebuilding can reconcile metadata and write a newer ledger itself.
        self:refreshChapterMenu()
    end
    if self.refreshDownloadsMenu then self:refreshDownloadsMenu(changed_mangas) end
end

local function retryDelay(retry_count)
    if retry_count >= 7 then
        return 300
    end
    return math.min(5 * (2 ^ (retry_count - 1)), 300)
end

local function logTransition(event, reason, count, record)
    local fields = {
        operation = "finished_chapter_cleanup",
        event = event,
        reason = reason,
        count = count or 1,
    }
    if record then
        fields.retry_count = record.retry_count
        fields.retry_after = record.retry_after
    end
    SuwayomiDebug.log(fields)
end

local function addReason(reasons, reason)
    reasons[reason] = (reasons[reason] or 0) + 1
end

local function reportPending(self, reasons)
    local rejected = (reasons.unsafe_path or 0) + (reasons.path_mismatch or 0)
    if rejected == 0 then
        self.finished_cleanup_notification_state = nil
        return
    end
    local previous = self.finished_cleanup_notification_state
    self.finished_cleanup_notification_state = rejected
    if previous and rejected <= previous then return end
    self:showMessage(I18n.f("Automatic chapter cleanup paused for %1 unsafe files.", rejected))
end

local function notifyCompatibility(self, error_code)
    if self.finished_cleanup_compatibility_notification == error_code then
        return
    end
    self.finished_cleanup_compatibility_notification = error_code
    self:showMessage(I18n.t(
        "Automatic chapter cleanup is paused because its saved data uses an unsupported version."
    ))
end

function Methods:recordFinishedChapter(entry)
    if cleanupSetting() <= 0 then
        return false, "disabled"
    end
    if type(entry) ~= "table" or entry.read ~= true
        or not validId(entry.manga_id) or not validId(entry.chapter_id)
        or (entry.path ~= nil and (type(entry.path) ~= "string" or entry.path == ""))
    then
        if type(entry) == "table" and entry.read == false and entry.manga_id and entry.chapter_id then
            self:cancelFinishedChapter(entry.manga_id, entry.chapter_id)
        end
        return false, type(entry) == "table" and entry.read == false and "unread" or "invalid_entry"
    end

    local journal, error_code = SuwayomiSettings:loadFinishedChapterCleanupJournal()
    if error_code then
        return false, error_code
    end
    local manga_id = tostring(entry.manga_id)
    local chapter_id = tostring(entry.chapter_id)
    local archive_target = entry.archive_target
    if entry.path and not archive_target and entry.archive_generation then
        local removal = self:getDownloadQueue().manual_deletion
        local current = removal and removal:getTarget(manga_id .. ":" .. chapter_id, entry.path)
        if current and current.generation == entry.archive_generation then archive_target = current end
    end
    removeRecord(journal, manga_id, chapter_id)
    journal.mangas[manga_id] = journal.mangas[manga_id] or { records = {} }
    table.insert(journal.mangas[manga_id].records, {
        chapter_id = chapter_id,
        path = entry.path,
        archive_target = archive_target,
        archive_retired = entry.archive_retired,
        sequence = journal.next_sequence,
        retry_count = 0,
        retry_after = 0,
    })
    journal.next_sequence = journal.next_sequence + 1
    SuwayomiSettings:saveFinishedChapterCleanupJournal(journal)
    self.finished_cleanup_cursor = nil
    self.finished_cleanup_traversal_retry_at = nil
    self.finished_cleanup_traversal_reasons = nil
    self:scheduleFinishedChapterCleanup(0)
    return true
end

function Methods:cancelFinishedChapter(manga_id, chapter_id)
    if manga_id == nil or chapter_id == nil then
        return false
    end
    local journal, error_code = SuwayomiSettings:loadFinishedChapterCleanupJournal()
    if error_code then
        return false
    end
    local removed = removeRecord(journal, tostring(manga_id), tostring(chapter_id))
    if removed then
        SuwayomiSettings:saveFinishedChapterCleanupJournal(journal)
    end
    return removed
end

local function scheduleFinishedChapterCleanup(self, delay_seconds)
    delay_seconds = math.max(0, tonumber(delay_seconds) or 0)
    local deadline = SuwayomiDebug.now() + delay_seconds
    if self.finished_cleanup_scheduled then
        if self.finished_cleanup_scheduled_deadline
            and self.finished_cleanup_scheduled_deadline <= deadline
        then
            return false
        end
        self:cancelFinishedChapterCleanup()
    end
    self.finished_cleanup_scheduled = true
    self.finished_cleanup_scheduled_deadline = deadline
    local generation = self.finished_cleanup_generation or 0
    self.finished_cleanup_scheduled_generation = generation
    UIManager:scheduleIn(delay_seconds, function()
        if generation ~= (self.finished_cleanup_generation or 0) then
            return
        end
        self.finished_cleanup_scheduled = nil
        self.finished_cleanup_scheduled_deadline = nil
        self.finished_cleanup_scheduled_generation = nil
        self:processFinishedChapterCleanup()
    end)
    return true
end

function Methods:scheduleFinishedChapterCleanup(delay_seconds)
    if (tonumber(delay_seconds) or 0) <= 0 then
        self.finished_cleanup_cursor = nil
        self.finished_cleanup_traversal_retry_at = nil
        self.finished_cleanup_traversal_reasons = nil
    end
    return scheduleFinishedChapterCleanup(self, delay_seconds)
end

function Methods:cancelFinishedChapterCleanup()
    local scheduled = self.finished_cleanup_scheduled == true
    self.finished_cleanup_generation = (self.finished_cleanup_generation or 0) + 1
    self.finished_cleanup_scheduled = nil
    self.finished_cleanup_scheduled_deadline = nil
    self.finished_cleanup_scheduled_generation = nil
    return scheduled
end

function Methods:onFinishedCleanupSettingChanged(previous_value, current_value)
    previous_value = tonumber(previous_value) or 0
    current_value = tonumber(current_value) or 0
    if current_value <= 0 then
        self:cancelFinishedChapterCleanup()
        self.finished_cleanup_cursor = nil
        self.finished_cleanup_traversal_retry_at = nil
        self.finished_cleanup_traversal_reasons = nil
        self.finished_cleanup_notification_state = nil
        self.finished_cleanup_retry_reasons = nil
        local _journal, error_code = SuwayomiSettings:loadFinishedChapterCleanupJournal()
        if error_code then
            notifyCompatibility(self, error_code)
            return false
        end
        SuwayomiSettings:clearFinishedChapterCleanupJournal()
        self.finished_cleanup_compatibility_notification = nil
    elseif previous_value <= 0 or current_value < previous_value then
        self.finished_cleanup_cursor = nil
        self.finished_cleanup_traversal_retry_at = nil
        self.finished_cleanup_traversal_reasons = nil
        self:scheduleFinishedChapterCleanup(0)
    end
end

function Methods:onFinishedCleanupDownloadDirectoryChanged()
    self.finished_cleanup_revalidate_blocked = true
    self.finished_cleanup_cursor = nil
    self.finished_cleanup_traversal_retry_at = nil
    self.finished_cleanup_traversal_reasons = nil
    return self:scheduleFinishedChapterCleanup(0)
end

local function newSummary()
    return {
        processed = 0,
        deleted = 0,
        missing = 0,
        cancelled = 0,
        deferred = 0,
        rejected = 0,
        retrying = 0,
        remaining = 0,
    }
end

local function saveJournal(journal)
    return SuwayomiSettings:saveFinishedChapterCleanupJournal(journal)
end

local function rejectCandidate(journal, record, reason, summary, reasons)
    local changed = record.blocked_reason ~= reason
        or record.retry_count ~= 0 or record.retry_after ~= 0
    record.blocked_reason = reason
    record.retry_count = 0
    record.retry_after = 0
    if changed then
        saveJournal(journal)
    end
    summary.rejected = summary.rejected + 1
    addReason(reasons, reason)
    logTransition("rejected", reason, 1)
end

local function retryCandidate(self, journal, manga_id, record, reason, now, summary, reasons)
    local retry_key = manga_id .. "\0" .. record.chapter_id
    self.finished_cleanup_retry_reasons = self.finished_cleanup_retry_reasons or {}
    local previous_reason = self.finished_cleanup_retry_reasons[retry_key]
    if previous_reason and previous_reason ~= reason then
        record.retry_count = 0
        record.retry_after = 0
    end
    record.blocked_reason = nil
    record.retry_count = (tonumber(record.retry_count) or 0) + 1
    record.retry_after = now + retryDelay(record.retry_count)
    self.finished_cleanup_retry_reasons[retry_key] = reason
    saveJournal(journal)
    summary.deferred = summary.deferred + 1
    summary.retrying = summary.retrying + 1
    addReason(reasons, reason)
    logTransition("retry", reason, 1, record)
    return record.retry_after
end

local function clearRetryReason(self, manga_id, chapter_id)
    if self.finished_cleanup_retry_reasons then
        self.finished_cleanup_retry_reasons[manga_id .. "\0" .. chapter_id] = nil
    end
end

local function pruneUnreadRecords(self, journal, ledger, summary)
    -- Retained entries must be revalidated too: server reconciliation does not
    -- run the manual mark-unread callback that cancels journal records.
    local read_chapters = {}
    for _, entry in pairs(ledger) do
        if entry.read == true then
            local manga_id = tostring(entry.manga_id or "")
            read_chapters[manga_id] = read_chapters[manga_id] or {}
            read_chapters[manga_id][tostring(entry.chapter_id or "")] = true
        end
    end
    for manga_id, manga in pairs(journal.mangas) do
        local records = {}
        for _, record in ipairs(manga.records) do
            local chapter_id = record.chapter_id
            if read_chapters[manga_id] and read_chapters[manga_id][chapter_id] then
                records[#records + 1] = record
            else
                clearRetryReason(self, manga_id, chapter_id)
                summary.cancelled = summary.cancelled + 1
            end
        end
        manga.records = records
        if #manga.records == 0 then journal.mangas[manga_id] = nil end
    end
    if summary.cancelled > 0 then
        saveJournal(journal)
        logTransition("converged", "unread", summary.cancelled)
    end
end

local function recordIsAfterCursor(record, cursor)
    if record.sequence ~= cursor.sequence then
        return record.sequence > cursor.sequence
    end
    return record.chapter_id > cursor.chapter_id
end

local function processFinishedChapterCleanup(self, summary)
    local changed_mangas = {}
    if self.finished_cleanup_scheduled then
        self:cancelFinishedChapterCleanup()
    end

    local journal, error_code = SuwayomiSettings:loadFinishedChapterCleanupJournal()
    if error_code then
        summary.compatibility_error = error_code
        self.finished_cleanup_cursor = nil
        self.finished_cleanup_traversal_retry_at = nil
        self.finished_cleanup_traversal_reasons = nil
        notifyCompatibility(self, error_code)
        logTransition("compatibility", error_code, 1)
        return summary
    end
    self.finished_cleanup_compatibility_notification = nil

    local setting = cleanupSetting()
    if setting <= 0 then
        SuwayomiSettings:clearFinishedChapterCleanupJournal()
        self.finished_cleanup_cursor = nil
        self.finished_cleanup_traversal_retry_at = nil
        self.finished_cleanup_traversal_reasons = nil
        return summary
    end

    local ledger = self:loadChapterLedger()
    pruneUnreadRecords(self, journal, ledger, summary)
    local manga_ids = {}
    local total_records = 0
    for manga_id, manga in pairs(journal.mangas or {}) do
        table.insert(manga_ids, manga_id)
        total_records = total_records + #(manga.records or {})
    end
    table.sort(manga_ids)

    local max_candidates = tonumber(self.finished_cleanup_batch_size) or 25
    max_candidates = math.max(1, math.floor(max_candidates))
    if total_records > max_candidates then
        logTransition("bounded", "large_journal", total_records)
    end

    local now = SuwayomiDebug.now()
    local reasons = self.finished_cleanup_traversal_reasons or {}
    local earliest_retry = self.finished_cleanup_traversal_retry_at
    local needs_follow_up = false
    local revalidate_blocked = self.finished_cleanup_revalidate_blocked == true
    local cursor = self.finished_cleanup_cursor
    for _, manga_id in ipairs(manga_ids) do
        local cursor_skips_manga = cursor and (
            manga_id < cursor.manga_id
            or (manga_id == cursor.manga_id and cursor.manga_done == true)
        )
        if not cursor_skips_manga then
        local manga = journal.mangas[manga_id]
        sortRecords(manga.records)
        local candidate_count = math.max(0, #manga.records - (setting - 1))
        local index = 1
        if cursor and cursor.manga_id == manga_id and cursor.manga_done ~= true then
            while index <= candidate_count and not recordIsAfterCursor(manga.records[index], cursor) do
                index = index + 1
            end
        end
        local stop_manga = false
        while index <= candidate_count and not stop_manga do
            if summary.processed >= max_candidates then
                needs_follow_up = true
                break
            end

            local record = manga.records[index]
            self.finished_cleanup_cursor = {
                manga_id = manga_id,
                sequence = record.sequence,
                chapter_id = record.chapter_id,
            }
            summary.processed = summary.processed + 1
            local chapter_id = tostring(record.chapter_id)
            local ledger_entry = findLedgerEntry(ledger, manga_id, chapter_id)
            local archive_exists, archive_error
            if record.path then
                archive_exists, archive_error = self:chapterArchiveExists(record.path)
            end

            if not ledger_entry or ledger_entry.read ~= true then
                table.remove(manga.records, index)
                candidate_count = candidate_count - 1
                summary.cancelled = summary.cancelled + 1
                clearRetryReason(self, manga_id, chapter_id)
                if #manga.records == 0 then
                    journal.mangas[manga_id] = nil
                end
                saveJournal(journal)
                logTransition("converged", "unread", 1)
            elseif not record.path or record.archive_retired then
                -- A completion without a captured file only occupies retention.
                -- Never attach it to a download that appeared after completion.
                table.remove(manga.records, index)
                candidate_count = candidate_count - 1
                clearRetryReason(self, manga_id, chapter_id)
                if #manga.records == 0 then journal.mangas[manga_id] = nil end
                saveJournal(journal)
            elseif type(record.archive_target) ~= "table" or type(record.archive_target.generation) ~= "number" then
                rejectCandidate(journal, record, "unproved_generation", summary, reasons)
                clearRetryReason(self, manga_id, chapter_id)
                index = index + 1
            elseif archive_exists == false and not archive_error then
                if convergeMissingDownload(self, ledger, ledger_entry, manga_id, chapter_id,
                    record.path, changed_mangas, record.archive_target) then
                    table.remove(manga.records, index)
                    candidate_count = candidate_count - 1
                    summary.missing = summary.missing + 1
                    clearRetryReason(self, manga_id, chapter_id)
                    if #manga.records == 0 then journal.mangas[manga_id] = nil end
                    saveJournal(journal)
                    logTransition("converged", "missing", 1)
                else
                    rejectCandidate(journal, record, "unproved_generation", summary, reasons)
                    index = index + 1
                end
            elseif ledger_entry.path and ledger_entry.path ~= record.path then
                rejectCandidate(journal, record, "path_mismatch", summary, reasons)
                clearRetryReason(self, manga_id, chapter_id)
                index = index + 1
            elseif record.blocked_reason == "unsafe_path" and not revalidate_blocked then
                summary.rejected = summary.rejected + 1
                addReason(reasons, "unsafe_path")
                logTransition("paused", "unsafe_path", 1)
                index = index + 1
            elseif record.retry_after > now then
                summary.deferred = summary.deferred + 1
                summary.retrying = summary.retrying + 1
                local retry_key = manga_id .. "\0" .. chapter_id
                local reason = self.finished_cleanup_retry_reasons
                    and self.finished_cleanup_retry_reasons[retry_key] or "retry"
                addReason(reasons, reason)
                earliest_retry = not earliest_retry and record.retry_after
                    or math.min(earliest_retry, record.retry_after)
                stop_manga = true
            else
                local current_path = self:getCurrentReaderDocumentPath()
                local queue_status = self:getDownloadQueue():getStatus(
                    { id = manga_id }, { id = chapter_id, path = record.path }
                )
                local transient_reason
                if archive_error or archive_exists == nil then
                    transient_reason = "stat_failed"
                elseif current_path == record.path then
                    transient_reason = "current_document"
                elseif (queue_status and (queue_status.state == "queued" or queue_status.state == "downloading"))
                    or (self:getDownloadQueue().isChapterBusy
                        and self:getDownloadQueue():isChapterBusy(manga_id .. ":" .. chapter_id)) then
                    transient_reason = queue_status and queue_status.state or "downloading"
                end

                if transient_reason then
                    local retry_after = retryCandidate(
                        self, journal, manga_id, record, transient_reason, now, summary, reasons
                    )
                    earliest_retry = not earliest_retry and retry_after
                        or math.min(earliest_retry, retry_after)
                    stop_manga = true
                else
                    local root = resolvedPath(SuwayomiSettings:loadDownloadDirectory())
                    local candidate = resolvedPath(record.path)
                    local current = current_path and resolvedPath(current_path) or nil
                    if not root or not candidate or (current_path and not current) then
                        local retry_after = retryCandidate(
                            self, journal, manga_id, record, "realpath_failed", now, summary, reasons
                        )
                        earliest_retry = not earliest_retry and retry_after
                            or math.min(earliest_retry, retry_after)
                        stop_manga = true
                    elseif not isStrictDescendant(root, candidate) then
                        rejectCandidate(journal, record, "unsafe_path", summary, reasons)
                        clearRetryReason(self, manga_id, chapter_id)
                        index = index + 1
                    elseif current and current == candidate then
                        local retry_after = retryCandidate(
                            self, journal, manga_id, record, "current_document", now, summary, reasons
                        )
                        earliest_retry = not earliest_retry and retry_after
                            or math.min(earliest_retry, retry_after)
                        stop_manga = true
                    else
                        record.blocked_reason = nil
                        local ok, state = self:deleteChapterFromDeviceWithOptions(
                            { id = manga_id },
                            { id = chapter_id, path = record.path, is_read = true },
                            {
                                ledger = ledger,
                                chapter_path = record.path,
                                retention = true,
                                archive_target = record.archive_target,
                                quiet_active = true,
                                quiet_delete_failed = true,
                                quiet_missing = true,
                                skip_refresh = true,
                            }
                        )
                        if state == "deleted" or state == "missing" or (ok and state == nil) then
                            if state == "missing" then
                                convergeMissingDownload(
                                    self, ledger, ledger_entry, manga_id, chapter_id,
                                    record.path, changed_mangas, record.archive_target
                                )
                                summary.missing = summary.missing + 1
                            else
                                summary.deleted = summary.deleted + 1
                                changed_mangas[manga_id] = true
                            end
                            table.remove(manga.records, index)
                            candidate_count = candidate_count - 1
                            clearRetryReason(self, manga_id, chapter_id)
                            if #manga.records == 0 then
                                journal.mangas[manga_id] = nil
                            end
                            saveJournal(journal)
                            logTransition("converged", state or "deleted", 1)
                        elseif state == "manual_pending" then
                            -- The manual processor owns this generation's removal.
                            summary.deferred = summary.deferred + 1
                            index = index + 1
                        elseif state == "blocked" then
                            rejectCandidate(journal, record, "unproved_generation", summary, reasons)
                            clearRetryReason(self, manga_id, chapter_id)
                            index = index + 1
                        else
                            local is_transient = state == "queued" or state == "downloading"
                                or state == "delete_failed"
                            local reason = is_transient and state or "delete_failed"
                            local retry_after = retryCandidate(
                                self, journal, manga_id, record, reason, now, summary, reasons
                            )
                            earliest_retry = not earliest_retry and retry_after
                                or math.min(earliest_retry, retry_after)
                            stop_manga = true
                        end
                    end
                end
            end
        end
        if needs_follow_up then
            break
        end
        self.finished_cleanup_cursor = { manga_id = manga_id, manga_done = true }
        end
    end

    for _, manga in pairs(journal.mangas or {}) do
        summary.remaining = summary.remaining + #(manga.records or {})
    end
    if needs_follow_up then
        self.finished_cleanup_traversal_retry_at = earliest_retry
        self.finished_cleanup_traversal_reasons = reasons
        scheduleFinishedChapterCleanup(self, 0)
    else
        reportPending(self, reasons)
        self.finished_cleanup_cursor = nil
        self.finished_cleanup_traversal_retry_at = nil
        self.finished_cleanup_traversal_reasons = nil
        self.finished_cleanup_revalidate_blocked = nil
        if earliest_retry then
            scheduleFinishedChapterCleanup(self, math.max(0, earliest_retry - now))
        end
    end
    -- All durable transitions and continuation decisions precede UI callbacks.
    -- The outer processing guard remains set until both views finish refreshing.
    refreshChangedDownloadViews(self, changed_mangas)
    return summary
end

function Methods:processFinishedChapterCleanup()
    local summary = newSummary()
    if self.finished_cleanup_processing then
        summary.busy = true
        return summary
    end
    self.finished_cleanup_processing = true
    local ok, result = pcall(processFinishedChapterCleanup, self, summary)
    self.finished_cleanup_processing = nil
    if not ok then
        error(result)
    end
    return result
end

FinishedChapterCleanup.methods = Methods

return FinishedChapterCleanup
