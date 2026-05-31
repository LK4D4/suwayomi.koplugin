-- Boundary: standalone navigation stack for KOReader widget routes.
--
-- Responsibility: track route widgets, coordinate branch replacement, and keep
-- navigator state in sync when current widgets close themselves.
-- Owned state: ordered route entries for one navigator instance.
-- Dependencies: injected UIManager close method.
-- External data: route ids, widgets, and route options are stored opaquely.

local Navigation = {}
Navigation.__index = Navigation

local function findEntryIndex(entries, widget)
    for index = #entries, 1, -1 do
        if entries[index].widget == widget then
            return index
        end
    end
    return nil
end

local function isTrackableWidget(widget)
    local kind = type(widget)
    return kind == "table" or kind == "userdata"
end

local function removeEntry(entries, index)
    if not index then
        return nil
    end
    local entry = entries[index]
    table.remove(entries, index)
    return entry
end

local function restoreCallback(entry)
    if type(entry.widget) == "table" then
        entry.widget.close_callback = entry.original_close_callback
        entry.widget.onClose = entry.original_on_close
    end
end

local Navigator = {}
Navigator.__index = Navigator

function Navigator:_wrapCloseCallback(entry)
    local widget = entry.widget
    if type(widget) ~= "table" then
        return
    end

    local navigator = self
    local original_close_callback = widget.close_callback
    entry.original_close_callback = original_close_callback
    widget.close_callback = function(...)
        if navigator.closing_widgets[widget] then
            return nil
        end

        if original_close_callback then
            return original_close_callback(...)
        end
        return nil
    end

    local original_on_close = widget.onClose
    if type(original_on_close) ~= "function" then
        return
    end
    entry.original_on_close = original_on_close
    widget.onClose = function(...)
        if navigator.closing_widgets[widget] then
            return nil
        end

        if navigator:isCurrent(widget) then
            navigator:pop(widget)
        end
        return original_on_close(...)
    end
end

function Navigator:push(route_id, widget, options)
    if not isTrackableWidget(widget) then
        return nil
    end

    local existing = removeEntry(self.entries, findEntryIndex(self.entries, widget))
    if existing then
        restoreCallback(existing)
    end

    local entry = {
        route_id = route_id,
        widget = widget,
        options = options,
    }
    self:_wrapCloseCallback(entry)
    table.insert(self.entries, entry)
    return widget
end

function Navigator:replaceBranch(route_id, widget, options)
    if not isTrackableWidget(widget) then
        return nil
    end

    self:closeAll()
    return self:push(route_id, widget, options)
end

function Navigator:pop(widget)
    local index
    if widget == nil then
        index = #self.entries
    else
        index = findEntryIndex(self.entries, widget)
    end

    local entry = removeEntry(self.entries, index)
    if not entry then
        return nil
    end

    restoreCallback(entry)
    return entry.widget
end

function Navigator:closeAll()
    while #self.entries > 0 do
        local entry = removeEntry(self.entries, #self.entries)
        local widget = entry.widget
        self.closing_widgets[widget] = true
        local close_ok, close_err = true, nil
        if self.ui_manager and self.ui_manager.close then
            close_ok, close_err = pcall(self.ui_manager.close, self.ui_manager, widget)
        end
        local callback_ok, callback_err = true, nil
        if entry.original_close_callback then
            callback_ok, callback_err = pcall(entry.original_close_callback)
        end
        restoreCallback(entry)
        self.closing_widgets[widget] = nil
        if not close_ok then
            error(close_err)
        end
        if not callback_ok then
            error(callback_err)
        end
    end
end

function Navigator:isCurrent(widget)
    if not isTrackableWidget(widget) then
        return false
    end
    local entry = self.entries[#self.entries]
    return entry ~= nil and entry.widget == widget
end

function Navigator:contains(widget)
    if not isTrackableWidget(widget) then
        return false
    end
    return findEntryIndex(self.entries, widget) ~= nil
end

function Navigation.new(ui_manager)
    return setmetatable({
        ui_manager = ui_manager,
        entries = {},
        closing_widgets = {},
    }, Navigator)
end

return Navigation
