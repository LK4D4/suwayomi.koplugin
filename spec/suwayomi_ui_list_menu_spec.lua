package.path = "?.lua;" .. package.path

describe("suwayomi/ui/list_menu", function()
    local created_options

    before_each(function()
        created_options = nil
        package.loaded["suwayomi/ui/list_menu"] = nil
        package.loaded["ui/widget/menu"] = nil

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
        package.preload["ui/widget/menu"] = nil
        package.loaded["ui/widget/menu"] = nil
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
