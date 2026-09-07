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

    describe("message sizing", function()
        local module_names = {
            "device",
            "ui/font",
            "ui/uimanager",
            "ui/widget/infomessage",
            "ui/widget/textboxwidget",
            "ui/widget/textviewer",
            "suwayomi/ui",
            "suwayomi/i18n",
            "suwayomi/plugin/home",
            "suwayomi/client/library",
        }
        local saved_modules
        local screen_width, screen_height, text_height
        local measurements, shown, freed, scheduled
        local plugin, client

        before_each(function()
            saved_modules = {}
            for _, name in ipairs(module_names) do
                saved_modules[name] = { loaded = package.loaded[name], preload = package.preload[name] }
                package.loaded[name] = nil
                package.preload[name] = nil
            end
            screen_width, screen_height, text_height = 600, 800, 32
            measurements, shown, freed, scheduled = {}, {}, 0, 0
            package.preload.device = function()
                return { screen = {
                    getWidth = function() return screen_width end,
                    getHeight = function() return screen_height end,
                } }
            end
            package.preload["ui/font"] = function()
                return { getFace = function(_, name) return { name = name } end }
            end
            package.preload["ui/uimanager"] = function()
                return {
                    show = function(_, widget) shown[#shown + 1] = widget end,
                    scheduleIn = function() scheduled = scheduled + 1 end,
                }
            end
            package.preload["ui/widget/infomessage"] = function()
                return { new = function(_, options)
                    options.kind = "message"
                    return options
                end }
            end
            package.preload["ui/widget/textboxwidget"] = function()
                return { new = function(_, options)
                    measurements[#measurements + 1] = options
                    return {
                        getSize = function() return { w = options.width, h = options.height or text_height } end,
                        getAllLineCount = function() return math.ceil(text_height / 32) end,
                        getVisLineCount = function() return math.floor((options.height or text_height) / 32) end,
                        free = function() freed = freed + 1 end,
                    }
                end }
            end
            package.preload["ui/widget/textviewer"] = function()
                return { new = function(_, options)
                    options.kind = "scrollable viewer"
                    return options
                end }
            end
            package.preload["suwayomi/ui"] = function() return {} end
            package.preload["suwayomi/i18n"] = function()
                return { t = function(text) return "tx:" .. text end }
            end
            plugin = require("suwayomi/plugin/home").methods
            local Client = {}
            require("suwayomi/client/library").install(Client)
            client = setmetatable({ plugin = plugin }, { __index = Client })
        end)

        after_each(function()
            for _, name in ipairs(module_names) do
                package.loaded[name] = saved_modules[name].loaded
                package.preload[name] = saved_modules[name].preload
            end
        end)

        it("shows complete category and manga errors in a persistent scrollable viewer", function()
            local message = "Server diagnostic\n" .. string.rep("Long diagnostic line\n", 120) .. "Final detail"
            text_height = 3200

            client:showLibraryCategoriesResult({}, { ok = false, error = message })
            client:showLibraryMangaResult(nil, {}, { ok = false, error = message })
            plugin:showMessage(message, { timeout = 3 })

            assert.are.equal(3, #shown)
            for _, widget in ipairs(shown) do
                assert.are.equal("scrollable viewer", widget.kind)
                assert.are.equal(message, widget.text)
                assert.are.equal("tx:Suwayomi", widget.title)
                assert.is_nil(widget.timeout)
                -- Native TextViewer sizes itself to the screen and supplies scrolling and Close/Back.
                assert.is_nil(widget.height)
                assert.is_nil(widget.width)
            end
            assert.are.equal(0, scheduled)
            assert.are.equal(3, freed)
        end)

        it("bounds the measurement viewport before constructing a huge diagnostic", function()
            text_height = 1000000

            plugin:showMessage(string.rep("Diagnostic line\n", 10000))

            assert.are.equal("scrollable viewer", shown[1].kind)
            assert.is_number(measurements[1].height)
            assert.is_true(measurements[1].height > 0 and measurements[1].height < screen_height)
            assert.is_true(measurements[1].width > 0 and measurements[1].width < screen_width)
            assert.are.equal(1, freed)
        end)

        it("keeps short messages compact and preserves their timeout", function()
            plugin:showMessage("Saved.", { timeout = 3 })

            assert.are.equal("message", shown[1].kind)
            assert.are.equal("Saved.", shown[1].text)
            assert.are.equal(3, shown[1].timeout)
            assert.is_nil(package.loaded["ui/widget/textviewer"])
            assert.are.equal("infofont", measurements[1].face.name)
            assert.are.equal(1, freed)
        end)

        it("uses rendered wrapping even when the error contains no newlines", function()
            local message = string.rep("Wrapped diagnostic text ", 300)
            text_height = 1600

            plugin:showMessage(message)

            assert.are.equal("scrollable viewer", shown[1].kind)
            assert.are.equal(message, shown[1].text)
            assert.are.equal(message, measurements[1].text)
        end)

        it("reevaluates current screen dimensions and font layout for each message", function()
            local message = string.rep("Diagnostic line\n", 19) .. "Final detail"
            screen_width, screen_height, text_height = 600, 1280, 640
            plugin:showMessage(message)
            assert.are.equal("message", shown[1].kind)
            assert.are.equal(400, measurements[1].width)

            screen_width, screen_height = 1280, 600
            plugin:showMessage(message)
            assert.are.equal("scrollable viewer", shown[2].kind)
            assert.are.equal(853, measurements[2].width)

            screen_width, screen_height, text_height = 600, 1280, 1280
            plugin:showMessage(message)
            assert.are.equal("scrollable viewer", shown[3].kind)
            assert.are.equal(message, shown[3].text)
            assert.are.equal(3, freed)
        end)
    end)
end)
