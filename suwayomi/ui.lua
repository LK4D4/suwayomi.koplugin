-- Boundary: public KOReader UI facade for the plugin.
--
-- Responsibility: preserve require("suwayomi/ui") while delegating browse,
-- directory, and downloads surfaces to focused UI modules.
-- Owned state: none; returned KOReader widgets own their runtime state.
-- Dependencies: KOReader widget modules and suwayomi/ui/* helpers.
-- External data: menu rows and callbacks come from controllers and are bound to
-- KOReader widgets without changing business behavior.

local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local _ = require("gettext")

local BrowseUI = require("suwayomi/ui/browse")
local DirectoryUI = require("suwayomi/ui/directory")
local DownloadsUI = require("suwayomi/ui/downloads")
local menu_utils = require("suwayomi/ui/menu_utils")

local SuwayomiUI = {}

local bindMenuCallbacks = menu_utils.bindMenuCallbacks
local newStateMark = menu_utils.newStateMark
local getStateMarkWidth = menu_utils.getStateMarkWidth

SuwayomiUI.showDirectoryChooser = DirectoryUI.showDirectoryChooser

SuwayomiUI.showSourcesMenu = BrowseUI.showSourcesMenu
SuwayomiUI.showSourceModeMenu = BrowseUI.showSourceModeMenu
SuwayomiUI.showSourceSearchPrompt = BrowseUI.showSourceSearchPrompt
SuwayomiUI.showGlobalSearchPrompt = BrowseUI.showGlobalSearchPrompt
SuwayomiUI.updateSourcesMenu = BrowseUI.updateSourcesMenu
SuwayomiUI.showGlobalSearchResultsMenu = BrowseUI.showGlobalSearchResultsMenu
SuwayomiUI.updateGlobalSearchResultsMenu = BrowseUI.updateGlobalSearchResultsMenu
SuwayomiUI.showMangaMenu = BrowseUI.showMangaMenu
SuwayomiUI.updateMangaMenu = BrowseUI.updateMangaMenu
SuwayomiUI.showLibraryCategoryMenu = BrowseUI.showLibraryCategoryMenu
SuwayomiUI.showLibraryMangaMenu = BrowseUI.showLibraryMangaMenu
SuwayomiUI.updateLibraryMangaMenu = BrowseUI.updateLibraryMangaMenu

SuwayomiUI.buildDownloadsMenuTable = DownloadsUI.buildDownloadsMenuTable
SuwayomiUI.showDownloadsMenu = DownloadsUI.showDownloadsMenu

function SuwayomiUI.buildChapterMenuTable(chapter_list, onSelectCallback)
    local menu_table = {}
    for _, chapter in ipairs(chapter_list) do
        table.insert(menu_table, {
            text = chapter.menu_text or chapter.name,
            mandatory = chapter.menu_status,
            chapter = chapter,
            callback = function()
                if onSelectCallback then onSelectCallback(chapter) end
            end
        })
    end
    return menu_table
end

function SuwayomiUI.showSettingsMenu(items)
    local menu = Menu:new{
        title = _("Suwayomi Settings"),
        item_table = items or {},
    }
    bindMenuCallbacks(menu.item_table, menu)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
end

function SuwayomiUI.showChapterMenu(chapter_list, onSelectCallback, onHoldCallback)
    local options = {}
    if type(chapter_list) == "table" and chapter_list.chapters then
        options = chapter_list
        chapter_list = options.chapters
    end

    local menu_options = {
        title = options.title or _("Suwayomi Chapters"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = SuwayomiUI.buildChapterMenuTable(chapter_list, onSelectCallback),
        close_callback = options.close_callback,
    }
    local menu = Menu:new(menu_utils.applyNativeTitleBarStyle(menu_options))
    if options.on_title_bar_left_tap then
        menu.onLeftButtonTap = function(...)
            return options.on_title_bar_left_tap(menu, ...)
        end
    end
    menu.onMenuSelect = function(_, entry)
        if entry and entry.callback then
            entry.callback()
        end
        return true
    end
    if onHoldCallback then
        menu.onMenuHold = function(_, entry)
            if entry and entry.chapter then
                onHoldCallback(entry.chapter)
            end
            return true
        end
    end
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
end

function SuwayomiUI.showHomeDialog(options, onSelectCallback)
    local UIManager = require("ui/uimanager")
    local dialog
    local buttons = {}
    local row = {}

    options = options or {}
    for _, action in ipairs(options.actions or {}) do
        table.insert(row, {
            text = action.text,
            callback = function()
                UIManager:close(dialog)
                if options.onClose then
                    options.onClose()
                end
                if onSelectCallback then
                    onSelectCallback(action)
                elseif action.callback then
                    action.callback(action)
                end
            end,
        })
        if #row == 2 then
            table.insert(buttons, row)
            row = {}
        end
    end

    if #row > 0 then
        table.insert(buttons, row)
    end

    dialog = ButtonDialog:new{
        title = options.title or _("Suwayomi"),
        buttons = buttons,
    }
    UIManager:show(dialog)
    return dialog
end

function SuwayomiUI.showActionMenu(options, onSelectCallback)
    local UIManager = require("ui/uimanager")
    local dialog
    local buttons = {}
    local row = {}
    options = options or {}
    for _, action in ipairs(options.actions or {}) do
        table.insert(row, {
            text = action.text,
            callback = function()
                UIManager:close(dialog)
                if onSelectCallback then
                    onSelectCallback(action)
                end
            end,
        })
        if #row == 2 then
            table.insert(buttons, row)
            row = {}
        end
    end

    if #row > 0 then
        table.insert(buttons, row)
    end

    dialog = ButtonDialog:new{
        title = options.title or _("Actions"),
        buttons = buttons,
        anchor = options.anchor,
        close_callback = options.close_callback,
    }
    UIManager:show(dialog)
    return dialog
end

function SuwayomiUI.showChapterActionsMenu(options, onSelectCallback)
    options = options or {}
    options.title = options.title or _("Chapter actions")
    return SuwayomiUI.showActionMenu(options, onSelectCallback)
end

function SuwayomiUI.showMangaActionsMenu(options, onSelectCallback)
    options = options or {}
    options.title = options.title or _("Manga actions")
    return SuwayomiUI.showActionMenu(options, onSelectCallback)
end

function SuwayomiUI.showConfirm(options)
    local UIManager = require("ui/uimanager")
    local dialog = ConfirmBox:new{
        text = options.text,
        ok_text = options.ok_text,
        ok_callback = options.ok_callback,
        cancel_text = options.cancel_text,
    }
    UIManager:show(dialog)
    return dialog
end

function SuwayomiUI.updateChapterMenu(menu, options, onSelectCallback, onHoldCallback)
    if not menu then
        return
    end

    local item_table = SuwayomiUI.buildChapterMenuTable(options.chapters or {}, onSelectCallback)
    menu.item_table = item_table
    menu.title = options.title or menu.title
    if menu.title_bar and options.title then
        menu.title_bar:setTitle(options.title, true)
    end
    if options.title_bar_left_icon and menu.setTitleBarLeftIcon then
        menu:setTitleBarLeftIcon(options.title_bar_left_icon)
    end
    if options.on_title_bar_left_tap then
        menu.onLeftButtonTap = function(...)
            return options.on_title_bar_left_tap(menu, ...)
        end
    end
    if onHoldCallback then
        menu.onMenuHold = function(_, entry)
            if entry and entry.chapter then
                onHoldCallback(entry.chapter)
            end
            return true
        end
    end
    if menu.switchItemTable then
        menu:switchItemTable(options.title or menu.title, item_table, -1)
        return
    end
    if menu.updateItems then
        menu:updateItems(nil, true)
    end
end

function SuwayomiUI.buildLanguageMenuTable(options, onToggleCallback)
    local menu_table = {}

    for _, language in ipairs(options.languages or {}) do
        table.insert(menu_table, {
            text = language.label,
            state = newStateMark("check", language.enabled),
            checked_func = function()
                return language.enabled == true
            end,
            callback = function()
                if options.skipNextCloseCallback then
                    options.skipNextCloseCallback()
                end
                if onToggleCallback then
                    onToggleCallback(language.code, not language.enabled)
                end
            end,
            keep_menu_open = true,
        })
    end

    table.insert(menu_table, {
        text = _("Done"),
        callback = function()
            if options.onClose then
                options.onClose()
            end
        end,
    })

    return menu_table
end

function SuwayomiUI.showLanguageMenu(options)
    options = options or {}
    local UIManager = require("ui/uimanager")
    local menu
    local close_ran = false
    local menu_options = {}
    for key, value in pairs(options) do
        menu_options[key] = value
    end
    local function runClose(close_menu)
        if close_ran then
            return
        end
        close_ran = true
        if close_menu and menu then
            UIManager:close(menu)
        end
        if options.onClose then
            options.onClose()
        end
    end
    menu_options.onClose = function()
        runClose(true)
    end
    menu_options.skipNextCloseCallback = function()
        if menu then
            menu.suwayomi_skip_next_close_callback = true
        end
    end

    menu = Menu:new{
        title = _("Suwayomi source languages"),
        item_table = SuwayomiUI.buildLanguageMenuTable(menu_options, options.onToggle),
        state_w = getStateMarkWidth(),
        close_callback = function()
            if menu and menu.suwayomi_skip_next_close_callback then
                menu.suwayomi_skip_next_close_callback = nil
                return
            end
            runClose(false)
        end,
    }
    UIManager:show(menu)
    return menu
end

function SuwayomiUI.showParallelDownloadsMenu(options)
    options = options or {}
    local UIManager = require("ui/uimanager")
    local menu = Menu:new{
        title = _("Parallel chapter downloads"),
        item_table = SuwayomiUI.buildParallelDownloadsMenuTable(options),
        state_w = getStateMarkWidth(),
    }
    UIManager:show(menu)
    return menu
end

function SuwayomiUI.showLibraryCategoryPickerBehaviorMenu(options)
    options = options or {}
    local UIManager = require("ui/uimanager")
    local menu = Menu:new{
        title = _("Library category picker"),
        item_table = SuwayomiUI.buildLibraryCategoryPickerBehaviorMenuTable(options),
        state_w = getStateMarkWidth(),
    }
    UIManager:show(menu)
    return menu
end

function SuwayomiUI.buildLibraryCategoryPickerBehaviorMenuTable(options)
    options = options or {}
    local labels = {
        automatic = _("Automatic"),
        always = _("Always ask"),
        never = _("Never ask"),
    }
    local menu_table = {}
    local current = options.current or "automatic"
    for _, behavior in ipairs(options.choices or { "automatic", "always", "never" }) do
        table.insert(menu_table, {
            text = labels[behavior] or behavior,
            radio = true,
            state = newStateMark("radio", behavior == current),
            checked_func = function()
                return behavior == current
            end,
            callback = function()
                if options.onSelect then
                    options.onSelect(behavior)
                end
            end,
            keep_menu_open = true,
        })
    end

    return menu_table
end

function SuwayomiUI.updateLibraryCategoryPickerBehaviorMenu(menu, options)
    if not menu then
        return
    end

    menu.item_table = SuwayomiUI.buildLibraryCategoryPickerBehaviorMenuTable(options)
    if menu.updateItems then
        menu:updateItems()
    end
end

function SuwayomiUI.buildParallelDownloadsMenuTable(options)
    options = options or {}
    local menu_table = {}
    local current = tonumber(options.current) or 2
    for _, value in ipairs(options.choices or { 1, 2, 3, 4 }) do
        table.insert(menu_table, {
            text = tostring(value),
            radio = true,
            state = newStateMark("radio", value == current),
            checked_func = function()
                return value == current
            end,
            callback = function()
                if options.onSelect then
                    options.onSelect(value)
                end
            end,
            keep_menu_open = true,
        })
    end

    return menu_table
end

function SuwayomiUI.updateParallelDownloadsMenu(menu, options)
    if not menu then
        return
    end

    menu.item_table = SuwayomiUI.buildParallelDownloadsMenuTable(options)
    if menu.updateItems then
        menu:updateItems(nil, true)
    end
end

local function formatKeepNextUnreadDownloadsLabel(value)
    value = tonumber(value) or 0
    if value == 0 then
        return _("Off")
    end
    return tostring(value) .. " " .. _("chapters")
end

function SuwayomiUI.showKeepNextUnreadDownloadsMenu(options)
    local UIManager = require("ui/uimanager")
    local dialog
    local buttons = {}
    options = options or {}

    for _, value in ipairs(options.choices or { 0, 5, 10, 50 }) do
        table.insert(buttons, {
            {
                text = formatKeepNextUnreadDownloadsLabel(value),
                callback = function()
                    UIManager:close(dialog)
                    if options.onSelect then
                        options.onSelect(value)
                    end
                end,
            },
        })
    end

    dialog = ButtonDialog:new{
        title = _("Keep next unread downloaded"),
        buttons = buttons,
    }
    UIManager:show(dialog)
    return dialog
end

function SuwayomiUI.updateKeepNextUnreadDownloadsMenu()
    return nil
end

function SuwayomiUI.updateLanguageMenu(menu, options, onToggleCallback)
    if not menu then
        return
    end

    options = options or {}
    local UIManager = require("ui/uimanager")
    local menu_options = {}
    for key, value in pairs(options) do
        menu_options[key] = value
    end
    local close_ran = false
    local function runClose(close_menu)
        if close_ran then
            return
        end
        close_ran = true
        if close_menu then
            UIManager:close(menu)
        end
        if options.onClose then
            options.onClose()
        end
    end
    menu_options.onClose = function()
        runClose(true)
    end
    menu_options.skipNextCloseCallback = function()
        menu.suwayomi_skip_next_close_callback = true
    end

    menu.item_table = SuwayomiUI.buildLanguageMenuTable(menu_options, onToggleCallback or options.onToggle)
    menu.close_callback = nil
    if menu.updateItems then
        menu:updateItems(nil, true)
    end
    menu.close_callback = function()
        if menu.suwayomi_skip_next_close_callback then
            menu.suwayomi_skip_next_close_callback = nil
            return
        end
        runClose(false)
    end
end

function SuwayomiUI.showLoginDialog(options)
    local credentials = options.credentials or {}
    local UIManager = require("ui/uimanager")
    local dialog

    dialog = MultiInputDialog:new{
        title = _("Suwayomi login"),
        fields = {
            {
                hint = _("Server URL"),
                text = credentials.server_url or "",
            },
            {
                hint = _("Username"),
                text = credentials.username or "",
            },
            {
                hint = _("Password"),
                text = credentials.password or "",
                text_type = "password",
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
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)
                        if options.onSave then
                            options.onSave({
                                server_url = fields[1],
                                username = fields[2],
                                password = fields[3],
                                auth_method = "basic_auth",
                            })
                        end
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return SuwayomiUI
