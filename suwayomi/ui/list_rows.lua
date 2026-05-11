-- Boundary: shared thumbnail list row formatting.
--
-- Responsibility: convert manga and source tables into KOReader Menu row
-- tables for Library, Browse, source search, and global-search result screens.
-- Owned state: none.
-- Dependencies: gettext only.
-- External data: manga and source tables come from API/client layers and are
-- treated as optional-field records.

local _ = require("gettext")

local ListRows = {}

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

function ListRows.getMangaTitle(manga)
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

function ListRows.getMangaMandatory(manga, options)
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

function ListRows.getMangaSubtitle(manga)
    if type(manga) ~= "table" or type(manga.source) ~= "table" then
        return nil
    end
    return manga.source.displayName
        or manga.source.display_name
        or manga.source.name
        or manga.source.raw_name
        or manga.source.id
end

function ListRows.buildMangaRow(manga, options)
    options = options or {}
    return {
        text = ListRows.getMangaTitle(manga),
        subtitle = ListRows.getMangaSubtitle(manga),
        mandatory = ListRows.getMangaMandatory(manga, options),
        thumbnail_url = type(manga) == "table" and manga.thumbnail_url or nil,
        thumbnail_placeholder = true,
        manga = manga,
        callback = function()
            if options.on_select then
                options.on_select(manga)
            end
        end,
    }
end

function ListRows.buildMangaMenuTable(manga_list, options)
    local menu_table = {}
    for _, manga in ipairs(manga_list or {}) do
        table.insert(menu_table, ListRows.buildMangaRow(manga, options))
    end
    return menu_table
end

function ListRows.getSourceTitle(source)
    if type(source) ~= "table" then
        return ""
    end
    return source.display_name
        or source.displayName
        or source.name
        or source.raw_name
        or (source.id ~= nil and tostring(source.id))
        or ""
end

function ListRows.getSourceSubtitle(source, options)
    options = options or {}
    if options.show_language == false or type(source) ~= "table" then
        return nil
    end
    local lang = source.lang
    if lang == nil or lang == "" or lang == "localsourcelang" then
        return nil
    end
    return string.upper(tostring(lang))
end

function ListRows.getSourceMandatory(source)
    if type(source) == "table" and source.is_nsfw == true then
        return "18+"
    end
    return nil
end

function ListRows.buildSourceRow(source, options)
    options = options or {}
    return {
        text = ListRows.getSourceTitle(source),
        subtitle = ListRows.getSourceSubtitle(source, options),
        mandatory = ListRows.getSourceMandatory(source),
        thumbnail_url = type(source) == "table" and source.icon_url or nil,
        thumbnail_placeholder = true,
        source = source,
        callback = function()
            if options.on_select then
                options.on_select(source)
            end
        end,
    }
end

function ListRows.buildSourceMenuTable(sources, options)
    local menu_table = {}
    for _, source in ipairs(sources or {}) do
        table.insert(menu_table, ListRows.buildSourceRow(source, options))
    end
    return menu_table
end

return ListRows
