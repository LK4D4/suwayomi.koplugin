-- Boundary: manga information dialog UI.
--
-- Responsibility: format already-loaded manga metadata and show read-only KOReader text dialog.
-- Owned state: none; TextViewer owns dialog state.
-- Dependencies: KOReader TextViewer, UIManager, gettext.
-- External data: manga fields come from server responses and are displayed only after nil/empty checks.

local _ = require("gettext")

local MangaInfo = {}

local function cleanText(value)
    if value == nil then
        return nil
    end
    local text = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return nil
    end
    return text
end

local function joinList(values)
    if type(values) ~= "table" then
        return cleanText(values)
    end
    local parts = {}
    for _, value in ipairs(values) do
        local text = cleanText(type(value) == "table" and (value.name or value.title or value.id) or value)
        if text then
            table.insert(parts, text)
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, ", ")
end

local function sourceName(source)
    if type(source) ~= "table" then
        return cleanText(source)
    end
    return cleanText(source.displayName or source.display_name or source.name or source.id)
end

local function chapterName(chapter)
    if type(chapter) ~= "table" then
        return cleanText(chapter)
    end
    return cleanText(chapter.name or chapter.title or chapter.id)
end

local function appendField(lines, label, value)
    value = cleanText(value)
    if value then
        table.insert(lines, label .. ": " .. value)
    end
end

function MangaInfo.buildText(manga)
    manga = manga or {}
    local lines = {}

    appendField(lines, _("Source"), sourceName(manga.source))
    appendField(lines, _("Status"), manga.status)
    appendField(lines, _("Author"), joinList(manga.authors or manga.author))
    appendField(lines, _("Artist"), joinList(manga.artists or manga.artist))
    appendField(lines, _("Chapters"), manga.chapter_count)
    appendField(lines, _("Unread"), manga.unread_count)
    appendField(lines, _("Downloaded"), manga.download_count)
    if manga.in_library ~= nil then
        appendField(lines, _("Library"), manga.in_library and _("In library") or _("Not in library"))
    end
    appendField(lines, _("Categories"), joinList(manga.categories))
    appendField(lines, _("Genres"), joinList(manga.genres or manga.genre))
    appendField(lines, _("First unread"), chapterName(manga.first_unread_chapter))
    appendField(lines, _("Latest fetched"), chapterName(manga.latest_fetched_chapter))

    if #lines > 0 then
        table.insert(lines, "")
    end
    table.insert(lines, cleanText(manga.description) or _("No description available."))
    return table.concat(lines, "\n")
end

function MangaInfo.show(manga)
    local TextViewer = require("ui/widget/textviewer")
    local UIManager = require("ui/uimanager")
    local dialog
    dialog = TextViewer:new{
        title = manga and (manga.title or tostring(manga.id)) or _("Manga information"),
        text = MangaInfo.buildText(manga),
        text_type = "book_info",
        show_menu = false,
        buttons_table = {
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return dialog
end

return MangaInfo
