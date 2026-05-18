package.path = "?.lua;" .. package.path

describe("suwayomi/ui/list_menu", function()
    local created_options
    local created_textboxes
    local stubbed_modules

    local function widgetModule()
        return {
            new = function(_, options)
                return options or {}
            end,
        }
    end

    local function textWidgetModule()
        return {
            new = function(_, options)
                options = options or {}
                table.insert(created_textboxes, options)
                function options:getSize()
                    local face = self.face or {}
                    local size = face.size or 12
                    local natural_width = #tostring(self.text or "") * math.max(1, math.floor(size / 2))
                    local lines = 1
                    if self.width and self.width > 0 then
                        lines = math.max(1, math.ceil(natural_width / self.width))
                    end
                    return {
                        w = math.min(natural_width, self.width or natural_width),
                        h = size * lines,
                    }
                end
                function options:free() end
                function options:init() end
                return options
            end,
        }
    end

    before_each(function()
        created_options = nil
        created_textboxes = {}
        stubbed_modules = {
            "ui/bidi",
            "ffi/blitbuffer",
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
        }
        package.loaded["suwayomi/ui/list_menu"] = nil
        for _, name in ipairs(stubbed_modules) do
            package.loaded[name] = nil
            package.preload[name] = nil
        end

        package.preload["ui/bidi"] = function()
            return { auto = function(text) return text end }
        end
        package.preload["ffi/blitbuffer"] = function()
            return {
                COLOR_BLACK = "black",
                COLOR_DARK_GRAY = "dark_gray",
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
            return { getFace = function(_, name, size) return { name = name, size = size } end }
        end
        package.preload["ui/geometry"] = function()
            return {
                new = function(_, options)
                    options = options or {}
                    function options:copy()
                        return self
                    end
                    function options:combine(other)
                        return other or self
                    end
                    return options
                end,
            }
        end
        package.preload["ui/widget/container/inputcontainer"] = function()
            return {
                extend = function(_, definition)
                    definition.new = definition.new or function(_, options)
                        options = options or {}
                        setmetatable(options, { __index = definition })
                        if options.init then
                            options:init()
                        end
                        return options
                    end
                    return definition
                end,
            }
        end
        package.preload["ui/size"] = function()
            return {
                border = { thin = 1 },
                line = { thin = 1 },
                span = { horizontal_default = 3, vertical_default = 2 },
            }
        end
        package.preload["ui/uimanager"] = function()
            return { show = function() end, setDirty = function() end }
        end
        package.preload["ffi/util"] = function()
            return {}
        end
        package.preload["suwayomi/subprocess/job"] = function()
            return {}
        end
        package.preload["suwayomi/ui/thumbnail_cache"] = function()
            return {}
        end
        package.preload["suwayomi/ui/thumbnail_worker"] = function()
            return {}
        end
        package.preload["suwayomi/ui/menu_utils"] = function()
            return {
                applyNativeTitleBarStyle = function(options) return options end,
                applyTitleBarOptions = function(menu) return menu end,
                applyCloseCallback = function(menu) return menu end,
            }
        end
        for _, name in ipairs({
            "ui/widget/container/centercontainer",
            "ui/widget/container/framecontainer",
            "ui/gesturerange",
            "ui/widget/horizontalgroup",
            "ui/widget/horizontalspan",
            "ui/widget/imagewidget",
            "ui/widget/container/leftcontainer",
            "ui/widget/overlapgroup",
            "ui/widget/container/rightcontainer",
            "ui/widget/container/underlinecontainer",
            "ui/widget/verticalgroup",
            "ui/widget/verticalspan",
        }) do
            package.preload[name] = widgetModule
        end
        package.preload["ui/widget/textboxwidget"] = textWidgetModule
        package.preload["ui/widget/textwidget"] = textWidgetModule

        package.preload["ui/widget/menu"] = function()
            return {
                new = function(_, options)
                    created_options = options
                    return options
                end,
            }
        end
    end)

    after_each(function()
        for _, name in ipairs(stubbed_modules or {}) do
            package.preload[name] = nil
            package.loaded[name] = nil
        end
        package.loaded["suwayomi/ui/list_menu"] = nil
    end)

    it("creates KOReader file-manager-style list menus by default", function()
        local ListMenu = require("suwayomi/ui/list_menu")

        local menu = ListMenu.new({
            title = "Manga",
            item_table = {
                { text = "A very long manga title", mandatory = "12 chapters" },
            },
        })

        assert.are.same(created_options, menu)
        assert.are.equal("Manga", menu.title)
        assert.is_true(menu.is_borderless)
        assert.is_false(menu.is_popout)
        assert.is_true(menu.title_bar_fm_style)
        assert.is_true(menu.with_bottom_line)
        assert.are.equal("dark_gray", menu.bottom_line_color)
        assert.are.equal("tfont", menu.title_face.name)
        assert.is_true(menu.title_shrink_font_to_fit)
        assert.is_false(menu.subtitle)
        assert.are.equal(3, menu.items_max_lines)
        assert.is_true(menu.multilines_show_more_text)
        assert.is_nil(menu.items_mandatory_font_size)
    end)

    it("lets callers override list layout defaults", function()
        local ListMenu = require("suwayomi/ui/list_menu")

        local menu = ListMenu.new({
            title = "Compact",
            is_borderless = false,
            is_popout = true,
            title_bar_fm_style = false,
            with_bottom_line = false,
            title_face = { name = "custom-title", size = 30 },
            title_shrink_font_to_fit = false,
            items_max_lines = 2,
            multilines_show_more_text = false,
            items_mandatory_font_size = 12,
        })

        assert.is_false(menu.is_borderless)
        assert.is_true(menu.is_popout)
        assert.is_false(menu.title_bar_fm_style)
        assert.is_false(menu.with_bottom_line)
        assert.are.equal("custom-title", menu.title_face.name)
        assert.is_false(menu.title_shrink_font_to_fit)
        assert.are.equal(2, menu.items_max_lines)
        assert.is_false(menu.multilines_show_more_text)
        assert.are.equal(12, menu.items_mandatory_font_size)
    end)

    it("shows menus with caller-provided line limits", function()
        package.loaded["suwayomi/ui/list_menu"] = nil
        package.loaded["ui/widget/menu"] = nil
        package.loaded.device = nil
        package.preload.device = function()
            return {
                screen = {
                    scaleBySize = function(_, value) return value / 2 end,
                    getWidth = function() return 480 end,
                    getHeight = function() return 800 end,
                },
            }
        end
        package.preload["ui/widget/menu"] = function()
            return {
                new = function(_, options)
                    options.inner_dimen = { w = 320, h = 256 }
                    options.page = 1
                    options.itemnumber = 1
                    if options.items_max_lines then
                        options.page_items = { { 1 } }
                        options.item_table[1].height = 96
                    end
                    options.item_group = {
                        clear = function(self)
                            for index = #self, 1, -1 do
                                self[index] = nil
                            end
                        end,
                    }
                    options.page_info = { resetLayout = function() end }
                    options.return_button = { resetLayout = function() end }
                    options.content_group = { resetLayout = function() end }
                    options.updatePageInfo = function() end
                    options.mergeTitleBarIntoLayout = function() end
                    return options
                end,
            }
        end
        local ListMenu = require("suwayomi/ui/list_menu")

        local menu = ListMenu.show({
            title = "Chapters",
            item_table = {
                { text = "Chapter 1", subtitle = "Scanlator" },
            },
            items_max_lines = false,
        })

        assert.is_false(menu.items_max_lines)
        assert.are.equal("dark_gray", menu.line_color)
        assert.is_true(menu.with_bottom_line)
        assert.are.equal("dark_gray", menu.bottom_line_color)
        assert.are.equal("tfont", menu.title_face.name)
        assert.is_true(menu.title_shrink_font_to_fit)
        assert.is_false(menu.subtitle)
        assert.is_nil(menu.item_table[1].height)
    end)

    it("does not fire close callbacks for rows that keep the menu open", function()
        local ListMenu = require("suwayomi/ui/list_menu")
        local selected = false
        local closed = false
        local base_selected = false
        local menu = {
            item_table = {},
            onMenuChoice = function(_, item)
                if item.callback then
                    item.callback()
                end
            end,
            onMenuSelect = function(self, item)
                base_selected = true
                self:onMenuChoice(item)
                if self.close_callback then
                    self.close_callback()
                end
                return true
            end,
            close_callback = function()
                closed = true
            end,
        }

        ListMenu.install(menu, {})
        menu:onMenuSelect({
            text = "Extension",
            keep_menu_open = true,
            callback = function()
                selected = true
            end,
        })

        assert.is_true(selected)
        assert.is_false(closed)
        assert.is_false(base_selected)
    end)

    it("lets callers intercept title-bar close before the menu closes", function()
        local ListMenu = require("suwayomi/ui/list_menu")
        local intercepted = false
        local base_closed = false
        local menu = {
            item_table_stack = {},
            onClose = function()
                base_closed = true
                return true
            end,
        }

        ListMenu.install(menu, {
            on_close = function()
                intercepted = true
                return true
            end,
        })

        assert.is_true(menu:onClose())
        assert.is_true(intercepted)
        assert.is_false(base_closed)
    end)

    it("notifies callers after visible page changes", function()
        local ListMenu = require("suwayomi/ui/list_menu")
        local calls = {}
        local menu = {
            page = 2,
            item_table = {
                { text = "A" },
                { text = "B" },
                { text = "C" },
            },
            layout = {},
            item_group = {
                clear = function() end,
            },
            page_info = {
                resetLayout = function() end,
            },
            return_button = {
                resetLayout = function() end,
            },
            content_group = {
                resetLayout = function() end,
            },
            _recalculateDimen = function(self)
                self.perpage = 1
                self.page_num = 3
                self.item_width = 320
                self.item_height = 64
                self.item_dimen = { w = 320, h = 64, copy = function(value) return value end }
            end,
            updatePageInfo = function() end,
            mergeTitleBarIntoLayout = function() end,
            show_parent = "menu",
            line_color = "black",
        }

        ListMenu.install(menu, {
            on_page_changed = function(changed_menu, page)
                table.insert(calls, { menu = changed_menu, page = page })
            end,
        })

        menu:updateItems()

        assert.are.equal(1, #calls)
        assert.are.equal(menu, calls[1].menu)
        assert.are.equal(2, calls[1].page)

        menu:updateItems()

        assert.are.equal(1, #calls)

        menu.page = 3
        menu:updateItems()

        assert.are.equal(2, #calls)
        assert.are.equal(menu, calls[2].menu)
        assert.are.equal(3, calls[2].page)
    end)

    it("uses compact rows for section headers", function()
        local ListMenu = require("suwayomi/ui/list_menu")
        local menu = {
            item_width = 320,
            item_dimen = { h = 64 },
            _suwayomi_base_item_height = 64,
            available_height = 180,
            items_max_lines = 3,
            item_table = {
                {
                    text = "Installed (1)",
                    is_section_header = true,
                    select_enabled = false,
                    title_bold = true,
                },
                {
                    text = "A very very very very very long available extension title",
                    thumbnail_placeholder = true,
                },
            },
        }

        ListMenu.setupItemHeights(menu)

        assert.is_true(menu.item_table[1].height < menu._suwayomi_base_item_height)
        assert.is_true(menu.item_table[2].height >= menu._suwayomi_base_item_height)
        assert.are.same({ { 1, 2 } }, menu.page_items)
    end)

    it("keeps section headers compact in fixed-height menus", function()
        local ListMenu = require("suwayomi/ui/list_menu")
        local function copyDimen(value)
            local copy = {}
            for key, child in pairs(value) do
                copy[key] = child
            end
            copy.copy = copyDimen
            return copy
        end
        local menu = {
            page = 1,
            itemnumber = 1,
            item_table = {
                { text = "Installed (8)", is_section_header = true, select_enabled = false, title_bold = true },
                { text = "Extension", subtitle = "English", thumbnail_placeholder = true },
            },
            layout = {},
            item_group = {
                clear = function(self)
                    for index = #self, 1, -1 do
                        self[index] = nil
                    end
                end,
            },
            page_info = { resetLayout = function() end },
            return_button = { resetLayout = function() end },
            content_group = { resetLayout = function() end },
            _recalculateDimen = function(self)
                self.perpage = 2
                self.page_num = 1
                self.item_width = 320
                self.item_height = 64
                self._suwayomi_base_item_height = 64
                self.item_dimen = copyDimen{ w = 320, h = 64 }
            end,
            updatePageInfo = function() end,
            mergeTitleBarIntoLayout = function() end,
            show_parent = "menu",
            line_color = "black",
            fixed_item_heights = true,
            items_max_lines = 3,
        }

        ListMenu.install(menu, {})
        menu:updateItems()

        assert.is_true(menu.item_group[1].dimen.h < menu.item_group[2].dimen.h)
    end)

    it("packs fixed-height pages by compact section-header height", function()
        package.loaded["suwayomi/ui/list_menu"] = nil
        package.loaded["ui/widget/menu"] = nil
        package.preload["ui/widget/menu"] = function()
            return {
                new = function(_, options)
                    options.inner_dimen = { w = 320, h = 385 }
                    options.page = 1
                    options.itemnumber = 1
                    options.item_group = {
                        clear = function(self)
                            for index = #self, 1, -1 do
                                self[index] = nil
                            end
                        end,
                    }
                    options.page_info = { resetLayout = function() end }
                    options.return_button = { resetLayout = function() end }
                    options.content_group = { resetLayout = function() end }
                    options.updatePageInfo = function() end
                    options.mergeTitleBarIntoLayout = function() end
                    return options
                end,
            }
        end
        local ListMenu = require("suwayomi/ui/list_menu")

        local menu = ListMenu.show({
            title = "Extensions",
            item_table = {
                { text = "Installed (2)", is_section_header = true },
                { text = "Installed A", subtitle = "All", thumbnail_placeholder = true },
                { text = "Installed B", subtitle = "All", thumbnail_placeholder = true },
                { text = "Available (4)", is_section_header = true },
                { text = "Available A", subtitle = "All", thumbnail_placeholder = true },
                { text = "Available B", subtitle = "All", thumbnail_placeholder = true },
                { text = "Available C", subtitle = "All", thumbnail_placeholder = true },
                { text = "Available D", subtitle = "All", thumbnail_placeholder = true },
            },
            fixed_item_heights = true,
        })

        assert.are.equal(6, menu.perpage)
        assert.are.same({ { 1, 2, 3, 4, 5, 6, 7 }, { 8 } }, menu.page_items)
        assert.are.equal(7, #menu.item_group)
    end)

    it("keeps empty fixed-height menus on a valid page", function()
        package.loaded["suwayomi/ui/list_menu"] = nil
        package.loaded["ui/widget/menu"] = nil
        package.preload["ui/widget/menu"] = function()
            return {
                new = function(_, options)
                    options.inner_dimen = { w = 320, h = 385 }
                    options.page = 1
                    options.itemnumber = 1
                    options.item_group = {
                        clear = function(self)
                            for index = #self, 1, -1 do
                                self[index] = nil
                            end
                        end,
                    }
                    options.page_info = { resetLayout = function() end }
                    options.return_button = { resetLayout = function() end }
                    options.content_group = { resetLayout = function() end }
                    options.updatePageInfo = function() end
                    options.mergeTitleBarIntoLayout = function() end
                    return options
                end,
            }
        end
        local ListMenu = require("suwayomi/ui/list_menu")

        local menu = ListMenu.show({
            title = "Empty",
            item_table = {},
            fixed_item_heights = true,
        })

        assert.are.equal(1, menu.page_num)
        assert.are.same({ {} }, menu.page_items)
        assert.are.equal(0, #menu.item_group)
    end)

    it("shrinks long row titles before clipping fixed-height rows", function()
        package.loaded["suwayomi/ui/list_menu"] = nil
        package.loaded["ui/widget/menu"] = nil
        package.loaded.device = nil
        package.preload.device = function()
            return {
                screen = {
                    scaleBySize = function(_, value) return value / 2 end,
                    getWidth = function() return 480 end,
                    getHeight = function() return 800 end,
                },
            }
        end
        package.preload["ui/widget/menu"] = function()
            return {
                new = function(_, options)
                    options.inner_dimen = { w = 320, h = 256 }
                    options.page = 1
                    options.itemnumber = 1
                    options.item_group = {
                        clear = function(self)
                            for index = #self, 1, -1 do
                                self[index] = nil
                            end
                        end,
                    }
                    options.page_info = { resetLayout = function() end }
                    options.return_button = { resetLayout = function() end }
                    options.content_group = { resetLayout = function() end }
                    options.updatePageInfo = function() end
                    options.mergeTitleBarIntoLayout = function() end
                    return options
                end,
            }
        end
        local ListMenu = require("suwayomi/ui/list_menu")

        local title = "A very very very very very very very very very very very long chapter title"
        local line_height = 20
        local row_padding = 2 * 2 + 1
        local menu = ListMenu.show({
            title = "Chapters",
            item_table = {
                { text = title, subtitle = "Scanlator", title_bold = true },
            },
            items_max_lines = 3,
            fixed_item_heights = true,
        })
        local title_widget
        for _, widget in ipairs(created_textboxes) do
            if widget.text == title then
                title_widget = widget
            end
        end

        assert.are.equal(menu.item_height, menu.item_group[1].dimen.h)
        assert.is_true(menu.item_height >= 3 * line_height + row_padding)
        assert.is_nil(menu.page_items)
        assert.is_not_nil(title_widget)
        assert.is_true(title_widget.bold)
        assert.is_true(title_widget.face.size < 20)
    end)

    it("sets a default row separator color for title-bar menus", function()
        local ListMenu = require("suwayomi/ui/list_menu")

        local menu = ListMenu.new({
            title = "Manga",
            item_table = {
                { text = "Chapter 1" },
            },
        })

        assert.are.equal("dark_gray", menu.line_color)
    end)

    it("refreshes visible rows after thumbnail timeouts", function()
        local started_options
        package.loaded["suwayomi/subprocess/job"] = nil
        package.loaded["suwayomi/ui/thumbnail_cache"] = nil
        package.preload["suwayomi/subprocess/job"] = function()
            return {
                buildResultPath = function()
                    return "/settings/thumbnail.json"
                end,
                start = function(options)
                    started_options = options
                    return options.active
                end,
            }
        end
        package.preload["suwayomi/ui/thumbnail_cache"] = function()
            return {
                getKey = function(_, url)
                    return "key:" .. url
                end,
            }
        end

        local ListMenu = require("suwayomi/ui/list_menu")
        local updates = 0
        local item = {
            text = "Frieren",
            thumbnail_url = "/cover.jpg",
        }
        local menu = {
            item_table = { item },
            _suwayomi_thumbnail_credentials = { server_url = "https://suwayomi.example" },
            _suwayomi_thumbnail_generation = 0,
            updateItems = function(_, _, no_recalculate_dimen)
                updates = updates + 1
                assert.is_true(no_recalculate_dimen)
            end,
        }

        assert.is_true(ListMenu.startThumbnailJob(menu, item))
        started_options.on_timeout(menu._suwayomi_thumbnail_active["key:/cover.jpg"])

        assert.are.equal(1, updates)
        assert.is_true(item.thumbnail_failed)
        assert.is_nil(item.thumbnail_loading)
        assert.are.equal(0, menu._suwayomi_thumbnail_active_count)
    end)
end)
