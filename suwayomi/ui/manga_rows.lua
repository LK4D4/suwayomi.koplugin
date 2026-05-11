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
    if options.show_in_library == true and type(manga) == "table" and manga.in_library == true then
        return _("In Library")
    end
    return nil
end

function MangaRows.buildRow(manga, options)
    options = options or {}
    return {
        text = MangaRows.getTitle(manga),
        mandatory = MangaRows.getMandatory(manga, options),
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
