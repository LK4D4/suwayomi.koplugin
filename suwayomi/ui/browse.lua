-- Boundary: Browse/library list and search UI.
--
-- Responsibility: build source, search, browse manga, and library category menus
-- while preserving controller-owned callbacks.
-- Owned state: none; menu refresh helpers mutate existing KOReader menu widgets.
-- Dependencies: KOReader Menu/MultiInputDialog, plugin i18n facade, and shared
-- menu utils.
-- External data: source and manga rows come from API/cache layers and are only
-- formatted for display here.

local MultiInputDialog = require("ui/widget/multiinputdialog")
local I18n = require("suwayomi/i18n")
local ListRows = require("suwayomi/ui/list_rows")

local BrowseUI = {}

local function getListMenu()
    return require("suwayomi/ui/list_menu")
end

local function getUI()
    return require("suwayomi/ui")
end

local function findExtensionItemNumber(menu_table, pkg_name)
    if pkg_name == nil or pkg_name == "" then
        return nil
    end
    for index, row in ipairs(menu_table or {}) do
        if type(row.extension) == "table" and row.extension.pkg_name == pkg_name then
            return index
        end
    end
    return nil
end

function BrowseUI.showSourcesMenu(sources, onSelectCallback, options)
    options = options or {}
    if type(onSelectCallback) == "table" then
        options = onSelectCallback
        onSelectCallback = options.onSelect
    end

    return getListMenu().show{
        title = I18n.t("Suwayomi Sources"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        fixed_item_heights = options.fixed_item_heights ~= false,
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
    local item_table = ListRows.buildExtensionMenuTable(extensions, {
        on_select = onSelectCallback,
        empty_text = options.empty_text,
        show_empty_sections = options.show_empty_extension_sections,
    })
    return getListMenu().show{
        title = options.title or I18n.t("Suwayomi Extensions"),
        title_bar_left_icon = options and options.title_bar_left_icon,
        fixed_item_heights = options.fixed_item_heights ~= false,
        item_table = item_table,
        itemnumber = options.itemnumber or findExtensionItemNumber(item_table, options.focus_extension_pkg_name),
        close_callback = options.close_callback,
        on_close = options.on_close,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        thumbnail_credentials = options.thumbnail_credentials,
    }
end

function BrowseUI.updateExtensionsMenu(menu, extensions, onSelectCallback, options)
    options = options or {}
    local item_table = ListRows.buildExtensionMenuTable(extensions, {
        on_select = onSelectCallback,
        empty_text = options.empty_text,
        show_empty_sections = options.show_empty_extension_sections,
    })
    return getListMenu().update(menu, {
        title = options.title or I18n.t("Suwayomi Extensions"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = item_table,
        itemnumber = options.itemnumber or findExtensionItemNumber(item_table, options.focus_extension_pkg_name),
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
        addAction("install", I18n.c("extension action", "Install"))
    elseif type(extension) == "table" and extension.has_update == true then
        addAction("update", I18n.c("extension action", "Update"))
    end
    if type(extension) == "table" and extension.is_installed == true then
        addAction("uninstall", I18n.c("extension action", "Uninstall"), true)
    end

    if #actions == 0 then
        table.insert(actions, { text = I18n.t("No actions available") })
    end

    return require("suwayomi/ui").showActionMenu({
        title = options.title or ListRows.getExtensionTitle(extension),
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
            text = I18n.c("source mode", "Popular"),
        },
    }

    if not source or source.supports_latest ~= false then
        table.insert(actions, {
            id = "LATEST",
            text = I18n.c("source mode", "Latest"),
        })
    end

    table.insert(actions, {
        id = "SEARCH",
        text = I18n.c("source mode", "Search"),
    })

    table.insert(actions, {
        id = "FILTERS",
        text = I18n.t("Source filters"),
    })

    return require("suwayomi/ui").showActionMenu({
        title = source and (source.name or source.display_name or source.displayName) or I18n.t("Suwayomi Source"),
        actions = actions,
        columns = 2,
        anchor = options.anchor,
        close_callback = options.close_callback,
        on_back = options.on_back,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
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
        title = I18n.f("Search %1", source and (source.name or source.display_name or source.displayName) or I18n.t("source")),
        fields = {
            {
                hint = I18n.t("Search query"),
                text = options.query or "",
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
                    text = I18n.c("source action", "Search"),
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

local function copyDraft(draft)
    draft = type(draft) == "table" and draft or {}
    local copied = {
        query = draft.query ~= nil and tostring(draft.query) or "",
        filters = {},
    }
    for _ , entry in ipairs(type(draft.filters) == "table" and draft.filters or {}) do
        local copied_entry = {}
        for key, value in pairs(entry) do
            if key == "group_change" and type(value) == "table" then
                local child = {}
                for child_key, child_value in pairs(value) do
                    child[child_key] = child_value
                end
                copied_entry[key] = child
            else
                copied_entry[key] = value
            end
        end
        table.insert(copied.filters, copied_entry)
    end
    return copied
end

local function findDraftEntry(draft, position, state_type)
    for _ , entry in ipairs(draft.filters or {}) do
        if entry.position == position and entry.type == state_type then
            return entry
        end
    end
    local entry = {
        position = position,
        type = state_type,
    }
    table.insert(draft.filters, entry)
    return entry
end

local function findGroupDraftEntry(draft, group_position, position, state_type)
    for _ , entry in ipairs(draft.filters or {}) do
        local group_change = type(entry.group_change) == "table" and entry.group_change or nil
        if entry.position == group_position
            and group_change
            and group_change.position == position
            and group_change.type == state_type
        then
            return group_change
        end
    end
    local entry = {
        position = group_position,
        group_change = {
            position = position,
            type = state_type,
        },
    }
    table.insert(draft.filters, entry)
    return entry.group_change
end

local function findDraftStateEntry(draft, position, state_type, group_position)
    if group_position then
        return findGroupDraftEntry(draft, group_position, position, state_type)
    end
    return findDraftEntry(draft, position, state_type)
end

local function getDraftState(draft, position, state_type, default, group_position)
    for _ , entry in ipairs(draft.filters or {}) do
        local candidate = entry
        if group_position then
            candidate = entry.position == group_position
                and type(entry.group_change) == "table"
                and entry.group_change
                or nil
        end
        if candidate and candidate.position == position and candidate.type == state_type then
            return candidate.state
        end
    end
    return default
end

local function stateText(value)
    return value and I18n.c("source filter state", "On") or I18n.c("source filter state", "Off")
end

local function sortStateText(filter, state)
    local values = type(filter.values) == "table" and filter.values or {}
    state = type(state) == "table" and state or {}
    local index = tonumber(state.index) or 0
    local label = values[index + 1] or tostring(index)
    if state.ascending == false then
        return I18n.cf("source filter sort summary", "%1 - Descending", label)
    end
    return I18n.cf("source filter sort summary", "%1 - Ascending", label)
end

local function triStateText(value)
    value = tostring(value or "IGNORE")
    if value == "INCLUDE" then
        return I18n.c("source filter tri-state", "Include")
    elseif value == "EXCLUDE" then
        return I18n.c("source filter tri-state", "Exclude")
    end
    return I18n.c("source filter tri-state", "Any")
end

local function triStateChoices()
    return {
        { value = "IGNORE", text = I18n.c("source filter tri-state", "Any") },
        { value = "INCLUDE", text = I18n.c("source filter tri-state", "Include") },
        { value = "EXCLUDE", text = I18n.c("source filter tri-state", "Exclude") },
    }
end

local function sortStatesEqual(left, right)
    left = type(left) == "table" and left or {}
    right = type(right) == "table" and right or {}
    return (tonumber(left.index) or 0) == (tonumber(right.index) or 0)
        and (left.ascending ~= false) == (right.ascending ~= false)
end

local function childFilterHasDraftChange(child, child_index, draft, group_position)
    child = type(child) == "table" and child or {}
    if child.type == "CheckBoxFilter" then
        local default = child.default == true
        return getDraftState(draft, child_index, "checkBoxState", default, group_position) ~= default
    elseif child.type == "TriStateFilter" then
        local default = tostring(child.default or "IGNORE")
        return tostring(getDraftState(draft, child_index, "triState", default, group_position)) ~= default
    elseif child.type == "SelectFilter" then
        local default = tonumber(child.default) or 0
        return (tonumber(getDraftState(draft, child_index, "selectState", default, group_position)) or 0) ~= default
    elseif child.type == "TextFilter" then
        local default = tostring(child.default or "")
        return tostring(getDraftState(draft, child_index, "textState", default, group_position)) ~= default
    elseif child.type == "SortFilter" then
        local default = type(child.default) == "table" and child.default or { index = 0, ascending = true }
        return not sortStatesEqual(getDraftState(draft, child_index, "sortState", default, group_position), default)
    end
    return false
end

local function groupStateText(filter, draft, group_position)
    local active_count = 0
    for child_index, child in ipairs(type(filter.filters) == "table" and filter.filters or {}) do
        if childFilterHasDraftChange(child, child_index, draft, group_position) then
            active_count = active_count + 1
        end
    end
    if active_count == 0 then
        return I18n.c("source filter tri-state", "Any")
    end
    return I18n.count(active_count, "1 selected", "%1 selected")
end

local function showTextFilterDialog(filter, current, onSave)
    local UIManager = require("ui/uimanager")
    local dialog
    dialog = MultiInputDialog:new{
        title = filter.name or I18n.t("Text filter"),
        fields = {
            {
                hint = filter.name or I18n.t("Text"),
                text = current or "",
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
                        onSave(fields[1] or "")
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

local function canShowGroupAsChecklist(filters)
    if type(filters) ~= "table" or #filters == 0 or #filters > 8 then
        return false
    end
    for _ , child in ipairs(filters) do
        local child_type = type(child) == "table" and child.type or nil
        if child_type ~= "CheckBoxFilter" then
            return false
        end
    end
    return true
end

local function hasSourceFilterTitleActions(title_options)
    return type(title_options.actions) == "table"
        or type(title_options.on_title_bar_left_tap) == "function"
        or type(title_options.on_title_bar_left_hold) == "function"
end

local function refreshSourceFilterMenu(context, menu)
    if type(menu) ~= "table" and context and type(context.get_menu) == "function" then
        menu = context.get_menu()
    end
    if type(menu) == "table" and type(menu.updateItems) == "function" then
        menu:updateItems(nil, true)
    end
end

local function hasFilterLabel(filter)
    return tostring(filter and filter.name or ""):match("%S") ~= nil
end

local function buildSourceFilterRows(filters, draft, context)
    context = context or {}
    local rows = {}
    for index, filter in ipairs(filters or {}) do
        filter = type(filter) == "table" and filter or {}
        local filter_type = tostring(filter.type or "")
        if filter_type == "HeaderFilter" or filter_type == "SeparatorFilter" then
            if hasFilterLabel(filter) then
                table.insert(rows, {
                    text = filter.name,
                    select_enabled = false,
                })
            end
        elseif filter_type == "CheckBoxFilter" then
            local value = getDraftState(draft, index, "checkBoxState", filter.default == true, context.group_position)
            local row = {
                text = filter.name or "",
                mandatory = stateText(value),
                keep_menu_open = true,
            }
            row.callback = function(menu)
                local entry = findDraftStateEntry(draft, index, "checkBoxState", context.group_position)
                entry.state = getDraftState(
                    draft,
                    index,
                    "checkBoxState",
                    filter.default == true,
                    context.group_position
                ) ~= true
                row.mandatory = stateText(entry.state)
                refreshSourceFilterMenu(context, menu)
            end
            table.insert(rows, row)
        elseif filter_type == "TriStateFilter" then
            local value = tostring(getDraftState(draft, index, "triState", filter.default or "IGNORE", context.group_position))
            local row = {
                text = filter.name or "",
                mandatory = triStateText(value),
            }
            row.callback = function(menu)
                local current = tostring(getDraftState(
                    draft,
                    index,
                    "triState",
                    filter.default or "IGNORE",
                    context.group_position
                ))
                return getUI().showChoiceDialog({
                    title = filter.name or "",
                    current = current,
                    choices = triStateChoices(),
                    onSelect = function(state)
                        local entry = findDraftStateEntry(draft, index, "triState", context.group_position)
                        entry.state = state
                        row.mandatory = triStateText(state)
                        refreshSourceFilterMenu(context, menu)
                    end,
                })
            end
            table.insert(rows, row)
        elseif filter_type == "SelectFilter" then
            local value = tonumber(getDraftState(draft, index, "selectState", filter.default or 0, context.group_position)) or 0
            local values = type(filter.values) == "table" and filter.values or {}
            local row = {
                text = filter.name or "",
                mandatory = values[value + 1] or tostring(value),
            }
            if #values == 0 then
                row.select_enabled = false
            else
                row.callback = function(menu)
                    local choices = {}
                    local current = tonumber(getDraftState(
                        draft,
                        index,
                        "selectState",
                        filter.default or 0,
                        context.group_position
                    )) or 0
                    for value_index, label in ipairs(values) do
                        table.insert(choices, {
                            value = value_index - 1,
                            text = label,
                        })
                    end
                    return getUI().showChoiceDialog({
                        title = filter.name or "",
                        current = current,
                        choices = choices,
                        onSelect = function(state, choice)
                            local entry = findDraftStateEntry(draft, index, "selectState", context.group_position)
                            entry.state = state
                            row.mandatory = choice and choice.text or values[state + 1] or tostring(state)
                            refreshSourceFilterMenu(context, menu)
                        end,
                    })
                end
            end
            table.insert(rows, row)
        elseif filter_type == "TextFilter" then
            local row = {
                text = filter.name or "",
                mandatory = tostring(getDraftState(draft, index, "textState", filter.default or "", context.group_position)),
            }
            row.callback = function(menu)
                return showTextFilterDialog(filter, row.mandatory, function(value)
                    local entry = findDraftStateEntry(draft, index, "textState", context.group_position)
                    entry.state = value
                    row.mandatory = value
                    refreshSourceFilterMenu(context, menu)
                end)
            end
            table.insert(rows, row)
        elseif filter_type == "SortFilter" then
            local default = type(filter.default) == "table" and filter.default or { index = 0, ascending = true }
            local state = getDraftState(draft, index, "sortState", default, context.group_position)
            if type(state) ~= "table" then
                state = default
            end
            local row = {
                text = filter.name or "",
                mandatory = sortStateText(filter, state),
            }
            local values = type(filter.values) == "table" and filter.values or {}
            row.callback = function(menu)
                local actions = {}
                local current = getDraftState(draft, index, "sortState", default, context.group_position)
                if type(current) ~= "table" then
                    current = default
                end
                for value_index, label in ipairs(values) do
                    local sort_index = value_index - 1
                    local prefix = current.index == sort_index and "* " or ""
                    table.insert(actions, {
                        id = "sort_index",
                        text = prefix .. tostring(label),
                        sort_index = sort_index,
                    })
                end
                table.insert(actions, {
                    id = "ascending",
                    text = (current.ascending ~= false and "* " or "")
                        .. I18n.c("source filter sort direction", "Ascending"),
                })
                table.insert(actions, {
                    id = "descending",
                    text = (current.ascending == false and "* " or "")
                        .. I18n.c("source filter sort direction", "Descending"),
                })
                return getUI().showActionMenu({
                    title = filter.name or "",
                    actions = actions,
                    vertical = true,
                }, function(action)
                    local entry = findDraftStateEntry(draft, index, "sortState", context.group_position)
                    local current_state = type(entry.state) == "table" and entry.state or default
                    if action.id == "sort_index" then
                        entry.state = {
                            index = tonumber(action.sort_index) or 0,
                            ascending = current_state.ascending ~= false,
                        }
                    elseif action.id == "ascending" then
                        entry.state = {
                            index = tonumber(current_state.index) or 0,
                            ascending = true,
                        }
                    elseif action.id == "descending" then
                        entry.state = {
                            index = tonumber(current_state.index) or 0,
                            ascending = false,
                        }
                    end
                    row.mandatory = sortStateText(filter, entry.state)
                    refreshSourceFilterMenu(context, menu)
                end)
            end
            table.insert(rows, row)
        elseif filter_type == "GroupFilter" then
            local row = {
                text = filter.name or "",
                mandatory = groupStateText(filter, draft, index),
            }
            if canShowGroupAsChecklist(filter.filters) then
                row.callback = function(menu)
                    local choices = {}
                    local function childChoiceText(child, child_index)
                        return child.name or tostring(child_index)
                    end
                    for child_index, child in ipairs(filter.filters) do
                        table.insert(choices, {
                            value = {
                                type = child.type,
                                child_index = child_index,
                            },
                            text = childChoiceText(child, child_index),
                        })
                    end
                    return getUI().showChecklistDialog({
                        title = filter.name or "",
                        choices = choices,
                        isSelected = function(value)
                            local child = filter.filters[value.child_index]
                            if value.type == "CheckBoxFilter" then
                                return getDraftState(draft, value.child_index, "checkBoxState", child.default == true, index) == true
                            end
                            return getDraftState(draft, value.child_index, "triState", child.default or "IGNORE", index) ~= "IGNORE"
                        end,
                        onToggle = function(value, selected, choice)
                            local child = filter.filters[value.child_index]
                            if value.type == "CheckBoxFilter" then
                                local entry = findDraftStateEntry(draft, value.child_index, "checkBoxState", index)
                                entry.state = selected == true
                            end
                            choice.text = childChoiceText(child, value.child_index)
                            row.mandatory = groupStateText(filter, draft, index)
                            refreshSourceFilterMenu(context, menu)
                        end,
                    })
                end
            else
                local sub_rows = buildSourceFilterRows(filter.filters, draft, {
                    group_position = index,
                    get_menu = context.get_menu,
                })
                row.sub_item_table = sub_rows
                if #sub_rows == 0 then
                    row.select_enabled = false
                end
            end
            table.insert(rows, row)
        else
            table.insert(rows, {
                text = filter.name or filter_type,
                mandatory = I18n.t("Unsupported"),
                select_enabled = false,
            })
        end
    end
    return rows
end

function BrowseUI.showSourceFilterEditor(source, filters, draft, options)
    options = options or {}
    draft = copyDraft(draft)
    local source_name = source and (source.name or source.display_name or source.displayName) or I18n.t("Source")
    local title = I18n.f("%1 filters", source_name)
    local title_options = options.title_options or {}
    local menu_options = {
        actions = {
            { id = "apply_source_filters", text = I18n.t("Apply filters") },
            { id = "reset_source_filters", text = I18n.t("Reset filters") },
            { id = "source_filter_search_text", text = I18n.t("Search text") },
            { id = "save_source_filter", text = I18n.t("Save filter") },
            { id = "saved_source_filters", text = I18n.t("Saved filters") },
        },
        onSelect = function(action)
            local action_id = action and action.id
            if action_id == "apply_source_filters" and options.on_apply then
                return options.on_apply(copyDraft(draft))
            elseif action_id == "reset_source_filters" and options.on_reset then
                return options.on_reset()
            elseif action_id == "source_filter_search_text" and options.on_search_text then
                return options.on_search_text(copyDraft(draft))
            elseif action_id == "save_source_filter" and options.on_save_filter then
                return options.on_save_filter(copyDraft(draft))
            elseif action_id == "saved_source_filters" and options.on_saved_filters then
                return options.on_saved_filters(copyDraft(draft))
            end
        end,
    }
    local show_options = {}
    for key, value in pairs(title_options) do
        show_options[key] = value
    end
    local function withCurrentDraft(callback)
        return function(menu, ...)
            if type(menu) == "table" then
                menu.suwayomi_source_filter_draft = copyDraft(draft)
            end
            return callback(menu, ...)
        end
    end
    if type(show_options.on_title_bar_left_tap) == "function" then
        show_options.on_title_bar_left_tap = withCurrentDraft(show_options.on_title_bar_left_tap)
    end
    if type(show_options.on_title_bar_left_hold) == "function" then
        show_options.on_title_bar_left_hold = withCurrentDraft(show_options.on_title_bar_left_hold)
    end
    show_options.title = title_options.title or title
    local menu
    show_options.item_table = buildSourceFilterRows(filters, draft, {
        get_menu = function()
            return menu
        end,
    })
    if not hasSourceFilterTitleActions(title_options) then
        table.insert(show_options.item_table, {
            text = I18n.t("Apply filters"),
            callback = function()
                if options.on_apply then
                    return options.on_apply(copyDraft(draft))
                end
            end,
        })
        table.insert(show_options.item_table, {
            text = I18n.t("Reset filters"),
            callback = function()
                if options.on_reset then
                    return options.on_reset()
                end
            end,
        })
        table.insert(show_options.item_table, {
            text = I18n.t("Search text"),
            callback = function()
                if options.on_search_text then
                    return options.on_search_text(copyDraft(draft))
                end
            end,
        })
        table.insert(show_options.item_table, {
            text = I18n.t("Save filter"),
            callback = function()
                if options.on_save_filter then
                    return options.on_save_filter(copyDraft(draft))
                end
            end,
        })
        table.insert(show_options.item_table, {
            text = I18n.t("Saved filters"),
            callback = function()
                if options.on_saved_filters then
                    return options.on_saved_filters(copyDraft(draft))
                end
            end,
        })
    end
    show_options.menu_options = menu_options
    if not show_options.on_title_bar_left_hold and title_options.onSelect == nil then
        show_options.on_title_bar_left_hold = function()
            return menu_options.onSelect({ id = "apply_source_filters" })
        end
    end
    menu = getListMenu().show(show_options)
    return menu
end

local function buildSavedFilterRows(saved_filters, onSelectCallback)
    local rows = {}
    for _, entry in ipairs(type(saved_filters) == "table" and saved_filters or {}) do
        local row = {
            text = tostring(entry.name or ""),
            subtitle = entry.query and entry.query ~= "" and entry.query or nil,
            mandatory = I18n.t("Apply saved filter"),
            saved_filter = entry,
        }
        row.callback = function()
            if onSelectCallback then
                return onSelectCallback(entry)
            end
        end
        table.insert(rows, row)
    end
    if #rows == 0 then
        rows[1] = {
            text = I18n.t("No saved filters."),
            select_enabled = false,
        }
    end

    return rows
end

function BrowseUI.showSavedFiltersMenu(saved_filters, onSelectCallback, options)
    options = options or {}
    local rows = buildSavedFilterRows(saved_filters, onSelectCallback)

    return getListMenu().show{
        title = options.title or I18n.t("Saved filters"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = rows,
        onMenuHold = function(_, row)
            if row and row.saved_filter and options.on_delete then
                return options.on_delete(row.saved_filter)
            end
            return true
        end,
        close_callback = options.close_callback,
        on_back = options.on_back,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
    }
end

function BrowseUI.updateSavedFiltersMenu(menu, saved_filters, onSelectCallback, options)
    if not menu then
        return
    end
    options = options or {}
    return getListMenu().update(menu, {
        title = options.title or I18n.t("Saved filters"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = buildSavedFilterRows(saved_filters, onSelectCallback),
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
    })
end

function BrowseUI.showSavedFilterNamePrompt(current_name, onSaveCallback)
    local UIManager = require("ui/uimanager")
    local dialog
    dialog = MultiInputDialog:new{
        title = I18n.t("Save current filter"),
        fields = {
            {
                hint = I18n.t("Filter name"),
                text = current_name or "",
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
                    text = I18n.t("Save filter"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)
                        if onSaveCallback then
                            onSaveCallback(fields[1] or "")
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

function BrowseUI.showDeleteSavedFilterConfirm(entry, onConfirm)
    return getUI().showConfirm({
        text = I18n.f('Delete saved filter "%1"?', entry and entry.name or ""),
        ok_text = I18n.t("Delete saved filter"),
        cancel_text = I18n.t("Cancel"),
        ok_callback = onConfirm,
    })
end

function BrowseUI.showOverwriteSavedFilterConfirm(name, onConfirm)
    return getUI().showConfirm({
        text = I18n.f('Overwrite saved filter "%1"?', name or ""),
        ok_text = I18n.t("Save filter"),
        cancel_text = I18n.t("Cancel"),
        ok_callback = onConfirm,
    })
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
        title = I18n.t("Search extensions"),
        fields = {
            {
                hint = I18n.t("Extension name, language, or package"),
                text = currentQuery or "",
            },
        },
        buttons = {
            {
                {
                    text = I18n.t("Cancel"),
                    id = "close",
                    callback = function()
                        finish("")
                    end,
                },
                {
                    text = I18n.c("extension action", "Search"),
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
        title = I18n.t("Global search"),
        fields = {
            {
                hint = I18n.t("Search query"),
                text = "",
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
                    text = I18n.c("source action", "Search"),
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
        title = I18n.t("Suwayomi Sources"),
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
        title = I18n.t("Global search"),
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
        title = I18n.t("Global search"),
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
            text = I18n.t("Previous page"),
            callback = options.on_previous_page,
        })
    end
    for _ , row in ipairs(ListRows.buildMangaMenuTable(manga_list, {
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
            text = I18n.t("Next page"),
            callback = options.on_next_page,
        })
    end
    return menu_table
end

function BrowseUI.showMangaMenu(manga_list, onSelectCallback, options)
    options = options or {}
    local menu_table = buildMangaMenuTable(manga_list, onSelectCallback, options)
    return getListMenu().show{
        title = options.title or I18n.t("Suwayomi Manga"),
        title_bar_left_icon = options.title_bar_left_icon,
        fixed_item_heights = options.fixed_item_heights ~= false,
        item_table = menu_table,
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        thumbnail_credentials = options.thumbnail_credentials,
        on_page_changed = options.on_page_changed,
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
        on_page_changed = options.on_page_changed,
    })
end

function BrowseUI.showLibraryCategoryMenu(categories, onSelectCallback, options)
    options = options or {}
    return getListMenu().show{
        title = I18n.t("Suwayomi Library"),
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
        title = I18n.t("Suwayomi Library"),
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
        title = I18n.t("Suwayomi Library"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = buildLibraryMangaMenuTable(manga_list, onSelectCallback),
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        thumbnail_credentials = options.thumbnail_credentials,
    })
end

return BrowseUI
