-- Boundary: TitleMenuController.
--
-- Responsibility: Owns shared title-bar burger action menus and the universal
-- Suwayomi home title action for full-screen plugin menus.
-- Owned state: none; callbacks and screen-specific actions are supplied by callers.
-- Dependencies: Suwayomi UI action menu renderer and the plugin i18n facade.
-- External data: screen actions are controller-owned and treated as opaque action tables.

local SuwayomiUI = require("suwayomi/ui")
local I18n = require("suwayomi/i18n")

local TitleMenuController = {}
TitleMenuController.__index = TitleMenuController

function TitleMenuController:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

function Methods:buildTitleBarActions(screen_actions)
    local actions = {
        { id = "home", text = I18n.t("Suwayomi home") },
    }
    for _, action in ipairs(screen_actions or {}) do
        table.insert(actions, action)
    end
    return actions
end

function Methods:performTitleBarAction(menu, action, screen_options, action_context)
    screen_options = screen_options or {}
    if not action then
        return false
    end
    if action.id == "home" then
        if self.showHome then
            self:showHome()
        end
        return true
    end
    if screen_options.onSelect then
        return screen_options.onSelect(action, menu, action_context)
    end
    return false
end

local function titleBarLeftButtonDimen(menu)
    if menu
            and menu.title_bar
            and menu.title_bar.left_button
            and menu.title_bar.left_button.image then
        return menu.title_bar.left_button.image.dimen
    end
    return nil
end

local function titleBarAnchor(menu)
    return function()
        return titleBarLeftButtonDimen(menu)
    end
end

function Methods:showTitleBarActionMenu(menu, screen_options)
    screen_options = screen_options or {}
    local anchor = titleBarAnchor(menu)
    return SuwayomiUI.showActionMenu({
        title = screen_options.title or I18n.t("Suwayomi"),
        actions = self:buildTitleBarActions(screen_options.actions),
        vertical = screen_options.vertical,
        columns = screen_options.columns,
        destructive_actions_at_bottom = screen_options.destructive_actions_at_bottom,
        anchor = anchor,
    }, function(action)
        return self:performTitleBarAction(menu, action, screen_options, {
            anchor = anchor,
        })
    end)
end

function Methods:getTitleBarMenuOptions(screen_options)
    screen_options = screen_options or {}
    return {
        title_bar_left_icon = "appbar.menu",
        on_title_bar_left_tap = function(menu)
            self:showTitleBarActionMenu(menu, screen_options)
            return true
        end,
        on_title_bar_left_hold = function(menu)
            self:showTitleBarActionMenu(menu, screen_options)
            return true
        end,
    }
end

TitleMenuController.methods = Methods

return TitleMenuController
