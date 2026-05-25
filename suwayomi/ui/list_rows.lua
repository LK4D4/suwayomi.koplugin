-- Boundary: shared file-manager-like list row formatting.
--
-- Responsibility: convert source, manga, chapter, search summary, category, and
-- download-adjacent tables into KOReader Menu row tables for content screens.
-- Owned state: none.
-- Dependencies: shared i18n facade and source language label helpers.
-- External data: manga and source tables come from API/client layers and are
-- treated as optional-field records.

local I18n = require("suwayomi/i18n")
local SourceLanguages = require("suwayomi/source_languages")

local ListRows = {}
local MANGA_COVER_THUMBNAIL_WIDTH = 64
local MANGA_COVER_THUMBNAIL_HEIGHT = 96

local function formatChapterCount(count)
    count = tonumber(count)
    if not count then
        return nil
    end
    if count == 0 then
        return nil
    end
    return I18n.count(count, "%1 chapter", "%1 chapters")
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
        table.insert(labels, I18n.t("In Library"))
    end
    if type(manga) == "table" then
        local chapter_count
        if type(manga.chapter_count_error) == "string" and manga.chapter_count_error ~= "" then
            chapter_count = manga.chapter_count_error
        elseif manga.chapter_count_loading == true then
            chapter_count = I18n.t("Checking chapters")
        elseif manga.chapter_count_verified == true and tonumber(manga.chapter_count) == 0 then
            chapter_count = I18n.count(0, "%1 chapter", "%1 chapters")
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
    return I18n.join(labels, " · ")
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
        thumbnail_variant = "manga_cover",
        thumbnail_width = MANGA_COVER_THUMBNAIL_WIDTH,
        thumbnail_height = MANGA_COVER_THUMBNAIL_HEIGHT,
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
    for _index, manga in ipairs(manga_list or {}) do
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
    for _index, source in ipairs(sources or {}) do
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
        status = I18n.t("Update available")
    elseif extension.is_installed ~= true then
        status = I18n.t("Not installed")
    elseif extension.is_obsolete == true then
        status = I18n.t("Obsolete")
    else
        status = I18n.t("Installed")
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
    return status .. "\n" .. I18n.join(markers, " · ")
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
    local show_empty_sections = options.show_empty_sections == true and #(extensions or {}) > 0

    for _index, extension in ipairs(extensions or {}) do
        if type(extension) == "table" and extension.has_update == true then
            table.insert(updates, extension)
        elseif type(extension) == "table" and extension.is_installed == true then
            table.insert(installed, extension)
        else
            table.insert(available, extension)
        end
    end

    local function appendSection(label, group, show_empty)
        if #group == 0 and not show_empty then
            return
        end
        table.insert(menu_table, ListRows.buildSectionHeaderRow(sectionTitle(label, #group)))
        for _index, extension in ipairs(group) do
            table.insert(menu_table, ListRows.buildExtensionRow(extension, options))
        end
    end

    appendSection(I18n.t("Updates"), updates)
    appendSection(I18n.t("Installed"), installed, show_empty_sections)
    appendSection(I18n.t("Available"), available, show_empty_sections)

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
    if suffix == "" then
        return I18n.count(count, "%1 result", "%1 results")
    end
    return I18n.f("%1 results", tostring(count) .. suffix)
end

function ListRows.getGlobalSearchSummaryMandatory(summary)
    if not summary or summary.status == "empty" then
        return I18n.t("No results")
    end
    if summary.status == "searching" then
        return I18n.t("searching")
    end
    if summary.status == "timed_out" then
        return I18n.t("timed out")
    end
    if summary.status == "canceled" then
        return I18n.t("canceled")
    end
    if summary.status == "error" then
        return I18n.t("Error")
    end
    return formatResultCount(summary)
end

local function isGlobalSearchSummaryOpenable(summary)
    return summary
        and (summary.status == "ok" or summary.status == "pageable_empty")
end

local function isGlobalSearchSummaryRetryable(summary)
    return summary and (summary.status == "error" or summary.status == "timed_out")
end

function ListRows.buildGlobalSearchSummaryRow(summary, options)
    options = options or {}
    local source = type(summary) == "table" and summary.source or nil
    local row = ListRows.buildSourceRow(source, {
        show_language = true,
    })
    if row.text == "" then
        row.text = I18n.t("Source")
    end
    row.subtitle = summary and summary.status == "error"
        and tostring(summary.error or I18n.t("Unknown error"))
        or row.subtitle
    if options.on_retry and isGlobalSearchSummaryRetryable(summary) then
        row.mandatory = I18n.t("Retry")
    else
        row.mandatory = ListRows.getGlobalSearchSummaryMandatory(summary)
    end
    row.summary = summary
    row.select_enabled = isGlobalSearchSummaryOpenable(summary)
        or (options.on_retry and isGlobalSearchSummaryRetryable(summary))
        or false
    row.callback = function()
        if options.on_retry and isGlobalSearchSummaryRetryable(summary) then
            options.on_retry(summary)
        elseif row.select_enabled and options.on_select then
            options.on_select(summary)
        end
    end
    return row
end

function ListRows.buildGlobalSearchSummaryMenuTable(summaries, options)
    local menu_table = {}
    for _index, summary in ipairs(summaries or {}) do
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
    return I18n.count(category.manga_count, "%1 manga", "%1 manga")
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
    for _index, category in ipairs(categories or {}) do
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
        title_bold = true,
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
    for _index, chapter in ipairs(chapters or {}) do
        table.insert(menu_table, ListRows.buildChapterRow(chapter, options))
    end
    return menu_table
end

return ListRows
