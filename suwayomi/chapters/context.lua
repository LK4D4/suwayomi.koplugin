-- Boundary: ChapterContext.
--
-- Responsibility: Owns chapter context, selection, filtering, status formatting, and ledger merge helpers.
-- Owned state: State lives on the plugin instance so KOReader callbacks keep the same behavior during the extraction.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and gettext are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local SuwayomiSettings = require("suwayomi/settings")

local ChapterContext = {}
ChapterContext.__index = ChapterContext

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function ChapterContext:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

function Methods:isCurrentChapterContextForManga(manga)
    if not self.current_chapter_context or not manga then
        return false
    end
    return self:getChapterSelectionKey(self.current_chapter_context.manga, {})
        == self:getChapterSelectionKey(manga, {})
end


function Methods:setCurrentMangaChapterContext(manga, chapters)
    if self.current_chapter_context and not self:isCurrentChapterContextForManga(manga) then
        self:clearChapterSelection(true)
    end
    self.current_scanlator_filter = self:getValidMangaScanlatorFilter(manga, chapters)
    self.current_chapter_context = {
        manga = manga,
        chapters = chapters or {},
    }
    return self.current_chapter_context
end


function Methods:ensureMangaChapterContext(manga)
    if self:isCurrentChapterContextForManga(manga)
        and self.current_chapter_context
        and #(self.current_chapter_context.chapters or {}) > 0
    then
        return self.current_chapter_context
    end

    if not manga or not manga.id then
        self:showMessage(_("This manga has no chapters loaded."))
        return nil
    end

    return nil
end


function Methods:getFirstUnreadChapterForManga(manga)
    local context = self:ensureMangaChapterContext(manga)
    if not context then
        return nil
    end

    for _, chapter in ipairs(context.chapters or {}) do
        if chapter.is_read ~= true then
            return chapter
        end
    end
    return nil
end


function Methods:getUnreadChaptersForManga(manga)
    local context = self:ensureMangaChapterContext(manga)
    local chapters = {}
    if not context then
        return chapters
    end
    for _, chapter in ipairs(self:getVisibleChapters(context.chapters or {})) do
        if chapter.is_read ~= true then
            table.insert(chapters, chapter)
        end
    end
    return chapters
end


function Methods:getAllChaptersForManga(manga)
    local context = self:ensureMangaChapterContext(manga)
    if not context then
        return {}
    end
    return self:getVisibleChapters(context.chapters or {})
end


function Methods:getChapterDownloadKey(manga, chapter)
    return self:getDownloadQueue():getKey(manga, chapter)
end


function Methods:getChapterProgressPath(manga, chapter, download_directory)
    return self:getDownloadQueue():buildProgressPath(manga, chapter, download_directory)
end


function Methods:getChapterDownloadStatus(manga, chapter)
    return self:getDownloadQueue():getStatus(manga, chapter)
end


function Methods:setChapterDownloadStatus(manga, chapter, status)
    self:getDownloadQueue():setStatus(manga, chapter, status)
end


function Methods:formatChapterMenuText(chapter, status)
    return self:getDownloadQueue():formatChapterMenuText(chapter, status)
end


function Methods:addChapterSelectionMarker(menu_status)
    if menu_status and menu_status ~= "" then
        return "● " .. menu_status
    end
    return "●"
end


function Methods:stripChapterSelectionStatus(menu_status)
    if not menu_status then
        return nil
    end
    local stripped = tostring(menu_status):gsub("^●%s*", "", 1)
    if stripped == "" then
        return nil
    end
    return stripped
end


function Methods:getChapterSelectionKey(manga, chapter)
    return tostring(manga.id or manga.title or "") .. ":" .. tostring(chapter.id or chapter.name or "")
end


