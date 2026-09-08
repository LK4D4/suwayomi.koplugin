-- Boundary: ChapterReadActions.
-- Owns checked manual read transactions, captured completions, and immediate outcomes.
-- Filesystem removal belongs to the process-owned manual deletion coordinator.

local SuwayomiDebug = require("suwayomi/debug")
local SuwayomiSettings = require("suwayomi/settings")
local I18n = require("suwayomi/i18n")

local ChapterReadActions = {}
ChapterReadActions.__index = ChapterReadActions

function ChapterReadActions:new(deps)
    deps = deps or {}
    return setmetatable({ plugin = deps.plugin }, self)
end

local Methods = {}

local function copyLedger(ledger)
    local copy = {}
    for key, entry in pairs(ledger) do
        if type(entry) == "table" then
            copy[key] = {}
            for field, value in pairs(entry) do copy[key][field] = value end
        else
            copy[key] = entry
        end
    end
    return copy
end

local function copyTarget(target)
    if type(target) ~= "table" then return target end
    local copy = {}
    for key, value in pairs(target) do copy[key] = copyTarget(value) end
    return copy
end

local function updateContext(self, manga, chapter, read)
    local context = self.current_chapter_context
    if not context or not context.manga or tostring(context.manga.id) ~= tostring(manga.id) then return end
    for _, current in ipairs(context.chapters or {}) do
        if tostring(current.id or "") == tostring(chapter.id or "") then
            current.is_read = read
            break
        end
    end
end

local function captureContext(self)
    local previous = {}
    local context = self.current_chapter_context
    for _, chapter in ipairs(context and context.chapters or {}) do
        previous[chapter] = { read = chapter.is_read, pending = chapter.pending_read_sync }
    end
    return previous
end

local function refreshCommitted(self, options, supplied, previous)
    local ledger = self:loadChapterLedger()
    if supplied then
        for key in pairs(supplied) do supplied[key] = nil end
        for key, entry in pairs(ledger) do supplied[key] = entry end
    end
    local context = self.current_chapter_context
    if context and context.manga then
        for _, chapter in ipairs(context.chapters or {}) do
            local entry = ledger[self:getChapterLedgerKey(context.manga, chapter)]
            if type(entry) == "table" then
                chapter.is_read = entry.read == true
                chapter.pending_read_sync = entry.pending_read_sync
            elseif previous and previous[chapter] then
                chapter.is_read = previous[chapter].read
                chapter.pending_read_sync = previous[chapter].pending
            elseif chapter._suwayomi_is_read ~= nil then
                chapter.is_read = chapter._suwayomi_is_read == true
                chapter.pending_read_sync = nil
            end
        end
    end
    if not options.skip_refresh then
        -- A quick rebuild does not reconcile sidecars or write an old ledger over
        -- an uncertain replacement. Only the store may reconcile that uncertainty.
        self:refreshChapterMenu({ quick = true })
    end
end

local function showReadSummary(self, result, options)
    if result.committed and result.busy == 0 and result.blocked == 0 then return end
    local parts = {}
    if not result.committed then
        parts[1] = I18n.t("Could not confirm the read state was saved. No deletion was started. Reopen the chapter list and try again.")
    else
        if result.busy > 0 then
            parts[#parts + 1] = I18n.count(result.busy,
                "%1 download is busy. Mark it read again after it finishes.",
                "%1 downloads are busy. Mark them read again after they finish.")
        end
        if result.blocked > 0 then
            parts[#parts + 1] = I18n.count(result.blocked,
                "Could not delete %1 download safely. Check its status in the chapter list.",
                "Could not delete %1 downloads safely. Check their status in the chapter list.")
        end
    end
    if #parts == 0 then return end
    result.message = table.concat(parts, "\n")
    if not options.quiet then
        self:showMessage(result.message)
        result.summary_shown = true
    end
end

