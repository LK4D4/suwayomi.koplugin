-- Boundary: shared KOReader menu utility helpers.
--
-- Responsibility: keep title-bar mutation, menu callback binding, and state-mark
-- construction consistent across UI surface modules.
-- Owned state: none.
-- Dependencies: KOReader widgets are required lazily where needed by helpers.
-- External data: menu tables are controller-built and mutated only to attach
-- KOReader-compatible callbacks or state marks.

local MenuUtils = {}

function MenuUtils.applyNativeTitleBarStyle(menu_options)
    menu_options = menu_options or {}
    if menu_options.title_bar_left_icon then
        menu_options.title_bar_fm_style = true
        if menu_options.is_popout == nil then
            menu_options.is_popout = false
        end
    end
    return menu_options
end

function MenuUtils.applyTitleBarOptions(menu, options)
    options = options or {}
    if options.title then
        menu.title = options.title
        if menu.title_bar and menu.title_bar.setTitle then
            menu.title_bar:setTitle(options.title, true)
        end
    end
    if options.title_bar_left_icon then
        menu.title_bar_left_icon = options.title_bar_left_icon
        if menu.setTitleBarLeftIcon then
            menu:setTitleBarLeftIcon(options.title_bar_left_icon)
        end
    end
    if options.on_title_bar_left_tap then
        menu.onLeftButtonTap = function(...)
            return options.on_title_bar_left_tap(menu, ...)
        end
    end
    if options.on_title_bar_left_hold then
        menu.onLeftButtonHold = function(...)
            return options.on_title_bar_left_hold(menu, ...)
        end
    end
    return menu
end

function MenuUtils.applyCloseCallback(menu, options)
    options = options or {}
    if options.close_callback then
        menu.close_callback = options.close_callback
    end
    return menu
end

function MenuUtils.bindMenuCallbacks(items, menu)
    for _, item in ipairs(items or {}) do
        if item.callback then
            local callback = item.callback
            item.callback = function(...)
                return callback(menu, ...)
            end
        end
        MenuUtils.bindMenuCallbacks(item.sub_item_table, menu)
    end
end

function MenuUtils.newStateMark(mark_type, checked)
    local module_name = mark_type == "radio" and "ui/widget/radiomark" or "ui/widget/checkmark"
    local ok, Mark = pcall(require, module_name)
    if not ok or not Mark then
        return nil
    end
    return Mark:new{
        checked = checked == true,
    }
end

function MenuUtils.getStateMarkWidth()
    local mark = MenuUtils.newStateMark("check", true)
    if mark and mark.getSize then
        return mark:getSize().w + 12
    end
    if mark and mark.dimen then
        return mark.dimen.w + 12
    end
    return nil
end

return MenuUtils
