package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/chapters/context", function()
    it("exports chapter context and selection methods", function()
        helper.assertControllerModule("suwayomi/chapters/context", {
            "getChapterSelectionKey",
            "getVisibleChapters",
            "mergeChaptersWithReadLedger",
            "toggleChapterSelection",
        })
    end)
end)