local function readResult(core, outcomes, count)
    local result = { committed = true, marked_read = count, removed = 0, pending = 0, busy = 0, blocked = 0 }
    local snapshot = core:snapshot()
    for key, outcome in pairs(outcomes or {}) do
        local current = snapshot[key]
        if current and outcome.revision and current.revision == outcome.revision then
            outcome = current
        end
        local state = outcome.state
        if state == "removed" then result.removed = result.removed + 1
        elseif state == "pending" then result.pending = result.pending + 1
        elseif state == "busy" then result.busy = result.busy + 1
        elseif state ~= "missing" and state ~= "revoked" then result.blocked = result.blocked + 1 end
    end
    return result
end

local function markRead(self, manga, chapters, options, batch, clear_selection)
    local started_at = SuwayomiDebug.now()
    local core = self:getDownloadQueue().manual_deletion
    local ledger = copyLedger(options.ledger or self:loadChapterLedger())
    local previous = captureContext(self)
    local delete_settings = SuwayomiSettings:loadDeleteChaptersSettings()
    local capture_deletion = delete_settings.delete_after_mark_read == true and not options.skip_delete_after_mark_read
    local root = SuwayomiSettings:loadDownloadDirectory()
    local captures, prepared = {}, {}
    -- Capture every target before metadata or a menu rebuild can change the view.
    for _, chapter in ipairs(chapters) do
        local downloaded, path = self:isChapterDownloaded(manga, chapter)
        local key = self:getChapterLedgerKey(manga, chapter)
        local capture = capture_deletion and core:capture(key, path, root) or nil
        if capture then captures[#captures + 1] = capture end
        prepared[#prepared + 1] = {
            chapter = chapter, downloaded = downloaded, path = path, capture = capture,
            target = downloaded and path and core:getTarget(key, path) or nil,
        }
    end
    for _, item in ipairs(prepared) do
        if item.downloaded and item.path then self:setKoreaderChapterReadState(item.path, true) end
        local entry = self:upsertChapterLedgerEntryInLedger(ledger, manga, item.chapter, {
            path = item.path, read = true, pending_read_sync = true, pending_read_state = true,
        })
        item.completion = {
            manga_id = entry.manga_id, chapter_id = entry.chapter_id, read = true,
            path = item.downloaded and item.path or nil,
            archive_generation = item.target and item.target.generation or nil,
            archive_target = copyTarget(item.target),
        }
        updateContext(self, manga, item.chapter, true)
    end
    if clear_selection then self:clearChapterSelection(true) end
    if batch then
        -- Include reconciliation of visible non-target chapters in the same save.
        self:refreshChapterMenu({ ledger = ledger })
    end
    local ok, err, outcomes = core:commitRead(ledger, captures, {}, { manga })
    if not ok then
        refreshCommitted(self, options, options.ledger, previous)
        local result = { committed = false, error = err, marked_read = 0, removed = 0, pending = 0, busy = 0, blocked = #captures }
        SuwayomiDebug.log({ operation = "manual_mark_read", event = "error",
            code = tostring(err):match("^([%w_]+)"), chapter_count = #chapters,
            elapsed_ms = SuwayomiDebug.elapsedMs(started_at) })
        showReadSummary(self, result, options)
        return 0, result
    end
    for _, item in ipairs(prepared) do
        local completion = item.completion
        if item.capture and item.capture.target and item.capture.target.generation then
            completion.archive_generation = item.capture.target.generation
            completion.archive_target = copyTarget(item.capture.target)
        end
        if self.recordFinishedChapter then
            if options.finished_entries then
                options.finished_entries[#options.finished_entries + 1] = completion
            else
                self:recordFinishedChapter(completion)
            end
        end
    end
    -- A caller-owned completion buffer retains publication ordering: do not run
    -- deletion before the caller has had a chance to publish its snapshots.
    if not options.finished_entries then
        core:process()
        core:wake()
    end
    if not options.skip_refresh then self:refreshChapterMenu() end
    if not options.skip_schedule then self:schedulePendingReadSync() end
    if options.ledger then
        local committed = self:loadChapterLedger()
        for key in pairs(options.ledger) do options.ledger[key] = nil end
        for key, entry in pairs(committed) do options.ledger[key] = entry end
    end
    local result = readResult(core, outcomes, #chapters)
    showReadSummary(self, result, options)
    SuwayomiDebug.log({ operation = "manual_mark_read", event = "end", chapter_count = #chapters,
        removed_count = result.removed, pending_count = result.pending, busy_count = result.busy, blocked_count = result.blocked,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at) })
    return #chapters, result
end

function Methods:markChapterRead(manga, chapter, options)
    local count, result = markRead(self, manga, { chapter }, options or {}, false)
    return count == 1, result
end

local function markUnread(self, manga, chapters, options, batch, clear_selection)
    local core = self:getDownloadQueue().manual_deletion
    local ledger = copyLedger(options.ledger or self:loadChapterLedger())
    local previous = captureContext(self)
    local keys = {}
    for _, chapter in ipairs(chapters) do
        local downloaded, path = self:isChapterDownloaded(manga, chapter)
        if downloaded and path then self:setKoreaderChapterReadState(path, false) end
        self:upsertChapterLedgerEntryInLedger(ledger, manga, chapter, {
            path = path, read = false, pending_read_sync = true, pending_read_state = false,
        })
        keys[#keys + 1] = self:getChapterLedgerKey(manga, chapter)
        updateContext(self, manga, chapter, false)
    end
    if clear_selection then self:clearChapterSelection(true) end
    if batch then self:refreshChapterMenu({ ledger = ledger }) end
    -- Metadata reconciliation must not undo an explicit unread choice.
    for index, chapter in ipairs(chapters) do
        ledger[keys[index]].read = false
        ledger[keys[index]].pending_read_sync = true
        ledger[keys[index]].pending_read_state = false
        updateContext(self, manga, chapter, false)
    end
    local ok, err = core:commitRead(ledger, {}, keys, { manga })
    if not ok then
        refreshCommitted(self, options, options.ledger, previous)
        local result = { committed = false, marked_unread = 0, error = err }
        if not options.quiet then
            self:showMessage(I18n.t("Could not confirm the unread state was saved. Pending deletion may still run. Reopen the chapter list and try again."))
            result.summary_shown = true
        end
        return 0, result
    end
    for _, chapter in ipairs(chapters) do
        if self.cancelFinishedChapter then self:cancelFinishedChapter(manga.id, chapter.id) end
    end
    core:wake()
    refreshCommitted(self, options, options.ledger)
    if not options.skip_schedule then self:schedulePendingReadSync() end
    return #chapters, { committed = true, marked_unread = #chapters }
end

function Methods:markChapterUnread(manga, chapter, options)
    local count, result = markUnread(self, manga, { chapter }, options or {}, false)
    return count == 1, result
end

function Methods:markChapterListUnread(manga, chapters, clear_selection)
    if #chapters == 0 then return 0 end
    return markUnread(self, manga, chapters, {}, true, clear_selection)
end

function Methods:markChapterListRead(manga, chapters)
    if #chapters == 0 then return 0 end
    return markRead(self, manga, chapters, {}, true)
end

function Methods:markSelectedChaptersRead()
    if not self.current_chapter_context then return 0 end
    local manga = self.current_chapter_context.manga
    local chapters = self:getSelectedChapters(manga, self.current_chapter_context.chapters)
    if #chapters == 0 then
        self:showMessage(I18n.t("No chapters selected."))
        return 0
    end
    return markRead(self, manga, chapters, {}, true, true)
end

function Methods:markChaptersBeforeRead(manga, chapter)
    return self:markChapterListRead(manga, self:getChaptersBefore(chapter))
end

ChapterReadActions.methods = Methods
return ChapterReadActions
