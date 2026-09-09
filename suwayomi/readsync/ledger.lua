-- Boundary: ReadSyncLedger.
--
-- Responsibility: Owns read-ledger keys, upserts, pending batches, and downloaded chapter reconciliation.
-- Owned state: Works on settings-backed ledger tables and keeps network sync decisions explicit for the controller.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and gettext are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local SuwayomiSettings = require("suwayomi/settings")

local ReadSyncLedger = {}
ReadSyncLedger.__index = ReadSyncLedger

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function ReadSyncLedger:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local read_fields = {
    manga_id = true, manga_title = true, chapter_id = true, chapter_name = true,
    read = true, path = true, pending_read_sync = true, pending_read_state = true,
}

local function hasUnrelatedFields(entry)
    for key in pairs(entry or {}) do
        if not read_fields[key] then return true end
    end
    return false
end

function Methods:loadChapterLedger()
    if not SuwayomiSettings.loadChapterLedger then
        return {}
    end
    return SuwayomiSettings:loadChapterLedger() or {}
end


function Methods:saveChapterLedger(ledger)
    return self:getDownloadQueue().refill:commitLedger(ledger or {})
end


function Methods:upsertChapterLedgerEntryInLedger(ledger, manga, chapter, updates)
    ledger = ledger or {}
    local key = self:getChapterLedgerKey(manga, chapter)
    local existing = ledger[key] or {}

    local entry = {}
    for key_name, value in pairs(existing) do entry[key_name] = value end
    entry.manga_id = tostring(manga.id or existing.manga_id or "")
    entry.manga_title = manga.title or existing.manga_title
    entry.chapter_id = tostring(chapter.id or existing.chapter_id or "")
    entry.chapter_name = chapter.name or existing.chapter_name
    entry.read = existing.read == true
    entry.pending_read_sync = existing.pending_read_sync == true or nil

    for update_key, value in pairs(updates or {}) do
        entry[update_key] = value
    end

    ledger[key] = entry
    return entry
end


function Methods:upsertChapterLedgerEntry(manga, chapter, updates)
    local ledger = self:loadChapterLedger()
    local entry = self:upsertChapterLedgerEntryInLedger(ledger, manga, chapter, updates)
    local saved, err = self:saveChapterLedger(ledger)
    if not saved then return nil, err end
    return entry
end


function Methods:getChapterLedgerKey(manga, chapter)
    return self:getChapterDownloadKey(manga, chapter)
end


function Methods:mergeChaptersWithReadLedger(manga, chapters)
    local ledger = self:loadChapterLedger()
    local changed = false
    local merged = {}

    for _, chapter in ipairs(chapters or {}) do
        local item = {}
        for key, value in pairs(chapter) do
            item[key] = value
        end

        local key = self:getChapterLedgerKey(manga, item)
        local entry = ledger[key]
        local suwayomi_is_read = item.is_read == true
        local pending_read_state
        if entry and entry.pending_read_sync == true then
            if entry.pending_read_state ~= nil then
                pending_read_state = entry.pending_read_state == true
            else
                pending_read_state = entry.read == true
            end
        end
        local remote_matches_pending = pending_read_state ~= nil and suwayomi_is_read == pending_read_state
        local is_read = pending_read_state
        if remote_matches_pending then
            pending_read_state = nil
            is_read = suwayomi_is_read
        end
        if is_read == nil then
            is_read = suwayomi_is_read
        end
        item._suwayomi_is_read = suwayomi_is_read
        item.is_read = is_read

        if remote_matches_pending then
            if is_read or (entry and entry.path) or hasUnrelatedFields(entry) then
                entry = self:upsertChapterLedgerEntryInLedger(ledger, manga, item, { read = is_read == true })
                entry.pending_read_sync = nil
                entry.pending_read_state = nil
            else
                ledger[key] = nil
            end
            changed = true
        elseif is_read or pending_read_state ~= nil then
            entry = self:upsertChapterLedgerEntryInLedger(ledger, manga, item, { read = is_read == true })
            entry.pending_read_sync = pending_read_state ~= nil and true or nil
            entry.pending_read_state = pending_read_state
            changed = true
        elseif entry and entry.read == true then
            if entry.path or hasUnrelatedFields(entry) then
                entry.read = false
                entry.pending_read_sync = nil
                ledger[key] = entry
            else
                ledger[key] = nil
            end
            changed = true
        end

        table.insert(merged, item)
    end

    if changed then
        local saved, err = self:saveChapterLedger(ledger)
        if not saved then return nil, err end
    end

    return merged
end


function Methods:markCurrentContextChapterReadFromLedger(entry)
    if not self.current_chapter_context or type(entry) ~= "table" or entry.read ~= true then
        return false
    end

    local context = self.current_chapter_context
    local manga = context.manga or {}
    if entry.manga_id and tostring(manga.id or "") ~= tostring(entry.manga_id) then
        return false
    end

    for _, chapter in ipairs(context.chapters or {}) do
        local same_id = entry.chapter_id and tostring(chapter.id or "") == tostring(entry.chapter_id)
        local same_name = entry.chapter_name and tostring(chapter.name or "") == tostring(entry.chapter_name)
        if same_id or same_name then
            chapter.is_read = true
            return true
        end
    end
    return false
end


function Methods:markLedgerEntryRead(entry)
    if not entry or entry.read == true then
        return false
    end

    local ledger = self:loadChapterLedger()
    local key = tostring(entry.manga_id or "") .. ":" .. tostring(entry.chapter_id or "")
    local ledger_entry = ledger[key]
    if not ledger_entry or ledger_entry.read == true then
        return false
    end

    ledger_entry.read = true
    ledger_entry.pending_read_sync = true
    ledger_entry.pending_read_state = true
    local saved_ledger, err = self:saveChapterLedger(ledger)
    if not saved_ledger then return false, nil, err end
    self:markCurrentContextChapterReadFromLedger(ledger_entry)

    self:schedulePendingReadSync()
    return true, saved_ledger[key] or ledger_entry
end


function Methods:hasPendingReadSync(ledger)
    for _, entry in pairs(ledger or {}) do
        if entry.pending_read_sync == true and entry.chapter_id then
            return true
        end
    end
    return false
end


function Methods:buildPendingReadSyncBatch(ledger, max_count)
    local keys = {}
    for key, entry in pairs(ledger or {}) do
        if entry.pending_read_sync == true and entry.chapter_id then
            table.insert(keys, key)
        end
    end
    table.sort(keys)

    local batch = {}
    for _, key in ipairs(keys) do
        if max_count and #batch >= max_count then
            break
        end
        local entry = ledger[key]
        local desired_read_state = entry.pending_read_state
        if desired_read_state == nil then
            desired_read_state = entry.read == true
        end
        table.insert(batch, {
            key = key,
            chapter_id = tostring(entry.chapter_id),
            desired_read_state = desired_read_state == true,
        })
    end
    return batch
end


function Methods:getDesiredReadStateFromLedgerEntry(entry)
    if not entry then
        return nil
    end
    if entry.pending_read_state ~= nil then
        return entry.pending_read_state == true
    end
    return entry.read == true
end


ReadSyncLedger.methods = Methods

return ReadSyncLedger
