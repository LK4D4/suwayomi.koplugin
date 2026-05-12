-- Boundary: Browse/library list and search UI.
--
-- Responsibility: build source, search, browse manga, and library category menus
-- while preserving controller-owned callbacks.
-- Owned state: none; menu refresh helpers mutate existing KOReader menu widgets.
-- Dependencies: KOReader Menu/MultiInputDialog, gettext, and shared menu utils.
-- External data: source and manga rows come from API/cache layers and are only
-- formatted for display here.

local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local _ = require("gettext")
local ListRows = require("suwayomi/ui/list_rows")
local menu_utils = require("suwayomi/ui/menu_utils")

local BrowseUI = {}

local function getListMenu()
    return require("suwayomi/ui/list_menu")
end

local function newPluginMenu(options)
    return Menu:new(menu_utils.applyNativeTitleBarStyle(options))
end

function BrowseUI.showSourcesMenu(sources, onSelectCallback, options)
    options = options or {}
    if type(onSelectCallback) == "table" then
        options = onSelectCallback
        onSelectCallback = options.onSelect
    end

    return getListMenu().show{
        title = _("Suwayomi Sources"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = ListRows.buildSourceMenuTable(sources, {
            show_language = true,
            on_select = onSelectCallback,
        }),
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        thumbnail_credentials = options.thumbnail_credentials,
    }
end

function BrowseUI.showSourceModeMenu(source, onSelectCallback, options)
    options = options or {}
    local menu_table = {
        {
            text = _("Popular"),
            callback = function()
                if onSelectCallback then onSelectCallback("POPULAR") end
            end,
        },
    }

    if not source or source.supports_latest ~= false then
        table.insert(menu_table, {
            text = _("Latest"),
            callback = function()
                if onSelectCallback then onSelectCallback("LATEST") end
            end,
        })
    end

    table.insert(menu_table, {
        text = _("Search"),
        callback = function()
            if onSelectCallback then onSelectCallback("SEARCH") end
        end,
    })

    local menu = newPluginMenu{
        title = source and (source.name or source.display_name or source.displayName) or _("Suwayomi Source"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = menu_table,
    }
    menu_utils.applyTitleBarOptions(menu, options)
    menu_utils.applyCloseCallback(menu, options)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
end

function BrowseUI.showSourceSearchPrompt(source, onSearchCallback)
    local UIManager = require("ui/uimanager")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Search ") .. (source and (source.name or source.display_name or source.displayName) or _("source")),
        fields = {
            {
                hint = _("Search query"),
                text = "",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)
                        if onSearchCallback then
                            onSearchCallback(fields[1] or "")
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

function BrowseUI.showGlobalSearchPrompt(onSearchCallback)
    local UIManager = require("ui/uimanager")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Global search"),
        fields = {
            {
                hint = _("Search query"),
                text = "",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)
                        if onSearchCallback then
                            onSearchCallback(fields[1] or "")
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

function BrowseUI.updateSourcesMenu(menu, sources, onSelectCallback, options)
    if not menu then
        return
    end

    return getListMenu().update(menu, {
        title = _("Suwayomi Sources"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = ListRows.buildSourceMenuTable(sources, {
            show_language = true,
            on_select = onSelectCallback,
        }),
        close_callback = options and options.close_callback,
        on_title_bar_left_tap = options and options.on_title_bar_left_tap,
        on_title_bar_left_hold = options and options.on_title_bar_left_hold,
        thumbnail_credentials = options and options.thumbnail_credentials,
    })
end

function BrowseUI.showGlobalSearchResultsMenu(summaries, onSelectCallback, options)
    options = options or {}
    return getListMenu().show{
        title = _("Global search"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = ListRows.buildGlobalSearchSummaryMenuTable(summaries, {
            on_select = onSelectCallback,
        }),
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        thumbnail_credentials = options.thumbnail_credentials,
    }
end

function BrowseUI.updateGlobalSearchResultsMenu(menu, summaries, onSelectCallback, options)
    if not menu then
        return
    end

    options = options or {}
    return getListMenu().update(menu, {
        title = _("Global search"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = ListRows.buildGlobalSearchSummaryMenuTable(summaries, {
            on_select = onSelectCallback,
        }),
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        thumbnail_credentials = options.thumbnail_credentials,
    })
end

local function buildMangaMenuTable(manga_list, onSelectCallback, options)
    options = options or {}
    local menu_table = {}
    if options.on_previous_page then
        table.insert(menu_table, {
            text = _("Previous page"),
            callback = options.on_previous_page,
        })
    end
    for _, row in ipairs(ListRows.buildMangaMenuTable(manga_list, {
        show_in_library = true,
        on_select = onSelectCallback,
    })) do
        table.insert(menu_table, row)
    end
    if options.on_next_page then
        table.insert(menu_table, {
            text = _("Next page"),
            callback = options.on_next_page,
        })
    end
    return menu_table
end

function BrowseUI.showMangaMenu(manga_list, onSelectCallback, options)
    options = options or {}
    local menu_table = buildMangaMenuTable(manga_list, onSelectCallback, options)
    return getListMenu().show{
        title = options.title or _("Suwayomi Manga"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = menu_table,
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        thumbnail_credentials = options.thumbnail_credentials,
    }
end

function BrowseUI.updateMangaMenu(menu, manga_list, onSelectCallback, options)
    if not menu then
        return
    end

    options = options or {}
    local menu_table = buildMangaMenuTable(manga_list, onSelectCallback, options)
    return getListMenu().update(menu, {
        title = options.title or menu.title,
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = menu_table,
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        thumbnail_credentials = options.thumbnail_credentials,
    })
end

function BrowseUI.showLibraryCategoryMenu(categories, onSelectCallback, options)
    options = options or {}
    return getListMenu().show{
        title = _("Suwayomi Library"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = ListRows.buildLibraryCategoryMenuTable(categories, {
            on_select = onSelectCallback,
        }),
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
    }
end

local function buildLibraryMangaMenuTable(manga_list, onSelectCallback)
    return ListRows.buildMangaMenuTable(manga_list, {
        show_in_library = false,
        on_select = onSelectCallback,
    })
end

function BrowseUI.showLibraryMangaMenu(manga_list, onSelectCallback, options)
    options = options or {}
    return getListMenu().show{
        title = _("Suwayomi Library"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = buildLibraryMangaMenuTable(manga_list, onSelectCallback),
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        thumbnail_credentials = options.thumbnail_credentials,
    }
end

function BrowseUI.updateLibraryMangaMenu(menu, manga_list, onSelectCallback, options)
    if not menu then
        return
    end

    options = options or {}
    return getListMenu().update(menu, {
        title = _("Suwayomi Library"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = buildLibraryMangaMenuTable(manga_list, onSelectCallback),
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        thumbnail_credentials = options.thumbnail_credentials,
    })
end

return BrowseUI
