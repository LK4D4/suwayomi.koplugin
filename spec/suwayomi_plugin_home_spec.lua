package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/plugin/home", function()
    it("exports the home/menu methods as a controller boundary", function()
        helper.assertControllerModule("suwayomi/plugin/home", {
            "showHome",
            "showMessage",
            "withLoadingMessage",
            "addToMainMenu",
        })
    end)

    it("opens first-run setup from the main menu before showing home", function()
        package.loaded["suwayomi/plugin/home"] = nil
        helper.stubControllerDependencies()
        local HomeController = require("suwayomi/plugin/home")
        local plugin = {
            setup_options = nil,
            home_shown = false,
            isBookMode = function()
                return false
            end,
            closeMenu = function() end,
            needsOnboardingSetup = function()
                return true
            end,
            showOnboardingSetup = function(self, options)
                self.setup_options = options
            end,
            showHome = function(self)
                self.home_shown = true
            end,
        }
        for name, method in pairs(HomeController.methods) do
            if name ~= "showHome" then
                plugin[name] = method
            end
        end

        local menu_items = {}
        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi.callback({})

        assert.is_true(plugin.setup_options.first_run)
        assert.is_false(plugin.home_shown)
    end)
end)
