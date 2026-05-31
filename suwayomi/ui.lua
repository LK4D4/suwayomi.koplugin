-- Boundary: public KOReader UI facade for the plugin.
--
-- Responsibility: preserve require("suwayomi/ui") while delegating browse,
-- directory, and downloads surfaces to focused UI modules.
-- Owned state: none; returned KOReader widgets own their runtime state.
-- Dependencies: KOReader widget modules and suwayomi/ui/* helpers.
-- External data: menu rows and callbacks come from controllers and are bound to
-- KOReader widgets without changing business behavior.

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local I18n = require("suwayomi/i18n")

local BrowseUI = require("suwayomi/ui/browse")
local ChoiceDialogs = require("suwayomi/ui/choice_dialogs")
local DirectoryUI = require("suwayomi/ui/directory")
local DownloadsUI = require("suwayomi/ui/downloads")
local ListRows = require("suwayomi/ui/list_rows")
local MangaInfoUI = require("suwayomi/ui/manga_info")
local menu_utils = require("suwayomi/ui/menu_utils")

local SuwayomiUI = {}

local bindMenuCallbacks = menu_utils.bindMenuCallbacks
local newStateMark = menu_utils.newStateMark

local function getListMenu()
    return require("suwayomi/ui/list_menu")
end

SuwayomiUI.showDirectoryChooser = DirectoryUI.showDirectoryChooser

SuwayomiUI.showSourcesMenu = BrowseUI.showSourcesMenu
SuwayomiUI.showSourceModeMenu = BrowseUI.showSourceModeMenu
SuwayomiUI.showSourceSearchPrompt = BrowseUI.showSourceSearchPrompt
SuwayomiUI.showSourceFilterEditor = BrowseUI.showSourceFilterEditor
SuwayomiUI.showSavedFiltersMenu = BrowseUI.showSavedFiltersMenu
SuwayomiUI.updateSavedFiltersMenu = BrowseUI.updateSavedFiltersMenu
SuwayomiUI.showSavedFilterNamePrompt = BrowseUI.showSavedFilterNamePrompt
SuwayomiUI.showDeleteSavedFilterConfirm = BrowseUI.showDeleteSavedFilterConfirm
SuwayomiUI.showOverwriteSavedFilterConfirm = BrowseUI.showOverwriteSavedFilterConfirm
SuwayomiUI.showGlobalSearchPrompt = BrowseUI.showGlobalSearchPrompt
SuwayomiUI.showExtensionSearchPrompt = BrowseUI.showExtensionSearchPrompt
SuwayomiUI.updateSourcesMenu = BrowseUI.updateSourcesMenu
SuwayomiUI.showGlobalSearchResultsMenu = BrowseUI.showGlobalSearchResultsMenu
SuwayomiUI.updateGlobalSearchResultsMenu = BrowseUI.updateGlobalSearchResultsMenu
SuwayomiUI.showExtensionsMenu = BrowseUI.showExtensionsMenu
SuwayomiUI.updateExtensionsMenu = BrowseUI.updateExtensionsMenu
SuwayomiUI.showExtensionActionMenu = BrowseUI.showExtensionActionMenu
SuwayomiUI.showMangaMenu = BrowseUI.showMangaMenu
SuwayomiUI.updateMangaMenu = BrowseUI.updateMangaMenu
SuwayomiUI.showLibraryCategoryMenu = BrowseUI.showLibraryCategoryMenu
SuwayomiUI.showLibraryMangaMenu = BrowseUI.showLibraryMangaMenu
SuwayomiUI.updateLibraryMangaMenu = BrowseUI.updateLibraryMangaMenu

SuwayomiUI.buildDownloadsMenuTable = DownloadsUI.buildDownloadsMenuTable
SuwayomiUI.showDownloadsMenu = DownloadsUI.showDownloadsMenu
SuwayomiUI.updateDownloadsMenu = DownloadsUI.updateDownloadsMenu
SuwayomiUI.buildMangaInformationText = MangaInfoUI.buildText
SuwayomiUI.showMangaInformation = MangaInfoUI.show
SuwayomiUI.showChoiceDialog = ChoiceDialogs.showChoiceDialog
SuwayomiUI.showChecklistDialog = ChoiceDialogs.showChecklistDialog

function SuwayomiUI.buildChapterMenuTable(chapter_list, onSelectCallback)
    return ListRows.buildChapterMenuTable(chapter_list, {
        on_select = onSelectCallback,
    })
end

function SuwayomiUI.showSettingsMenu(items, options)
    options = options or {}
    local menu = getListMenu().show({
        title = I18n.t("Suwayomi Settings"),
        title_bar_left_icon = options.title_bar_left_icon,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        item_table = items or {},
    })
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
    bindMenuCallbacks(menu.item_table, menu)
    return menu
end

function SuwayomiUI.showChapterMenu(chapter_list, onSelectCallback, onHoldCallback)
    local options = {}
    if type(chapter_list) == "table" and chapter_list.chapters then
        options = chapter_list
        chapter_list = options.chapters
    end

    local menu_options = {
        title = options.title or I18n.t("Suwayomi Chapters"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = SuwayomiUI.buildChapterMenuTable(chapter_list, onSelectCallback),
        fixed_item_heights = true,
        items_max_lines = 3,
        itemnumber = options.itemnumber,
        close_callback = options.close_callback,
    }
    menu_options.on_title_bar_left_tap = options.on_title_bar_left_tap
    local menu = getListMenu().show(menu_options)
    if options.on_title_bar_left_tap then
        menu.onLeftButtonTap = function(...)
            return options.on_title_bar_left_tap(menu, ...)
        end
    end
    menu.onMenuSelect = function(_menu, entry)
        if entry and entry.callback then
            entry.callback()
        end
        return true
    end
    if onHoldCallback then
        menu.onMenuHold = function(_menu, entry)
            if entry and entry.chapter then
                onHoldCallback(entry.chapter)
            end
            return true
        end
    end
    return menu
end

function SuwayomiUI.showHomeDialog(options, onSelectCallback)
    local UIManager = require("ui/uimanager")
    local dialog
    local buttons = {}
    local row = {}

    options = options or {}
    local columns = options.vertical and 1 or (options.columns or 1)
    for action_index = 1, #(options.actions or {}) do
        local action = options.actions[action_index]
        table.insert(row, {
            text = action.text,
            callback = function()
                if action.close_before_select ~= false then
                    UIManager:close(dialog)
                    if options.onClose then
                        options.onClose()
                    end
                end
                if onSelectCallback then
                    onSelectCallback(action)
                elseif action.callback then
                    action.callback(action)
                end
            end,
        })
        if #row == columns then
            table.insert(buttons, row)
            row = {}
        end
    end

    if #row > 0 then
        table.insert(buttons, row)
    end

    dialog = ButtonDialog:new{
        title = options.title or I18n.t("Suwayomi"),
        buttons = buttons,
    }
    UIManager:show(dialog)
    return dialog
end

local function formatActionButtonText(action)
    local text = action and action.text or ""
    if action and action.submenu == true then
        return tostring(text) .. " >"
    end
    return text
end

local function buildActionMenuButton(action, dialogProvider, UIManager, onSelectCallback)
    return {
        id = action.id,
        text = formatActionButtonText(action),
        destructive = action.destructive == true or nil,
        callback = function()
            local function selectAction()
                if onSelectCallback then
                    onSelectCallback(action)
                end
            end
            UIManager:close(dialogProvider())
            if UIManager.nextTick then
                UIManager:nextTick(selectAction)
            else
                selectAction()
            end
        end,
    }
end

local function buildBackActionButton(options, dialogProvider, UIManager)
    if type(options.on_back) ~= "function" then
        return nil
    end
    return {
        id = "back",
        text = "< " .. I18n.t("Back"),
        callback = function()
            local function goBack()
                options.on_back()
            end
            UIManager:close(dialogProvider())
            if UIManager.nextTick then
                UIManager:nextTick(goBack)
            else
                goBack()
            end
        end,
    }
end

local function appendActionButtonRows(buttons, actions, columns, dialogProvider, UIManager, onSelectCallback)
    local row = {}
    for action_index = 1, #(actions or {}) do
        local action = actions[action_index]
        table.insert(row, buildActionMenuButton(action, dialogProvider, UIManager, onSelectCallback))
        if #row == columns then
            table.insert(buttons, row)
            row = {}
        end
    end

    if #row > 0 then
        table.insert(buttons, row)
    end
end


local function splitActionGroups(actions)
    local normal_actions = {}
    local destructive_actions = {}
    for action_index = 1, #(actions or {}) do
        local action = actions[action_index]
        if action.destructive == true then
            table.insert(destructive_actions, action)
        else
            table.insert(normal_actions, action)
        end
    end
    return normal_actions, destructive_actions
end


local function buildActionMenuButtons(options, dialogProvider, UIManager, onSelectCallback)
    local buttons = {}
    local columns = options.vertical and 1 or (options.columns or 1)
    local normal_actions = options.actions or {}
    local destructive_actions = {}
    local back_button = buildBackActionButton(options, dialogProvider, UIManager)

    if back_button then
        table.insert(buttons, { back_button })
        table.insert(buttons, {})
    end

    if options.destructive_actions_at_bottom then
        normal_actions, destructive_actions = splitActionGroups(options.actions)
    end

    appendActionButtonRows(buttons, normal_actions, columns, dialogProvider, UIManager, onSelectCallback)
    if #destructive_actions > 0 then
        if #buttons > 0 then
            table.insert(buttons, {})
        end
        appendActionButtonRows(buttons, destructive_actions, columns, dialogProvider, UIManager, onSelectCallback)
    end

    return buttons
end


function SuwayomiUI.showActionMenu(options, onSelectCallback)
    local UIManager = require("ui/uimanager")
    local dialog
    options = options or {}

    dialog = ButtonDialog:new{
        title = options.title or I18n.t("Actions"),
        buttons = buildActionMenuButtons(options, function()
            return dialog
        end, UIManager, onSelectCallback),
        anchor = options.anchor,
        close_callback = options.close_callback,
    }
    UIManager:show(dialog)
    return dialog
end

function SuwayomiUI.showChapterActionsMenu(options, onSelectCallback)
    options = options or {}
    options.title = options.title or I18n.t("Chapter actions")
    options.vertical = true
    options.destructive_actions_at_bottom = true
    return SuwayomiUI.showActionMenu(options, onSelectCallback)
end

function SuwayomiUI.showMangaActionsMenu(options, onSelectCallback)
    options = options or {}
    options.title = options.title or I18n.t("Manga actions")
    options.vertical = true
    options.destructive_actions_at_bottom = true
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
    if options.on_title_bar_left_tap then
        menu.onLeftButtonTap = function(...)
            return options.on_title_bar_left_tap(menu, ...)
        end
    end
    if onHoldCallback then
        menu.onMenuHold = function(_menu, entry)
            if entry and entry.chapter then
                onHoldCallback(entry.chapter)
            end
            return true
        end
    end
    return getListMenu().update(menu, {
        title = options.title or menu.title,
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = item_table,
        itemnumber = options.itemnumber,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
    })
end

function SuwayomiUI.buildLanguageMenuTable(options, onToggleCallback)
    local menu_table = {}

    for language_index = 1, #(options.languages or {}) do
        local language = options.languages[language_index]
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

    if options.show_done ~= false then
        table.insert(menu_table, {
            text = I18n.t("Done"),
            callback = function()
                if options.onClose then
                    options.onClose()
                end
            end,
        })
    end

    return menu_table
end

function SuwayomiUI.showLanguageMenu(options)
    options = options or {}
    local close_ran = false
    local choices = {}

    for language_index = 1, #(options.languages or {}) do
        local language = options.languages[language_index]
        table.insert(choices, {
            value = language.code,
            text = language.label,
            language = language,
        })
    end

    local function runClose()
        if close_ran then
            return
        end
        close_ran = true
        if options.onClose then
            options.onClose()
        end
    end

    return SuwayomiUI.showChecklistDialog({
        title = options.title or I18n.t("Suwayomi source languages"),
        choices = choices,
        anchor = options.anchor,
        isSelected = function(_value, choice)
            return choice.language and choice.language.enabled == true
        end,
        onToggle = function(code, selected, choice)
            if choice and choice.language then
                choice.language.enabled = selected == true
            end
            if options.onToggle then
                options.onToggle(code, selected)
            end
        end,
        onDone = runClose,
        close_callback = runClose,
    })
end

local function buildLibraryCategoryPickerBehaviorChoices(choices)
    local labels = {
        automatic = I18n.t("Automatic"),
        always = I18n.t("Always ask"),
        never = I18n.t("Never ask"),
    }

    local dialog_choices = {}
    for behavior_index = 1, #(choices or { "automatic", "always", "never" }) do
        local behavior = choices[behavior_index]
        table.insert(dialog_choices, {
            value = behavior,
            text = labels[behavior] or behavior,
        })
    end

    return dialog_choices
end

local function buildDeleteFinishedWhileReadingChoices(choices)
    local labels = {
        [0] = I18n.t("Disabled"),
        [1] = I18n.t("Last read chapter"),
        [2] = I18n.t("Second to last read chapter"),
        [3] = I18n.t("Third to last read chapter"),
        [4] = I18n.t("Fourth to last read chapter"),
        [5] = I18n.t("Fifth to last read chapter"),
    }

    local dialog_choices = {}
    for value_index = 1, #(choices or { 0, 1, 2, 3, 4, 5 }) do
        local value = choices[value_index]
        table.insert(dialog_choices, {
            value = value,
            text = labels[value] or tostring(value),
        })
    end

    return dialog_choices
end

local function buildParallelDownloadChoices(choices)
    local dialog_choices = {}
    for value_index = 1, #(choices or { 1, 2, 3, 4 }) do
        local value = choices[value_index]
        table.insert(dialog_choices, {
            value = value,
            text = tostring(value),
        })
    end

    return dialog_choices
end

function SuwayomiUI.showParallelDownloadsMenu(options)
    options = options or {}
    return ChoiceDialogs.showChoiceDialog({
        title = I18n.t("Parallel chapter downloads"),
        current = tonumber(options.current) or 2,
        choices = buildParallelDownloadChoices(options.choices),
        onSelect = options.onSelect,
        anchor = options.anchor,
        close_callback = options.close_callback,
    })
end

function SuwayomiUI.showLibraryCategoryPickerBehaviorMenu(options)
    options = options or {}
    return ChoiceDialogs.showChoiceDialog({
        title = I18n.t("Library category picker"),
        current = options.current or "automatic",
        choices = buildLibraryCategoryPickerBehaviorChoices(options.choices),
        onSelect = options.onSelect,
        anchor = options.anchor,
        close_callback = options.close_callback,
    })
end

function SuwayomiUI.showDeleteFinishedWhileReadingMenu(options)
    options = options or {}
    return ChoiceDialogs.showChoiceDialog({
        title = I18n.t("Delete finished chapters"),
        current = tonumber(options.current) or 0,
        choices = buildDeleteFinishedWhileReadingChoices(options.choices),
        onSelect = options.onSelect,
        anchor = options.anchor,
        close_callback = options.close_callback,
    })
end

function SuwayomiUI.updateLanguageMenu(menu, _options, _onToggleCallback)
    return menu
end

function SuwayomiUI.showLoginDialog(options)
    local credentials = options.credentials or {}
    local UIManager = require("ui/uimanager")
    local dialog

    dialog = MultiInputDialog:new{
        title = I18n.t("Suwayomi login"),
        fields = {
            {
                hint = I18n.t("Server URL"),
                text = credentials.server_url or "",
            },
            {
                hint = I18n.t("Username"),
                text = credentials.username or "",
            },
            {
                hint = I18n.t("Password"),
                text = credentials.password or "",
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = I18n.t("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = I18n.t("Save"),
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

local function getCredentialsFromDialog(dialog)
    local fields = dialog:getFields()
    return {
        server_url = fields[1],
        username = fields[2],
        password = fields[3],
        auth_method = "basic_auth",
    }
end

local function formatOnboardingConnectionTitle(status)
    local suffixes = {
        testing = I18n.t("testing..."),
        passed = I18n.t("tested"),
        failed = I18n.t("failed"),
        untested = I18n.t("not tested"),
    }
    return I18n.f("Suwayomi setup: connection (%1)", suffixes[status] or suffixes.untested)
end

function SuwayomiUI.updateOnboardingConnectionDialogStatus(dialog, status)
    if not dialog then
        return
    end
    local title = formatOnboardingConnectionTitle(status)
    dialog.title = title
    if dialog.title_bar and dialog.title_bar.setTitle then
        dialog.title_bar:setTitle(title, true)
    end
    local continue_button = dialog.button_table
        and dialog.button_table.getButtonById
        and dialog.button_table:getButtonById("continue")
    if continue_button and continue_button.refresh then
        continue_button:refresh()
    end
end

function SuwayomiUI.showOnboardingConnectionDialog(options)
    options = options or {}
    local credentials = options.credentials or {}
    local UIManager = require("ui/uimanager")
    local dialog
    local close_ran = false
    local function runClose()
        if close_ran then
            return
        end
        close_ran = true
        if options.onClose then
            options.onClose()
        end
    end
    local function canContinue()
        if not options.canContinue then
            return true
        end
        if not dialog or not dialog.getFields then
            return false
        end
        return options.canContinue(getCredentialsFromDialog(dialog)) == true
    end

    dialog = MultiInputDialog:new{
        title = formatOnboardingConnectionTitle(options.connection_status),
        fields = {
            {
                hint = I18n.t("Server URL"),
                text = credentials.server_url or "",
            },
            {
                hint = I18n.t("Username"),
                text = credentials.username or "",
            },
            {
                hint = I18n.t("Password"),
                text = credentials.password or "",
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = I18n.t("Cancel"),
                    id = "close",
                    callback = function()
                        runClose()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = I18n.t("Test connection"),
                    callback = function()
                        if options.onTestConnection then
                            options.onTestConnection(getCredentialsFromDialog(dialog))
                        end
                    end,
                },
            },
            {
                {
                    text = I18n.t("Continue"),
                    id = "continue",
                    enabled = canContinue(),
                    enabled_func = canContinue,
                    is_enter_default = true,
                    callback = function()
                        if not canContinue() then
                            return
                        end
                        local dialog_credentials = getCredentialsFromDialog(dialog)
                        local should_close = true
                        if options.onContinue then
                            should_close = options.onContinue(dialog_credentials) ~= false
                        end
                        if should_close then
                            UIManager:close(dialog)
                        end
                    end,
                },
            },
        },
        close_callback = runClose,
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

return SuwayomiUI
