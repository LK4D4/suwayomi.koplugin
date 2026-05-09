package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/chapters/actions", function()
    it("exports chapter and bulk action methods", function()
        helper.assertControllerModule("suwayomi/chapters/actions", {
            "openChapter",
            "markChapterRead",
            "downloadSelectedChapters",
            "performBulkChapterAction",
        })
    end)
end)
