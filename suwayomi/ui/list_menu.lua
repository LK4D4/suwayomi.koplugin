-- Boundary: file-manager-like shared list menu.
--
-- Responsibility: render source, manga, and chapter rows with optional cached
-- thumbnails while preserving KOReader Menu navigation, title bars, paging
-- rows, and callbacks.
-- Owned state: visible thumbnail download jobs for the menu instance.
-- Dependencies: KOReader Menu/widget primitives, thumbnail cache/worker, and
-- shared menu utilities.
-- External data: titles, status labels, and thumbnail URLs are displayed or
-- fetched only after nil-safe normalization by upstream row builders.

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local FFIUtil = require("ffi/util")
local SubprocessJob = require("suwayomi/subprocess/job")
local ThumbnailCache = require("suwayomi/ui/thumbnail_cache")
local ThumbnailWorker = require("suwayomi/ui/thumbnail_worker")
local menu_utils = require("suwayomi/ui/menu_utils")

local Screen = Device.screen

local ListMenu = {}

local THUMBNAIL_MAX_ACTIVE = 2
local ROW_HEIGHT_BASE = 64
local DEFAULT_OPTIONS = {
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    with_bottom_line = true,
    bottom_line_color = Blitbuffer.COLOR_DARK_GRAY,
    title_face = Font:getFace("tfont"),
    title_shrink_font_to_fit = true,
    subtitle = false,
    items_max_lines = 3,
    multilines_show_more_text = true,
    line_color = Blitbuffer.COLOR_DARK_GRAY,
}
local scale_by_size = Screen and Screen.scaleBySize
    and Screen:scaleBySize(1000000) * (1 / 1000000)
    or 1

local ListMenuItem = InputContainer:extend{
    entry = nil,
    text = nil,
    mandatory = nil,
    dimen = nil,
    menu = nil,
    show_parent = nil,
    line_color = nil,
}

local function scaled(value)
    if Screen and Screen.scaleBySize then
        return Screen:scaleBySize(value)
    end
    return value
end

local function fontFace(name, size)
    return Font:getFace(name, size)
end

local function fontSizeForRow(nominal, max_size, row_height)
    local font_size = math.floor(nominal * row_height * (1 / ROW_HEIGHT_BASE) / scale_by_size)
    if max_size and font_size >= max_size then
        return max_size
    end
    return math.max(1, font_size)
end

local function round(value)
    return math.floor(value + 0.5)
end

local function verticalDefaultSpan()
    return Size.span and Size.span.vertical_default or Size.line.thin
end

local function widgetWidth(widget)
    if not widget then
        return 0
    end
    if widget.getWidth then
        return widget:getWidth()
    end
    if widget.getSize then
        local size = widget:getSize()
        return size and size.w or 0
    end
    return 0
end

local function widgetHeight(widget)
    if not widget then
        return 0
    end
    if widget.getSize then
        local size = widget:getSize()
        return size and size.h or 0
    end
    return 0
end

local function freeWidget(widget)
    if widget and widget.free then
        widget:free()
    end
end

local function textWidth(text, face, bold)
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = face,
        bold = bold,
    }
    local width = widgetWidth(widget)
    freeWidget(widget)
    return width
end

local function textBoxLineHeight(face)
    local widget = TextBoxWidget:new{
        text = "A",
        face = face,
    }
    local height = widgetHeight(widget)
    freeWidget(widget)
    return math.max(1, height)
end

local function fittingTextBox(options)
    local font_size = options.font_size
    local min_font_size = math.min(font_size, math.max(12, font_size - 8))
    local widget

    local function build(size, constrain_height)
        if widget then
            freeWidget(widget)
        end
        widget = TextBoxWidget:new{
            text = options.text,
            face = fontFace(options.font or "cfont", size),
            width = options.width,
            height = constrain_height and options.height or nil,
            height_adjust = constrain_height or nil,
            height_overflow_show_ellipsis = constrain_height or nil,
            alignment = options.alignment,
            bold = options.bold,
            fgcolor = options.fgcolor,
            bgcolor = options.bgcolor,
        }
        return widgetHeight(widget) <= options.height
    end

    if build(font_size, false) then
        return widget
    end
    for size = font_size - 1, min_font_size, -1 do
        if build(size, false) then
            return widget
        end
    end
    build(min_font_size, true)
    return widget
