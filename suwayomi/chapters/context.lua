-- Boundary: ChapterContext.
--
-- Responsibility: Owns chapter context, selection, filtering, status formatting, and ledger merge helpers.
-- Owned state: State lives on the plugin instance so KOReader callbacks keep the same behavior during the extraction.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and the plugin i18n facade are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local I18n = require("suwayomi/i18n")
local SuwayomiSettings = require("suwayomi/settings")

local ChapterContext = {}
ChapterContext.__index = ChapterContext

local CHAPTER_SCREEN_MANGA_TITLE_MAX_LENGTH = 58
local CHAPTER_SCREEN_SOURCE_TITLE_MAX_LENGTH = 24

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function ChapterContext:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function firstNonEmptyString(...)
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if value ~= nil and value ~= "" then
            return tostring(value)
        end
    end
    return nil
end

local function truncateTitlePart(value, max_length)
    if not value or #value <= max_length then
        return value
    end
    local prefix_char_count = max_length - 3
    local char_count = 0
    local index = 1
    local cutoff_index
    while index <= #value do
        if char_count == prefix_char_count and not cutoff_index then
            cutoff_index = index - 1
        end
        char_count = char_count + 1
        local byte = value:byte(index)
        if byte < 0x80 then
            index = index + 1
        elseif byte < 0xE0 then
            index = index + 2
        elseif byte < 0xF0 then
            index = index + 3
        else
            index = index + 4
        end
    end
    if char_count <= max_length then
        return value
    end
    return value:sub(1, cutoff_index or (max_length - 3)) .. "..."
end

local function getMangaSourceTitle(manga)
    if type(manga) ~= "table" or type(manga.source) ~= "table" then
        return nil
    end
    return firstNonEmptyString(
        manga.source.displayName,
        manga.source.display_name,
        manga.source.name,
        manga.source.raw_name,
        manga.source.id
    )
end

local function formatChapterScreenContext(manga)
    if type(manga) ~= "table" then
        return nil
    end
    local manga_title = truncateTitlePart(
        firstNonEmptyString(manga.title, manga.name, manga.id),
        CHAPTER_SCREEN_MANGA_TITLE_MAX_LENGTH
    )
    local source_title = truncateTitlePart(getMangaSourceTitle(manga), CHAPTER_SCREEN_SOURCE_TITLE_MAX_LENGTH)
    if manga_title and source_title then
        return manga_title .. " - " .. source_title
    end
    return manga_title or source_title
end

function Methods:isCurrentChapterContextForManga(manga)
    if not self.current_chapter_context or not manga then
        return false
    end
    return self:getChapterSelectionKey(self.current_chapter_context.manga, {})
        == self:getChapterSelectionKey(manga, {})
end


function Methods:setCurrentMangaChapterContext(manga, chapters)
    local same_manga = self:isCurrentChapterContextForManga(manga)
    if self.current_chapter_context and not self:isCurrentChapterContextForManga(manga) then
        self:clearChapterSelection(true)
    end
    local filter, present = self:getValidMangaScanlatorFilter(manga, chapters)
    self.current_scanlator_filter = filter
    self.current_chapter_context = {
        manga = manga,
        chapters = chapters or {},
    }
    if same_manga then
        self:pruneChapterSelectionForCurrentContext()
    end
    if filter and not present then
        self:showMessage(I18n.t("No chapters match the saved scanlator filter. Choose another scanlator or All scanlators."))
    end
    return self.current_chapter_context
end


function Methods:ensureMangaChapterContext(manga)
    if self:isCurrentChapterContextForManga(manga)
        and self.current_chapter_context
    then
        return self.current_chapter_context
    end

    if not manga or not manga.id then
        self:showMessage(I18n.t("This manga has no chapters loaded."))
        return nil
    end

    return nil
end

function Methods:isChapterInCurrentContext(manga, chapter)
    if self.suwayomi_host_retired then return false end
    if not self.current_chapter_context then return true end
    if not self:isCurrentChapterContextForManga(manga) then return false end
    for _, current in ipairs(self:getVisibleChapters(self.current_chapter_context.chapters)) do
        if tostring(current.id) == tostring(chapter and chapter.id) then return true end
    end
    return false
end

function Methods:captureChapterActionGuard()
    local context = self.current_chapter_context
    local manga = context and context.manga
    local manga_id = manga and tostring(manga.id or manga.title)
    local revision = self.chapter_request_revision
    local scanlator_filter = self.current_scanlator_filter
    return function()
        return not self.suwayomi_host_retired
            and self.current_chapter_context == context
            and (not context or context.manga == manga)
            and (not manga or tostring(manga.id or manga.title) == manga_id)
            and self.chapter_request_revision == revision
            and self.current_scanlator_filter == scanlator_filter
    end
end


function Methods:getFirstUnreadChapterForManga(manga)
    local context = self:ensureMangaChapterContext(manga)
    if not context then
        return nil
    end

    for _index, chapter in ipairs(self:getVisibleChapters(context.chapters or {})) do
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
    for _index, chapter in ipairs(self:getVisibleChapters(context.chapters or {})) do
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
    for _index, selected in pairs(self.selected_chapters or {}) do
        if selected then
            count = count + 1
        end
    end
    return count
end


