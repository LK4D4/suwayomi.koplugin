package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/readsync/controller", function()
    it("exports read-sync worker orchestration methods", function()
        helper.assertControllerModule("suwayomi/readsync/controller", {
            "startPendingReadSyncWorker",
            "applyPendingReadSyncResult",
            "syncReadStateNow",
            "onCloseDocument",
        })
    end)
end)
