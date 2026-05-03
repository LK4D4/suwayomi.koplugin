local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local _ = require("gettext")

local SuwayomiUI = {}

function SuwayomiUI.buildChapterMenuTable(chapter_list, onSelectCallback)
    local menu_table = {}
    for _, chapter in ipairs(chapter_list) do
        table.insert(menu_table, {
            text = chapter.menu_text or chapter.name,
            chapter = chapter,
            callback = function()
                if onSelectCallback then onSelectCallback(chapter) end
            end
        })
    end
    return menu_table
end

function SuwayomiUI.showDirectoryChooser(callback)
    require("ui/downloadmgr"):new{
        title = _("Choose download directory"),
        onConfirm = function(path)
            if callback then
                callback(path)
            end
        end,
    }:chooseDir()
end

function SuwayomiUI.showSourcesMenu(sources, onSelectCallback)
    local menu_table = {}
    for _, source in ipairs(sources) do
        table.insert(menu_table, {
            text = source.name,
            callback = function()
                if onSelectCallback then onSelectCallback(source) end
            end
        })
    end

    local menu = Menu:new{
        title = _("Suwayomi Sources"),
        item_table = menu_table,
    }
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
end

function SuwayomiUI.showMangaMenu(manga_list, onSelectCallback)
    local menu_table = {}
    for _, manga in ipairs(manga_list) do
        table.insert(menu_table, {
            text = manga.title,
            callback = function()
                if onSelectCallback then onSelectCallback(manga) end
            end
        })
    end

    local menu = Menu:new{
        title = _("Suwayomi Manga"),
        item_table = menu_table,
    }
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
end

function SuwayomiUI.showChapterMenu(chapter_list, onSelectCallback, onHoldCallback)
    local options = {}
    if type(chapter_list) == "table" and chapter_list.chapters then
        options = chapter_list
        chapter_list = options.chapters
    end

    local menu = Menu:new{
        title = options.title or _("Suwayomi Chapters"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = SuwayomiUI.buildChapterMenuTable(chapter_list, onSelectCallback),
    }
    if options.on_title_bar_left_tap then
        menu.onLeftButtonTap = options.on_title_bar_left_tap
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

function SuwayomiUI.showChapterActionsMenu(options, onSelectCallback)
    local UIManager = require("ui/uimanager")
    local dialog
    local buttons = {}
    local row = {}
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
        title = options.title or _("Chapter actions"),
        buttons = buttons,
    }
    UIManager:show(dialog)
    return dialog
end

function SuwayomiUI.updateChapterMenu(menu, options, onSelectCallback, onHoldCallback)
    if not menu then
        return
    end

    menu.item_table = SuwayomiUI.buildChapterMenuTable(options.chapters or {}, onSelectCallback)
    menu.title = options.title or menu.title
    if menu.title_bar and options.title then
        menu.title_bar:setTitle(options.title, true)
    end
    if options.title_bar_left_icon and menu.setTitleBarLeftIcon then
        menu:setTitleBarLeftIcon(options.title_bar_left_icon)
    end
    if options.on_title_bar_left_tap then
        menu.onLeftButtonTap = options.on_title_bar_left_tap
    end
    if onHoldCallback then
        menu.onMenuHold = function(_, entry)
            if entry and entry.chapter then
                onHoldCallback(entry.chapter)
            end
            return true
        end
    end
    if menu.updateItems then
        menu:updateItems(nil, true)
    end
end

function SuwayomiUI.buildLanguageMenuTable(options, onToggleCallback)
    local menu_table = {}

    for _, language in ipairs(options.languages or {}) do
        table.insert(menu_table, {
            text = string.format("%s %s", language.enabled and "[x]" or "[ ]", language.label),
            callback = function()
                if onToggleCallback then
                    onToggleCallback(language.code, not language.enabled)
                end
            end,
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
    local UIManager = require("ui/uimanager")
    local menu = Menu:new{
        title = _("Suwayomi source languages"),
        item_table = SuwayomiUI.buildLanguageMenuTable(options, options.onToggle),
    }
    UIManager:show(menu)
    return menu
end

function SuwayomiUI.updateLanguageMenu(menu, options, onToggleCallback)
    if not menu then
        return
    end

    menu.item_table = SuwayomiUI.buildLanguageMenuTable(options, onToggleCallback or options.onToggle)
    if menu.updateItems then
        menu:updateItems(nil, true)
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
