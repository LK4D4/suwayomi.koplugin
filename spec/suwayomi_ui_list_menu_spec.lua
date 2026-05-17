package.path = "?.lua;" .. package.path

describe("suwayomi/ui/list_menu", function()
    local created_options
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
                function options:getSize()
                    local face = self.face or {}
                    local size = face.size or 12
                    return {
                        w = #tostring(self.text or "") * math.max(1, math.floor(size / 2)),
                        h = size,
                    }
                end
                function options:free() end
                return options
            end,
        }
    end

    before_each(function()
        created_options = nil
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
                        return options or {}
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
            items_max_lines = 2,
            multilines_show_more_text = false,
            items_mandatory_font_size = 12,
        })

        assert.is_false(menu.is_borderless)
        assert.is_true(menu.is_popout)
        assert.is_false(menu.title_bar_fm_style)
        assert.are.equal(2, menu.items_max_lines)
        assert.is_false(menu.multilines_show_more_text)
        assert.are.equal(12, menu.items_mandatory_font_size)
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
                self.item_dimen = { h = 64, copy = function(value) return value end }
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