function Methods:isChapterSelected(manga, chapter)
    local manga_id = type(manga) == "table" and (manga.id or manga.title) or manga
    local chapter_id = type(chapter) == "table" and (chapter.id or chapter.name) or chapter
    local key = tostring(manga_id or "") .. ":" .. tostring(chapter_id or "")
    return self.selected_chapters and self.selected_chapters[key] == true
end


function Methods:getSelectedChapterCount()
    local count = 0
    for _, selected in pairs(self.selected_chapters or {}) do
        if selected then
            count = count + 1
        end
    end
    return count
end


function Methods:getSelectedChapters(manga, chapters)
    local selected = {}
    for _, chapter in ipairs(self:getVisibleChapters(chapters)) do
        if self:isChapterSelected(manga, chapter) then
            table.insert(selected, chapter)
        end
    end
    return selected
end


function Methods:getChapterScanlator(chapter)
    local scanlator = chapter and chapter.scanlator
    if scanlator == nil then
        return nil
    end
    scanlator = tostring(scanlator)
    if scanlator == "" then
        return nil
    end
    return scanlator
end


function Methods:getChapterScanlatorChoices(chapters)
    local choices = {}
    local seen = {}
    for _, chapter in ipairs(chapters or {}) do
        local scanlator = self:getChapterScanlator(chapter)
        if scanlator and not seen[scanlator] then
            seen[scanlator] = true
            table.insert(choices, scanlator)
        end
    end
    return choices
end


function Methods:getValidMangaScanlatorFilter(manga, chapters)
    local filter = self:loadMangaScanlatorFilter(manga)
    if not filter then
        return nil
    end
    for _, scanlator in ipairs(self:getChapterScanlatorChoices(chapters)) do
        if scanlator == filter then
            return filter
        end
    end
    return nil
end


function Methods:getVisibleChapters(chapters)
    if not self.current_scanlator_filter then
        return chapters or {}
    end

    local visible = {}
    for _, chapter in ipairs(chapters or {}) do
        if self:getChapterScanlator(chapter) == self.current_scanlator_filter then
            table.insert(visible, chapter)
        end
    end
    return visible
end


function Methods:formatChapterListTitle(manga)
    local selected_count = self:getSelectedChapterCount()
    local title = manga.title
    if self.selection_mode then
        title = T(_("%1 selected"), selected_count)
    end
    if self.current_scanlator_filter then
        title = title .. " - " .. self.current_scanlator_filter
    end
    return title
end


function Methods:clearChapterSelection(skip_refresh)
    self.selected_chapters = {}
    self.selection_mode = false
    if not skip_refresh then
        self:refreshChapterMenu()
    end
end


function Methods:selectAllChapters()
    local context = self.current_chapter_context
    local manga = context and context.manga
    local chapters = self:getVisibleChapters(context and context.chapters or {})

    self.selected_chapters = {}
    for _, chapter in ipairs(chapters) do
        self.selected_chapters[self:getChapterSelectionKey(manga, chapter)] = true
    end
    self.selection_mode = self:getSelectedChapterCount() > 0
    self:refreshChapterMenu()
    return self:getSelectedChapterCount()
end


function Methods:toggleChapterSelection(manga, chapter)
    self.selected_chapters = self.selected_chapters or {}
    local key = self:getChapterSelectionKey(manga, chapter)
    if self.selected_chapters[key] then
        self.selected_chapters[key] = nil
    else
        self.selected_chapters[key] = true
    end
    self.selection_mode = self:getSelectedChapterCount() > 0
    self:refreshChapterMenu()
end


function Methods:handleChapterTap(manga, chapter)
    if self.selection_mode then
        self:toggleChapterSelection(manga, chapter)
        return
    end

    self:showChapterActions(manga, chapter)
end


function Methods:getChaptersBefore(chapter)
    local chapters = {}
    if not self.current_chapter_context or not self.current_chapter_context.chapters then
        return chapters
    end

    for _, current in ipairs(self:getVisibleChapters(self.current_chapter_context.chapters)) do
        if tostring(current.id or "") == tostring(chapter.id or "") then
            return chapters
        end
        table.insert(chapters, current)
    end
    return {}
