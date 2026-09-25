describe("suwayomi/ui/manga_menu", function()
    local dirty_count
    local started_jobs
    local canceled_jobs
    local cache_paths
    local decoded_images
    local raw_images
    local image_errors
    local view_dialog

    local function clearModules()
        for _, name in ipairs({
            "suwayomi/ui/manga_menu",
            "suwayomi/ui/list_menu",
            "suwayomi/ui/browse",
            "suwayomi/ui/list_rows",
            "suwayomi/ui",
            "ui/widget/button",
            "ui/widget/multiinputdialog",
            "ui/bidi",
            "ffi/blitbuffer",
            "ui/renderimage",
            "ui/widget/container/centercontainer",
            "device",
            "ui/font",
            "ui/widget/container/framecontainer",
            "ui/geometry",
            "ui/gesturerange",
            "ui/widget/horizontalgroup",
            "ui/widget/horizontalspan",
            "ui/widget/imagewidget",
            "ui/widget/container/inputcontainer",
            "ui/widget/container/leftcontainer",
            "ui/widget/menu",
            "ui/widget/overlapgroup",
            "ui/widget/container/rightcontainer",
            "ui/size",
            "ui/widget/textboxwidget",
            "ui/widget/textwidget",
            "ui/uimanager",
            "ui/widget/container/underlinecontainer",
            "ui/widget/verticalgroup",
            "ui/widget/verticalspan",
            "ffi/util",
            "suwayomi/subprocess/job",
            "suwayomi/ui/thumbnail_cache",
            "suwayomi/ui/thumbnail_worker",
            "suwayomi/ui/menu_utils",
        }) do
            package.loaded[name] = nil
            package.preload[name] = nil
        end
    end

    local function widgetModule(kind)
        return {
            new = function(_, options)
                options = options or {}
                options.kind = kind
                return options
            end,
        }
    end

    local function newGroup()
        local group = {}
        function group:clear()
            for index = #self, 1, -1 do
                self[index] = nil
            end
        end
        return group
    end

    local function installStubs()
        clearModules()
        dirty_count = 0
        started_jobs = {}
        canceled_jobs = {}
        cache_paths = {}
        decoded_images = {}
        raw_images = {}
        image_errors = {}
        view_dialog = nil

        package.preload["suwayomi/ui"] = function()
            return {
                showChoiceDialog = function(options)
                    view_dialog = options
                    return options
                end,
            }
        end
        package.preload["ui/widget/button"] = function()
            return {
                new = function(_, options)
                    options.dimen = { w = options.width, h = options.icon_height }
                    function options:showHide(visible) self.visible = visible end
                    return options
                end,
            }
        end

        package.preload["ui/bidi"] = function()
            return { auto = function(text) return text end }
        end
        package.preload["ffi/blitbuffer"] = function()
            return {
                COLOR_BLACK = "black",
                COLOR_DARK_GRAY = "dark_gray",
                COLOR_WHITE = "white",
            }
        end
        package.preload["ui/renderimage"] = function()
            return {
                renderImageFile = function(_, path)
                    if image_errors[path] then
                        error(image_errors[path])
                    end
                    return raw_images[path]
                end,
            }
        end
        package.preload.device = function()
            return {
                screen = {
                    scaleBySize = function(_, value) return value end,
                    getWidth = function() return 480 end,
                    getHeight = function() return 800 end,
                },
            }
        end
        package.preload["ui/font"] = function()
            return {
                getFace = function(_, name, size)
                    return { name = name, size = size }
                end,
            }
        end
        package.preload["ui/geometry"] = function()
            local Geom = {}
            function Geom:new(options)
                options = options or {}
                function options:copy()
                    return Geom:new{ x = self.x, y = self.y, w = self.w, h = self.h }
                end
                function options:combine(other)
                    return other or self
                end
                return options
            end
            return Geom
        end
        package.preload["ui/gesturerange"] = function() return widgetModule("gesture_range") end
        package.preload["ui/widget/container/centercontainer"] = function() return widgetModule("center") end
        package.preload["ui/widget/container/framecontainer"] = function() return widgetModule("frame") end
        package.preload["ui/widget/horizontalgroup"] = function() return widgetModule("horizontal_group") end
        package.preload["ui/widget/horizontalspan"] = function() return widgetModule("horizontal_span") end
        package.preload["ui/widget/imagewidget"] = function()
            return {
                new = function(_, options)
                    if image_errors[options and options.file] then
                        error(image_errors[options.file])
                    end
                    options = options or {}
                    options.kind = "image"
                    return options
                end,
            }
        end
        package.preload["ui/widget/container/leftcontainer"] = function() return widgetModule("left") end
        package.preload["ui/widget/overlapgroup"] = function() return widgetModule("overlap") end
        package.preload["ui/widget/container/rightcontainer"] = function() return widgetModule("right") end
        package.preload["ui/widget/container/underlinecontainer"] = function() return widgetModule("underline") end
        package.preload["ui/widget/verticalgroup"] = function() return widgetModule("vertical_group") end
        package.preload["ui/widget/verticalspan"] = function() return widgetModule("vertical_span") end
        package.preload["ui/widget/container/inputcontainer"] = function()
            local InputContainer = {}
            function InputContainer:extend(definition)
                definition.__index = definition
                function definition:new(options)
                    options = options or {}
                    setmetatable(options, definition)
                    if options.init then
                        options:init()
                    end
                    return options
                end
                return definition
            end
            return InputContainer
        end
        package.preload["ui/size"] = function()
            return {
                border = { thin = 1 },
                line = { thin = 1 },
                padding = { fullscreen = 4 },
                span = {
                    horizontal_default = 3,
                    horizontal_small = 1,
                    vertical_default = 3,
                },
            }
        end
        package.preload["ui/widget/textboxwidget"] = function()
            return {
                getFontSizeToFitHeight = function(_, height, lines)
                    return math.floor((height or 0) / math.max(lines or 1, 1))
                end,
                new = function(_, options)
                    options = options or {}
                    assert(options.width == nil or options.width > 0, "text width must be strictly positive")
                    options.kind = "textbox"
                    local font_size = options.face and options.face.size or 12
                    function options:getSize()
                        local width = options.width or #(options.text or "")
                        local chars_per_line = math.max(1, math.floor(width / math.max(font_size, 1)))
                        local lines = math.max(1, math.ceil(#(options.text or "") / chars_per_line))
                        local height = options.height or lines * font_size
                        return { w = math.min(width, #(options.text or "") * font_size), h = height }
                    end
                    return options
                end,
            }
        end
        package.preload["ui/widget/textwidget"] = function()
            return {
                new = function(_, options)
                    options = options or {}
                    options.kind = "text"
                    local font_size = options.face and options.face.size or 12
                    function options:getSize()
                        return { w = #(options.text or "") * font_size, h = font_size }
                    end
                    function options:getWidth()
                        return self:getSize().w
                    end
                    return options
                end,
            }
        end
        package.preload["ui/uimanager"] = function()
            return {
                show = function() end,
                setDirty = function(_, _, callback)
                    dirty_count = dirty_count + 1
                    if callback then
                        callback()
                    end
                end,
            }
        end
        package.preload["ffi/util"] = function()
            return {
                runInSubProcess = function() return 42 end,
                terminateSubProcess = function() end,
            }
        end
        package.preload["suwayomi/subprocess/job"] = function()
            return {
                buildResultPath = function(prefix)
                    return "/settings/" .. prefix .. ".json"
                end,
                start = function(options)
                    local active = options.active or {}
                    active.on_finish = options.on_finish
                    active.on_timeout = options.on_timeout
                    table.insert(started_jobs, active)
                    return active
                end,
                cancel = function(active)
                    table.insert(canceled_jobs, active)
                    active.canceled = true
                end,
            }
        end
        package.preload["suwayomi/ui/thumbnail_cache"] = function()
            return {
                getKey = function(credentials, thumbnail_url)
                    return (credentials and credentials.server_url or "") .. "|" .. tostring(thumbnail_url)
                end,
                find = function(_, thumbnail_url)
                    return cache_paths[thumbnail_url]
                end,
                isDecodedPath = function(path)
                    return tostring(path or ""):match("%.bb$") ~= nil
                end,
                loadDecoded = function(path)
                    return decoded_images[path]
                end,
            }
        end
        package.preload["suwayomi/ui/thumbnail_worker"] = function()
            return {
                run = function() end,
                readResult = function() end,
            }
        end
        package.preload["suwayomi/ui/menu_utils"] = function()
            return {
                applyNativeTitleBarStyle = function(options) return options end,
                applyTitleBarOptions = function(menu, options)
                    menu.applied_title = options and options.title
                end,
                applyCloseCallback = function(menu, options)
                    menu.close_callback = options and options.close_callback
                end,
            }
        end
        package.preload["ui/widget/multiinputdialog"] = function() return {} end
        package.preload["ui/widget/menu"] = function()
            local Menu = {}
            function Menu:new(options)
                options = options or {}
                options.page = 1
                options.perpage = options.items_per_page or 10
                options.itemnumber = 1
                options.item_group = newGroup()
                options.inner_dimen = { w = 480, h = 641 }
                -- Native Menu measures mandatory text before rendering each title.
                for _, item in ipairs(options.item_table or {}) do
                    if item.mandatory then
                        local mandatory = require("ui/widget/textwidget"):new{ text = item.mandatory }
                        require("ui/widget/textboxwidget"):new{
                            text = item.text,
                            width = options.inner_dimen.w - mandatory:getWidth(),
                        }
                    end
                end
                options.page_info = {
                    resetLayout = function() end,
                    getSize = function() return { h = 0 } end,
                }
                options.return_button = { resetLayout = function() end }
                options.content_group = { resetLayout = function() end }
                options.item_dimen = {
                    copy = function()
                        return {
                            w = 200,
                            h = 40,
                            copy = function(dimen) return { w = dimen.w, h = dimen.h, copy = dimen.copy } end,
                        }
                    end,
                }
                options.dimen = {
                    copy = function(dimen) return dimen end,
                    combine = function(_, other) return other end,
                }
                options.font_size = 18
                options.line_color = "line"
                options.show_parent = options
                function options:onMenuChoice(item) if item.callback then item.callback() end end
                function options:onMenuSelect(item)
                    if item.select_enabled == false then return true end
                    self:onMenuChoice(item)
                    if self.close_callback then self.close_callback() end
                    return true
                end
                function options:_recalculateDimen()
                    self.recalculated = true
                end
                function options:updatePageInfo(select_number)
                    self.updated_select_number = select_number
                end
                function options:mergeTitleBarIntoLayout()
                    self.merged_title_bar = true
                end
                return options
            end
            function Menu.getMenuText(item)
                return item.text
            end
            return Menu
        end
    end

    before_each(installStubs)
    after_each(clearModules)

    local function findWidgetByKind(widget, kind, seen)
        if type(widget) ~= "table" then
            return nil
        end
        seen = seen or {}
        if seen[widget] then
            return nil
        end
        seen[widget] = true
        if widget.kind == kind then
            return widget
        end
        for _, child in ipairs(widget) do
            local found = findWidgetByKind(child, kind, seen)
            if found then
                return found
            end
        end
        return nil
    end

    local function collectWidgetsByKind(widget, kind, widgets, seen)
        if type(widget) ~= "table" then
            return widgets
        end
        widgets = widgets or {}
        seen = seen or {}
        if seen[widget] then
            return widgets
        end
        seen[widget] = true
        if widget.kind == kind then
            table.insert(widgets, widget)
        end
        for _, child in pairs(widget) do
            collectWidgetsByKind(child, kind, widgets, seen)
        end
        return widgets
    end

    it("keeps Library navigation alive when native Menu selects categories and manga", function()
        local browse = require("suwayomi/ui/browse")
        local retired, selected, manga_menu = false
        local categories = browse.showLibraryCategoryMenu({ { id = 1, name = "Reading" } }, function()
            manga_menu = browse.showLibraryMangaMenu({ { id = 7, title = "Saved" } }, function(manga)
                if not retired then selected = manga.id end
            end, { close_callback = function() retired = true end })
        end, { close_callback = function() retired = true end })
        categories:onMenuSelect(categories.item_table[1])
        manga_menu:onMenuSelect(manga_menu.item_table[1])
        assert.are.equal(7, selected)
        assert.is_false(retired)
        manga_menu.close_callback()
        assert.is_true(retired)
    end)

    it("uses KOReader detailed-list sizing and cfont row text", function()
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Results",
            item_table = {
                {
                    text = "Manga title",
                    subtitle = "MangaDex",
                    mandatory = "12 chapters",
                    manga = { id = "m1" },
                },
            },
        }

        assert.is_true(menu.is_borderless)
        assert.is_false(menu.is_popout)
        assert.is_true(menu.title_bar_fm_style)
        assert.is_true(menu.perpage <= 10)
        assert.is_true(menu.item_dimen.h >= 63)

        local textboxes = collectWidgetsByKind(menu.item_group[1], "textbox")
        local saw_title = false
        local saw_subtitle = false
        local saw_metadata = false
        for _, widget in ipairs(textboxes) do
            if widget.text == "Manga title" then
                saw_title = widget.bold ~= true
                    and widget.face.name == "cfont"
            elseif widget.text == "MangaDex" then
                saw_subtitle = widget.face.name == "cfont"
            elseif widget.text == "12 chapters" then
                saw_metadata = widget.face.name == "cfont"
            end
        end
        assert.is_true(saw_title)
        assert.is_true(saw_subtitle)
        assert.is_true(saw_metadata)
    end)

    it("shows browse covers in a grid without title or metadata labels", function()
        local browse = require("suwayomi/ui/browse")
        local manga, selected = {}, nil
        for index = 1, 7 do
            manga[index] = { id = index, title = "Manga " .. index, thumbnail_url = "/cover/" .. index }
            cache_paths[manga[index].thumbnail_url] = "/cover-" .. index .. ".bb"
            decoded_images["/cover-" .. index .. ".bb"] = { id = index }
        end
        local menu = browse.showMangaMenu(manga, function(item) selected = item.id end)

        assert.are.equal(2, #menu.item_group)
        assert.are.equal(3, #menu.layout[1])
        assert.are.equal(3, #menu.layout[2])
        assert.are.same({ { 1, 2, 3, 4, 5, 6 }, { 7 } }, menu.page_items)
        local tile = menu.layout[1][2]
        local image = findWidgetByKind(tile, "image")
        assert.is_true(image.width > 64)
        assert.is_true(image.height > 96)
        assert.is_nil(findWidgetByKind(tile, "textbox"))
        assert.is_nil(findWidgetByKind(tile, "text"))
        tile:onTapSelect()
        assert.are.equal(2, selected)
        local held
        menu.onMenuHold = function(_, item) held = item.manga.id end
        tile:onHoldSelect()
        assert.are.equal(2, held)

        menu.page = 2
        menu:updateItems(1, true)
        assert.are.equal(1, #menu.layout[1])
        assert.are.equal(7, menu.layout[1][1].entry.manga.id)
        browse.updateMangaMenu(menu, { manga[1] }, function() end)
        assert.are.equal(1, menu.page)
        assert.are.equal(1, menu.page_num)
        assert.is_true(menu.cover_grid)
    end)

    it("keeps browse status and paging rows full width around cover rows", function()
        local browse = require("suwayomi/ui/browse")
        local next_page = false
        local menu = browse.showMangaMenu({
            { raw_menu_row = true, text = "Loading", select_enabled = false },
            { id = 1, title = "One" }, { id = 2, title = "Two" },
        }, nil, { on_next_page = function() next_page = true end })
        assert.are.equal(menu.inner_dimen.w, menu.layout[1][1].dimen.w)
        assert.are.equal(2, #menu.layout[2])
        assert.are.equal(menu.inner_dimen.w, menu.layout[3][1].dimen.w)
        assert.are.equal("Loading", findWidgetByKind(menu.layout[1][1], "textbox").text)
        menu.layout[3][1]:onTapSelect()
        assert.is_true(next_page)
    end)

    it("loads poster-sized covers and retains usable placeholders after failures", function()
        local browse = require("suwayomi/ui/browse")
        local menu = browse.showMangaMenu({
            { id = 1, title = "One", thumbnail_url = "/cover/one" },
            { id = 2, title = "Two" },
        }, nil, { thumbnail_credentials = { server_url = "http://example.test" } })
        assert.are.equal(1, #started_jobs)
        assert.are.same({ variant = "poster", width = 240, height = 360 }, started_jobs[1].thumbnail_options)
        started_jobs[1].on_finish(started_jobs[1], { ok = false })
        assert.is_true(menu.item_table[1].thumbnail_failed)
        assert.is_not_nil(findWidgetByKind(menu.layout[1][1], "text"))
        assert.is_not_nil(findWidgetByKind(menu.layout[1][2], "text"))
        assert.are.equal(1, #started_jobs)
        browse.updateMangaMenu(menu, {}, nil)
        assert.are.equal(0, #menu.item_group)
        assert.are.equal(1, menu.page)
    end)

    it("fits the cover grid on narrow and landscape screens", function()
        local list_menu = require("suwayomi/ui/list_menu")
        local menu = { item_table = {}, page = 9 }
        for index = 1, 17 do menu.item_table[index] = { manga = { id = index } } end
        for _, dimensions in ipairs({ { 320, 480 }, { 800, 320 } }) do
            menu.inner_dimen = { w = dimensions[1] }
            menu.available_height = dimensions[2]
            list_menu.setupGrid(menu)
            local seen = {}
            for _, rows in ipairs(menu._suwayomi_grid_rows) do
                local height = 0
                for _, row in ipairs(rows) do
                    height = height + menu.item_table[row[1]].height
                    assert.is_true(#row * menu.item_width <= dimensions[1])
                    for _, index in ipairs(row) do table.insert(seen, index) end
                end
                assert.is_true(height <= dimensions[2])
            end
            assert.are.equal(17, #seen)
            for index = 1, 17 do assert.are.equal(index, seen[index]) end
            assert.is_true(menu.page <= menu.page_num)
        end
    end)

    it("restores grid focus by item number with a full-width row above covers", function()
        local browse = require("suwayomi/ui/browse")
        local menu = browse.showMangaMenu({
            { raw_menu_row = true, text = "Status" },
            { id = 1, title = "One" }, { id = 2, title = "Two" },
        }, nil)
        -- Exercise the native Menu's single-column focus calculation.
        menu.updatePageInfo = function(self, index)
            assert.are.equal(1, #self.layout[1])
            self.selected = { x = 1, y = index }
            self.layout[index][1]:onFocus()
            self.itemnumber = nil
        end
        menu._suwayomi_pending_itemnumber = 3
        menu:updateItems()
        assert.are.same({ x = 2, y = 2 }, menu.selected)
        assert.are.equal("black", menu.layout[2][2]._underline_container.color)
        menu.layout[2][2]:onUnfocus()
        assert.are.equal("white", menu.layout[2][2]._underline_container.color)
    end)

    it("switches between list, covers, and titles below covers through the view button", function()
        local browse = require("suwayomi/ui/browse")
        local options = {}
        options.on_view_mode_changed = function(mode)
            options.view_mode = mode
            return true
        end
        local manga = { { id = 1, title = "A long manga title that wraps below the cover", thumbnail_url = "/one" } }
        cache_paths["/one"] = "/one.bb"
        decoded_images["/one.bb"] = {}
        local menu = browse.showMangaMenu(manga, nil, options)
        local button = menu._suwayomi_view_button
        assert.is_true(button.visible)
        assert.are.equal(button, menu.return_button[1])
        button.callback()
        assert.are.equal("cover_only", view_dialog.current)
        assert.are.same({ "list", "cover_only", "cover_text" }, {
            view_dialog.choices[1].value, view_dialog.choices[2].value, view_dialog.choices[3].value,
        })
        view_dialog.onSelect("cover_text")
        local tile = menu.layout[1][1]
        local column = findWidgetByKind(tile, "vertical_group")
        assert.is_not_nil(findWidgetByKind(column[1], "image"))
        assert.are.equal(manga[1].title, column[2].text)
        assert.are.equal("center", column[2].alignment)
        assert.is_true(column[2].height_overflow_show_ellipsis)
        assert.are.equal(32, column[2].height)

        button.callback()
        assert.are.equal("cover_text", view_dialog.current)
        view_dialog.onSelect("list")
        assert.is_false(menu.cover_grid)
        assert.are.equal(menu.inner_dimen.w, menu.item_group[1].dimen.w)
        assert.is_true(menu.item_group[1].dimen.h < 200)
        assert.are.equal(manga[1].title, findWidgetByKind(menu.item_group[1], "textbox").text)
        assert.is_true(findWidgetByKind(menu.item_group[1], "image").width < 64)

        browse.updateMangaMenu(menu, manga, nil, options)
        assert.are.equal("list", menu.view_mode)
        assert.are.equal(button, menu._suwayomi_view_button)
        button.callback()
        view_dialog.onSelect("cover_only")
        assert.is_nil(findWidgetByKind(menu.layout[1][1], "textbox"))
        assert.is_true(findWidgetByKind(menu.layout[1][1], "image").width > 64)
    end)

    it("keeps the current view when its preference cannot be saved", function()
        local browse = require("suwayomi/ui/browse")
        local menu = browse.showMangaMenu({ { id = 1, title = "One" } }, nil, {
            on_view_mode_changed = function() return false end,
        })
        menu._suwayomi_view_button.callback()
        view_dialog.onSelect("list")
        assert.are.equal("cover_only", menu.view_mode)
        assert.is_true(menu.cover_grid)
    end)

    it("preserves the visible manga across view changes and cancels obsolete cover jobs", function()
        local browse = require("suwayomi/ui/browse")
        local list_menu = require("suwayomi/ui/list_menu")
        local rows = {}
        for index = 1, 23 do rows[index] = { id = index, title = tostring(index), thumbnail_url = "/" .. index } end
        local page_changes = 0
        local menu = browse.showMangaMenu(rows, nil, {
            thumbnail_credentials = { server_url = "http://example.test" },
            on_page_changed = function() page_changes = page_changes + 1 end,
        })
        menu.inner_dimen.h = 501
        menu.page = 3
        menu.itemnumber = nil
        menu:updateItems()
        assert.are.equal(13, menu.layout[1][1].entry.manga.id)
        local stale_job = started_jobs[1]
        list_menu.setViewMode(menu, "cover_text")
        assert.are.equal(5, menu.page)
        assert.are.equal(13, menu.layout[1][1].entry.manga.id)
        assert.is_true(stale_job.canceled)
        stale_job.on_finish(stale_job, { ok = true, path = "/stale.bb" })
        assert.is_nil(menu.item_table[1].thumbnail_path)
        list_menu.setViewMode(menu, "list")
        local visible_ids = {}
        for _, widget in ipairs(menu.item_group) do visible_ids[widget.entry.manga.id] = true end
        assert.is_true(visible_ids[13])
        assert.is_true(page_changes >= 4)
        local list_job = started_jobs[#started_jobs]
        assert.are.same({ variant = "manga_cover", width = 64, height = 96 }, list_job.thumbnail_options)
    end)

    it("keeps long names in fixed-height rows like File Manager", function()
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Results",
            item_table = {
                {
                    text = "A very long manga title that needs wrapping instead of being cut short",
                    mandatory = "12 chapters",
                    thumbnail_placeholder = true,
                    height = 96,
                    manga = { id = "long" },
                },
                {
                    text = "Short",
                    mandatory = "1 chapter",
                    thumbnail_placeholder = true,
                    manga = { id = "short" },
                },
            },
        }

        assert.is_true(menu.items_max_lines >= 2)
        assert.is_true(menu.fixed_item_heights)
        assert.is_nil(menu.page_items)
        assert.is_nil(menu.item_table[1].height)
        assert.is_nil(menu.item_table[2].height)
        assert.are.equal(menu.item_height, menu.item_group[1].dimen.h)
        assert.are.equal(menu.item_height, menu.item_group[2].dimen.h)
    end)

    it("renders long pending-deletion status on first display without consuming the title width", function()
        local list_menu = require("suwayomi/ui/list_menu")
        local status = "Read · Archive deletion pending: close reader · Downloaded"
        local menu = list_menu.show{
            title = "Chapters",
            item_table = {
                { text = "Chapter 2", mandatory = status },
            },
        }

        local title_width, status_width
        for _, widget in ipairs(collectWidgetsByKind(menu.item_group[1], "textbox")) do
            if widget.text == "Chapter 2" then
                title_width = widget.width
            elseif widget.text == status then
                status_width = widget.width
            end
        end
        assert.is_true(title_width > 0)
        assert.is_true(status_width > 0)
        assert.is_true(title_width + status_width <= menu.item_group[1].dimen.w)
    end)

    it("opens the page containing the requested initial item", function()
        local list_menu = require("suwayomi/ui/list_menu")

        local menu = list_menu.show{
            title = "Chapters",
            itemnumber = 5,
            items_per_page = 2,
            item_table = {
                { text = "Chapter 1" },
                { text = "Chapter 2" },
                { text = "Chapter 3" },
                { text = "Chapter 4" },
                { text = "Chapter 5" },
            },
        }

        assert.are.equal(3, menu.page)
        assert.are.equal(5, menu.itemnumber)
        assert.are.equal(1, menu.updated_select_number)
        assert.are.equal("Chapter 5", menu.item_group[1].entry.text)
    end)

    it("passes state marker width into shared list menus before layout", function()
        local list_menu = require("suwayomi/ui/list_menu")

        local menu = list_menu.show{
            title = "Choices",
            state_w = 32,
            item_table = {
                {
                    text = "* 2",
                    state = { mark_type = "radio", checked = true },
                },
            },
        }

        assert.are.equal(32, menu.state_w)
    end)

    it("renders chapter rows with the shared row widget and no thumbnail gutter", function()
        local list_menu = require("suwayomi/ui/list_menu")

        local menu = list_menu.show{
            title = "Chapters",
            item_table = {
                {
                    text = "Chapter 1",
                    subtitle = "Official",
                    mandatory = "Read · Downloaded",
                    chapter = { id = "c1" },
                },
            },
        }

        local row_group = menu.item_group[1][1][1]
        local left_padding = row_group[1]
        assert.are.equal("horizontal_group", row_group.kind)
        assert.are.equal("horizontal_span", left_padding.kind)
        assert.are.equal(10, left_padding.width)
        assert.is_nil(findWidgetByKind(menu.item_group[1], "text"))
        assert.are.equal(0, #started_jobs)

        local textboxes = collectWidgetsByKind(menu.item_group[1], "textbox")
        local saw_title = false
        local saw_subtitle = false
        local saw_metadata = false
        for _, widget in ipairs(textboxes) do
            if widget.text == "Chapter 1" then
                saw_title = widget.face.name == "cfont"
            elseif widget.text == "Official" then
                saw_subtitle = widget.face.name == "cfont"
            elseif widget.text == "Read · Downloaded" then
                saw_metadata = widget.face.name == "cfont"
            end
        end
        assert.is_true(saw_title)
        assert.is_true(saw_subtitle)
        assert.is_true(saw_metadata)
    end)

    it("shows menu rows, discovers cached thumbnails, and schedules only visible uncached thumbnails", function()
        cache_paths["/cached.jpg"] = "/settings/cached.jpg"
        local cached_image = { kind = "raw_bitmap" }
        raw_images["/settings/cached.jpg"] = cached_image
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Results",
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                { text = "Cached", manga = { id = "cached" }, thumbnail_url = "/cached.jpg" },
                { text = "Remote A", manga = { id = "a" }, thumbnail_url = "/a.jpg" },
                { text = "Remote B", manga = { id = "b" }, thumbnail_url = "/b.jpg" },
                { text = "Remote C", manga = { id = "c" }, thumbnail_url = "/c.jpg" },
                { text = "Next page" },
            },
            items_per_page = 5,
        }

        assert.are.same(cached_image, findWidgetByKind(menu.item_group[1], "image").image)
        assert.are.equal(2, #started_jobs)
        assert.are.equal("/a.jpg", started_jobs[1].thumbnail_url)
        assert.are.equal("/b.jpg", started_jobs[2].thumbnail_url)
        assert.are.equal(5, #menu.item_group)
    end)

    it("renders source rows with thumbnail placeholders and remote icon jobs", function()
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Sources",
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                {
                    text = "MangaDex",
                    subtitle = "EN",
                    mandatory = "18+",
                    source = { id = "s1" },
                    thumbnail_placeholder = true,
                    thumbnail_url = "/icons/mangadex.png",
                },
            },
        }

        assert.is_not_nil(findWidgetByKind(menu.item_group[1], "text"))
        assert.are.equal(1, #started_jobs)
        assert.are.equal("/icons/mangadex.png", started_jobs[1].thumbnail_url)
    end)

    it("renders poster-shaped manga thumbnail slots and cache jobs", function()
        local decoded_image = { kind = "decoded_bitmap" }
        cache_paths["/cover.webp"] = "/settings/cover.bb"
        decoded_images["/settings/cover.bb"] = decoded_image
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Results",
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                {
                    text = "Frieren",
                    manga = { id = "m1" },
                    thumbnail_placeholder = true,
                    thumbnail_url = "/cover.webp",
                    thumbnail_variant = "manga_cover",
                    thumbnail_width = 64,
                    thumbnail_height = 96,
                },
            },
        }

        local image = findWidgetByKind(menu.item_group[1], "image")
        local frame = findWidgetByKind(menu.item_group[1], "frame")
        assert.are.same(decoded_image, image.image)
        assert.are.equal(62, image.width)
        assert.are.equal(93, image.height)
        assert.are.equal(64, frame.width)
        assert.are.equal(95, frame.height)
        assert.are.equal(96, menu.item_group[1].dimen.h)
        assert.are.equal(0, #started_jobs)
    end)

    it("requests distinct poster-shaped cache variants for uncached manga thumbnails", function()
        local seen_options
        package.loaded["suwayomi/ui/thumbnail_cache"] = nil
        package.preload["suwayomi/ui/thumbnail_cache"] = function()
            return {
                getKey = function(_, thumbnail_url, options)
                    seen_options = options
                    return "key:" .. tostring(thumbnail_url) .. ":" .. tostring(options and options.variant)
                end,
                find = function(_, _, options)
                    seen_options = options
                    return nil
                end,
                isDecodedPath = function()
                    return false
                end,
            }
        end
        local manga_menu = require("suwayomi/ui/manga_menu")

        manga_menu.show{
            title = "Results",
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                {
                    text = "Frieren",
                    manga = { id = "m1" },
                    thumbnail_url = "/cover.jpg",
                    thumbnail_variant = "manga_cover",
                    thumbnail_width = 64,
                    thumbnail_height = 96,
                },
            },
        }

        assert.are.same({
            variant = "manga_cover",
            width = 64,
            height = 96,
        }, seen_options)
        assert.are.same({
            variant = "manga_cover",
            width = 64,
            height = 96,
        }, started_jobs[1].thumbnail_options)
    end)

    it("renders decoded cached thumbnails as in-memory images", function()
        local decoded_image = { kind = "decoded_bitmap" }
        cache_paths["/cached.webp"] = "/settings/cached.bb"
        decoded_images["/settings/cached.bb"] = decoded_image
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Results",
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                { text = "Cached", manga = { id = "cached" }, thumbnail_url = "/cached.webp" },
            },
        }

        local image = findWidgetByKind(menu.item_group[1], "image")
        assert.are.same(decoded_image, image.image)
        assert.is_nil(image.file)
    end)

    it("uses the placeholder when decoded cached thumbnails cannot be loaded", function()
        cache_paths["/cached.webp"] = "/settings/cached.bb"
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Results",
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                { text = "Cached", manga = { id = "cached" }, thumbnail_url = "/cached.webp" },
            },
        }

        assert.is_nil(findWidgetByKind(menu.item_group[1], "image"))
        assert.is_not_nil(findWidgetByKind(menu.item_group[1], "text"))
    end)

    it("renders cached raw thumbnails without a request even when another thumbnail fails", function()
        local raw_image = { kind = "raw_bitmap" }
        cache_paths["/cached.jpg"] = "/settings/cached.jpg"
        raw_images["/settings/cached.jpg"] = raw_image
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Results",
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                { text = "Cached", manga = { id = "cached" }, thumbnail_url = "/cached.jpg" },
                { text = "Missing", manga = { id = "missing" }, thumbnail_url = "/missing.jpg" },
            },
        }

        assert.are.same(raw_image, findWidgetByKind(menu.item_group[1], "image").image)
        assert.is_nil(findWidgetByKind(menu.item_group[2], "image"))
        assert.are.equal(1, #started_jobs)
        assert.are.equal("/missing.jpg", started_jobs[1].thumbnail_url)
        started_jobs[1].on_finish(started_jobs[1], { ok = false })
        assert.are.same(raw_image, findWidgetByKind(menu.item_group[1], "image").image)
        assert.are.equal(1, #started_jobs)
    end)

    it("replaces undecodable raw thumbnails through the normal online fetch path", function()
        cache_paths["/invalid.jpg"] = "/settings/invalid.jpg"
        image_errors["/settings/invalid.jpg"] = "invalid image"
        cache_paths["/unavailable.png"] = "/settings/unavailable.png"
        local manga_menu = require("suwayomi/ui/manga_menu")
        local menu = manga_menu.show{
            title = "Results",
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                { text = "Invalid", thumbnail_url = "/invalid.jpg" },
                { text = "Unavailable", thumbnail_url = "/unavailable.png" },
            },
        }

        assert.is_nil(findWidgetByKind(menu.item_group[1], "image"))
        assert.is_nil(findWidgetByKind(menu.item_group[2], "image"))
        assert.is_not_nil(findWidgetByKind(menu.item_group[1], "text"))
        assert.is_not_nil(findWidgetByKind(menu.item_group[2], "text"))
        assert.are.equal(2, #started_jobs)
        local replacement = { kind = "replacement_bitmap" }
        decoded_images["/settings/replacement.bb"] = replacement
        started_jobs[1].on_finish(started_jobs[1], { ok = true, path = "/settings/replacement.bb" })
        assert.are.same(replacement, findWidgetByKind(menu.item_group[1], "image").image)
        started_jobs[2].on_finish(started_jobs[2], { ok = false })
        assert.is_nil(findWidgetByKind(menu.item_group[2], "image"))
        assert.are.equal(2, #started_jobs)
    end)

    it("cancels active thumbnail jobs when menu contents are replaced", function()
        local manga_menu = require("suwayomi/ui/manga_menu")
        local menu = manga_menu.show{
            thumbnail_credentials = { server_url = "https://old.example" },
            item_table = {
                { text = "Old", manga = { id = "old" }, thumbnail_url = "/same.jpg" },
            },
        }
        assert.are.equal(1, #started_jobs)

        manga_menu.update(menu, {
            thumbnail_credentials = { server_url = "https://new.example" },
            item_table = {
                { text = "New", manga = { id = "new" }, thumbnail_url = "/same.jpg" },
            },
        })

        assert.are.equal(1, #canceled_jobs)
        assert.is_true(started_jobs[1].canceled)
        assert.are.equal(2, #started_jobs)
    end)

    it("ignores stale thumbnail finishes from previous menu generations", function()
        local manga_menu = require("suwayomi/ui/manga_menu")
        local menu = manga_menu.show{
            thumbnail_credentials = { server_url = "https://old.example" },
            item_table = {
                { text = "Old", manga = { id = "old" }, thumbnail_url = "/same.jpg" },
            },
        }
        local old_job = started_jobs[1]

        manga_menu.update(menu, {
            thumbnail_credentials = { server_url = "https://new.example" },
            item_table = {
                { text = "New", manga = { id = "new" }, thumbnail_url = "/same.jpg" },
            },
        })
        old_job.on_finish(old_job, { ok = true, path = "/settings/old.jpg" })

        assert.is_nil(menu.item_table[1].thumbnail_path)
    end)

    it("does not retry thumbnails that finish with a worker failure", function()
        local manga_menu = require("suwayomi/ui/manga_menu")
        local menu = manga_menu.show{
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                { text = "Remote", manga = { id = "remote" }, thumbnail_url = "/remote.webp" },
            },
        }
        local failed_job = started_jobs[1]

        failed_job.on_finish(failed_job, { ok = false, error = "Unsupported thumbnail image type." })

        assert.is_true(menu.item_table[1].thumbnail_failed)
        assert.are.equal(1, #started_jobs)
    end)

    it("cancels active thumbnail jobs on close", function()
        local manga_menu = require("suwayomi/ui/manga_menu")
        local menu = manga_menu.show{
            item_table = {
                { text = "Remote", manga = { id = "remote" }, thumbnail_url = "/remote.jpg" },
            },
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
        }

        menu:onCloseWidget()

        assert.are.equal(1, #canceled_jobs)
        assert.is_true(started_jobs[1].canceled)
    end)
end)
