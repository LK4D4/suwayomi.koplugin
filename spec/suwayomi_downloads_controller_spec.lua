package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/downloads/controller", function()
    it("exports downloads hub and queue policy methods", function()
        helper.assertControllerModule("suwayomi/downloads/controller", {
            "showDownloads",
            "getDownloadJobTitle",
            "applyKeepNextUnreadDownloadsPolicy",
            "reconcileDownloadedChapterLedger",
        })
    end)
end)
