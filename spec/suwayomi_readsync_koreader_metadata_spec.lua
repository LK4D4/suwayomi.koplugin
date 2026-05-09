package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/readsync/koreader_metadata", function()
    it("exports KOReader sidecar and history helpers", function()
        helper.assertControllerModule("suwayomi/readsync/koreader_metadata", {
            "getKoreaderMetadataPathForDocument",
            "loadKoreaderMetadataTable",
            "setKoreaderChapterReadState",
            "loadKoreaderHistoryPaths",
        })
    end)
end)