end


function Methods:pluralize(count, singular, plural)
    if count == 1 then
        return singular
    end
    return plural
end


function Methods:formatBulkDownloadMessage(queued, skipped)
    local parts = {}
    if queued > 0 then
        table.insert(parts, T(
            self:pluralize(queued, _("Queued %1 selected chapter download."), _("Queued %1 selected chapter downloads.")),
            queued
        ))
    else
        table.insert(parts, _("No new downloads queued."))
    end

    if skipped > 0 then
        table.insert(parts, T(
            self:pluralize(skipped, _("Skipped %1 already downloaded or queued."), _("Skipped %1 already downloaded or queued.")),
            skipped
        ))
    end
    return table.concat(parts, " ")
end


function Methods:canQueueChapterDownload(manga, chapter)
    if chapter.is_read == true then
        return false
    end

    local status = self:getDownloadQueue():getStatus(manga, chapter)
    if status and (
        status.state == "queued"
            or status.state == "downloading"
            or status.state == "downloaded"
            or status.state == "skipped"
    ) then
        return false
    end

    local downloaded = self:isChapterDownloaded(manga, chapter)
    return downloaded ~= true
end


function Methods:isChapterDownloadAvailable(manga, chapter)
    local status = self:getDownloadQueue():getStatus(manga, chapter)
    if status and (
        status.state == "queued"
            or status.state == "downloading"
            or status.state == "downloaded"
            or status.state == "skipped"
    ) then
        return true
    end

    local downloaded = self:isChapterDownloaded(manga, chapter)
    return downloaded == true
end


function Methods:getNextUnreadChaptersForDownload(manga, limit)
    local chapters = {}
    for _, chapter in ipairs(self:getVisibleChapters((self.current_chapter_context and self.current_chapter_context.chapters) or {})) do
        if self:canQueueChapterDownload(manga, chapter) then
            table.insert(chapters, chapter)
            if #chapters >= limit then
                break
            end
        end
    end
    return chapters
end


function Methods:getReadChaptersFromCurrentContext()
    local read_chapters = {}
    for _, chapter in ipairs(self:getVisibleChapters((self.current_chapter_context and self.current_chapter_context.chapters) or {})) do
        if chapter.is_read == true then
            table.insert(read_chapters, chapter)
        end
    end
    return read_chapters
end


function Methods:loadMangaScanlatorFilter(manga)
    if SuwayomiSettings.loadMangaScanlatorFilter then
        return SuwayomiSettings:loadMangaScanlatorFilter(manga)
    end
    return nil
end


function Methods:saveMangaScanlatorFilter(manga, scanlator)
    if SuwayomiSettings.saveMangaScanlatorFilter then
        return SuwayomiSettings:saveMangaScanlatorFilter(manga, scanlator)
    end
    return scanlator
end


function Methods:setScanlatorFilter(scanlator)
    self.current_scanlator_filter = self:saveMangaScanlatorFilter(
        self.current_chapter_context and self.current_chapter_context.manga,
        scanlator
    )
    self:clearChapterSelection(true)
    self:refreshChapterMenu()
    return true
end


function Methods:getScanlatorFilterActions()
    local actions = {
        { id = "scanlator_filter_all", text = _("All scanlators") },
    }
    local context = self.current_chapter_context
    for _, scanlator in ipairs(self:getChapterScanlatorChoices(context and context.chapters or {})) do
        table.insert(actions, {
            id = "scanlator_filter_value",
            text = scanlator,
            scanlator = scanlator,
        })
    end
    return actions
end

-- Chapter menus need this read-merged view close to context helpers; ledger remains the source of persistence semantics.
Methods.mergeChaptersWithReadLedger = require("suwayomi/readsync/ledger").methods.mergeChaptersWithReadLedger


ChapterContext.methods = Methods

return ChapterContext
