package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/plugin/title_menu", function()
    local shown_action_menu
    local action_callback

    before_each(function()
        shown_action_menu = nil
        action_callback = nil

        package.loaded["suwayomi/plugin/title_menu"] = nil
        package.loaded["suwayomi/ui"] = nil
        package.loaded.gettext = nil
        package.preload.gettext = function()
            return function(text)
                return text
            end
        end
        package.preload["suwayomi/ui"] = function()
            return {
                showActionMenu = function(options, onSelect)
                    shown_action_menu = options
                    action_callback = onSelect
                    return { name = "title-action-menu" }
                end,
            }
        end
    end)

    after_each(function()
        package.preload.gettext = nil
        package.preload["suwayomi/ui"] = nil
        package.preload["suwayomi/i18n"] = nil
        package.loaded["suwayomi/i18n"] = nil
    end)

    it("exports title menu methods", function()
        helper.assertControllerModule("suwayomi/plugin/title_menu", {
            "getTitleBarMenuOptions",
            "buildTitleBarActions",
            "showTitleBarActionMenu",
            "performTitleBarAction",
        })
    end)

    it("prepends Suwayomi home to screen actions", function()
        local TitleMenu = require("suwayomi/plugin/title_menu")
        local plugin = {}
        for name, method in pairs(TitleMenu.methods) do
            plugin[name] = method
        end

        local actions = plugin:buildTitleBarActions({
            { id = "refresh", text = "Refresh" },
        })

        assert.are.equal("home", actions[1].id)
        assert.are.equal("Suwayomi home", actions[1].text)
        assert.are.equal("refresh", actions[2].id)
    end)

    it("routes title-bar labels through i18n", function()
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
        package.loaded["suwayomi/plugin/title_menu"] = nil
        package.loaded["suwayomi/i18n"] = nil

        local controller = require("suwayomi/plugin/title_menu")
        local plugin = {}
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        local actions = plugin:buildTitleBarActions()

        assert.are.equal("tx:Suwayomi home", actions[1].text)
    end)

    it("cleans marker i18n stubs between tests", function()
        assert.is_nil(package.preload["suwayomi/i18n"])
        assert.is_nil(package.loaded["suwayomi/i18n"])
    end)

    it("opens title actions from a native burger callback and delegates screen actions", function()
        local TitleMenu = require("suwayomi/plugin/title_menu")
        local delegated
        local plugin = {}
        for name, method in pairs(TitleMenu.methods) do
            plugin[name] = method
        end

        local options = plugin:getTitleBarMenuOptions({
            title = "Library",
            actions = { { id = "refresh", text = "Refresh" } },
            onSelect = function(action, menu, context)
                delegated = { action = action, menu = menu, context = context }
            end,
        })
        local title_bar_dimen = { x = 3, y = 4, w = 32, h = 32 }
        local source_menu = {
            name = "library-menu",
            title_bar = {
                left_button = {
                    image = {
                        dimen = title_bar_dimen,
                    },
                },
            },
        }

        assert.are.equal("appbar.menu", options.title_bar_left_icon)
        assert.is_function(options.on_title_bar_left_tap)
        assert.is_function(options.on_title_bar_left_hold)

        options.on_title_bar_left_hold(source_menu)

        assert.are.equal("Library", shown_action_menu.title)
        assert.are.equal("home", shown_action_menu.actions[1].id)
        assert.are.equal("refresh", shown_action_menu.actions[2].id)
        assert.is_function(shown_action_menu.anchor)
        assert.are.equal(title_bar_dimen, shown_action_menu.anchor())

        action_callback({ id = "refresh", text = "Refresh" })

        assert.are.equal("refresh", delegated.action.id)
        assert.are.equal(source_menu, delegated.menu)
        assert.is_function(delegated.context and delegated.context.anchor)
        assert.are.equal(title_bar_dimen, delegated.context and delegated.context.anchor())
    end)

    it("forwards vertical destructive action layout options to title action menus", function()
        local TitleMenu = require("suwayomi/plugin/title_menu")
        local plugin = {}
        for name, method in pairs(TitleMenu.methods) do
            plugin[name] = method
        end

        local options = plugin:getTitleBarMenuOptions({
            title = "Chapter downloads",
            actions = {
                { id = "bulk_downloads", text = "Bulk downloads" },
                { id = "delete_read_downloaded", text = "Delete read downloads", destructive = true },
            },
            vertical = true,
            destructive_actions_at_bottom = true,
        })

        options.on_title_bar_left_tap({ name = "chapter-menu" })

        assert.is_true(shown_action_menu.vertical)
        assert.is_true(shown_action_menu.destructive_actions_at_bottom)
        assert.are.equal("delete_read_downloaded", shown_action_menu.actions[#shown_action_menu.actions].id)
        assert.is_true(shown_action_menu.actions[#shown_action_menu.actions].destructive)
    end)

    it("handles home centrally without closing the current plugin screen", function()
        local TitleMenu = require("suwayomi/plugin/title_menu")
        local events = {}
        local plugin = {
            closeSuwayomiPlugin = function()
                table.insert(events, "close")
            end,
            showHome = function()
                table.insert(events, "home")
            end,
        }
        for name, method in pairs(TitleMenu.methods) do
            plugin[name] = method
        end

        plugin:performTitleBarAction({ name = "menu" }, { id = "home" }, {})

        assert.are.same({ "home" }, events)
    end)

    it("keeps Home and unguarded Downloads actions independent of a chapter guard", function()
        local plugin = { homes = 0, downloads = 0 }
        for name, method in pairs(require("suwayomi/plugin/title_menu").methods) do plugin[name] = method end
        function plugin:showHome() self.homes = self.homes + 1 end
        local function downloadAction() plugin.downloads = plugin.downloads + 1 end
        plugin:showTitleBarActionMenu({}, {
            captureActionGuard = function() return function() return false end end,
            onSelect = downloadAction,
        })
        action_callback({ id = "home" })
        assert.are.equal(1, plugin.homes)
        assert.is_false(action_callback({ id = "download_next_5_unread" }))
        assert.are.equal(0, plugin.downloads)
        plugin:showTitleBarActionMenu({}, { onSelect = downloadAction })
        action_callback({ id = "retry_failed_downloads" })
        assert.are.equal(1, plugin.downloads)
    end)
end)
