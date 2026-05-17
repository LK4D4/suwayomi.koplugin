-- Boundary: Browse/library list and search UI.
--
-- Responsibility: build source, search, browse manga, and library category menus
-- while preserving controller-owned callbacks.
-- Owned state: none; menu refresh helpers mutate existing KOReader menu widgets.
-- Dependencies: KOReader Menu/MultiInputDialog, gettext, and shared menu utils.
-- External data: source and manga rows come from API/cache layers and are only
-- formatted for display here.

local MultiInputDialog = require("ui/widget/multiinputdialog")
local _ = require("gettext")
local ListRows = require("suwayomi/ui/list_rows")

local BrowseUI = {}

local function getListMenu()
    return require("suwayomi/ui/list_menu")
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

function BrowseUI.showExtensionsMenu(extensions, onSelectCallback, options)
    options = options or {}
    return getListMenu().show{
        title = options.title or _("Suwayomi Extensions"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = ListRows.buildExtensionMenuTable(extensions, {
            on_select = onSelectCallback,
            empty_text = options.empty_text,
        }),
        close_callback = options.close_callback,
        on_close = options.on_close,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        thumbnail_credentials = options.thumbnail_credentials,
    }
end

function BrowseUI.updateExtensionsMenu(menu, extensions, onSelectCallback, options)
    options = options or {}
    return getListMenu().update(menu, {
        title = options.title or _("Suwayomi Extensions"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = ListRows.buildExtensionMenuTable(extensions, {
            on_select = onSelectCallback,
            empty_text = options.empty_text,
        }),
        close_callback = options.close_callback,
        on_close = options.on_close,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        thumbnail_credentials = options.thumbnail_credentials,
    })
end

function BrowseUI.showExtensionActionMenu(extension, onSelectCallback, options)
    options = options or {}
    local actions = {}

    local function addAction(action_id, text, destructive)
        table.insert(actions, {
            id = action_id,
            text = text,
            destructive = destructive == true or nil,
        })
    end

    if type(extension) == "table" and extension.is_installed ~= true then
        addAction("install", _("Install"))
    elseif type(extension) == "table" and extension.has_update == true then
        addAction("update", _("Update"))
    end
    if type(extension) == "table" and extension.is_installed == true then
        addAction("uninstall", _("Uninstall"), true)
    end

    if #actions == 0 then
        table.insert(actions, { text = _("No actions available") })
    end

    return require("suwayomi/ui").showActionMenu({
        title = ListRows.getExtensionTitle(extension),
        actions = actions,
        anchor = options.anchor,
        close_callback = options.close_callback,
        vertical = true,
        destructive_actions_at_bottom = true,
    }, function(action)
        if action and action.id and onSelectCallback then
            onSelectCallback(action.id)
        end
    end)
end

function BrowseUI.showSourceModeMenu(source, onSelectCallback, options)
    options = options or {}
    local actions = {
        {
            id = "POPULAR",
            text = _("Popular"),
        },
    }

    if not source or source.supports_latest ~= false then
        table.insert(actions, {
            id = "LATEST",
            text = _("Latest"),
        })
    end

    table.insert(actions, {
        id = "SEARCH",
        text = _("Search"),
    })

    return require("suwayomi/ui").showActionMenu({
        title = source and (source.name or source.display_name or source.displayName) or _("Suwayomi Source"),
        actions = actions,
        anchor = options.anchor,
        close_callback = options.close_callback,
        on_back = options.on_back,
    }, function(action)
        if action and action.id and onSelectCallback then
            onSelectCallback(action.id)
        end
    end)
end

function BrowseUI.showSourceSearchPrompt(source, onSearchCallback, options)
    options = options or {}
    local UIManager = require("ui/uimanager")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Search ") .. (source and (source.name or source.display_name or source.displayName) or _("source")),
        fields = {
            {
                hint = _("Search query"),
                text = options.query or "",
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

function BrowseUI.showExtensionSearchPrompt(currentQuery, onSearchCallback)
    local UIManager = require("ui/uimanager")
    local dialog
    local handled = false
    local function finish(query)
        if handled then
            return
        end
        handled = true
        UIManager:close(dialog)
        if onSearchCallback then
            onSearchCallback(query or "")
        end
    end
    dialog = MultiInputDialog:new{
        title = _("Search extensions"),
        fields = {
            {
                hint = _("Extension name, language, or package"),
                text = currentQuery or "",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        finish("")
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        finish(fields[1] or "")
                    end,
                },
            },
        },
        close_callback = function()
            if not handled and onSearchCallback then
                handled = true
                onSearchCallback("")
            end
        end,
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
            on_retry = options.on_retry_summary,
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
            on_retry = options.on_retry_summary,
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
        if type(row.manga) == "table" and row.manga.raw_menu_row == true then
            table.insert(menu_table, row.manga)
        else
            table.insert(menu_table, row)
        end
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
