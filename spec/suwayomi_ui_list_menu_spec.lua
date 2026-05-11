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
                    return definition
                end,
            }
        end
        package.preload["ui/size"] = function()
            return {
                border = { thin = 1 },
                line = { thin = 1 },
                span = { horizontal_default = 3 },
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
            "ui/widget/textboxwidget",
            "ui/widget/textwidget",
            "ui/widget/container/underlinecontainer",
            "ui/widget/verticalgroup",
            "ui/widget/verticalspan",
        }) do
            package.preload[name] = widgetModule
        end

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
end)