end

local function isSectionHeader(item)
    return type(item) == "table" and item.is_section_header == true
end

local function thumbnailOptionsForItem(item)
    if type(item) ~= "table" then
        return nil
    end
    local width = math.floor(tonumber(item.thumbnail_width) or 0)
    local height = math.floor(tonumber(item.thumbnail_height) or 0)
    local variant = item.thumbnail_variant
    if variant == nil and width < 1 and height < 1 then
        return nil
    end
    local options = {}
    if variant ~= nil then
        options.variant = tostring(variant)
    end
    if width > 0 then
        options.width = width
    end
    if height > 0 then
        options.height = height
    end
    return options
end

local function thumbnailSlotDimensions(item, row_height, fallback_height)
    local options = thumbnailOptionsForItem(item)
    if not options then
        local size = math.max(1, math.min(row_height, fallback_height))
        return size, size
    end

    local height = options.height and scaled(options.height) or row_height
    local width = options.width and scaled(options.width) or height
    return math.max(1, math.min(width, row_height)), math.max(1, math.min(height, row_height))
end

local function preferredItemHeight(item, base_height, normal_height)
    local height = normal_height or base_height
    local options = thumbnailOptionsForItem(item)
    if options and options.height then
        height = math.max(height, scaled(options.height))
    end
    return height
end

local function hasVariableItemHeight(item)
    if isSectionHeader(item) then
        return true
    end
    local options = thumbnailOptionsForItem(item)
    return options and options.height ~= nil
end

local function placeholderText(text)
    text = tostring(text or ""):gsub("^%s+", "")
    if text == "" then
        return "..."
    end
    return "..."
end

local function newImageWidget(options)
    local ok, image = pcall(function()
        return ImageWidget:new(options)
    end)
    return ok and image or nil
end

function ListMenuItem:init()
    self.ges_events = {
        TapSelect = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
        HoldSelect = {
            GestureRange:new{
                ges = "hold",
                range = self.dimen,
            },
        },
    }

    local width = self.dimen.w
    local height = self.dimen.h
    local line_size = Size.line.thin
    local row_dimen = Geom:new{
        w = width,
        h = height,
    }
    self._underline_container = UnderlineContainer:new{
        color = self.line_color,
        linesize = line_size,
        vertical_align = "top",
        padding = 0,
        dimen = row_dimen,
        self:buildRowWidget(width, height - line_size),
    }
    self[1] = self._underline_container
end

