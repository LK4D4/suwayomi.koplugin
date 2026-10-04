package.path = "?.lua;" .. package.path

describe("suwayomi/ui/menu_utils", function()
    before_each(function()
        package.loaded["suwayomi/ui/menu_utils"] = nil
    end)

    after_each(function()
        package.loaded["suwayomi/ui/menu_utils"] = nil
    end)

    it("binds title-bar left tap and hold callbacks to the menu", function()
        local menu_utils = require("suwayomi/ui/menu_utils")
        local menu = {}
        local calls = {}

        menu_utils.applyTitleBarOptions(menu, {
            on_title_bar_left_tap = function(target, value)
                table.insert(calls, { type = "tap", menu = target, value = value })
            end,
            on_title_bar_left_hold = function(target, value)
                table.insert(calls, { type = "hold", menu = target, value = value })
            end,
        })

        menu.onLeftButtonTap("tap-value")
        menu.onLeftButtonHold("hold-value")

        assert.are.same({
            { type = "tap", menu = menu, value = "tap-value" },
            { type = "hold", menu = menu, value = "hold-value" },
        }, calls)
    end)

    it("keeps an unchanged native title intact while still applying a changed title", function()
        local menu_utils = require("suwayomi/ui/menu_utils")
        local calls = {}
        local menu = { title = "Library", title_bar = {
            setTitle = function(_, text, no_refresh)
                assert.is_true(no_refresh)
                calls[#calls + 1] = text
            end,
        } }
        menu_utils.applyTitleBarOptions(menu, { title = "Library" })
        assert.same({}, calls)
        menu_utils.applyTitleBarOptions(menu, { title = "Chapters" })
        assert.same({ "Chapters" }, calls)
        assert.are.equal("Chapters", menu.title)
    end)
end)
