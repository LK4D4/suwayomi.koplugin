local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local _ = require("gettext")

local SuwayomiUI = {}

local function applyTitleBarOptions(menu, options)
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
    if options.on_global_search then
        table.insert(menu_table, {
            text = _("Global search"),
            callback = options.on_global_search,
        })
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

function SuwayomiUI.showSourceModeMenu(source, onSelectCallback, options)
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

    local menu = Menu:new{
        title = source and (source.name or source.display_name or source.displayName) or _("Suwayomi Source"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = menu_table,
    }
    applyTitleBarOptions(menu, options)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
end

function SuwayomiUI.showSourceSearchPrompt(source, onSearchCallback)
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

function SuwayomiUI.showGlobalSearchPrompt(onSearchCallback)
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
    if options and options.on_global_search then
        table.insert(menu_table, {
            text = _("Global search"),
            callback = options.on_global_search,
        })
    end
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

local function getMangaRowTitle(manga)
    if type(manga) ~= "table" then
        return ""
    end
    return manga.title or tostring(manga.id or "")
end

local function formatGlobalSearchSummary(summary)
    local source_name = getSourceRowName(summary and summary.source)
    if not summary or summary.status == "empty" then
        return source_name .. ": " .. _("No results")
    end
    if summary.status == "pageable_empty" then
        return source_name .. ": " .. _("More results")
    end
    if summary.status == "error" then
        return source_name .. ": " .. _("Error") .. " - " .. tostring(summary.error or _("Unknown error"))
    end
    return source_name .. ": " .. getMangaRowTitle(summary.first_match)
end

function SuwayomiUI.showGlobalSearchResultsMenu(summaries, onSelectCallback, options)
    options = options or {}
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

    local menu = Menu:new{
        title = _("Global search"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        item_table = menu_table,
    }
    applyTitleBarOptions(menu, options)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
end

local function formatBrowseMangaRow(manga)
    local marker = manga and manga.in_library == true and "[+] " or "[ ] "
    return marker .. tostring(manga and (manga.title or manga.id) or "")
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
    for _, manga in ipairs(manga_list or {}) do
        table.insert(menu_table, {
            text = formatBrowseMangaRow(manga),
            callback = function()
                if onSelectCallback then onSelectCallback(manga) end
            end
        })
    end
    if options.on_next_page then
        table.insert(menu_table, {
            text = _("Next page"),
            callback = options.on_next_page,
        })
    end
    return menu_table
end

function SuwayomiUI.showMangaMenu(manga_list, onSelectCallback, options)
    local menu_table = buildMangaMenuTable(manga_list, onSelectCallback, options)

    local menu = Menu:new{
        title = options and options.title or _("Suwayomi Manga"),
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

    local menu_table = buildMangaMenuTable(manga_list, onSelectCallback, options)
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
            callback = callbacks.onSelectActive and function(menu)
                callbacks.onSelectActive(job, menu)
            end or nil,
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