function ListMenuItem:buildThumbnail(slot_width, slot_height)
    if not self.entry.thumbnail_placeholder and not self.entry.thumbnail_url and not self.entry.thumbnail_path then
        return HorizontalSpan:new{ width = 0 }
    end

    local border = Size.border.thin
    local image_width = math.max(1, slot_width - 2 * border)
    local image_height = math.max(1, slot_height - 2 * border)
    local image
    if self.entry.thumbnail_path then
        local is_decoded_path = ThumbnailCache.isDecodedPath and ThumbnailCache.isDecodedPath(self.entry.thumbnail_path)
        local decoded_image
        if is_decoded_path and ThumbnailCache.loadDecoded then
            local ok
            ok, decoded_image = pcall(ThumbnailCache.loadDecoded, self.entry.thumbnail_path)
            decoded_image = ok and decoded_image or nil
        end
        if decoded_image then
            image = newImageWidget{
                image = decoded_image,
                width = image_width,
                height = image_height,
                scale_factor = 0,
            }
        end
    end
    if not image then
        image = CenterContainer:new{
            dimen = Geom:new{ w = image_width, h = image_height },
            TextWidget:new{
                text = placeholderText(self.text),
                face = fontFace("cfont", math.max(10, math.floor(math.min(image_width, image_height) / 2))),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        }
    end

    return CenterContainer:new{
        dimen = Geom:new{ w = slot_width, h = slot_height },
        FrameContainer:new{
            width = image_width + 2 * border,
            height = image_height + 2 * border,
            margin = 0,
            padding = 0,
            bordersize = border,
            image,
        },
    }
end

function ListMenuItem:buildRowWidget(width, height)
    if isSectionHeader(self.entry) then
        local horizontal_padding = scaled(12)
        local title_width = math.max(1, width - 2 * horizontal_padding)
        local title = TextBoxWidget:new{
            text = BD.auto(tostring(self.text or "")),
            face = fontFace("cfont", fontSizeForRow(16, 20, self.menu and self.menu._suwayomi_base_item_height or height)),
            width = title_width,
            height = height,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            alignment = "left",
            bold = true,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        return HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = horizontal_padding },
            title,
            HorizontalSpan:new{ width = horizontal_padding },
        }
    end

    local has_thumbnail = self.entry.thumbnail_placeholder or self.entry.thumbnail_url or self.entry.thumbnail_path
    local font_height = self.menu and self.menu._suwayomi_base_item_height or height
    local left_padding = has_thumbnail and 0 or scaled(10)
    local right_padding = scaled(10)
    local thumbnail_width, thumbnail_height = 0, 0
    if has_thumbnail then
        thumbnail_width, thumbnail_height = thumbnailSlotDimensions(self.entry, height, font_height)
    end
    local gap = has_thumbnail and scaled(5) or 0
    local inner_width = width - left_padding - right_padding
    local mandatory_widget
    local mandatory_width = 0

    if self.mandatory then
        mandatory_widget = TextBoxWidget:new{
            text = tostring(self.mandatory),
            face = fontFace("cfont", fontSizeForRow(14, 18, font_height)),
            width = math.floor(inner_width * 0.28),
            alignment = "right",
            height = height,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        mandatory_width = math.min(mandatory_widget:getSize().w, math.floor(inner_width * 0.28))
    end

    local title_width = math.max(
        1,
        inner_width - thumbnail_width - gap - mandatory_width - (mandatory_widget and Size.span.horizontal_default or 0)
    )
    local subtitle = self.entry.subtitle
    local subtitle_height = 0
    if subtitle then
        local subtitle_face = fontFace("cfont", fontSizeForRow(18, 22, font_height))
        subtitle_height = math.min(
            math.max(1, height - 1),
            textBoxLineHeight(subtitle_face) + verticalDefaultSpan()
        )
    end
    local title_height = subtitle and math.max(1, height - subtitle_height) or height
    local title = fittingTextBox{
        text = BD.auto(tostring(self.text or "")),
        font = "cfont",
        font_size = fontSizeForRow(20, 24, font_height),
        width = title_width,
        height = title_height,
        alignment = "left",
        bold = self.entry.title_bold == true,
    }
    local text_column = title
    if subtitle then
        text_column = VerticalGroup:new{
            title,
            TextBoxWidget:new{
                text = BD.auto(tostring(subtitle)),
                face = fontFace("cfont", fontSizeForRow(18, 22, font_height)),
                width = title_width,
                height = subtitle_height,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
                alignment = "left",
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        }
    end

    local title_items = {
        self:buildThumbnail(thumbnail_width, thumbnail_height),
    }
    if has_thumbnail then
        table.insert(title_items, HorizontalSpan:new{ width = gap })
    end
    table.insert(title_items, text_column)

    local main = LeftContainer:new{
        dimen = Geom:new{ w = inner_width, h = height },
        HorizontalGroup:new(title_items),
    }
    local row = OverlapGroup:new{
        dimen = Geom:new{ w = inner_width, h = height },
        main,
    }
    if mandatory_widget then
        table.insert(row, RightContainer:new{
            dimen = Geom:new{ w = inner_width, h = height },
            mandatory_widget,
        })
    end

    return HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = left_padding },
        VerticalGroup:new{
            VerticalSpan:new{ width = math.floor((self.dimen.h - height) / 2) },
            row,
        },
        HorizontalSpan:new{ width = right_padding },
    }
end

function ListMenuItem:onFocus()
    self._underline_container.color = Blitbuffer.COLOR_BLACK
    return true
end

function ListMenuItem:onUnfocus()
    self._underline_container.color = self.line_color
    return true
end

function ListMenuItem:onTapSelect()
    self.menu:onMenuSelect(self.entry)
    return true
end

function ListMenuItem:onHoldSelect()
    self.menu:onMenuHold(self.entry)
    return true
end

local function getItemText(item)
    if Menu.getMenuText then
        return Menu.getMenuText(item)
    end
    return item and item.text or ""
end

local function applyDefaults(options)
    local menu_options = {}
    for key, value in pairs(options or {}) do
        menu_options[key] = value
    end
    for key, value in pairs(DEFAULT_OPTIONS) do
        if menu_options[key] == nil then
            menu_options[key] = value
        end
    end
    return menu_options
