package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/plugin/home", function()
    after_each(function()
        package.preload["suwayomi/i18n"] = nil
        package.loaded["suwayomi/i18n"] = nil
        package.preload.gettext = nil
        package.loaded.gettext = nil
    end)

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

    it("routes home action labels through i18n", function()
        package.preload.gettext = function()
            return function(text)
                return text
            end
        end
        package.preload["suwayomi/i18n"] = function()
            return {
                t = function(text)
                    return "tx:" .. text
                end,
            }
        end
        package.loaded["suwayomi/plugin/home"] = nil
        package.loaded["suwayomi/i18n"] = nil

        local controller = require("suwayomi/plugin/home")
        local plugin = {}
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        local actions = plugin:buildHomeActions()

        assert.are.equal("tx:Library", actions[1].text)
        assert.are.equal("tx:Close plugin", actions[#actions].text)
    end)

    it("cleans marker i18n stubs between tests", function()
        assert.is_nil(package.preload["suwayomi/i18n"])
        assert.is_nil(package.loaded["suwayomi/i18n"])
    end)

    it("preserves the actual failure count when a locale uses singular for 21", function()
        helper.stubControllerDependencies()
        package.preload.gettext = function()
            return setmetatable({
                ngettext = function(singular, plural, count)
                    if count % 10 == 1 and count % 100 ~= 11 then
                        return "singular:" .. singular
                    end
                    return "plural:" .. plural
                end,
            }, {
                __call = function(_, text)
                    return "tx:" .. text
                end,
            })
        end
        package.loaded.gettext = nil
        package.preload["suwayomi/i18n"] = nil
        package.loaded["suwayomi/i18n"] = nil
        package.loaded["suwayomi/plugin/home"] = nil
        local controller = require("suwayomi/plugin/home")
        local failed_count = 0
        local queue = {
            getFailedCount = function()
                return failed_count
            end,
        }
        local plugin = {
            getDownloadQueue = function()
                return queue
            end,
        }
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        assert.are.equal("tx:Downloads", plugin:buildHomeActions()[3].text)
        failed_count = 1
        assert.are.equal("singular:Downloads · 1 failed", plugin:buildHomeActions()[3].text)
        failed_count = 3
        assert.are.equal("plural:Downloads · 3 failed", plugin:buildHomeActions()[3].text)
        failed_count = 21
        assert.are.equal("singular:Downloads · 21 failed", plugin:buildHomeActions()[3].text)
    end)
end)
