-- Sandbox-only adapter for KOReader v2026.07.1's bundled HTTP inspector.
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local PluginLoader = require("pluginloader")
local Server = require("ui/message/simpletcpserver")
local userpatch = require("userpatch")
local function readLine(name)
    local file = assert(io.open(DataStorage:getDataDir() .. "/" .. name, "r"), "Missing sandbox inspector configuration")
    local value = file:read("*l")
    file:close()
    return value
end
local token = readLine("inspector.token")
assert(type(token) == "string" and #token == 64 and token:match("^%x+$"), "Invalid sandbox inspector token")
local port = tonumber(readLine("inspector.port"))
assert(port and port % 1 == 0 and port >= 1024 and port <= 65535, "Invalid sandbox inspector port")
local prefix = "/koreader/ui/httpinspector/"

userpatch.registerPatchPluginFunc("httpinspector", function(Inspector)
    if not Inspector.sandbox_secured then
        local function text(value)
            if type(value) == "string" then return value:sub(1, 300) end
        end
        local function enabled(control)
            return control.enabled ~= false
                and not (control.entry and control.entry.select_enabled == false)
                and not (control.item and control.item.enabled == false)
                and (not control.isEnabled or control:isEnabled())
        end
        function Inspector:observe()
            -- Never walk settings, model graphs, or arbitrary object properties.
            local stack = UIManager._window_stack
            local index = #stack
            local widget = stack[index] and stack[index].widget
            local path = "/koreader/UIManager/_window_stack/" .. index .. "/widget/"
            local result = { screen = "empty", controls = {} }
            self._sandbox_controls = {}
            if not widget then return result end
            -- ReaderMenu wraps TouchMenu in a CenterContainer. Its focus rows
            -- are sparse: an item lives at [cur_tab], not necessarily [1].
            if widget[1] and widget[1].tab_item_table then
                widget, path = widget[1], path .. "1/"
            end
            result.screen = widget.tab_item_table and "reader-menu" or "dialog"
            result.title = text(widget.title)
                or (widget.titlebar and text(widget.titlebar.title))
                or (widget.title_bar and text(widget.title_bar.title))
            result.message = text(widget.text)
            result.page, result.pages = widget.page, widget.page_num
            result.selected = widget.selected and {
                x = widget.selected.x, y = widget.selected.y,
            } or nil
            result.tab = widget.cur_tab
            if self.ui.document then
                -- Private identity used by the Python controller; never printed.
                result.document_file = self.ui.document.file
                result.document_page = self.ui:getCurrentPage()
                result.document_pages = self.ui.document:getPageCount()
                if widget == self.ui then result.screen = "reader" end
            end
            local layout, layout_path = widget.layout, path .. "layout/"
            if not layout and widget.button_table then
                layout, layout_path = widget.button_table.layout, path .. "button_table/layout/"
            end
            for row_index, row in ipairs(layout or {}) do
                local columns = {}
                for column in pairs(row) do
                    if type(column) == "number" then columns[#columns + 1] = column end
                end
                table.sort(columns)
                for _, column in ipairs(columns) do
                    local control = row[column]
                    local method = type(control.onTapSelectButton) == "function" and "onTapSelectButton"
                        or type(control.onTapSelect) == "function" and "onTapSelect"
                    if method and not control.hidden then
                        local label = text(control.text) or text(control.icon)
                        if not label and control.item then
                            label = text(require("ui/widget/menu").getMenuText(control.item))
                        end
                        if label then
                            local activate = layout_path .. row_index .. "/" .. column .. "/" .. method .. "/"
                            local item = {
                                label = label,
                                status = text(control.mandatory),
                                enabled = enabled(control),
                                -- Button feedback repaints its frame immediately.
                                ready = method ~= "onTapSelectButton"
                                    or (control[1] ~= nil and control[1].dimen ~= nil),
                                selected = widget.selected and widget.selected.x == column
                                    and widget.selected.y == row_index or false,
                                kind = widget.tab_item_table and row_index == 1 and "tab" or "control",
                                activate = activate,
                            }
                            result.controls[#result.controls + 1] = item
                            self._sandbox_controls[activate] = {
                                control = control, method = method, enabled = item.enabled and item.ready,
                            }
                        end
                    end
                end
            end
            return result
        end

        local original_request = Inspector.onRequest
        function Inspector:onRequest(data, request_id)
            local headers = 0
            local authorized = false
            for line in data:gmatch("[^\r\n]+") do
                local name, value = line:match("^([^:]+):%s*(.-)%s*$")
                if name and name:lower() == "authorization" then
                    headers = headers + 1
                    authorized = value == "Bearer " .. token
                end
            end
            local info = { request_id = request_id }
            if headers ~= 1 or not authorized then
                return self:sendResponse(info, 401, "text/plain", "Unauthorized")
            end
            local method, uri = data:match("^(%u+) ([^\r\n ]+) HTTP/%d%.%d")
            if method ~= "GET" then
                return self:sendResponse(info, 405, "text/plain", "Only GET supported")
            end
            -- Do not expose upstream's global-object browser, assignment syntax,
            -- static file traversal, arbitrary method calls, or arbitrary events.
            if uri == prefix .. "quit/" then
                if self.ui.document then
                    return self:sendResponse(info, 409, "text/plain", "Close the reader first")
                end
                UIManager:nextTick(function()
                    self.ui:onClose() -- normal FileManager save/flush/finalize
                    UIManager:quit() -- any remaining sandbox dialogs cannot keep it alive
                end)
                return self:sendResponse(info, 200, "application/json", "[true]")
            end
            if uri == prefix .. "observe/" or uri == "/koreader/device/screen/bb" then
                return original_request(self, data, request_id)
            end
            local owner, action
            if uri == "/koreader/ui/suwayomi/showHome/" and not self.ui.document then
                owner, action = self.ui.suwayomi, "showHome"
            elseif uri == "/koreader/ui/menu/onShowMenu/" and self.ui.document ~= nil then
                owner, action = self.ui.menu, "onShowMenu"
            else
                local previous = self._sandbox_controls and self._sandbox_controls[uri]
                if previous and previous.enabled then
                    self:observe()
                    local current = self._sandbox_controls[uri]
                    if current and current.enabled and current.control == previous.control
                            and current.method == previous.method then
                        owner, action = current.control, current.method
                    end
                end
            end
            if not owner then
                return self:sendResponse(info, 403, "text/plain", "Not an available sandbox control")
            end
            -- Like upstream events, acknowledge before a callback can close this
            -- inspector during a FileManager/ReaderUI transition.
            UIManager:nextTick(function() owner[action](owner) end)
            return self:sendResponse(info, 200, "application/json", "[true]")
        end

        function Inspector:start()
            if self:isRunning() then return end
            local server = Server:new{
                host = "127.0.0.1", port = port,
                receiveCallback = function(data, id) return self:onRequest(data, id) end,
            }
            -- Upstream waitEvent logs complete headers at debug level. Keep the
            -- same bounded HTTP transport without ever logging the bearer token.
            function server:waitEvent()
                local client = self.server:accept()
                if not client then return end
                client:settimeout(0.1, "t")
                local lines, size = {}, 0
                while true do
                    local line = client:receive("*l")
                    if not line then client:close(); return end
                    size = size + #line + 2
                    if size > 8192 then client:close(); return end
                    lines[#lines + 1] = line
                    if line == "" then
                        client:settimeout(0.5, "t")
                        return self.receiveCallback(table.concat(lines, "\r\n"), client)
                    end
                end
            end
            assert(server:start(), "Sandbox inspector failed to listen")
            self.http_socket = server
            self.http_messagequeue = UIManager:insertZMQ(server)
        end
        Inspector.sandbox_secured = true
    end
    -- Plugin patches run after init, including every reader/FileManager switch.
    local instance = assert(PluginLoader.loaded_plugins.httpinspector)
    UIManager:nextTick(function() instance:start() end)
end)
