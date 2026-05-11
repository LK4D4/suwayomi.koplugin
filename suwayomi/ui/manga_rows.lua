-- Boundary: shared manga menu row formatting.
--
-- Responsibility: convert manga tables into KOReader Menu row tables for
-- Library, Browse, source search, and global-search result screens.
-- Owned state: none.
-- Dependencies: gettext only.
-- External data: manga tables come from API/client layers and are treated as
-- optional-field records.

local _ = require("gettext")

local MangaRows = {}

local function formatChapterCount(count)
    count = tonumber(count)
    if not count then
        return nil
    end
    if count == 0 then
        return nil
    end
    if count == 1 then
        return "1 " .. _("chapter")
    end
    return tostring(count) .. " " .. _("chapters")
end

function MangaRows.getTitle(manga)
    if type(manga) ~= "table" then
        return ""
    end
    if manga.title ~= nil then
        return tostring(manga.title)
    end
    if manga.id ~= nil then
        return tostring(manga.id)
    end
    return ""
end

function MangaRows.getMandatory(manga, options)
    options = options or {}
    local labels = {}
    if options.show_in_library == true and type(manga) == "table" and manga.in_library == true then
        table.insert(labels, _("In Library"))
    end
    if type(manga) == "table" then
        local chapter_count
        if manga.chapter_count_loading == true then
            chapter_count = _("Checking chapters")
        elseif manga.chapter_count_verified == true and tonumber(manga.chapter_count) == 0 then
            chapter_count = "0 " .. _("chapters")
        else
            chapter_count = formatChapterCount(manga.chapter_count)
        end
        if chapter_count then
            table.insert(labels, chapter_count)
        end
    end
    if #labels == 0 then
        return nil
    end
    return table.concat(labels, _(" · "))
end

function MangaRows.getSubtitle(manga)
    if type(manga) ~= "table" or type(manga.source) ~= "table" then
        return nil
    end
    return manga.source.displayName
        or manga.source.display_name
        or manga.source.name
        or manga.source.raw_name
        or manga.source.id
end

function MangaRows.buildRow(manga, options)
    options = options or {}
    return {
        text = MangaRows.getTitle(manga),
        subtitle = MangaRows.getSubtitle(manga),
        mandatory = MangaRows.getMandatory(manga, options),
        thumbnail_url = type(manga) == "table" and manga.thumbnail_url or nil,
        manga = manga,
        callback = function()
            if options.on_select then
                options.on_select(manga)
            end
        end,
    }
end

function MangaRows.buildMenuTable(manga_list, options)
    local menu_table = {}
    for _, manga in ipairs(manga_list or {}) do
        table.insert(menu_table, MangaRows.buildRow(manga, options))
    end
    return menu_table
end

return MangaRows