end

function ListMenu.new(options)
    return Menu:new(applyDefaults(options))
end

function ListMenu.getPageNumber(menu, item_number)
    if #menu.item_table == 0 or item_number == 0 then
        return 1
    end
    if menu.items_max_lines and menu.page_items then
        for page, items in ipairs(menu.page_items) do
            if item_number <= items[#items] then
                return page
            end
        end
        return #menu.page_items
    end
    return math.ceil(math.min(item_number, #menu.item_table) / menu.perpage)
end

local function normalizeItemNumber(menu, item_number)
    item_number = tonumber(item_number)
    if not item_number or item_number < 1 or #menu.item_table == 0 then
        return nil
    end
    return math.min(math.floor(item_number), #menu.item_table)
end

function ListMenu.consumePendingItemNumber(menu)
    local item_number = normalizeItemNumber(menu, menu._suwayomi_pending_itemnumber)
    menu._suwayomi_pending_itemnumber = nil
    if not item_number then
        return nil
    end
    menu.itemnumber = item_number
    menu.page = ListMenu.getPageNumber(menu, item_number)
    return item_number
end

function ListMenu.estimateItemTitleWidth(menu, item, base_height)
    if isSectionHeader(item) then
        return math.max(1, menu.item_width - 2 * scaled(12))
    end

    local has_thumbnail = item.thumbnail_placeholder or item.thumbnail_url or item.thumbnail_path
    local left_padding = has_thumbnail and 0 or scaled(10)
    local right_padding = scaled(10)
    local thumbnail_width = 0
    if has_thumbnail then
        thumbnail_width = thumbnailSlotDimensions(item, preferredItemHeight(item, base_height, base_height), base_height)
    end
    local gap = has_thumbnail and scaled(5) or 0
    local inner_width = math.max(1, menu.item_width - left_padding - right_padding)
    local mandatory_width = 0
    if item.mandatory then
        local mandatory_face = fontFace("cfont", fontSizeForRow(14, 18, base_height))
        mandatory_width = math.min(
            textWidth(item.mandatory, mandatory_face),
            math.floor(inner_width * 0.28)
        )
    end
    return math.max(
        1,
        inner_width
            - thumbnail_width
            - gap
            - mandatory_width
            - (item.mandatory and Size.span.horizontal_default or 0)
    )
end

function ListMenu.sectionHeaderHeight(base_height, line_height, row_padding)
    return math.max(line_height + row_padding, math.floor(base_height * 0.55))
end

function ListMenu.setupFixedItemHeights(menu)
    if #menu.item_table == 0 then
        menu.page_items = {{}}
        return
    end

    local has_variable_height = false
    for _, item in ipairs(menu.item_table) do
        if hasVariableItemHeight(item) then
            has_variable_height = true
            break
        end
    end
    if not has_variable_height then
        menu.page_items = nil
        for _, item in ipairs(menu.item_table) do
            item.height = nil
        end
        return
    end

    local base_height = menu._suwayomi_base_item_height or menu.item_dimen.h
    local normal_height = menu.item_height or base_height
    local title_face = fontFace("cfont", fontSizeForRow(20, 24, base_height))
    local row_padding = 2 * verticalDefaultSpan() + Size.line.thin
    local header_height = ListMenu.sectionHeaderHeight(base_height, textBoxLineHeight(title_face), row_padding)
    menu.page_items = {}

    local page_items = {}
    local page_height = 0
    for index, item in ipairs(menu.item_table) do
        item.height = isSectionHeader(item) and header_height or preferredItemHeight(item, base_height, normal_height)
        page_height = page_height + item.height
        if page_height <= menu.available_height or #page_items == 0 then
            table.insert(page_items, index)
        else
            table.insert(menu.page_items, page_items)
            page_items = { index }
            page_height = item.height
        end
        if index == #menu.item_table then
            table.insert(menu.page_items, page_items)
        end
    end
end

function ListMenu.setupItemHeights(menu)
    if #menu.item_table == 0 then
        menu.page_items = {{}}
        return
    end

    local base_height = menu._suwayomi_base_item_height or menu.item_dimen.h
    local title_face = fontFace("cfont", fontSizeForRow(20, 24, base_height))
    local line_height = textBoxLineHeight(title_face)
    local row_padding = 2 * verticalDefaultSpan() + Size.line.thin
    menu.page_items = {}

    local page_items = {}
    local page_height = 0
    for index, item in ipairs(menu.item_table) do
        if isSectionHeader(item) then
            item.height = ListMenu.sectionHeaderHeight(base_height, line_height, row_padding)
        else
            local title_width = ListMenu.estimateItemTitleWidth(menu, item, base_height)
            local title_width_px = textWidth(getItemText(item), title_face, item.title_bold == true) * 1.08
            local subtitle_lines = item.subtitle and 1 or 0
            local max_title_lines = math.max(1, (menu.items_max_lines or 1) - subtitle_lines)
            local title_lines = math.min(math.max(1, math.ceil(title_width_px / title_width)), max_title_lines)
            local lines = title_lines + subtitle_lines
            item.height = math.max(preferredItemHeight(item, base_height, base_height), lines * line_height + row_padding)
        end

        page_height = page_height + item.height
        if page_height <= menu.available_height or #page_items == 0 then
            table.insert(page_items, index)
        else
            table.insert(menu.page_items, page_items)
            page_items = { index }
            page_height = item.height
        end
        if index == #menu.item_table then
            table.insert(menu.page_items, page_items)
        end
    end
end

function ListMenu.recalculateDimen(menu, no_recalculate_dimen)
    if no_recalculate_dimen and menu.item_dimen then
        return
    end
    if not menu.inner_dimen or not Screen or not Screen.getWidth or not Screen.getHeight then
        if menu._suwayomi_original_recalculate_dimen then
            return menu._suwayomi_original_recalculate_dimen(menu, no_recalculate_dimen)
        end
        return
    end

    menu.portrait_mode = Screen:getWidth() <= Screen:getHeight()
    local others_height = 0
    if menu.title_bar then
        if not menu.is_borderless then
            others_height = others_height + 2
        end
        if not menu.no_title then
            others_height = others_height + menu.title_bar.dimen.h
        end
        if menu.page_info then
            others_height = others_height + menu.page_info:getSize().h
        end
    end

    local available_height = menu.inner_dimen.h - others_height - Size.line.thin
    menu.available_height = available_height
    if menu._suwayomi_files_per_page == nil then
        menu._suwayomi_files_per_page = menu.items_per_page
            or math.max(1, math.floor(available_height / scale_by_size / ROW_HEIGHT_BASE))
    end

    menu.perpage = menu._suwayomi_files_per_page
    if not menu.portrait_mode then
        local portrait_available_height = Screen:getWidth() - others_height - Size.line.thin
        local portrait_item_height = math.floor(portrait_available_height / menu.perpage) - Size.line.thin
        menu.perpage = math.max(1, round(available_height / portrait_item_height))
    end

    local function setItemHeight()
        menu.item_height = math.floor(available_height / menu.perpage) - Size.line.thin
    end

    setItemHeight()
    if menu.fixed_item_heights and menu.items_max_lines then
        local title_face = fontFace("cfont", fontSizeForRow(20, 24, menu.item_height))
        local line_height = textBoxLineHeight(title_face)
        local row_padding = 2 * verticalDefaultSpan() + Size.line.thin
        local minimum_item_height = menu.items_max_lines * line_height + row_padding
        if menu.item_height < minimum_item_height then
            menu.perpage = math.max(1, math.floor(available_height / (minimum_item_height + Size.line.thin)))
            setItemHeight()
        end
    end

    menu.page_num = math.ceil(#menu.item_table / menu.perpage)
    if menu.page_num > 0 and menu.page > menu.page_num then
        menu.page = menu.page_num
    end

    menu.item_width = menu.inner_dimen.w
    menu._suwayomi_base_item_height = menu.item_height
    menu.item_dimen = Geom:new{
        x = 0,
        y = 0,
        w = menu.item_width,
        h = menu.item_height,
    }
    if menu.fixed_item_heights then
        ListMenu.setupFixedItemHeights(menu)
        if menu.page_items then
            menu.page_num = ListMenu.getPageNumber(menu, #menu.item_table)
            if menu.page_num > 0 and menu.page > menu.page_num then
                menu.page = menu.page_num
            end
        end
    elseif menu.items_max_lines then
        ListMenu.setupItemHeights(menu)
        menu.page_num = ListMenu.getPageNumber(menu, #menu.item_table)
        if menu.page_num > 0 and menu.page > menu.page_num then
            menu.page = menu.page_num
        end
    end
end

function ListMenu.prepareThumbnail(menu, item)
    if not item or not item.thumbnail_url or item.thumbnail_url == "" then
        return
    end
    local thumbnail_options = thumbnailOptionsForItem(item)
    item.thumbnail_path = item.thumbnail_path
        or ThumbnailCache.find(menu._suwayomi_thumbnail_credentials, item.thumbnail_url, thumbnail_options)
    if item.thumbnail_path then
        item.thumbnail_failed = nil
    end
end

local function getThumbnailKey(credentials, thumbnail_url, thumbnail_options)
    return ThumbnailCache.getKey(credentials, thumbnail_url, thumbnail_options)
end

local function markThumbnailResult(menu, thumbnail_key, path)
    for _, item in ipairs(menu.item_table or {}) do
        if item.thumbnail_url
            and getThumbnailKey(
                menu._suwayomi_thumbnail_credentials,
                item.thumbnail_url,
                thumbnailOptionsForItem(item)
            ) == thumbnail_key
        then
            item.thumbnail_loading = nil
            if path then
                item.thumbnail_path = path
                item.thumbnail_failed = nil
            else
                item.thumbnail_failed = true
            end
        end
    end
end

function ListMenu.startThumbnailJob(menu, item)
    local credentials = menu._suwayomi_thumbnail_credentials
    local thumbnail_url = item.thumbnail_url
    local thumbnail_options = thumbnailOptionsForItem(item)
    local thumbnail_key = thumbnail_url and getThumbnailKey(credentials, thumbnail_url, thumbnail_options)
    if not item.thumbnail_url
        or item.thumbnail_path
        or item.thumbnail_loading
        or item.thumbnail_failed
        or (menu._suwayomi_thumbnail_active and menu._suwayomi_thumbnail_active[thumbnail_key])
        or not credentials
        or not credentials.server_url
        or credentials.server_url == ""
    then
        return false
    end
    if (menu._suwayomi_thumbnail_active_count or 0) >= THUMBNAIL_MAX_ACTIVE then
        return false
    end

    item.thumbnail_loading = true
    menu._suwayomi_thumbnail_active = menu._suwayomi_thumbnail_active or {}
    local active = SubprocessJob.start({
        active = {
            thumbnail_url = thumbnail_url,
            thumbnail_key = thumbnail_key,
            thumbnail_options = thumbnail_options,
            generation = menu._suwayomi_thumbnail_generation or 0,
            result_path = SubprocessJob.buildResultPath and SubprocessJob.buildResultPath("thumbnail") or nil,
        },
        ffi_util = FFIUtil,
        ui_manager = UIManager,
        poll_interval_seconds = 0.5,
        timeout_seconds = 15,
        run = function(path)
            ThumbnailWorker:run(credentials, thumbnail_url, path, thumbnail_options)
        end,
        read_result = function(path)
            return ThumbnailWorker:readResult(path)
        end,
        on_finish = function(finished_active, result)
            if finished_active.generation ~= menu._suwayomi_thumbnail_generation
                or menu._suwayomi_thumbnail_active[finished_active.thumbnail_key] ~= finished_active
            then
                return
            end
            menu._suwayomi_thumbnail_active_count = math.max((menu._suwayomi_thumbnail_active_count or 1) - 1, 0)
            menu._suwayomi_thumbnail_active[finished_active.thumbnail_key] = nil
            markThumbnailResult(menu, finished_active.thumbnail_key, result and result.ok and result.path or nil)
            if menu.updateItems then
                menu:updateItems(nil, true)
            end
        end,
        on_timeout = function(timed_out_active)
            if timed_out_active.generation ~= menu._suwayomi_thumbnail_generation
                or menu._suwayomi_thumbnail_active[timed_out_active.thumbnail_key] ~= timed_out_active
            then
                return
            end
            menu._suwayomi_thumbnail_active_count = math.max((menu._suwayomi_thumbnail_active_count or 1) - 1, 0)
            menu._suwayomi_thumbnail_active[timed_out_active.thumbnail_key] = nil
            markThumbnailResult(menu, timed_out_active.thumbnail_key, nil)
            if menu.updateItems then
                menu:updateItems(nil, true)
            end
        end,
    })
    if active then
        menu._suwayomi_thumbnail_active[thumbnail_key] = active
        menu._suwayomi_thumbnail_active_count = (menu._suwayomi_thumbnail_active_count or 0) + 1
        return true
    end
    item.thumbnail_loading = nil
    return false
end

function ListMenu.startVisibleThumbnailJobs(menu, visible_items)
    for _, item in ipairs(visible_items or {}) do
        ListMenu.prepareThumbnail(menu, item)
        ListMenu.startThumbnailJob(menu, item)
    end
end

function ListMenu.updateItems(menu, select_number, no_recalculate_dimen)
    local old_dimen = menu.dimen and menu.dimen:copy()
    menu.layout = {}
    menu.item_group:clear()
    menu.page_info:resetLayout()
    menu.return_button:resetLayout()
    menu.content_group:resetLayout()
    menu:_recalculateDimen(no_recalculate_dimen)
    ListMenu.consumePendingItemNumber(menu)

    local items_nb
    local idx_offset
    if menu.items_max_lines and menu.page_items then
        items_nb = #(menu.page_items[menu.page] or {})
    else
        items_nb = menu.perpage
        idx_offset = (menu.page - 1) * items_nb
    end
    local visible_items = {}
    for idx = 1, items_nb do
        local index = menu.items_max_lines and menu.page_items and menu.page_items[menu.page][idx] or idx_offset + idx
        local item = menu.item_table[index]
        if item == nil then
            break
        end
        item.idx = index
        if index == menu.itemnumber then
            select_number = idx
        end
        ListMenu.prepareThumbnail(menu, item)
        if menu.page_items and item.height then
            menu.item_dimen.h = item.height
        elseif isSectionHeader(item) then
            local base_height = menu._suwayomi_base_item_height or menu.item_dimen.h
            local title_face = fontFace("cfont", fontSizeForRow(20, 24, base_height))
            local row_padding = 2 * verticalDefaultSpan() + Size.line.thin
            menu.item_dimen.h = ListMenu.sectionHeaderHeight(
                base_height,
                textBoxLineHeight(title_face),
                row_padding
            )
            item.height = nil
        else
            menu.item_dimen.h = menu.item_height or menu.item_dimen.h
            item.height = nil
        end
        local item_widget = ListMenuItem:new{
            entry = item,
            text = getItemText(item),
            mandatory = item.mandatory,
            dimen = menu.item_dimen:copy(),
            menu = menu,
            show_parent = menu.show_parent,
            line_color = menu.line_color,
        }
        table.insert(menu.item_group, item_widget)
        table.insert(menu.layout, { item_widget })
        table.insert(visible_items, item)
    end

    menu:updatePageInfo(select_number)
    menu:mergeTitleBarIntoLayout()

    UIManager:setDirty(menu.show_parent, function()
        local refresh_dimen = old_dimen and old_dimen:combine(menu.dimen) or menu.dimen
        return "ui", refresh_dimen, true
    end)
    ListMenu.startVisibleThumbnailJobs(menu, visible_items)
    if type(menu._suwayomi_on_page_changed) == "function" and menu.page ~= menu._suwayomi_last_notified_page then
        menu._suwayomi_last_notified_page = menu.page
        menu._suwayomi_on_page_changed(menu, menu.page)
    end
end

local function cancelThumbnailJobs(menu)
    for _, item in ipairs(menu.item_table or {}) do
        item.thumbnail_loading = nil
        item.thumbnail_failed = nil
    end
    for _, active in pairs(menu._suwayomi_thumbnail_active or {}) do
        if SubprocessJob.cancel then
            SubprocessJob.cancel(active)
        end
    end
    menu._suwayomi_thumbnail_active = {}
    menu._suwayomi_thumbnail_active_count = 0
    menu._suwayomi_thumbnail_generation = (menu._suwayomi_thumbnail_generation or 0) + 1
end

function ListMenu.install(menu, options)
    menu._suwayomi_thumbnail_credentials = options and options.thumbnail_credentials
    menu._suwayomi_on_close = options and options.on_close
    local on_page_changed = options and options.on_page_changed
    if menu._suwayomi_on_page_changed ~= on_page_changed then
        menu._suwayomi_last_notified_page = nil
    end
    menu._suwayomi_on_page_changed = on_page_changed
    menu._suwayomi_thumbnail_active = menu._suwayomi_thumbnail_active or {}
    menu._suwayomi_thumbnail_active_count = menu._suwayomi_thumbnail_active_count or 0
    menu._suwayomi_thumbnail_generation = menu._suwayomi_thumbnail_generation or 0

    if not menu._suwayomi_list_menu_installed then
        local original_on_close_widget = menu.onCloseWidget
        local original_on_close = menu.onClose
        local original_on_menu_select = menu.onMenuSelect
        menu._suwayomi_original_recalculate_dimen = menu._recalculateDimen
        menu._recalculateDimen = function(self, no_recalculate_dimen)
            return ListMenu.recalculateDimen(self, no_recalculate_dimen)
        end
        menu.updateItems = function(self, select_number, no_recalculate_dimen)
            return ListMenu.updateItems(self, select_number, no_recalculate_dimen)
        end
        menu.onClose = function(self, ...)
            if type(self._suwayomi_on_close) == "function" and self._suwayomi_on_close(self, ...) == true then
                return true
            end
            if original_on_close then
                return original_on_close(self, ...)
            end
            return false
        end
        menu.onMenuSelect = function(self, item)
            if item and item.keep_menu_open == true and item.sub_item_table == nil then
                if item.select_enabled == false then
                    return true
                end
                if item.select_enabled_func and not item.select_enabled_func() then
                    return true
                end
                self:onMenuChoice(item)
                return true
            end
            if original_on_menu_select then
                return original_on_menu_select(self, item)
            end
            return false
        end
        menu.onCloseWidget = function(self, ...)
            cancelThumbnailJobs(self)
            if original_on_close_widget then
                return original_on_close_widget(self, ...)
            end
        end
        menu._suwayomi_list_menu_installed = true
    end
end

local function applyOptions(menu, options)
    menu_utils.applyTitleBarOptions(menu, options)
    menu_utils.applyCloseCallback(menu, options)
    menu._suwayomi_thumbnail_credentials = options and options.thumbnail_credentials
    menu._suwayomi_on_close = options and options.on_close
    local on_page_changed = options and options.on_page_changed
    if menu._suwayomi_on_page_changed ~= on_page_changed then
        menu._suwayomi_last_notified_page = nil
    end
    menu._suwayomi_on_page_changed = on_page_changed
end

function ListMenu.show(options)
    options = options or {}
    local items_max_lines = options.items_max_lines
    if items_max_lines == nil then
        items_max_lines = 3
    end
    local fixed_item_heights = options.fixed_item_heights ~= false
    local native_items_max_lines = items_max_lines
    if fixed_item_heights then
        native_items_max_lines = false
    end
    local subtitle = options.subtitle
    if subtitle == nil then
        subtitle = false
    end
    local menu = Menu:new(menu_utils.applyNativeTitleBarStyle{
        title = options.title,
        subtitle = subtitle,
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = options.item_table or {},
        items_per_page = options.items_per_page,
        itemnumber = options.itemnumber,
        state_w = options.state_w,
        fixed_item_heights = fixed_item_heights,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        with_bottom_line = options.with_bottom_line ~= false,
        bottom_line_color = options.bottom_line_color or Blitbuffer.COLOR_DARK_GRAY,
        title_face = options.title_face or fontFace("tfont"),
        title_shrink_font_to_fit = options.title_shrink_font_to_fit ~= false,
        items_max_lines = native_items_max_lines,
        multilines_show_more_text = true,
        line_color = options.line_color or Blitbuffer.COLOR_DARK_GRAY,
    })
    if fixed_item_heights then
        menu.items_max_lines = items_max_lines
    end
    ListMenu.install(menu, options)
    applyOptions(menu, options)
    menu._suwayomi_pending_itemnumber = options.itemnumber
    menu:updateItems()
    UIManager:show(menu)
    return menu
end

function ListMenu.update(menu, options)
    if not menu then
        return
    end
    options = options or {}
    ListMenu.install(menu, options)
    cancelThumbnailJobs(menu)
    menu.item_table = options.item_table or {}
    menu.title = options.title or menu.title
    menu._suwayomi_pending_itemnumber = options.itemnumber
    applyOptions(menu, options)
    if menu.updateItems then
        menu:updateItems()
    end
end

return ListMenu
