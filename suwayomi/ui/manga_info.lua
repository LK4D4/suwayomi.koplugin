-- Boundary: manga information dialog UI.
--
-- Responsibility: format already-loaded manga metadata and show read-only KOReader dialog content.
-- Owned state: none; KOReader dialog/widgets own runtime state.
-- Dependencies: KOReader container/image/text widgets, thumbnail cache, UIManager, gettext.
-- External data: manga fields come from server responses and are displayed only after nil/empty checks.

local _ = require("gettext")

local MangaInfo = {}
local POSTER_CACHE_OPTIONS = {
    variant = "poster",
    width = 240,
    height = 360,
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
        ImageWidget = require("ui/widget/imagewidget"),
        InputContainer = require("ui/widget/container/inputcontainer"),
        LineWidget = require("ui/widget/linewidget"),
        MovableContainer = require("ui/widget/container/movablecontainer"),
        ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget"),
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

function MangaInfo.buildMetadataText(manga)
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
    return table.concat(lines, "\n")
end

function MangaInfo.buildDescriptionText(manga)
    return cleanText(manga and manga.description) or _("No description available.")
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
        return protect("<p>")
    end):gsub("<%s*/%s*[Pp]%s*>", function()
        return protect("</p>")
    end)

    text = escapeHtml(text:gsub("<[^>]*>", "")):gsub("\n", "<br/>")
    return (text:gsub("\001(%d+)\002", function(index)
        return tokens[tonumber(index)] or ""
    end))
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

local function findCachedPosterPath(manga, options)
    manga = manga or {}
    if not cleanText(manga.thumbnail_url) then
        return nil
    end
    local ok_cache, ThumbnailCache = pcall(require, "suwayomi/ui/thumbnail_cache")
    if not ok_cache then
        return nil
    end
    return ThumbnailCache.find(thumbnailCredentials(options), manga.thumbnail_url, POSTER_CACHE_OPTIONS)
end

local function findPosterPath(manga, options)
    manga = manga or {}
    if cleanText(options and options.poster_path) then
        return options.poster_path
    end
    local poster_path = findCachedPosterPath(manga, options)
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
    for _, child in ipairs(widget) do
        bindDialog(child, dialog)
    end
end

local function buildPosterWidget(modules, manga, options, width, height)
    local poster_path = findPosterPath(manga, options)
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
                text = (options and options.poster_loading) and _("Loading...") or _("No poster"),
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
    return manga and (manga.title or tostring(manga.id)) or _("Manga information")
end

local function lineThickness(Size)
    return (Size.line and (Size.line.thick or Size.line.medium)) or 3
end

function MangaInfo.buildContentWidget(manga, options, layout)
    local modules = requireWidgetModules()
    local Screen = modules.Screen
    layout = layout or {}
    local dialog_width = layout.width or math.floor(math.min(screenWidth(Screen), screenHeight(Screen)) * 0.84)
    local gap = scale(Screen, 12)
    local poster_width = math.floor(dialog_width * 0.34)
    local poster_height = math.floor(poster_width * 1.45)
    local text_width = dialog_width - poster_width - gap
    local description_height = math.max(
        scale(Screen, 180),
        (layout.height or math.floor(screenHeight(Screen) * 0.75)) - poster_height - modules.Size.padding.default
    )

    local poster = buildPosterWidget(modules, manga, options, poster_width, poster_height)
    local metadata = modules.TextBoxWidget:new{
        text = MangaInfo.buildMetadataText(manga),
        width = text_width,
        height = poster_height,
        face = modules.Font:getFace("infofont"),
        alignment = "left",
        auto_para_direction = true,
    }
    local top = modules.HorizontalGroup:new{
        align = "top",
        poster,
        modules.HorizontalSpan:new{ width = gap },
        metadata,
    }
    local description = modules.ScrollHtmlWidget:new{
        html_body = MangaInfo.buildDescriptionHtml(manga),
        css = DESCRIPTION_CSS,
        width = dialog_width,
        height = description_height,
        default_font_size = scale(Screen, 28),
        html_link_tapped_callback = function(link)
            openLink(modules.Device, link)
        end,
    }
    description.manga_info_scroll_html = true
    return modules.VerticalGroup:new{
        top,
        modules.VerticalSpan:new{ width = modules.Size.padding.default },
        description,
    }
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

local function buildDialog(modules, manga, options)
    local Screen = modules.Screen
    local screen_width = screenWidth(Screen)
    local screen_height = screenHeight(Screen)
    local dialog_width = math.floor(math.min(screen_width, screen_height) * 0.92)
    local dialog_height = math.floor(screen_height * 0.82)
    local content_padding = modules.Size.padding.default
    local button_padding = modules.Size.padding.default

    local Dialog = modules.InputContainer:extend{
        manga = manga,
        options = options,
        width = dialog_width,
        height = dialog_height,
    }

    function Dialog:onClose()
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
        if self.poster_job or findCachedPosterPath(self.manga, self.options) or cleanText(self.options and self.options.poster_path) then
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
                ThumbnailWorker:run(credentials, thumbnail_url, path, POSTER_CACHE_OPTIONS)
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
            on_error = function(_, failed_active)
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

    function Dialog:init()
        self.region = modules.Geom:new{
            x = 0,
            y = 0,
            w = screen_width,
            h = screen_height,
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

        local title_separator = modules.LineWidget:new{
            background = modules.Blitbuffer.COLOR_GRAY or modules.Blitbuffer.COLOR_BLACK,
            dimen = modules.Geom:new{
                w = self.width,
                h = lineThickness(modules.Size),
            },
        }

        local button_table = modules.ButtonTable:new{
            width = self.width - 2 * button_padding,
            buttons = {
                {
                    {
                        text = _("Close"),
                        callback = function()
                            self:onClose()
                        end,
                    },
                },
            },
            zero_sep = true,
            show_parent = self,
        }

        local content_height = self.height
            - widgetHeight(titlebar)
            - lineThickness(modules.Size)
            - widgetHeight(button_table)
            - 2 * content_padding
        self.content_layout = {
            width = self.width - 2 * content_padding,
            height = math.max(scale(Screen, 220), content_height),
        }
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
                h = content_height + 2 * content_padding,
            },
            self.content_frame,
        }

        self.frame = modules.FrameContainer:new{
            radius = modules.Size.radius and modules.Size.radius.window or nil,
            padding = 0,
            margin = 0,
            background = modules.Blitbuffer.COLOR_WHITE,
            modules.VerticalGroup:new{
                titlebar,
                title_separator,
                body,
                modules.CenterContainer:new{
                    dimen = modules.Geom:new{
                        w = self.width,
                        h = widgetHeight(button_table),
                    },
                    button_table,
                },
            },
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
