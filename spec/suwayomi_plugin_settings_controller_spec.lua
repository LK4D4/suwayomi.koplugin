package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/plugin/settings_controller", function()
    it("exports settings dialog and settings menu methods", function()
        helper.assertControllerModule("suwayomi/plugin/settings_controller", {
            "showSettings",
            "showLoginDialog",
            "showDownloadDirectoryDialog",
            "buildSettingsMenu",
        })
    end)
end)
