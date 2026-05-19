-- Boundary: manga information dialog UI.
--
-- Responsibility: format already-loaded manga metadata and show read-only KOReader dialog content.
-- Owned state: none; KOReader dialog/widgets own runtime state.
-- Dependencies: KOReader dialog/container/image/text widgets, thumbnail cache, UIManager, gettext.
-- External data: manga fields come from server responses and are displayed only after nil/empty checks.

local _ = require("gettext")

local MangaInfo = {}

local function requireWidgetModules()
    local Device = require("device")
    return {
        Blitbuffer = require("ffi/blitbuffer"),
        ButtonDialog = require("ui/widget/buttondialog"),
        CenterContainer = require("ui/widget/container/centercontainer"),
        Device = Device,
        Font = require("ui/font"),
        FrameContainer = require("ui/widget/container/framecontainer"),
        Geom = require("ui/geometry"),
        HorizontalGroup = require("ui/widget/horizontalgroup"),
        HorizontalSpan = require("ui/widget/horizontalspan"),
        ImageWidget = require("ui/widget/imagewidget"),
        ScrollTextWidget = require("ui/widget/scrolltextwidget"),
        Size = require("ui/size"),
        TextBoxWidget = require("ui/widget/textboxwidget"),
        TextWidget = require("ui/widget/textwidget"),
        UIManager = require("ui/uimanager"),
        VerticalGroup = require("ui/widget/verticalgroup"),
        VerticalSpan = require("ui/widget/verticalspan"),
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

local function findPosterPath(manga, options)
    manga = manga or {}
    if cleanText(manga.thumbnail_path) then
        return manga.thumbnail_path
    end
    if not cleanText(manga.thumbnail_url) then
        return nil
    end
    local ok_cache, ThumbnailCache = pcall(require, "suwayomi/ui/thumbnail_cache")
    if not ok_cache then
        return nil
    end
    local credentials = options and options.thumbnail_credentials
    if not credentials then
        local ok_settings, Settings = pcall(require, "suwayomi/settings")
        if ok_settings and Settings and Settings.load then
            credentials = Settings:load()
        end
    end
    return ThumbnailCache.find(credentials, manga.thumbnail_url)
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

local function bindDialog(widget, dialog)
    if widget == nil then
        return
    end
    if widget.manga_info_scroll_text then
        widget.dialog = dialog
        if widget.text_widget then
            widget.text_widget.dialog = dialog
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
                text = _("No poster"),
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

function MangaInfo.buildContentWidget(manga, options)
    local modules = requireWidgetModules()
    local Screen = modules.Screen
    local dialog_width = math.floor(math.min(screenWidth(Screen), screenHeight(Screen)) * 0.84)
    local gap = scale(Screen, 12)
    local poster_width = math.floor(dialog_width * 0.34)
    local poster_height = math.floor(poster_width * 1.45)
    local text_width = dialog_width - poster_width - gap
    local description_height = math.max(scale(Screen, 140), math.floor(screenHeight(Screen) * 0.24))

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
    local description = modules.ScrollTextWidget:new{
        text = MangaInfo.buildDescriptionText(manga),
        width = dialog_width,
        height = description_height,
        face = modules.Font:getFace("infofont"),
        alignment = "left",
        auto_para_direction = true,
    }
    description.manga_info_scroll_text = true
    return modules.VerticalGroup:new{
        top,
        modules.VerticalSpan:new{ width = modules.Size.padding.default },
        description,
    }
end

function MangaInfo.show(manga, options)
    local modules = requireWidgetModules()
    local dialog
    dialog = modules.ButtonDialog:new{
        title = manga and (manga.title or tostring(manga.id)) or _("Manga information"),
        width_factor = 0.92,
        _added_widgets = {
            MangaInfo.buildContentWidget(manga, options),
        },
        buttons = {
            {
                {
                    text = _("Close"),
                    callback = function()
                        modules.UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    for _, widget in ipairs(dialog._added_widgets or {}) do
        bindDialog(widget, dialog)
    end
    modules.UIManager:show(dialog)
    return dialog
end

return MangaInfo
