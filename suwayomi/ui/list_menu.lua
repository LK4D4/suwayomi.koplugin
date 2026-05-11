-- Boundary: file-manager-style list menu construction.
--
-- Responsibility: centralize KOReader Menu options for long-title list rows
-- with compact right-column metadata.
-- Owned state: none.
-- Dependencies: KOReader Menu widget.
-- External data: callers provide already-built menu rows and callbacks.

local Menu = require("ui/widget/menu")

local ListMenu = {}

local DEFAULT_OPTIONS = {
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    items_max_lines = 3,
    multilines_show_more_text = true,
}

local function applyDefaults(options)
    local menu_options = {}
    for key, value in pairs(options or {}) do
        menu_options[key] = value
    end
    for key, value in pairs(DEFAULT_OPTIONS) do
        if menu_options[key] == nil then
            menu_options[key] = value
        end
    end
    return menu_options
end

function ListMenu.new(options)
    return Menu:new(applyDefaults(options))
end

return ListMenu
