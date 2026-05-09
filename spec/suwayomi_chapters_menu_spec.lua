package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/chapters/menu", function()
    it("exports chapter menu construction methods", function()
        helper.assertControllerModule("suwayomi/chapters/menu", {
            "buildChapterMenuItems",
            "buildChapterMenuOptions",
            "buildQuickChapterMenuItems",
            "showChapterActions",
        })
    end)
end)
