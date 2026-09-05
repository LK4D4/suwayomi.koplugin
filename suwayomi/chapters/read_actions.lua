-- Boundary: ChapterReadActions.
--
-- Responsibility: Mark chapters read/unread and coordinate metadata, persisted ledger, explicit completion, and read-sync side effects.
-- Owned state: Mutates current chapter context and settings-backed read ledger through plugin methods.
-- Dependencies: Plugin mixin methods and Suwayomi debug timing.
-- External data: Manga/chapter tables may come from API responses or cached UI state and are matched by stable ids.

local SuwayomiDebug = require("suwayomi/debug")

local ChapterReadActions = {}
ChapterReadActions.__index = ChapterReadActions

function ChapterReadActions:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

function Methods:markChapterRead(manga, chapter, options)
    local started_at = SuwayomiDebug.now()
    options = options or {}
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
    if options.ledger then
        entry = self:upsertChapterLedgerEntryInLedger(options.ledger, manga, chapter, updates)
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
    if not options.skip_delete_after_mark_read and self.deleteChaptersAfterManualMarkRead then
        deleted_after_mark_read = self:deleteChaptersAfterManualMarkRead(manga, { chapter }, {
            ledger = options.ledger,
        })
    end
    if downloaded and chapter_path and deleted_after_mark_read == 0 and self.recordFinishedChapter then
        if options.finished_entries then
            -- The bulk caller publishes these only after saving its shared ledger.
            table.insert(options.finished_entries, entry)
        else
            if options.ledger then
                self:saveChapterLedger(options.ledger)
            end
            self:recordFinishedChapter(entry)
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

function Methods:markChapterListRead(manga, chapters)
    local started_at = SuwayomiDebug.now()
    if #chapters == 0 then
        return 0
    end

    local ledger = self:loadChapterLedger()
    local finished_entries = {}
    for _, current in ipairs(chapters) do
        self:markChapterRead(manga, current, {
            ledger = ledger,
            finished_entries = finished_entries,
            skip_refresh = true,
            skip_schedule = true,
            skip_keep_policy = true,
        })
    end

    self:refreshChapterMenu({ ledger = ledger })
    self:saveChapterLedger(ledger)
    -- Publish in list order only after the entire batch is durable.
    for _, entry in ipairs(finished_entries) do
        self:recordFinishedChapter(entry)
    end
    self:schedulePendingReadSync()
    if self.applyMangaKeepNextUnreadDownloadsPolicy then
        self:applyMangaKeepNextUnreadDownloadsPolicy(manga)
    end
    SuwayomiDebug.log({
        operation = "markChapterListRead",
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
