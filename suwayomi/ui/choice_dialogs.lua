-- Boundary: reusable modal choice/checklist dialogs.
--
-- Responsibility: build small KOReader ButtonDialog-based option surfaces.
-- Owned state: none; callbacks own persistence and parent refresh behavior.
-- Dependencies: KOReader ButtonDialog/UIManager and gettext.
-- External data: labels and values are caller-provided display data.

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local ChoiceDialogs = {}

local function selectedText(selected, text)
    text = tostring(text or "")
    if selected then
        return "* " .. text
    end
    return text
end

local function choiceValue(choice)
    if type(choice) == "table" then
        return choice.value
    end
    return choice
end

local function choiceLabel(choice)
    if type(choice) == "table" then
        return choice.text or choice.label or choice.value
    end
    return choice
end

local function closeThen(dialogProvider, callback)
    UIManager:close(dialogProvider())
    if callback then
        callback()
    end
end

function ChoiceDialogs.showChoiceDialog(options)
    options = options or {}
    local dialog
    local buttons = {}

    for _, choice in ipairs(options.choices or {}) do
        local value = choiceValue(choice)
        table.insert(buttons, {
            {
                text = selectedText(value == options.current, choiceLabel(choice)),
                callback = function()
                    closeThen(function()
                        return dialog
                    end, function()
                        if options.onSelect then
                            options.onSelect(value, choice)
                        end
                    end)
                end,
            },
        })
    end

    dialog = ButtonDialog:new{
        title = options.title or _("Choose"),
        buttons = buttons,
        anchor = options.anchor,
        close_callback = options.close_callback,
    }
    UIManager:show(dialog)
    return dialog
end

function ChoiceDialogs.showChecklistDialog(options)
    options = options or {}
    local dialog
    local buttons = {}
    local function reopen()
        local function showAgain()
            ChoiceDialogs.showChecklistDialog(options)
        end
        UIManager:close(dialog)
        if UIManager.nextTick then
            UIManager:nextTick(showAgain)
        else
            showAgain()
        end
    end

    for _, choice in ipairs(options.choices or {}) do
        local value = choiceValue(choice)
        local selected = options.isSelected and options.isSelected(value, choice) == true
        table.insert(buttons, {
            {
                text = selectedText(selected, choiceLabel(choice)),
                callback = function()
                    if options.onToggle then
                        options.onToggle(value, not selected, choice)
                    end
                    reopen()
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Done"),
            callback = function()
                closeThen(function()
                    return dialog
                end, options.onDone)
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = options.title or _("Choose"),
        buttons = buttons,
        anchor = options.anchor,
        close_callback = options.close_callback,
    }
    UIManager:show(dialog)
    return dialog
end

return ChoiceDialogs
