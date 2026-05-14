-- Boundary: shared file-manager-like list row formatting.
--
-- Responsibility: convert source, manga, chapter, search summary, category, and
-- download-adjacent tables into KOReader Menu row tables for content screens.
-- Owned state: none.
-- Dependencies: gettext and source language label helpers.
-- External data: manga and source tables come from API/client layers and are
-- treated as optional-field records.

local _ = require("gettext")
local SourceLanguages = require("suwayomi/source_languages")

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
    return SourceLanguages.formatLabel(lang)
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

function ListRows.getExtensionTitle(extension)
    if type(extension) ~= "table" then
        return ""
    end
    return extension.name
        or extension.pkg_name
        or extension.apk_name
        or ""
end

function ListRows.getExtensionSubtitle(extension)
    if type(extension) ~= "table" then
        return nil
    end
    local lang = extension.lang
    if lang == nil or lang == "" then
        return nil
    end
    return SourceLanguages.formatLabel(lang)
end

function ListRows.getExtensionMandatory(extension)
    if type(extension) ~= "table" then
        return nil
    end
    local status
    if extension.has_update == true then
        status = _("Update available")
    elseif extension.is_installed ~= true then
        status = _("Not installed")
    elseif extension.is_obsolete == true then
        status = _("Obsolete")
    else
        status = _("Installed")
    end
    local markers = {}
    if extension.is_nsfw == true then
        table.insert(markers, "18+")
    end
    if extension.version_name and extension.version_name ~= "" then
        table.insert(markers, "v" .. tostring(extension.version_name))
    end
    if #markers == 0 then
        return status
    end
    return status .. "\n" .. table.concat(markers, _(" · "))
end

function ListRows.buildExtensionRow(extension, options)
    options = options or {}
    return {
        text = ListRows.getExtensionTitle(extension),
        subtitle = ListRows.getExtensionSubtitle(extension),
        mandatory = ListRows.getExtensionMandatory(extension),
        thumbnail_url = type(extension) == "table" and extension.icon_url or nil,
        thumbnail_placeholder = true,
        extension = extension,
        keep_menu_open = true,
        callback = function()
            if options.on_select then
                options.on_select(extension)
            end
        end,
    }
end

function ListRows.buildSectionHeaderRow(text)
    return {
        text = text,
        title_bold = true,
        select_enabled = false,
        is_section_header = true,
    }
end

local function sectionTitle(label, count)
    return string.format("%s (%d)", label, count)
end

function ListRows.buildExtensionMenuTable(extensions, options)
    options = options or {}
    local menu_table = {}
    local updates = {}
    local installed = {}
    local available = {}

    for _, extension in ipairs(extensions or {}) do
        if type(extension) == "table" and extension.has_update == true then
            table.insert(updates, extension)
        elseif type(extension) == "table" and extension.is_installed == true then
            table.insert(installed, extension)
        else
            table.insert(available, extension)
        end
    end

    local function appendSection(label, group)
        if #group == 0 then
            return
        end
        table.insert(menu_table, ListRows.buildSectionHeaderRow(sectionTitle(label, #group)))
        for _, extension in ipairs(group) do
            table.insert(menu_table, ListRows.buildExtensionRow(extension, options))
        end
    end

    appendSection(_("Updates"), updates)
    appendSection(_("Installed"), installed)
    appendSection(_("Available"), available)

    if #menu_table == 0 and options.empty_text then
        table.insert(menu_table, {
            text = options.empty_text,
            select_enabled = false,
        })
    end

    return menu_table
end

local function formatResultCount(summary)
    local count = 0
    if type(summary) == "table" then
        count = tonumber(summary.result_count) or #(summary.manga or {})
    end
    local suffix = type(summary) == "table" and summary.has_next_page and "+" or ""
    if count == 1 and suffix == "" then
        return _("1 result")
    end
    return tostring(count) .. suffix .. " " .. _("results")
end

function ListRows.getGlobalSearchSummaryMandatory(summary)
    if not summary or summary.status == "empty" then
        return _("No results")
    end
    if summary.status == "searching" then
        return _("searching")
    end
    if summary.status == "timed_out" then
        return _("timed out")
    end
    if summary.status == "canceled" then
        return _("canceled")
    end
    if summary.status == "error" then
        return _("Error")
    end
    return formatResultCount(summary)
end

function ListRows.buildGlobalSearchSummaryRow(summary, options)
    options = options or {}
    local source = type(summary) == "table" and summary.source or nil
    local row = ListRows.buildSourceRow(source, {
        show_language = true,
    })
    if row.text == "" then
        row.text = _("Source")
    end
    row.subtitle = summary and summary.status == "error"
        and tostring(summary.error or _("Unknown error"))
        or row.subtitle
    row.mandatory = ListRows.getGlobalSearchSummaryMandatory(summary)
    row.summary = summary
    row.callback = function()
        if summary
            and (summary.status == "ok" or summary.status == "pageable_empty")
            and options.on_select
        then
            options.on_select(summary)
        end
    end
    return row
end

function ListRows.buildGlobalSearchSummaryMenuTable(summaries, options)
    local menu_table = {}
    for _, summary in ipairs(summaries or {}) do
        table.insert(menu_table, ListRows.buildGlobalSearchSummaryRow(summary, options))
    end
    return menu_table
end

function ListRows.getLibraryCategoryTitle(category)
    if type(category) ~= "table" then
        return ""
    end
    return category.name or (category.id ~= nil and tostring(category.id)) or ""
end

function ListRows.getLibraryCategoryMandatory(category)
    if type(category) ~= "table" or category.manga_count == nil then
        return nil
    end
    return tostring(category.manga_count) .. " " .. _("manga")
end

function ListRows.buildLibraryCategoryRow(category, options)
    options = options or {}
    return {
        text = ListRows.getLibraryCategoryTitle(category),
        mandatory = ListRows.getLibraryCategoryMandatory(category),
        category = category,
        callback = function()
            if options.on_select then
                options.on_select(category)
            end
        end,
    }
end

function ListRows.buildLibraryCategoryMenuTable(categories, options)
    local menu_table = {}
    for _, category in ipairs(categories or {}) do
        table.insert(menu_table, ListRows.buildLibraryCategoryRow(category, options))
    end
    return menu_table
end

function ListRows.getChapterTitle(chapter)
    if type(chapter) ~= "table" then
        return ""
    end
    return chapter.menu_text or chapter.name or (chapter.id ~= nil and tostring(chapter.id)) or ""
end

function ListRows.getChapterSubtitle(chapter)
    if type(chapter) ~= "table" then
        return nil
    end
    if chapter.scanlator == nil or chapter.scanlator == "" then
        return nil
    end
    return tostring(chapter.scanlator)
end

function ListRows.getChapterMandatory(chapter)
    if type(chapter) ~= "table" then
        return nil
    end
    return chapter.menu_status
end

function ListRows.buildChapterRow(chapter, options)
    options = options or {}
    return {
        text = ListRows.getChapterTitle(chapter),
        subtitle = ListRows.getChapterSubtitle(chapter),
        mandatory = ListRows.getChapterMandatory(chapter),
        chapter = chapter,
        callback = function()
            if options.on_select then
                options.on_select(chapter)
            end
        end,
    }
end

function ListRows.buildChapterMenuTable(chapters, options)
    local menu_table = {}
    for _, chapter in ipairs(chapters or {}) do
        table.insert(menu_table, ListRows.buildChapterRow(chapter, options))
    end
    return menu_table
end

return ListRows
