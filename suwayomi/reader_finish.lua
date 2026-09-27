-- Boundary: ReaderFinish.
-- Responsibility: Adapt native finish navigation while leaving completion and close to KOReader.
-- Owned state: Two status-instance wrappers, removed when their reader host retires.
-- Dependencies: Native status methods, UI stack/dialog shape, KOReader gettext, guarded reader Next.
-- External data: Recognized documents may still lack a usable successor; never fall back to folder scanning.

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local I18n = require("suwayomi/i18n")
local _ = require("gettext")
local Methods = {}

local function widgets()
    local result = {}
    for _, window in ipairs(UIManager._window_stack) do result[window.widget] = true end
    return result
end

local function nextButton(dialog)
    if type(dialog) ~= "table" or dialog.name ~= "end_document"
        or type(dialog.reinit) ~= "function" or type(dialog.buttons) ~= "table"
        or #dialog.buttons ~= 3 then return end
    local labels = { { false, _("Book status") }, { _("Go to beginning"), _("Open next file") },
        { _("Delete file"), _("File browser") } }
    for row, expected in ipairs(labels) do
        local buttons = dialog.buttons[row]
        if type(buttons) ~= "table" or #buttons ~= 2 then return end
        for col, label in ipairs(expected) do
            local button = buttons[col]
            if type(button) ~= "table" or type(button.callback) ~= "function"
                or (label and button.text ~= label)
                or (not label and type(button.text_func) ~= "function") then return end
        end
    end
    return dialog.buttons[2][2]
end

function Methods:installReaderFinishAdapter()
    if self.reader_finish_adapter then return end
    local reader = self.ui
    local status = reader and reader.document and reader.status
    if not status or type(status.onEndOfBook) ~= "function"
        or type(status.onOpenNextOrPreviousFileInFolder) ~= "function" then return end
    local state = { status = status, finish = status.onEndOfBook,
        next_file = status.onOpenNextOrPreviousFileInFolder, document = reader.document }
    self.reader_finish_adapter = state
    local function current()
        return self.reader_finish_adapter == state and not self.suwayomi_host_retired
            and self.ui == reader and reader.document == state.document
            and require("apps/reader/readerui").instance == reader
    end
    local function linked()
        return current() and self:getReaderReturnContextForPath(state.document.file, true) ~= nil
    end
    local function pending()
        return self.next_chapter_pending and self.next_chapter_pending()
    end
    state.next_wrapper = function(native, prev, ...)
        if not current() then return true end
        if prev or not linked() then return state.next_file(native, prev, ...) end
        if not pending() then self:openNextChapter() end
        return true
    end
    state.finish_wrapper = function(native, ...)
        if not current() then return end
        if not linked() then return state.finish(native, ...) end
        if pending() then return end
        local reader_settings = rawget(_G, "G_reader_settings")
        local action = reader_settings:readSetting("end_document_action") or "pop-up"
        local sort = reader_settings:readSetting("collate")
        local before = widgets()
        local result = state.finish(native, ...)
        if not linked() or action ~= (reader_settings:readSetting("end_document_action") or "pop-up")
            or sort ~= reader_settings:readSetting("collate") then return result end
        if action == "pop-up" then
            local dialog = UIManager:getTopmostVisibleWidget()
            local button = not before[dialog] and nextButton(dialog)
            if button then
                button.text = I18n.t("Next chapter")
                button.enabled = true
                -- ButtonDialog:init keeps an existing focus layout, whose buttons reinit frees.
                dialog.layout = nil
                dialog:reinit()
                UIManager:setDirty(dialog, "ui")
            end
        elseif action == "next_file" and (sort == "access" or sort == "date") then
            -- Native auto-mark has already run. Remove only this call's known sort error.
            -- Inspect new stack entries because an existing toast can cover the InfoMessage.
            local notice, added = nil, 0
            for widget in pairs(widgets()) do
                if not before[widget] then
                    added = added + 1
                    if getmetatable(widget) == InfoMessage and widget.text == _(
                        "Could not open next file. Sort by date does not support this feature.") then
                        notice = widget
                    end
                end
            end
            if added == 1 and notice then
                UIManager:close(notice)
                status:onOpenNextOrPreviousFileInFolder()
            elseif added == 0 and UIManager.silent_mode and InfoMessage.honor_silent_mode then
                status:onOpenNextOrPreviousFileInFolder()
            end
        end
        return result
    end
    status.onOpenNextOrPreviousFileInFolder = state.next_wrapper
    status.onEndOfBook = state.finish_wrapper
end

function Methods:removeReaderFinishAdapter()
    local state = self.reader_finish_adapter
    if not state then return end
    self.reader_finish_adapter = nil
    if state.status.onEndOfBook == state.finish_wrapper then state.status.onEndOfBook = state.finish end
    if state.status.onOpenNextOrPreviousFileInFolder == state.next_wrapper then
        state.status.onOpenNextOrPreviousFileInFolder = state.next_file
    end
end

return { methods = Methods }
