local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local _ = require("gettext")

local SuwayomiUI = {}

local function applyTitleBarOptions(menu, options)
    options = options or {}
    if options.title_bar_left_icon then
        menu.title_bar_left_icon = options.title_bar_left_icon
    end
    if options.on_title_bar_left_tap then
        menu.onLeftButtonTap = options.on_title_bar_left_tap
    end
    return menu
end

local function bindMenuCallbacks(items, menu)
    for _, item in ipairs(items or {}) do
        if item.callback then
            local callback = item.callback
            item.callback = function(...)
                return callback(menu, ...)
            end
        end
        bindMenuCallbacks(item.sub_item_table, menu)
    end
end

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

function SuwayomiUI.showSourcesMenu(sources, onSelectCallback, options)
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

    local menu = Menu:new{
        title = _("Suwayomi Sources"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = menu_table,
    }
    applyTitleBarOptions(menu, options)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
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

function SuwayomiUI.updateSourcesMenu(menu, sources, onSelectCallback, options)
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
    applyTitleBarOptions(menu, options)
    if menu.updateItems then
        menu:updateItems()
    end
end

function SuwayomiUI.showMangaMenu(manga_list, onSelectCallback, options)
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
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = menu_table,
    }
    applyTitleBarOptions(menu, options)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
end

function SuwayomiUI.updateMangaMenu(menu, manga_list, onSelectCallback, options)
    if not menu then
        return
    end

    local menu_table = {}
    for _, manga in ipairs(manga_list or {}) do
        table.insert(menu_table, {
            text = manga.title,
            callback = function()
                if onSelectCallback then onSelectCallback(manga) end
            end
        })
    end
    menu.item_table = menu_table
    applyTitleBarOptions(menu, options)
    if menu.updateItems then
        menu:updateItems()
    end
end

function SuwayomiUI.showLibraryCategoryMenu(categories, onSelectCallback, options)
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

    local menu = Menu:new{
        title = _("Suwayomi Library"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = menu_table,
    }
    applyTitleBarOptions(menu, options)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
end

function SuwayomiUI.showLibraryMangaMenu(manga_list, onSelectCallback, options)
    local menu_table = {}
    for _, manga in ipairs(manga_list or {}) do
        table.insert(menu_table, {
            text = manga.menu_text or manga.title,
            callback = function()
                if onSelectCallback then onSelectCallback(manga) end
            end,
        })
    end

    local menu = Menu:new{
        title = _("Suwayomi Library"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = menu_table,
    }
    applyTitleBarOptions(menu, options)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
end

function SuwayomiUI.updateLibraryMangaMenu(menu, manga_list, onSelectCallback, options)
    if not menu then
        return
    end

    local menu_table = {}
    for _, manga in ipairs(manga_list or {}) do
        table.insert(menu_table, {
            text = manga.menu_text or manga.title,
            callback = function()
                if onSelectCallback then onSelectCallback(manga) end
            end,
        })
    end
    menu.item_table = menu_table
    applyTitleBarOptions(menu, options)
    if menu.updateItems then
        menu:updateItems()
    end
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

function SuwayomiUI.showMangaActionsMenu(options, onSelectCallback)
    options = options or {}
    options.title = options.title or _("Manga actions")
    return SuwayomiUI.showChapterActionsMenu(options, onSelectCallback)
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

local function shortenMenuText(text, max_chars)
    text = tostring(text or "")
    max_chars = max_chars or 96
    if #text <= max_chars then
        return text
    end
    return text:sub(1, max_chars - 3) .. "..."
end

local function formatDownloadJobLabel(job)
    local manga_title = job and job.manga and job.manga.title or nil
    local chapter_name = job and job.chapter and job.chapter.name or nil
    local label = manga_title or tostring(job and job.key or "")
    if chapter_name and chapter_name ~= "" then
        label = label .. " / " .. chapter_name
    end
    return label
end

local function formatDownloadProgress(job)
    local progress = job and job.progress or nil
    local current = progress and tonumber(progress.current) or nil
    local total = progress and tonumber(progress.total) or nil
    if current and total and total > 0 then
        return tostring(current) .. "/" .. tostring(total)
    end
    return ""
end

local function formatFailedDownloadText(job)
    local text = "Failed  " .. formatDownloadJobLabel(job)
    local error_message = job and job.progress and job.progress.error or nil
    if error_message and error_message ~= "" then
        text = text .. " - " .. tostring(error_message)
    end
    return shortenMenuText(text)
end

function SuwayomiUI.buildDownloadsMenuTable(snapshot, callbacks)
    snapshot = snapshot or {}
    callbacks = callbacks or {}
    local menu_table = {}

    for _, job in ipairs(snapshot.active or {}) do
        local progress = formatDownloadProgress(job)
        local prefix = progress ~= "" and ("Downloading " .. progress) or "Downloading"
        table.insert(menu_table, {
            text = shortenMenuText(prefix .. "  " .. formatDownloadJobLabel(job)),
        })
    end

    for _, job in ipairs(snapshot.queued or {}) do
        table.insert(menu_table, {
            text = shortenMenuText("Queued  " .. formatDownloadJobLabel(job)),
            callback = function(menu)
                if callbacks.onSelectQueued then
                    callbacks.onSelectQueued(job, menu)
                end
            end,
        })
    end

    for _, job in ipairs(snapshot.failed or {}) do
        table.insert(menu_table, {
            text = formatFailedDownloadText(job),
            callback = function(menu)
                if callbacks.onRetryFailed then
                    callbacks.onRetryFailed(job, menu)
                end
            end,
        })
    end

    if #(snapshot.failed or {}) > 0 then
        table.insert(menu_table, {
            text = _("Clear failed"),
            callback = function(menu)
                if callbacks.onClearFailed then
                    callbacks.onClearFailed(menu)
                end
            end,
        })
    end

    return menu_table
end

function SuwayomiUI.showDownloadsMenu(snapshot, callbacks, options)
    options = options or {}
    local menu = Menu:new{
        title = _("Suwayomi Downloads"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = SuwayomiUI.buildDownloadsMenuTable(snapshot, callbacks),
    }
    applyTitleBarOptions(menu, options)
    bindMenuCallbacks(menu.item_table, menu)
    local UIManager = require("ui/uimanager")
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
