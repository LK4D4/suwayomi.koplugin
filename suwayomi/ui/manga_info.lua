-- Boundary: manga information dialog UI.
--
-- Responsibility: format already-loaded manga metadata and show read-only KOReader dialog content.
-- Owned state: none; KOReader dialog/widgets own runtime state.
-- Dependencies: KOReader container/image/text widgets, thumbnail cache, UIManager, suwayomi/i18n.
-- External data: manga fields come from server responses and are displayed only after nil/empty checks.

local I18n = require("suwayomi/i18n")

local MangaInfo = {}
local POSTER_CACHE_OPTIONS = {
    variant = "poster",
    width = 240,
    height = 360,
}
local POSTER_BUCKETS = {
    compact = { variant = "poster", width = 160, height = 240 },
    normal = POSTER_CACHE_OPTIONS,
    large = { variant = "poster", width = 320, height = 480 },
}

local function requireWidgetModules()
    local Device = require("device")
    return {
        Blitbuffer = require("ffi/blitbuffer"),
        ButtonTable = require("ui/widget/buttontable"),
        CenterContainer = require("ui/widget/container/centercontainer"),
        Device = Device,
        Font = require("ui/font"),
        FrameContainer = require("ui/widget/container/framecontainer"),
        Geom = require("ui/geometry"),
        HorizontalGroup = require("ui/widget/horizontalgroup"),
        HorizontalSpan = require("ui/widget/horizontalspan"),
        HtmlBoxWidget = require("ui/widget/htmlboxwidget"),
        ImageWidget = require("ui/widget/imagewidget"),
        InputContainer = require("ui/widget/container/inputcontainer"),
        LineWidget = require("ui/widget/linewidget"),
        MovableContainer = require("ui/widget/container/movablecontainer"),
        ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget"),
        ScrollableContainer = require("ui/widget/container/scrollablecontainer"),
        Size = require("ui/size"),
        TextBoxWidget = require("ui/widget/textboxwidget"),
        TextWidget = require("ui/widget/textwidget"),
        TitleBar = require("ui/widget/titlebar"),
        UIManager = require("ui/uimanager"),
        VerticalGroup = require("ui/widget/verticalgroup"),
        VerticalSpan = require("ui/widget/verticalspan"),
        WidgetContainer = require("ui/widget/container/widgetcontainer"),
        Screen = Device.screen,
    }
end

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
    for _index, value in ipairs(values) do
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

local function formatStatus(status)
    local raw_status = cleanText(status)
    if not raw_status then
        return nil
    end
    local normalized = raw_status:gsub("_", " "):lower()
    if normalized == "ongoing" then
        return I18n.t("Ongoing")
    end
    if normalized == "on hiatus" then
        return I18n.t("On hiatus")
    end
    if normalized == "completed" then
        return I18n.t("Completed")
    end
    if normalized == "unknown" then
        return I18n.t("Unknown")
    end
    return raw_status
end

local function appendField(lines, label, value)
    value = cleanText(value)
    if value then
        table.insert(lines, label .. ": " .. value)
    end
end

function MangaInfo.buildMetadataText(manga)
    manga = manga or {}
    local lines = {}

    appendField(lines, I18n.t("Source"), sourceName(manga.source))
    appendField(lines, I18n.t("Status"), formatStatus(manga.status))
    appendField(lines, I18n.t("Author"), joinList(manga.authors or manga.author))
    appendField(lines, I18n.t("Artist"), joinList(manga.artists or manga.artist))
    appendField(lines, I18n.t("Chapters"), manga.chapter_count)
    appendField(lines, I18n.t("Unread"), manga.unread_count)
    appendField(lines, I18n.t("Downloaded"), manga.download_count)
    if manga.in_library ~= nil then
        appendField(lines, I18n.t("Library"), manga.in_library and I18n.t("In library") or I18n.t("Not in library"))
    end
    appendField(lines, I18n.t("Categories"), joinList(manga.categories))
    appendField(lines, I18n.t("Genres"), joinList(manga.genres or manga.genre))
    appendField(lines, I18n.t("First unread"), chapterName(manga.first_unread_chapter))
    return table.concat(lines, "\n")
