-- Boundary: file-manager-like manga list menu.
--
-- Responsibility: render manga rows with small cached cover thumbnails while
-- preserving KOReader Menu navigation, title bars, paging rows, and callbacks.
-- Owned state: visible thumbnail download jobs for the menu instance.
-- Dependencies: KOReader Menu/widget primitives, thumbnail cache/worker, and
-- shared menu utilities.
-- External data: manga titles, status labels, and thumbnail URLs are displayed
-- or fetched only after nil-safe normalization by upstream row builders.

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

local MangaMenu = {}

local THUMBNAIL_MAX_ACTIVE = 2
local ROW_HEIGHT_BASE = 64
local scale_by_size = Screen and Screen.scaleBySize
    and Screen:scaleBySize(1000000) * (1 / 1000000)
    or 1

local MangaMenuItem = InputContainer:extend{
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

local function placeholderText(text)
    text = tostring(text or ""):gsub("^%s+", "")
    if text == "" then
        return "..."
    end
    return "..."
end

function MangaMenuItem:init()
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

function MangaMenuItem:buildThumbnail(slot_size)
    if not self.entry.manga then
        return HorizontalSpan:new{ width = 0 }
    end

    local border = Size.border.thin
    local image_size = math.max(1, slot_size - 2 * border)
    local image
    if self.entry.thumbnail_path then
        local is_decoded_path = ThumbnailCache.isDecodedPath and ThumbnailCache.isDecodedPath(self.entry.thumbnail_path)
        local decoded_image = is_decoded_path and ThumbnailCache.loadDecoded and ThumbnailCache.loadDecoded(self.entry.thumbnail_path)
        if decoded_image then
            image = ImageWidget:new{
                image = decoded_image,
                width = image_size,
                height = image_size,
                scale_factor = 0,
            }
        elseif not is_decoded_path then
            image = ImageWidget:new{
                file = self.entry.thumbnail_path,
                width = image_size,
                height = image_size,
                scale_factor = 0,
            }
        end
    end
    if not image then
        image = CenterContainer:new{
            dimen = Geom:new{ w = image_size, h = image_size },
            TextWidget:new{
                text = placeholderText(self.text),
                face = fontFace("cfont", math.max(10, math.floor(image_size / 2))),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        }
    end

    return CenterContainer:new{
        dimen = Geom:new{ w = slot_size, h = slot_size },
        FrameContainer:new{
            width = image_size + 2 * border,
            height = image_size + 2 * border,
            margin = 0,
            padding = 0,
            bordersize = border,
            image,
        },
    }
end

function MangaMenuItem:buildRowWidget(width, height)
    local is_manga_row = self.entry.manga ~= nil
    local left_padding = is_manga_row and 0 or scaled(10)
    local right_padding = scaled(10)
    local thumbnail_slot = is_manga_row and math.max(1, height) or 0
    local gap = is_manga_row and scaled(5) or 0
    local inner_width = width - left_padding - right_padding
    local mandatory_widget
    local mandatory_width = 0

    if self.mandatory then
        mandatory_widget = TextBoxWidget:new{
            text = tostring(self.mandatory),
            face = fontFace("cfont", fontSizeForRow(14, 18, height)),
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
        inner_width - thumbnail_slot - gap - mandatory_width - (mandatory_widget and Size.span.horizontal_default or 0)
    )
    local subtitle = self.entry.subtitle
    local title_height = subtitle and math.max(1, math.floor(height * 0.58)) or height
    local title = TextBoxWidget:new{
        text = BD.auto(tostring(self.text or "")),
        face = fontFace("cfont", fontSizeForRow(20, 24, height)),
        width = title_width,
        height = title_height,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        bold = is_manga_row,
    }
    local text_column = title
    if subtitle then
        text_column = VerticalGroup:new{
            title,
            TextBoxWidget:new{
                text = BD.auto(tostring(subtitle)),
                face = fontFace("cfont", fontSizeForRow(18, 22, height)),
                width = title_width,
                height = math.max(1, height - title_height),
                height_adjust = true,
                height_overflow_show_ellipsis = true,
                alignment = "left",
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        }
    end

    local title_items = {
        self:buildThumbnail(thumbnail_slot),
    }
    if is_manga_row then
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

function MangaMenuItem:onFocus()
    self._underline_container.color = Blitbuffer.COLOR_BLACK
    return true
end

function MangaMenuItem:onUnfocus()
    self._underline_container.color = self.line_color
    return true
end

function MangaMenuItem:onTapSelect()
    self.menu:onMenuSelect(self.entry)
    return true
end

function MangaMenuItem:onHoldSelect()
    self.menu:onMenuHold(self.entry)
    return true
end

local function getItemText(item)
    if Menu.getMenuText then
        return Menu.getMenuText(item)
    end
    return item and item.text or ""
end

function MangaMenu.recalculateDimen(menu, no_recalculate_dimen)
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

    menu.page_num = math.ceil(#menu.item_table / menu.perpage)
    if menu.page_num > 0 and menu.page > menu.page_num then
        menu.page = menu.page_num
    end

    menu.item_height = math.floor(available_height / menu.perpage) - Size.line.thin
    menu.item_width = menu.inner_dimen.w
    menu.item_dimen = Geom:new{
        x = 0,
        y = 0,
        w = menu.item_width,
        h = menu.item_height,
    }
end

function MangaMenu.prepareThumbnail(menu, item)
    if not item or not item.thumbnail_url or item.thumbnail_url == "" then
        return
    end
    item.thumbnail_path = item.thumbnail_path
        or ThumbnailCache.find(menu._suwayomi_thumbnail_credentials, item.thumbnail_url)
    if item.thumbnail_path then
        item.thumbnail_failed = nil
    end
end

local function getThumbnailKey(credentials, thumbnail_url)
    return ThumbnailCache.getKey(credentials, thumbnail_url)
end

local function markThumbnailResult(menu, thumbnail_key, path)
    for _, item in ipairs(menu.item_table or {}) do
        if item.thumbnail_url
            and getThumbnailKey(menu._suwayomi_thumbnail_credentials, item.thumbnail_url) == thumbnail_key
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

function MangaMenu.startThumbnailJob(menu, item)
    local credentials = menu._suwayomi_thumbnail_credentials
    local thumbnail_url = item.thumbnail_url
    local thumbnail_key = thumbnail_url and getThumbnailKey(credentials, thumbnail_url)
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
            generation = menu._suwayomi_thumbnail_generation or 0,
            result_path = SubprocessJob.buildResultPath and SubprocessJob.buildResultPath("thumbnail") or nil,
        },
        ffi_util = FFIUtil,
        ui_manager = UIManager,
        poll_interval_seconds = 0.5,
        timeout_seconds = 15,
        run = function(path)
            ThumbnailWorker:run(credentials, thumbnail_url, path)
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

function MangaMenu.startVisibleThumbnailJobs(menu, visible_items)
    for _, item in ipairs(visible_items or {}) do
        MangaMenu.prepareThumbnail(menu, item)
        MangaMenu.startThumbnailJob(menu, item)
    end
end

function MangaMenu.updateItems(menu, select_number, no_recalculate_dimen)
    local old_dimen = menu.dimen and menu.dimen:copy()
    menu.layout = {}
    menu.item_group:clear()
    menu.page_info:resetLayout()
    menu.return_button:resetLayout()
    menu.content_group:resetLayout()
    menu:_recalculateDimen(no_recalculate_dimen)

    local items_nb = menu.perpage
    local idx_offset = (menu.page - 1) * items_nb
    local visible_items = {}
    for idx = 1, items_nb do
        local index = idx_offset + idx
        local item = menu.item_table[index]
        if item == nil then
            break
        end
        item.idx = index
        if index == menu.itemnumber then
            select_number = idx
        end
        MangaMenu.prepareThumbnail(menu, item)
        local item_widget = MangaMenuItem:new{
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
    MangaMenu.startVisibleThumbnailJobs(menu, visible_items)
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

function MangaMenu.install(menu, options)
    menu._suwayomi_thumbnail_credentials = options and options.thumbnail_credentials
    menu._suwayomi_thumbnail_active = menu._suwayomi_thumbnail_active or {}
    menu._suwayomi_thumbnail_active_count = menu._suwayomi_thumbnail_active_count or 0
    menu._suwayomi_thumbnail_generation = menu._suwayomi_thumbnail_generation or 0

    if not menu._suwayomi_manga_menu_installed then
        local original_on_close_widget = menu.onCloseWidget
        menu._suwayomi_original_recalculate_dimen = menu._recalculateDimen
        menu._recalculateDimen = function(self, no_recalculate_dimen)
            return MangaMenu.recalculateDimen(self, no_recalculate_dimen)
        end
        menu.updateItems = function(self, select_number, no_recalculate_dimen)
            return MangaMenu.updateItems(self, select_number, no_recalculate_dimen)
        end
        menu.onCloseWidget = function(self, ...)
            cancelThumbnailJobs(self)
            if original_on_close_widget then
                return original_on_close_widget(self, ...)
            end
        end
        menu._suwayomi_manga_menu_installed = true
    end
end

local function applyOptions(menu, options)
    menu_utils.applyTitleBarOptions(menu, options)
    menu_utils.applyCloseCallback(menu, options)
    menu._suwayomi_thumbnail_credentials = options and options.thumbnail_credentials
end

function MangaMenu.show(options)
    options = options or {}
    local menu = Menu:new(menu_utils.applyNativeTitleBarStyle{
        title = options.title,
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = options.item_table or {},
        items_per_page = options.items_per_page,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    })
    MangaMenu.install(menu, options)
    applyOptions(menu, options)
    menu:updateItems()
    UIManager:show(menu)
    return menu
end

function MangaMenu.update(menu, options)
    if not menu then
        return
    end
    options = options or {}
    MangaMenu.install(menu, options)
    cancelThumbnailJobs(menu)
    menu.item_table = options.item_table or {}
    menu.title = options.title or menu.title
    applyOptions(menu, options)
    if menu.updateItems then
        menu:updateItems()
    end
end

return MangaMenu