function Methods:getSelectedChapters(manga, chapters)
    local selected = {}
    for _index, chapter in ipairs(self:getVisibleChapters(chapters)) do
        if self:isChapterSelected(manga, chapter) then
            table.insert(selected, chapter)
        end
    end
    return selected
end


function Methods:pruneChapterSelectionForCurrentContext()
    if not self.selected_chapters then
        return
    end

    local context = self.current_chapter_context
    local valid_keys = {}
    for _index, chapter in ipairs(self:getVisibleChapters(context and context.chapters or {})) do
        valid_keys[self:getChapterSelectionKey(context and context.manga, chapter)] = true
    end

    for key, selected in pairs(self.selected_chapters) do
        if selected and not valid_keys[key] then
            self.selected_chapters[key] = nil
        end
    end
    self.selection_mode = self:getSelectedChapterCount() > 0
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
    for _index, chapter in ipairs(chapters or {}) do
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
    for _index, scanlator in ipairs(self:getChapterScanlatorChoices(chapters)) do
        if scanlator == filter then
            return filter, true
        end
    end
    return filter, false
end


function Methods:getVisibleChapters(chapters)
    if not self.current_scanlator_filter then
        return chapters or {}
    end

    local visible = {}
    for _index, chapter in ipairs(chapters or {}) do
        if self:getChapterScanlator(chapter) == self.current_scanlator_filter then
            table.insert(visible, chapter)
        end
    end
    return visible
end


function Methods:formatChapterListTitle(manga)
    local selected_count = self:getSelectedChapterCount()
    local title = manga and manga.title or nil
    if self.selection_mode then
        title = I18n.count(selected_count, "%1 selected", "%1 selected")
    elseif title == nil or title == "" then
        title = I18n.t("Chapters")
    end
    if self.current_scanlator_filter then
        title = title .. " - " .. self.current_scanlator_filter
    end
    return title
end

function Methods:formatChapterListScreenTitle(manga)
    local selected_count = self:getSelectedChapterCount()
    if self.selection_mode then
        return I18n.count(selected_count, "%1 selected", "%1 selected")
    end
    local context = formatChapterScreenContext(manga)
    if context then
        return context
    end
    return I18n.t("Chapters")
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
    for _index, chapter in ipairs(chapters) do
        self.selected_chapters[self:getChapterSelectionKey(manga, chapter)] = true
    end
    self.selection_mode = self:getSelectedChapterCount() > 0
    self:refreshChapterMenu()
    return self:getSelectedChapterCount()
end


function Methods:toggleChapterSelection(manga, chapter)
    if not self:isChapterInCurrentContext(manga, chapter) then return false end
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
    if not self:isChapterInCurrentContext(manga, chapter) then return false end
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

    for _index, current in ipairs(self:getVisibleChapters(self.current_chapter_context.chapters)) do
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
        table.insert(parts, I18n.count(
            queued,
            "Queued %1 selected chapter download.",
            "Queued %1 selected chapter downloads."
        ))
    else
        table.insert(parts, I18n.t("No new downloads queued."))
    end

    if skipped > 0 then
        table.insert(parts, I18n.count(
            skipped,
            "Skipped %1 already downloaded or queued.",
            "Skipped %1 already downloaded or queued."
        ))
    end
    return table.concat(parts, " ")
end


function Methods:canQueueChapterDownload(manga, chapter, download_directory)
    if chapter.is_read == true then
        return false
    end

    return self:getDownloadQueue():canEnqueue(manga, chapter,
        download_directory or SuwayomiSettings:loadDownloadDirectory())
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


function Methods:getNextUnreadChaptersForDownload(manga, limit, download_directory)
    local chapters = {}
    local skipped = 0
    local seen = {}
    local queue = self:getDownloadQueue()
    local saved_filter = self:loadMangaScanlatorFilter(manga)
    for _index, chapter in ipairs(self:getVisibleChapters((self.current_chapter_context and self.current_chapter_context.chapters) or {})) do
        local key = queue:getKey(manga, chapter)
        if not seen[key] and (not saved_filter or self:getChapterScanlator(chapter) == saved_filter) then
            seen[key] = true
            if self:canQueueChapterDownload(manga, chapter, download_directory) then
                table.insert(chapters, chapter)
                if #chapters >= limit then
                    break
                end
            elseif chapter.is_read ~= true then
                skipped = skipped + 1
            end
        end
    end
    return chapters, skipped
end


function Methods:getReadChaptersFromCurrentContext()
    local read_chapters = {}
    for _index, chapter in ipairs(self:getVisibleChapters((self.current_chapter_context and self.current_chapter_context.chapters) or {})) do
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
    local saved_filter, err = self:saveMangaScanlatorFilter(
        self.current_chapter_context and self.current_chapter_context.manga,
        scanlator
    )
    if saved_filter == nil and err ~= nil then
        self:showMessage(err or I18n.t("Failed to save scanlator filter."))
        return false, err
    end
    self.current_scanlator_filter = saved_filter
    self:clearChapterSelection(true)
    self:refreshChapterMenu()
    return true
end


function Methods:getScanlatorFilterActions()
    local actions = {
        { id = "scanlator_filter_all", text = I18n.t("All scanlators") },
    }
    local context = self.current_chapter_context
    for _index, scanlator in ipairs(self:getChapterScanlatorChoices(context and context.chapters or {})) do
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