end

function MangaInfo.buildPrimaryMetadataText(manga)
    manga = manga or {}
    local lines = {}

    appendField(lines, I18n.t("Source"), sourceName(manga.source))
    appendField(lines, I18n.t("Status"), formatStatus(manga.status))
    appendField(lines, I18n.t("Author"), joinList(manga.authors or manga.author))
    appendField(lines, I18n.t("Artist"), joinList(manga.artists or manga.artist))
    appendField(lines, I18n.t("Chapters"), manga.chapter_count)
    appendField(lines, I18n.t("Unread"), manga.unread_count)
    appendField(lines, I18n.t("Downloaded"), manga.download_count)
    if manga.in_library ~= nil then
        appendField(lines, I18n.t("Library"), manga.in_library and I18n.t("In library") or I18n.t("Not in library"))
    end
    return table.concat(lines, "\n")
end

function MangaInfo.buildDetailsText(manga)
    manga = manga or {}
    local lines = {}

    appendField(lines, I18n.t("Categories"), joinList(manga.categories))
    appendField(lines, I18n.t("Genres"), joinList(manga.genres or manga.genre))
    appendField(lines, I18n.t("First unread"), chapterName(manga.first_unread_chapter))
    return table.concat(lines, "\n")
end

function MangaInfo.buildDescriptionText(manga)
    return cleanText(manga and manga.description) or I18n.t("No description available.")
end

