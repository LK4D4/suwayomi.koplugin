-- Boundary: reusable modal choice/checklist dialogs.
--
-- Responsibility: build small KOReader ButtonDialog-based option surfaces.
-- Owned state: none; callbacks own persistence and parent refresh behavior.
-- Dependencies: KOReader ButtonDialog/UIManager and plugin i18n facade.
-- External data: labels and values are caller-provided display data.

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local I18n = require("suwayomi/i18n")

local ChoiceDialogs = {}

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

local function choiceText(choice)
    return tostring(choiceLabel(choice) or "")
end

local function closeThen(dialogProvider, callback)
    local function run()
        UIManager:close(dialogProvider())
        if callback then
            callback()
        end
    end

    if UIManager.nextTick then
        UIManager:nextTick(run)
    else
        run()
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
                text = choiceText(choice),
                align = "left",
                checked_func = function()
                    return value == options.current
                end,
                no_refresh_checkmark = true,
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
        title = options.title or I18n.t("Choose"),
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

    local function isChoiceSelected(value, choice)
        return options.isSelected and options.isSelected(value, choice) == true
    end

    for _, choice in ipairs(options.choices or {}) do
        local value = choiceValue(choice)
        table.insert(buttons, {
            {
                text = choiceText(choice),
                align = "left",
                checked_func = function()
                    return isChoiceSelected(value, choice)
                end,
                callback = function()
                    if options.onToggle then
                        options.onToggle(value, not isChoiceSelected(value, choice), choice)
                    end
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = I18n.t("Done"),
            callback = function()
                closeThen(function()
                    return dialog
                end, options.onDone)
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = options.title or I18n.t("Choose"),
        buttons = buttons,
        anchor = options.anchor,
        close_callback = options.close_callback,
    }
    UIManager:show(dialog)
    return dialog
end

return ChoiceDialogs
