package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/manga/controller", function()
    it("exports manga/library action methods", function()
        helper.assertControllerModule("suwayomi/manga/controller", {
            "showMangaActions",
            "setMangaLibraryState",
            "refreshMangaChapters",
            "performMangaAction",
        })
    end)
end)
