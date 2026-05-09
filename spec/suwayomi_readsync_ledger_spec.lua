package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/readsync/ledger", function()
    it("exports read ledger state helpers", function()
        helper.assertControllerModule("suwayomi/readsync/ledger", {
            "loadChapterLedger",
            "upsertChapterLedgerEntry",
            "buildPendingReadSyncBatch",
            "hasPendingReadSync",
        })
    end)
end)
