local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local _ = require("gettext")

local SuwayomiUI = {}

local function newStateMark(mark_type, checked)
    local module_name = mark_type == "radio" and "ui/widget/radiomark" or "ui/widget/checkmark"
    local ok, Mark = pcall(require, module_name)
    if not ok or not Mark then
        return nil
    end
    return Mark:new{
        checked = checked == true,
    }
end

local function getStateMarkWidth()
    local mark = newStateMark("check", true)
    if mark and mark.getSize then
        return mark:getSize().w + 12
    end
    if mark and mark.dimen then
        return mark.dimen.w + 12
    end
    return nil
end

local function isKOReaderCurrentFolderItem(item)
    return item and type(item.path) == "string" and item.path:sub(-2, -1) == "/."
end

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

function SuwayomiUI.showDirectoryChooser(callback, start_dir)
    local PathChooser = require("ui/widget/pathchooser")
    local UIManager = require("ui/uimanager")

    local DirectoryChooser = PathChooser:extend{
        title = _("Choose download directory"),
        select_directory = true,
        select_file = false,
        show_files = false,
        show_path = true,
    }

    function DirectoryChooser:genItemTable(dirs, files, path)
        local item_table = PathChooser.genItemTable(self, dirs, files, path)
        if path then
            local current_folder_path = path .. "/."
            for __, item in ipairs(item_table) do
                if item.path == current_folder_path then
                    item.text = _("Use this folder")
                    item.bold = true
                    break
                end
            end
        end
        return item_table
    end

    function DirectoryChooser:onMenuSelect(item)
        if isKOReaderCurrentFolderItem(item) then
            return PathChooser.onMenuHold(self, item)
        end
        return PathChooser.onMenuSelect(self, item)
    end

    local path_chooser = DirectoryChooser:new{
        path = start_dir,
        onConfirm = function(path)
            if callback then
                callback(path)
            end
        end,
    }
    UIManager:show(path_chooser)
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
    return menu
end

function SuwayomiUI.updateSourcesMenu(menu, sources, onSelectCallback)
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
    if menu.updateItems then
        menu:updateItems()
    end
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
            text = language.label,
            state = newStateMark("check", language.enabled),
            checked_func = function()
                return language.enabled == true
            end,
            callback = function()
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
    local menu_options = {}
    for key, value in pairs(options) do
        menu_options[key] = value
    end
    menu_options.onClose = function()
        if menu then
            UIManager:close(menu)
        end
        if options.onClose then
            options.onClose()
        end
    end

    menu = Menu:new{
        title = _("Suwayomi source languages"),
        item_table = SuwayomiUI.buildLanguageMenuTable(menu_options, options.onToggle),
        state_w = getStateMarkWidth(),
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
    menu_options.onClose = function()
        UIManager:close(menu)
        if options.onClose then
            options.onClose()
        end
    end

    menu.item_table = SuwayomiUI.buildLanguageMenuTable(menu_options, onToggleCallback or options.onToggle)
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
