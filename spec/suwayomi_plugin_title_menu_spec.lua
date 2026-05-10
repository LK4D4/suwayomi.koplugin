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
            onSelect = function(action, menu)
                delegated = { action = action, menu = menu }
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

        options.on_title_bar_left_tap(source_menu)

        assert.are.equal("Library", shown_action_menu.title)
        assert.are.equal("home", shown_action_menu.actions[1].id)
        assert.are.equal("refresh", shown_action_menu.actions[2].id)
        assert.is_function(shown_action_menu.anchor)
        assert.are.equal(title_bar_dimen, shown_action_menu.anchor())

        action_callback({ id = "refresh", text = "Refresh" })

        assert.are.equal("refresh", delegated.action.id)
        assert.are.equal(source_menu, delegated.menu)
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

    it("handles home centrally by closing plugin screens and showing the hub", function()
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

        assert.are.same({ "close", "home" }, events)
    end)
end)
