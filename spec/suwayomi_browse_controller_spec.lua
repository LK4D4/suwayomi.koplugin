package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/browse/controller", function()
    it("exports source cache, worker, and browse flow methods", function()
        helper.assertControllerModule("suwayomi/browse/controller", {
            "filterSourcesByLanguage",
            "startSourceFetchWorker",
            "pollSourceFetch",
            "browseSuwayomi",
        })
    end)
end)