local function escapeHtml(text)
    return tostring(text or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
end

local function escapeAttribute(text)
    return escapeHtml(text):gsub('"', "&quot;")
end

local function isOpenableUrl(url)
    return type(url) == "string"
        and url:match("^https?://") ~= nil
        and url:match("[%z\001-\031%s]") == nil
end

local function stripUnsafeBlocks(text)
    return text
        :gsub("<[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-</[Ss][Cc][Rr][Ii][Pp][Tt]%s*>", "")
        :gsub("<[Ss][Tt][Yy][Ll][Ee][^>]*>.-</[Ss][Tt][Yy][Ll][Ee]%s*>", "")
end

function MangaInfo.buildDescriptionHtml(manga)
    local text = stripUnsafeBlocks(MangaInfo.buildDescriptionText(manga)):gsub("\r\n", "\n"):gsub("\r", "\n")
    local tokens = {}
    local function protect(html)
        table.insert(tokens, html)
        return "\001" .. tostring(#tokens) .. "\002"
    end
    local function protectLink(url, label)
        if not isOpenableUrl(url) then
            return label or url or ""
        end
        return protect(('<a href="%s">%s</a>'):format(escapeAttribute(url), escapeHtml(label or url)))
    end

    local function protectInlineMarkup(line)
        line = line:gsub("%[([^%]]+)%]%((https?://[^%s%)]+)%)", function(label, url)
            return protectLink(url, label)
        end)
        line = line:gsub("^(https?://[^%s<]+)", function(url)
            local trailing = ""
            while url:match("[,%.%;:%)%]]$") do
                trailing = url:sub(-1) .. trailing
                url = url:sub(1, -2)
            end
            return protectLink(url, url) .. trailing
        end)
        line = line:gsub("([%s%(])(https?://[^%s<]+)", function(prefix, url)
            local trailing = ""
            while url:match("[,%.%;:%)%]]$") do
                trailing = url:sub(-1) .. trailing
                url = url:sub(1, -2)
            end
            return prefix .. protectLink(url, url) .. trailing
        end)
        line = line:gsub("%*%*([^%*]-)%*%*", function(value)
            return protect("<strong>" .. escapeHtml(value) .. "</strong>")
        end)
        line = line:gsub("__([^_]-)__", function(value)
            return protect("<strong>" .. escapeHtml(value) .. "</strong>")
        end)
        line = line:gsub("%*([^%*]-)%*", function(value)
            return protect("<em>" .. escapeHtml(value) .. "</em>")
        end)
        line = line:gsub("_([^_]-)_", function(value)
            return protect("<em>" .. escapeHtml(value) .. "</em>")
        end)
        return line
    end

    text = text:gsub("%[([^%]]+)%]%((https?://[^%s%)]+)%)", function(label, url)
        return protectLink(url, label)
    end)
    text = text:gsub("<[Aa]%s+[^>]*[Hh][Rr][Ee][Ff]%s*=%s*\"([^\"]+)\"[^>]*>(.-)</[Aa]%s*>", protectLink)
    text = text:gsub("<[Aa]%s+[^>]*[Hh][Rr][Ee][Ff]%s*=%s*'([^']+)'[^>]*>(.-)</[Aa]%s*>", protectLink)
    text = text:gsub("<[Bb][Rr]%s*/?%s*>", function()
        return protect("<br/>")
    end)
    text = text:gsub("<%s*[Ii]%s*>", function()
        return protect("<i>")
    end):gsub("<%s*/%s*[Ii]%s*>", function()
        return protect("</i>")
    end)
    text = text:gsub("<%s*[Ee][Mm]%s*>", function()
        return protect("<em>")
    end):gsub("<%s*/%s*[Ee][Mm]%s*>", function()
        return protect("</em>")
    end)
    text = text:gsub("<%s*[Bb]%s*>", function()
        return protect("<b>")
    end):gsub("<%s*/%s*[Bb]%s*>", function()
        return protect("</b>")
    end)
    text = text:gsub("<%s*[Ss][Tt][Rr][Oo][Nn][Gg]%s*>", function()
        return protect("<strong>")
    end):gsub("<%s*/%s*[Ss][Tt][Rr][Oo][Nn][Gg]%s*>", function()
        return protect("</strong>")
    end)
    text = text:gsub("<%s*[Pp]%s*>", function()
        return "\n\n"
    end):gsub("<%s*/%s*[Pp]%s*>", function()
        return "\n\n"
    end)

    local html = {}
    local in_list = false
    local function restore(value)
        return (value:gsub("\001(%d+)\002", function(index)
            return tokens[tonumber(index)] or ""
        end))
    end
    local function inline(value)
        return restore(escapeHtml(protectInlineMarkup(value)))
    end
    local function closeList()
        if in_list then
            table.insert(html, "</ul>")
            in_list = false
        end
    end

    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed == "" then
            closeList()
        else
            local heading = trimmed:match("^#+%s+(.+)$")
            local bullet = trimmed:match("^[-%*+]%s+(.+)$")
            if heading then
                closeList()
                table.insert(html, "<h3>" .. inline(heading) .. "</h3>")
            elseif bullet then
                if not in_list then
                    table.insert(html, "<ul>")
                    in_list = true
                end
                table.insert(html, "<li>" .. inline(bullet) .. "</li>")
            else
                closeList()
                table.insert(html, "<p>" .. inline(trimmed) .. "</p>")
            end
        end
    end
    closeList()
    local details = MangaInfo.buildDetailsText(manga)
    if details ~= "" then
        table.insert(html, "<h3>" .. escapeHtml(I18n.t("Details")) .. "</h3>")
        local detail_lines = {}
        for line in (details .. "\n"):gmatch("([^\n]*)\n") do
            table.insert(detail_lines, (escapeHtml(line)))
        end
        table.insert(html, "<p>" .. table.concat(detail_lines, "<br/>") .. "</p>")
    end
    return table.concat(html)
end

function MangaInfo.buildText(manga)
    local metadata = MangaInfo.buildMetadataText(manga)
    local description = MangaInfo.buildDescriptionText(manga)
    if metadata ~= "" then
        return metadata .. "\n\n" .. description
    end
    return description
end

local function scale(Screen, value)
    if Screen and Screen.scaleBySize then
        return Screen:scaleBySize(value)
    end
    return value
end

local function screenWidth(Screen)
    if Screen and Screen.getWidth then
        return Screen:getWidth()
    end
    return 600
end

local function screenHeight(Screen)
    if Screen and Screen.getHeight then
        return Screen:getHeight()
    end
    return 800
end

local function countLines(text)
    if text == nil or text == "" then
        return 0
    end
    local count = select(2, tostring(text):gsub("\n", "\n"))
    return count + 1
end

local function estimateWrappedLineCount(text, width, char_width)
    local chars_per_line = math.max(1, math.floor(width / math.max(1, char_width)))
    local lines = 0
    text = tostring(text or "")
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines = lines + math.max(1, math.ceil(#line / chars_per_line))
    end
    return lines
end

local function copyPosterOptions(options)
    return {
        variant = options.variant,
        width = options.width,
        height = options.height,
    }
end

local function posterCacheOptionsForSlot(width, height)
    if width >= 280 or height >= 420 then
        return copyPosterOptions(POSTER_BUCKETS.large)
    end
    if width <= 180 or height <= 270 then
        return copyPosterOptions(POSTER_BUCKETS.compact)
    end
    return copyPosterOptions(POSTER_BUCKETS.normal)
end

local function computeDialogBounds(modules)
    local Screen = modules.Screen
    local width = screenWidth(Screen)
    local height = screenHeight(Screen)
    local margin = scale(Screen, 12)
    local max_width = scale(Screen, 920)
    local shape_width_cap = width > height and width * 0.96 or math.min(width, height) * 0.92
    local dialog_width = math.floor(math.min(math.max(1, width - 2 * margin), shape_width_cap, max_width))
    local dialog_height = math.floor(math.min(math.max(1, height - 2 * margin), height * 0.86))
    return {
        screen_width = width,
        screen_height = height,
        width = math.max(1, dialog_width),
        height = math.max(1, dialog_height),
    }
end

local function computeContentLayout(modules, manga, bounds, chrome)
    local Screen = modules.Screen
    local padding = modules.Size.padding.default
    local gap = scale(Screen, 12)
    local body_width = math.max(1, bounds.width - 2 * padding)
    local body_height = math.max(1, bounds.height
        - chrome.title_height
        - chrome.separator_height
        - chrome.button_height
        - 2 * padding)
    local metadata_text = MangaInfo.buildPrimaryMetadataText(manga)
    local metadata_lines = countLines(metadata_text)
    local split_poster_width = math.floor(math.min(scale(Screen, 320), math.max(scale(Screen, 180), body_width * 0.34)))
    local split_poster_height = math.floor(split_poster_width * 1.5)
    local split_metadata_width = body_width - split_poster_width - gap
    local split_description_height = body_height - split_poster_height - gap
    local split_metadata_lines = estimateWrappedLineCount(metadata_text, split_metadata_width, scale(Screen, 12))
    local split_metadata_content_height = math.max(scale(Screen, 120), split_metadata_lines * scale(Screen, 24))
    local split_fits = body_width >= scale(Screen, 520)
        and body_height >= scale(Screen, 420)
        and split_metadata_width >= scale(Screen, 220)
        and split_poster_height >= scale(Screen, 240)
        and split_metadata_content_height <= split_poster_height
        and split_description_height >= scale(Screen, 120)

    if split_fits then
        return {
            mode = "split",
            scroll_mode = "description",
            width = bounds.width,
            height = bounds.height,
            body_width = body_width,
            body_height = body_height,
            gap = gap,
            poster_width = split_poster_width,
            poster_height = split_poster_height,
            metadata_width = split_metadata_width,
            metadata_height = split_poster_height,
            metadata_content_height = split_metadata_content_height,
            description_width = body_width,
            description_height = split_description_height,
            poster_cache_options = posterCacheOptionsForSlot(split_poster_width, split_poster_height),
        }
    end

    local stacked_poster_width = math.floor(math.min(scale(Screen, 180), math.max(scale(Screen, 96), body_width * 0.36)))
    local stacked_poster_height = math.floor(stacked_poster_width * 1.5)
    local stacked_metadata_height = math.max(scale(Screen, 72), math.min(scale(Screen, 140), metadata_lines * scale(Screen, 20)))
    local remaining_height = body_height - stacked_poster_height - stacked_metadata_height - 2 * gap
    local stacked_description_height = math.max(scale(Screen, 120), remaining_height)
    return {
        mode = "stacked",
        scroll_mode = "body",
        width = bounds.width,
        height = bounds.height,
        body_width = body_width,
        body_height = body_height,
        gap = gap,
        poster_width = stacked_poster_width,
        poster_height = stacked_poster_height,
        metadata_width = body_width,
        metadata_height = stacked_metadata_height,
        metadata_content_height = stacked_metadata_height,
        description_width = body_width,
        description_height = stacked_description_height,
        poster_cache_options = posterCacheOptionsForSlot(stacked_poster_width, stacked_poster_height),
    }
end

local function thumbnailCredentials(options)
    local credentials = options and options.thumbnail_credentials
    if not credentials then
        local ok_settings, Settings = pcall(require, "suwayomi/settings")
        if ok_settings and Settings and Settings.load then
            credentials = Settings:load()
        end
    end
    return credentials
end

local function findCachedPosterPath(manga, options, cache_options)
    manga = manga or {}
    if not cleanText(manga.thumbnail_url) then
        return nil
    end
    local ok_cache, ThumbnailCache = pcall(require, "suwayomi/ui/thumbnail_cache")
    if not ok_cache then
        return nil
    end
    return ThumbnailCache.find(thumbnailCredentials(options), manga.thumbnail_url, cache_options or POSTER_CACHE_OPTIONS)
end

local function findPosterPath(manga, options, cache_options)
    manga = manga or {}
    if cleanText(options and options.poster_path) then
        return options.poster_path
    end
    local poster_path = findCachedPosterPath(manga, options, cache_options)
    if poster_path then
        return poster_path
    end
    return nil
end

local function loadPosterImage(path)
    if not cleanText(path) then
        return nil
    end
    local ok_cache, ThumbnailCache = pcall(require, "suwayomi/ui/thumbnail_cache")
    if not ok_cache then
        return nil
    end
    if ThumbnailCache.isDecodedPath and ThumbnailCache.isDecodedPath(path) and ThumbnailCache.loadDecoded then
        return ThumbnailCache.loadDecoded(path)
    end
    return nil
end

local function safeNew(factory, options)
    local ok, widget = pcall(function()
        return factory:new(options)
    end)
    if ok then
        return widget
    end
    return nil
end

local function openLink(Device, link)
    if type(link) == "table" then
        link = link.uri
    end
    if not isOpenableUrl(link) then
        return false
    end
    if Device and Device.canOpenLink and not Device:canOpenLink() then
        return false
    end
    if Device and Device.openLink then
        Device:openLink(link)
        return true
    end
    return false
end

local DESCRIPTION_CSS = [[
@page {
  margin: 0;
  font-family: 'Noto Sans';
}
html, body {
  margin: 0;
  padding: 0;
}
body {
  font-family: 'Noto Sans';
  line-height: 1.2;
}
p {
  margin: 0 0 0.6em 0;
}
a {
  text-decoration: underline;
}
]]

local function bindDialog(widget, dialog)
    if widget == nil then
        return
    end
    if widget.manga_info_scroll_html then
        widget.dialog = dialog
        if widget.htmlbox_widget then
            widget.htmlbox_widget.dialog = dialog
        end
    end
    if widget.manga_info_html_box then
        widget.dialog = dialog
    end
    for _index, child in ipairs(widget) do
        bindDialog(child, dialog)
    end
end

local function buildPosterWidget(modules, manga, options, width, height)
    local cache_options = options and options.poster_cache_options
    local poster_path = findPosterPath(manga, options, cache_options)
    local poster_image = loadPosterImage(poster_path)
    local poster
    if poster_image then
        poster = safeNew(modules.ImageWidget, {
            image = poster_image,
            width = width,
            height = height,
            scale_factor = 0,
        })
    end
    if not poster then
        poster = modules.CenterContainer:new{
            dimen = modules.Geom:new{
                w = width,
                h = height,
            },
            modules.TextWidget:new{
                text = (options and options.poster_loading) and I18n.t("Loading...") or I18n.t("No poster"),
                face = modules.Font:getFace("infofont"),
            },
        }
    end
    return modules.FrameContainer:new{
        width = width,
        height = height,
        padding = 0,
        bordersize = modules.Size.border.thin,
        background = modules.Blitbuffer.COLOR_WHITE,
        poster,
    }
end

local function mangaTitle(manga)
    local title = cleanText(manga and manga.title)
    if title then
        return title
    end
    local id = cleanText(manga and manga.id)
    if id then
        return id
    end
    return I18n.t("Manga information")
end

local function lineThickness(Size)
    return (Size.line and (Size.line.thick or Size.line.medium)) or 3
end

function MangaInfo.buildContentWidget(manga, options, layout)
    local modules = requireWidgetModules()
    local Screen = modules.Screen
    layout = layout or {}
    if not layout.poster_width then
        local bounds = computeDialogBounds(modules)
        layout = computeContentLayout(modules, manga, bounds, {
            title_height = 0,
            separator_height = 0,
            button_height = 0,
        })
    end
    local gap = layout.gap or scale(Screen, 12)

    options = options or {}
    options.poster_cache_options = layout.poster_cache_options or POSTER_CACHE_OPTIONS

    local poster = buildPosterWidget(modules, manga, options, layout.poster_width, layout.poster_height)
    local metadata_height = layout.metadata_content_height or layout.metadata_height
    local metadata = modules.TextBoxWidget:new{
        text = MangaInfo.buildPrimaryMetadataText(manga),
        width = layout.metadata_width,
        height = metadata_height,
        face = modules.Font:getFace("infofont"),
        alignment = "left",
        auto_para_direction = true,
    }
    local description_html = MangaInfo.buildDescriptionHtml(manga)
    local description
    if layout.scroll_mode == "body" then
        description = modules.HtmlBoxWidget:new{
            dimen = modules.Geom:new{
                w = layout.description_width,
                h = layout.description_height,
            },
            dialog = options.dialog,
            html_link_tapped_callback = function(link)
                openLink(modules.Device, link)
            end,
        }
        if description.setContent then
            description:setContent(description_html, DESCRIPTION_CSS, scale(Screen, 28))
        end
        if description.getSinglePageHeight then
            local single_page_height = description:getSinglePageHeight()
            if single_page_height and single_page_height > layout.description_height then
                description.dimen.h = math.ceil(single_page_height)
            end
        end
        description.width = layout.description_width
        description.height = description.dimen.h
        description.manga_info_html_box = true
    else
        description = modules.ScrollHtmlWidget:new{
            html_body = description_html,
            css = DESCRIPTION_CSS,
            width = layout.description_width,
            height = layout.description_height,
            default_font_size = scale(Screen, 28),
            html_link_tapped_callback = function(link)
                openLink(modules.Device, link)
            end,
        }
        description.manga_info_scroll_html = true
    end
    local content
    if layout.mode == "stacked" then
        content = modules.ScrollableContainer:new{
            dimen = modules.Geom:new{
                w = layout.body_width,
                h = layout.body_height,
            },
            modules.VerticalGroup:new{
                modules.CenterContainer:new{
                    dimen = modules.Geom:new{
                        w = layout.body_width,
                        h = layout.poster_height,
                    },
                    poster,
                },
                modules.VerticalSpan:new{ width = gap },
                metadata,
                modules.VerticalSpan:new{ width = gap },
                description,
            },
        }
    else
        local top = modules.HorizontalGroup:new{
            align = "top",
            poster,
            modules.HorizontalSpan:new{ width = gap },
            metadata,
        }
        content = modules.VerticalGroup:new{
            top,
            modules.VerticalSpan:new{ width = gap },
            description,
        }
    end
    content.manga_info_layout = layout
    return content
end

local function widgetHeight(widget)
    if not widget then
        return 0
    end
    if widget.getHeight then
        return widget:getHeight()
    end
    if widget.getSize then
        local size = widget:getSize()
        return size and size.h or 0
    end
    return widget.height or 0
end

local function buildActionButtons(dialog)
    local buttons = {}
    local options = dialog.options or {}
    for _index, action in ipairs(options.actions or {}) do
        if action and action.id and action.text then
            table.insert(buttons, {
                text = action.text,
                callback = function()
                    dialog:dismiss()
                    if options.onAction then
                        options.onAction(action)
                    end
                end,
            })
        end
    end
    return buttons
end

local function buildDialog(modules, manga, options)
    local content_padding = modules.Size.padding.default
    local button_padding = modules.Size.padding.default
    local bounds = computeDialogBounds(modules)

    local Dialog = modules.InputContainer:extend{
        manga = manga,
        options = options,
        width = bounds.width,
        height = bounds.height,
    }

    function Dialog:dismiss()
        if self.poster_job then
            local ok_job, SubprocessJob = pcall(require, "suwayomi/subprocess/job")
            if ok_job and SubprocessJob and SubprocessJob.cancel then
                SubprocessJob.cancel(self.poster_job)
            end
            self.poster_job = nil
        end
        modules.UIManager:close(self)
        return true
    end

    function Dialog:onClose()
        return self:dismiss()
    end

    function Dialog:refreshContent()
        if not self.content_frame or not self.content_layout then
            return
        end
        local content = MangaInfo.buildContentWidget(self.manga, self.options, self.content_layout)
        bindDialog(content, self)
        if self.content_frame[1] and self.content_frame[1].free then
            self.content_frame[1]:free()
        end
        self.content_frame[1] = content
        if self.content_frame.resetLayout then
            self.content_frame:resetLayout()
        end
        if self.frame and self.frame.resetLayout then
            self.frame:resetLayout()
        end
        if modules.UIManager.setDirty then
            modules.UIManager:setDirty(self, function()
                return "ui", self.frame and self.frame.dimen or self.region
            end)
        end
    end

    function Dialog:startPosterJob()
        local cache_options = (self.content_layout and self.content_layout.poster_cache_options) or POSTER_CACHE_OPTIONS
        if self.poster_job or findCachedPosterPath(self.manga, self.options, cache_options) or cleanText(self.options and self.options.poster_path) then
            return
        end
        local thumbnail_url = cleanText(self.manga and self.manga.thumbnail_url)
        local credentials = thumbnailCredentials(self.options)
        if not thumbnail_url or not credentials or not cleanText(credentials.server_url) then
            return
        end

        local ok_job, SubprocessJob = pcall(require, "suwayomi/subprocess/job")
        local ok_worker, ThumbnailWorker = pcall(require, "suwayomi/ui/thumbnail_worker")
        local ok_ffi, FFIUtil = pcall(require, "ffi/util")
        if not ok_job or not ok_worker or not ok_ffi then
            return
        end

        local active = SubprocessJob.start({
            active = {
                result_path = SubprocessJob.buildResultPath and SubprocessJob.buildResultPath("manga_info_poster") or nil,
            },
            ffi_util = FFIUtil,
            ui_manager = modules.UIManager,
            poll_interval_seconds = 0.5,
            timeout_seconds = 15,
            run = function(path)
                ThumbnailWorker:run(credentials, thumbnail_url, path, cache_options)
            end,
            read_result = function(path)
                return ThumbnailWorker:readResult(path)
            end,
            on_finish = function(finished_active, result)
                if self.poster_job ~= finished_active then
                    return
                end
                self.poster_job = nil
                self.options = self.options or {}
                self.options.poster_loading = false
                if result and result.ok and cleanText(result.path) then
                    self.options.poster_path = result.path
                end
                self:refreshContent()
            end,
            on_timeout = function(timed_out_active)
                if self.poster_job == timed_out_active then
                    self.poster_job = nil
                    self.options = self.options or {}
                    self.options.poster_loading = false
                    self:refreshContent()
                end
            end,
            on_error = function(_unused, failed_active)
                if self.poster_job == failed_active then
                    self.poster_job = nil
                    self.options = self.options or {}
                    self.options.poster_loading = false
                    self:refreshContent()
                end
            end,
        })
        self.poster_job = active
        if active then
            self.options = self.options or {}
            self.options.poster_loading = true
            self:refreshContent()
        end
    end

    function Dialog:buildFrame()
        local current_bounds = computeDialogBounds(modules)
        self.width = current_bounds.width
        self.height = current_bounds.height
        self.region = modules.Geom:new{
            x = 0,
            y = 0,
            w = current_bounds.screen_width,
            h = current_bounds.screen_height,
        }

        local titlebar = modules.TitleBar:new{
            width = self.width,
            align = "left",
            with_bottom_line = false,
            title = mangaTitle(self.manga),
            title_face = modules.Font:getFace("tfont"),
            title_shrink_font_to_fit = true,
            close_callback = function()
                self:onClose()
            end,
            show_parent = self,
        }
        self.titlebar = titlebar

        local title_separator = modules.LineWidget:new{
            background = modules.Blitbuffer.COLOR_GRAY or modules.Blitbuffer.COLOR_BLACK,
            dimen = modules.Geom:new{
                w = self.width,
                h = lineThickness(modules.Size),
            },
        }

        local action_buttons = buildActionButtons(self)
        local button_table
        if #action_buttons > 0 then
            button_table = modules.ButtonTable:new{
                width = self.width - 2 * button_padding,
                buttons = {
                    action_buttons,
                },
                zero_sep = true,
                show_parent = self,
            }
        end
        self.button_table = button_table

        self.content_layout = computeContentLayout(modules, self.manga, {
            width = self.width,
            height = self.height,
        }, {
            title_height = widgetHeight(titlebar),
            separator_height = lineThickness(modules.Size),
            button_height = widgetHeight(button_table),
        })
        local content = MangaInfo.buildContentWidget(self.manga, self.options, self.content_layout)
        self.content_frame = modules.FrameContainer:new{
            padding = content_padding,
            margin = 0,
            bordersize = 0,
            content,
        }

        local body = modules.CenterContainer:new{
            dimen = modules.Geom:new{
                w = self.width,
                h = self.content_layout.body_height + 2 * content_padding,
            },
            self.content_frame,
        }

        local frame_children = {
            titlebar,
            title_separator,
            body,
        }
        if button_table then
            table.insert(frame_children, modules.CenterContainer:new{
                dimen = modules.Geom:new{
                    w = self.width,
                    h = widgetHeight(button_table),
                },
                button_table,
            })
        end

        self.frame = modules.FrameContainer:new{
            radius = modules.Size.radius and modules.Size.radius.window or nil,
            padding = 0,
            margin = 0,
            background = modules.Blitbuffer.COLOR_WHITE,
            modules.VerticalGroup:new(frame_children),
        }
        self.movable = modules.MovableContainer:new{
            self.frame,
        }
        self[1] = modules.WidgetContainer:new{
            align = "center",
            dimen = self.region,
            self.movable,
        }

        bindDialog(self, self)
    end

    function Dialog:onSetDimensions()
        if self[1] and self[1].free then
            self[1]:free()
        end
        self:buildFrame()
        if modules.UIManager.setDirty then
            modules.UIManager:setDirty(self, function()
                return "ui", self.frame and self.frame.dimen or self.region
            end)
        end
        return true
    end

    function Dialog:init()
        self:buildFrame()
        self:startPosterJob()
    end

    return Dialog:new{}
end

function MangaInfo.show(manga, options)
    local modules = requireWidgetModules()
    local dialog = buildDialog(modules, manga, options)
    modules.UIManager:show(dialog)
    return dialog
end

return MangaInfo
