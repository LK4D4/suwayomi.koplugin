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
end)
