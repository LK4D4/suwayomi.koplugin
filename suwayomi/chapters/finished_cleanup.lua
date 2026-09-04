-- Boundary: FinishedChapterCleanup.
--
-- Responsibility: Persist finished-chapter order and process retention-based local cleanup.
-- Owned state: Per-plugin processing, scheduling, retry, and notification state.
-- Dependencies: Plugin ledger/delete methods, settings, UIManager, filesystem path resolution, debug, and i18n.
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

local function clearMatchingLedgerPath(self, ledger, entry, path)
    if not entry or entry.path ~= path then
        return false
    end
    entry.path = nil
    self:saveChapterLedger(ledger)
    return true
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
    local keys = {}
    local count = 0
    local rejected = 0
    for reason, reason_count in pairs(reasons) do
        table.insert(keys, reason)
        count = count + reason_count
        if reason == "unsafe_path" or reason == "path_mismatch" then
            rejected = rejected + reason_count
        end
    end
    if count == 0 then
        self.finished_cleanup_notification_state = nil
        return
    end
    table.sort(keys)
    local signature = table.concat(keys, ",")
    local previous = self.finished_cleanup_notification_state
    local should_notify = not previous or previous.signature ~= signature or count > previous.count
    self.finished_cleanup_notification_state = { signature = signature, count = count }
    if not should_notify then
        return
    end

    local message
    if rejected > 0 and rejected == count then
        message = I18n.f("Automatic chapter cleanup paused for %1 unsafe files.", count)
    elseif rejected == 0 then
        message = I18n.f("Automatic chapter cleanup will retry %1 files.", count)
    else
        message = I18n.f("Automatic chapter cleanup has %1 pending files.", count)
    end
    self:showMessage(message)
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
        or type(entry.path) ~= "string" or entry.path == ""
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
    removeRecord(journal, manga_id, chapter_id)
    journal.mangas[manga_id] = journal.mangas[manga_id] or { records = {} }
    table.insert(journal.mangas[manga_id].records, {
        chapter_id = chapter_id,
        path = entry.path,
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

local function recordIsAfterCursor(record, cursor)
    if record.sequence ~= cursor.sequence then
        return record.sequence > cursor.sequence
    end
    return record.chapter_id > cursor.chapter_id
end

local function processFinishedChapterCleanup(self, summary)
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
            elseif not self:chapterArchiveExists(record.path) then
                clearMatchingLedgerPath(self, ledger, ledger_entry, record.path)
                table.remove(manga.records, index)
                candidate_count = candidate_count - 1
                summary.missing = summary.missing + 1
                clearRetryReason(self, manga_id, chapter_id)
                if #manga.records == 0 then
                    journal.mangas[manga_id] = nil
                end
                saveJournal(journal)
                logTransition("converged", "missing", 1)
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
                if current_path == record.path then
                    transient_reason = "current_document"
                elseif queue_status and (queue_status.state == "queued" or queue_status.state == "downloading") then
                    transient_reason = queue_status.state
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
                    if not isStrictDescendant(root, candidate) then
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
                                quiet_active = true,
                                quiet_delete_failed = true,
                                quiet_missing = true,
                                skip_refresh = true,
                            }
                        )
                        if state == "deleted" or state == "missing" or (ok and state == nil) then
                            if state == "missing" then
                                clearMatchingLedgerPath(self, ledger, ledger_entry, record.path)
                                summary.missing = summary.missing + 1
                            else
                                self:saveChapterLedger(ledger)
                                summary.deleted = summary.deleted + 1
                            end
                            table.remove(manga.records, index)
                            candidate_count = candidate_count - 1
                            clearRetryReason(self, manga_id, chapter_id)
                            if #manga.records == 0 then
                                journal.mangas[manga_id] = nil
                            end
                            saveJournal(journal)
                            logTransition("converged", state or "deleted", 1)
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
