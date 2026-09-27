package.path = "?.lua;" .. package.path

describe("Suwayomi native finish adapter", function()
    local plugin, reader, status, manager, settings, info, adapter, native_next, native_finish
    local marked, opened, delegated, repaint, original_settings, reader_module
    local names = { "suwayomi/reader_finish", "ui/uimanager", "ui/widget/infomessage",
        "apps/reader/readerui", "gettext", "suwayomi/i18n" }
    local function translate(text) return "translated:" .. text end
    local function popup()
        local dialog = { name = "end_document", layout = { "old buttons" }, reinit = function(self)
            assert.is_nil(self.layout)
            self.layout = { "rebuilt buttons" }
            repaint = repaint + 1
        end }
        local function button(text) return { text = translate(text), callback = function() end } end
        dialog.buttons = {
            { { text_func = function() end, callback = function() end }, button("Book status") },
            { button("Go to beginning"), button("Open next file") },
            { button("Delete file"), button("File browser") },
        }
        dialog.buttons[2][2].enabled = settings.collate ~= "access" and settings.collate ~= "date"
        dialog.buttons[2][2].callback = function()
            manager:close(dialog)
            status:onOpenNextOrPreviousFileInFolder()
        end
        return dialog
    end
    before_each(function()
        for _, name in ipairs(names) do package.loaded[name] = nil end
        marked, opened, delegated, repaint = 0, 0, 0, 0
        settings = { end_document_action = "pop-up", collate = "strcoll" }
        original_settings = _G.G_reader_settings
        _G.G_reader_settings = { readSetting = function(_, key) return settings[key] end }
        manager = { _window_stack = {} }
        function manager:show(widget) table.insert(self._window_stack, { widget = widget }) end
        function manager:close(widget)
            for i, window in ipairs(self._window_stack) do
                if window.widget == widget then table.remove(self._window_stack, i) break end
            end
        end
        function manager:getTopmostVisibleWidget()
            local window = self._window_stack[#self._window_stack]
            return window and window.widget
        end
        function manager:setDirty() end
        info = {}
        reader = { document = { file = "current.cbz" } }
        reader_module = { instance = reader }
        native_next = function(_, prev) delegated = delegated + 1 return prev or "native" end
        native_finish = function()
            if settings.end_document_auto_mark then marked = marked + 1 end
            if settings.end_document_action == "next_file" then
                if settings.collate == "access" or settings.collate == "date" then
                    manager:show(setmetatable({ text = translate(
                        "Could not open next file. Sort by date does not support this feature.") }, info))
                else
                    status:onOpenNextOrPreviousFileInFolder()
                end
            elseif settings.end_document_action == "pop-up" then
                local top = manager:getTopmostVisibleWidget()
                if not top or top.name ~= "end_document" then manager:show(popup()) end
            end
            return "native-result"
        end
        status = { onEndOfBook = native_finish, onOpenNextOrPreviousFileInFolder = native_next }
        reader.status = status
        package.loaded["ui/uimanager"] = manager
        package.loaded["ui/widget/infomessage"] = info
        package.loaded["apps/reader/readerui"] = reader_module
        package.loaded.gettext = translate
        package.loaded["suwayomi/i18n"] = { t = translate }
        adapter = require("suwayomi/reader_finish")
        plugin = { ui = reader, getReaderReturnContextForPath = function(_, path, exact)
            assert.equals(reader.document.file, path)
            assert.is_true(exact)
            return { chapter_id = "1" }
        end,
            openNextChapter = function() opened = opened + 1 end }
        for name, method in pairs(adapter.methods) do plugin[name] = method end
        plugin:installReaderFinishAdapter()
    end)
    after_each(function()
        _G.G_reader_settings = original_settings
        for _, name in ipairs(names) do package.loaded[name] = nil end
    end)

    for _, sort in ipairs({ "strcoll", "access", "date" }) do
        for _, automatic in ipairs({ false, true }) do
            for _, auto_mark in ipairs({ false, true }) do
                it("preserves native marking: " .. sort .. "/" .. tostring(automatic) .. "/" .. tostring(auto_mark), function()
                    settings.collate = sort
                    settings.end_document_action = automatic and "next_file" or "pop-up"
                    settings.end_document_auto_mark = auto_mark
                    assert.equals("native-result", status:onEndOfBook())
                    assert.equals(auto_mark and 1 or 0, marked)
                    if not automatic then
                        local dialog = manager:getTopmostVisibleWidget()
                        assert.equals(translate("Next chapter"), dialog.buttons[2][2].text)
                        assert.is_true(dialog.buttons[2][2].enabled)
                        assert.equals(1, repaint)
                        dialog.buttons[2][2].callback()
                    end
                    assert.equals(1, opened)
                    assert.equals(0, delegated)
                    assert.equals(sort, settings.collate)
                    assert.equals(0, #manager._window_stack)
                end)
            end
        end
    end
    it("delegates previous navigation and unrelated documents", function()
        assert.is_true(status:onOpenNextOrPreviousFileInFolder(true))
        plugin.getReaderReturnContextForPath = function() end
        assert.equals("native", status:onOpenNextOrPreviousFileInFolder())
        status:onEndOfBook()
        assert.equals(translate("Open next file"), manager:getTopmostVisibleWidget().buttons[2][2].text)
        assert.equals(2, delegated)
        assert.equals(0, opened)
    end)
    it("never scans folders for recognized but blocked chapters", function()
        plugin.openNextChapter = function() return false end
        assert.is_true(status:onOpenNextOrPreviousFileInFolder())
        assert.equals(0, delegated)
    end)
    it("does not rebuild or duplicate an existing finish dialog", function()
        status:onEndOfBook()
        local dialog = manager:getTopmostVisibleWidget()
        status:onEndOfBook()
        assert.equals(dialog, manager:getTopmostVisibleWidget())
        assert.equals(1, repaint)
    end)
    it("suppresses duplicate finish requests during verification", function()
        plugin.next_chapter_pending = function() return true end
        status:onEndOfBook()
        status:onOpenNextOrPreviousFileInFolder()
        assert.equals(0, opened)
        assert.equals(0, #manager._window_stack)
    end)
    it("leaves other finish preferences with native status", function()
        settings.end_document_action = "mark_read"
        settings.end_document_auto_mark = true
        status:onEndOfBook()
        assert.equals(1, marked)
        assert.equals(0, opened)
    end)
    it("rejects reader replacement and retained stale wrappers", function()
        local stale = status.onOpenNextOrPreviousFileInFolder
        reader_module.instance = { document = reader.document }
        stale(status)
        assert.equals(0, opened)
        assert.equals(0, delegated)
        plugin:removeReaderFinishAdapter()
        assert.equals(native_next, status.onOpenNextOrPreviousFileInFolder)
        assert.equals(native_finish, status.onEndOfBook)
        stale(status)
        assert.equals(0, opened)
    end)
    it("installs once and does not overwrite later wrappers on removal", function()
        local first = status.onEndOfBook
        plugin:installReaderFinishAdapter()
        assert.equals(first, status.onEndOfBook)
        local later = function() end
        status.onEndOfBook = later
        plugin:removeReaderFinishAdapter()
        assert.equals(later, status.onEndOfBook)
        assert.equals(native_next, status.onOpenNextOrPreviousFileInFolder)
    end)
    it("leaves unexpected popup structure untouched", function()
        plugin:removeReaderFinishAdapter()
        status.onEndOfBook = function()
            local dialog = popup()
            dialog.buttons[3] = nil
            manager:show(dialog)
        end
        plugin:installReaderFinishAdapter()
        status:onEndOfBook()
        assert.equals(0, repaint)
        assert.equals(translate("Open next file"), manager:getTopmostVisibleWidget().buttons[2][2].text)
    end)
    it("does not remove an unexpected automatic-route dialog", function()
        plugin:removeReaderFinishAdapter()
        local other = setmetatable({ text = "different message" }, info)
        status.onEndOfBook = function() manager:show(other) end
        plugin:installReaderFinishAdapter()
        settings.end_document_action, settings.collate = "next_file", "date"
        status:onEndOfBook()
        assert.equals(other, manager:getTopmostVisibleWidget())
        assert.equals(0, opened)
    end)
    it("removes only the new sort notice underneath an existing toast", function()
        local toast = { toast = true }
        manager:show(toast)
        function manager:show(widget) table.insert(self._window_stack, 1, { widget = widget }) end
        settings.end_document_action, settings.collate = "next_file", "access"
        status:onEndOfBook()
        assert.equals(1, opened)
        assert.equals(toast, manager:getTopmostVisibleWidget())
        assert.equals(1, #manager._window_stack)
    end)
    it("advances when native silent mode suppresses the sort notice", function()
        manager.silent_mode, info.honor_silent_mode = true, true
        function manager:show() end
        settings.end_document_action, settings.collate = "next_file", "date"
        status:onEndOfBook()
        assert.equals(1, opened)
    end)
    it("rejects document replacement during the native finish call", function()
        plugin:removeReaderFinishAdapter()
        status.onEndOfBook = function()
            native_finish()
            reader.document = { file = "replacement.cbz" }
        end
        plugin:installReaderFinishAdapter()
        settings.end_document_action, settings.collate = "next_file", "date"
        status:onEndOfBook()
        assert.equals(0, opened)
        assert.equals(1, #manager._window_stack)
    end)
    it("installs a fresh adapter on a reopened reader", function()
        plugin:removeReaderFinishAdapter()
        reader = { document = { file = "reopened.cbz" }, status = {
            onEndOfBook = native_finish, onOpenNextOrPreviousFileInFolder = native_next } }
        reader_module.instance, plugin.ui = reader, reader
        plugin:installReaderFinishAdapter()
        reader.status:onOpenNextOrPreviousFileInFolder()
        assert.equals(1, opened)
        assert.equals(0, delegated)
    end)
end)
