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
local MangaRows = require("suwayomi/ui/manga_rows")
local menu_utils = require("suwayomi/ui/menu_utils")

local BrowseUI = {}

local function newPluginMenu(options)
    return Menu:new(menu_utils.applyNativeTitleBarStyle(options))
end

function BrowseUI.showSourcesMenu(sources, onSelectCallback, options)
    local menu_table = {}
    options = options or {}
    if type(onSelectCallback) == "table" then
        options = onSelectCallback
        onSelectCallback = options.onSelect
    end
    for _, source in ipairs(sources) do
        table.insert(menu_table, {
            text = source.name,
            callback = function()
                if onSelectCallback then onSelectCallback(source) end
            end
        })
    end

    local menu = newPluginMenu{
        title = _("Suwayomi Sources"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = menu_table,
    }
    menu_utils.applyTitleBarOptions(menu, options)
    menu_utils.applyCloseCallback(menu, options)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
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

    local menu_table = {}
    for _, source in ipairs(sources or {}) do
        table.insert(menu_table, {
            text = source.name,
            callback = function()
                if onSelectCallback then onSelectCallback(source) end
            end
        })
    end
    menu.item_table = menu_table
    menu_utils.applyTitleBarOptions(menu, options)
    if menu.updateItems then
        menu:updateItems()
    end
end

local function getSourceRowName(source)
    if type(source) ~= "table" then
        return _("Source")
    end
    return source.display_name
        or source.displayName
        or source.name
        or source.raw_name
        or tostring(source.id)
end

local function formatGlobalSearchSummary(summary)
    local source_name = getSourceRowName(summary and summary.source)
    if not summary or summary.status == "empty" then
        return source_name .. ": " .. _("No results")
    end
    if summary.status == "searching" then
        return source_name .. ": " .. _("searching")
    end
    if summary.status == "timed_out" then
        return source_name .. ": " .. _("timed out")
    end
    if summary.status == "canceled" then
        return source_name .. ": " .. _("canceled")
    end
    if summary.status == "error" then
        return source_name .. ": " .. _("Error") .. " - " .. tostring(summary.error or _("Unknown error"))
    end
    local count = tonumber(summary.result_count) or #(summary.manga or {})
    local suffix = summary.has_next_page and "+" or ""
    if count == 1 and not summary.has_next_page then
        return source_name .. ": " .. _("1 result")
    end
    return source_name .. ": " .. tostring(count) .. suffix .. " " .. _("results")
end

local function buildGlobalSearchMenuTable(summaries, onSelectCallback)
    local menu_table = {}
    for _, summary in ipairs(summaries or {}) do
        table.insert(menu_table, {
            text = formatGlobalSearchSummary(summary),
            callback = function()
                if (summary.status == "ok" or summary.status == "pageable_empty") and onSelectCallback then
                    onSelectCallback(summary)
                end
            end,
        })
    end
    return menu_table
end

function BrowseUI.showGlobalSearchResultsMenu(summaries, onSelectCallback, options)
    options = options or {}
    local menu = newPluginMenu{
        title = _("Global search"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = buildGlobalSearchMenuTable(summaries, onSelectCallback),
    }
    menu_utils.applyTitleBarOptions(menu, options)
    menu_utils.applyCloseCallback(menu, options)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
end

function BrowseUI.updateGlobalSearchResultsMenu(menu, summaries, onSelectCallback, options)
    if not menu then
        return
    end

    menu.item_table = buildGlobalSearchMenuTable(summaries, onSelectCallback)
    menu_utils.applyTitleBarOptions(menu, options)
    menu_utils.applyCloseCallback(menu, options)
    if menu.updateItems then
        menu:updateItems(nil, true)
    end
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
    for _, row in ipairs(MangaRows.buildMenuTable(manga_list, {
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
    local menu_table = buildMangaMenuTable(manga_list, onSelectCallback, options)

    local menu = newPluginMenu{
        title = options and options.title or _("Suwayomi Manga"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = menu_table,
    }
    menu_utils.applyTitleBarOptions(menu, options)
    menu_utils.applyCloseCallback(menu, options)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
end

function BrowseUI.updateMangaMenu(menu, manga_list, onSelectCallback, options)
    if not menu then
        return
    end

    local menu_table = buildMangaMenuTable(manga_list, onSelectCallback, options)
    menu.item_table = menu_table
    menu_utils.applyTitleBarOptions(menu, options)
    menu_utils.applyCloseCallback(menu, options)
    if menu.updateItems then
        menu:updateItems()
    end
end

function BrowseUI.showLibraryCategoryMenu(categories, onSelectCallback, options)
    local menu_table = {}
    for _, category in ipairs(categories or {}) do
        local suffix = ""
        if category.manga_count ~= nil then
            suffix = " (" .. tostring(category.manga_count) .. ")"
        end
        table.insert(menu_table, {
            text = (category.name or tostring(category.id)) .. suffix,
            callback = function()
                if onSelectCallback then onSelectCallback(category) end
            end,
        })
    end

    local menu = newPluginMenu{
        title = _("Suwayomi Library"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = menu_table,
    }
    menu_utils.applyTitleBarOptions(menu, options)
    menu_utils.applyCloseCallback(menu, options)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
end

local function buildLibraryMangaMenuTable(manga_list, onSelectCallback)
    return MangaRows.buildMenuTable(manga_list, {
        show_in_library = false,
        on_select = onSelectCallback,
    })
end

function BrowseUI.showLibraryMangaMenu(manga_list, onSelectCallback, options)
    local menu = newPluginMenu{
        title = _("Suwayomi Library"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = buildLibraryMangaMenuTable(manga_list, onSelectCallback),
    }
    menu_utils.applyTitleBarOptions(menu, options)
    menu_utils.applyCloseCallback(menu, options)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
end

function BrowseUI.updateLibraryMangaMenu(menu, manga_list, onSelectCallback, options)
    if not menu then
        return
    end

    menu.item_table = buildLibraryMangaMenuTable(manga_list, onSelectCallback)
    menu_utils.applyTitleBarOptions(menu, options)
    if menu.updateItems then
        menu:updateItems()
    end
end

return BrowseUI
