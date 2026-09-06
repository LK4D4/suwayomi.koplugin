-- Boundary: ChapterReadActions.
--
-- Responsibility: Mark chapters read/unread and coordinate metadata, persisted ledger, explicit completion, and read-sync side effects.
-- Owned state: Owns operation-local manual read ledgers and completion buffers; mutates chapter context through plugin methods.
-- Dependencies: Plugin mixin methods, Suwayomi debug timing, and i18n.
-- External data: Manga/chapter tables may come from API responses or cached UI state and are matched by stable ids.

local SuwayomiDebug = require("suwayomi/debug")
local I18n = require("suwayomi/i18n")

local ChapterReadActions = {}
ChapterReadActions.__index = ChapterReadActions

function ChapterReadActions:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function processChapterRead(self, manga, chapter, ledger, skip_delete_after_mark_read)
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    local metadata_updated = false
    if downloaded and chapter_path then
        metadata_updated = self:setKoreaderChapterReadState(chapter_path, true)
    end
    local updates = {
        path = chapter_path,
        read = true,
        pending_read_sync = true,
        pending_read_state = true,
    }
    local entry
    if ledger then
        entry = self:upsertChapterLedgerEntryInLedger(ledger, manga, chapter, updates)
    else
        entry = self:upsertChapterLedgerEntry(manga, chapter, updates)
    end

    if self.current_chapter_context and self.current_chapter_context.chapters then
        for _, current in ipairs(self.current_chapter_context.chapters) do
            if tostring(current.id or "") == tostring(chapter.id or "") then
                current.is_read = true
                break
            end
        end
    end
    local deleted_after_mark_read = 0
    if not skip_delete_after_mark_read and self.deleteChaptersAfterManualMarkRead then
        deleted_after_mark_read = self:deleteChaptersAfterManualMarkRead(manga, { chapter }, {
            ledger = ledger,
        })
    end
    local completion
    if self.recordFinishedChapter then
        -- Capture eligibility before a later download or menu refresh can change it.
        completion = {
            manga_id = entry.manga_id,
            chapter_id = entry.chapter_id,
            read = entry.read,
            path = downloaded and deleted_after_mark_read == 0 and chapter_path or nil,
        }
    end
    return completion, downloaded, metadata_updated, deleted_after_mark_read
end

function Methods:markChapterRead(manga, chapter, options)
    local started_at = SuwayomiDebug.now()
    options = options or {}
    local completion, downloaded, metadata_updated, deleted_after_mark_read = processChapterRead(
        self, manga, chapter, options.ledger, options.skip_delete_after_mark_read
    )
    if completion then
        if options.finished_entries then
            -- Retain compatibility for callers supplying a completion buffer.
            table.insert(options.finished_entries, completion)
        else
            if options.ledger then
                self:saveChapterLedger(options.ledger)
            end
            self:recordFinishedChapter(completion)
        end
    end
    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    if not options.skip_schedule then
        self:schedulePendingReadSync()
    end
    if not options.skip_keep_policy and self.applyMangaKeepNextUnreadDownloadsPolicy then
        self:applyMangaKeepNextUnreadDownloadsPolicy(manga)
    end
    if not options.skip_refresh or not options.skip_schedule then
        SuwayomiDebug.log({
            operation = "markChapterRead",
            event = "end",
            manga_id = manga and manga.id,
            chapter_id = chapter and chapter.id,
            downloaded = downloaded == true,
            metadata_updated = metadata_updated == true,
            deleted_after_mark_read = deleted_after_mark_read,
            skip_refresh = options.skip_refresh == true,
            skip_schedule = options.skip_schedule == true,
            elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
        })
    end
    return true
end

function Methods:markChapterUnread(manga, chapter, options)
    local started_at = SuwayomiDebug.now()
    options = options or {}
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    local metadata_updated = false
    if downloaded and chapter_path then
        metadata_updated = self:setKoreaderChapterReadState(chapter_path, false)
    end
    local updates = {
        path = chapter_path,
        read = false,
        pending_read_sync = true,
        pending_read_state = false,
    }
    if options.ledger then
        self:upsertChapterLedgerEntryInLedger(options.ledger, manga, chapter, updates)
    else
        self:upsertChapterLedgerEntry(manga, chapter, updates)
    end
    if self.cancelFinishedChapter then
        self:cancelFinishedChapter(manga.id, chapter.id)
    end

    if self.current_chapter_context and self.current_chapter_context.chapters then
        for _, current in ipairs(self.current_chapter_context.chapters) do
            if tostring(current.id or "") == tostring(chapter.id or "") then
                current.is_read = false
                break
            end
        end
    end

    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    if not options.skip_schedule then
        self:schedulePendingReadSync()
    end
    if not options.skip_refresh or not options.skip_schedule then
        SuwayomiDebug.log({
            operation = "markChapterUnread",
            event = "end",
            manga_id = manga and manga.id,
            chapter_id = chapter and chapter.id,
            downloaded = downloaded == true,
            metadata_updated = metadata_updated == true,
            skip_refresh = options.skip_refresh == true,
            skip_schedule = options.skip_schedule == true,
            elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
        })
    end
    return true
end

local function markReadBatch(self, manga, chapters, clear_selection)
    local ledger = self:loadChapterLedger()
    local completions = {}
    for _, chapter in ipairs(chapters) do
        local completion = processChapterRead(self, manga, chapter, ledger)
        if completion then
            completions[#completions + 1] = completion
        end
    end

    if clear_selection then
        self:clearChapterSelection(true)
    end
    -- Menu reconciliation can update visible chapters outside this batch.
    self:refreshChapterMenu({ ledger = ledger })
    self:saveChapterLedger(ledger)
    for _, completion in ipairs(completions) do
        self:recordFinishedChapter(completion)
    end
    self:schedulePendingReadSync()
    if self.applyMangaKeepNextUnreadDownloadsPolicy then
        self:applyMangaKeepNextUnreadDownloadsPolicy(manga)
    end
end

function Methods:markChapterListRead(manga, chapters)
    local started_at = SuwayomiDebug.now()
    if #chapters == 0 then
        return 0
    end

    markReadBatch(self, manga, chapters)
    SuwayomiDebug.log({
        operation = "markChapterListRead",
        event = "end",
        manga_id = manga and manga.id,
        chapter_count = #chapters,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return #chapters
end

function Methods:markSelectedChaptersRead()
    local started_at = SuwayomiDebug.now()
    if not self.current_chapter_context then
        return 0
    end

    local manga = self.current_chapter_context.manga
    local chapters = self:getSelectedChapters(manga, self.current_chapter_context.chapters)
    if #chapters == 0 then
        self:showMessage(I18n.t("No chapters selected."))
        return 0
    end

    markReadBatch(self, manga, chapters, true)
    SuwayomiDebug.log({
        operation = "markSelectedChaptersRead",
        event = "end",
        manga_id = manga and manga.id,
        chapter_count = #chapters,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return #chapters
end


function Methods:markChaptersBeforeRead(manga, chapter)
    return self:markChapterListRead(manga, self:getChaptersBefore(chapter))
end

ChapterReadActions.methods = Methods

return ChapterReadActions
