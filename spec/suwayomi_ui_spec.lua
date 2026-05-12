package.path = "?.lua;" .. package.path

describe("suwayomi/ui", function()
    local shown_dialog
    local closed_dialog
    local events

    before_each(function()
        shown_dialog = nil
        closed_dialog = nil
        events = {}

        package.loaded["suwayomi/ui"] = nil
        package.loaded["suwayomi/ui/browse"] = nil
        package.loaded["suwayomi/ui/directory"] = nil
        package.loaded["suwayomi/ui/downloads"] = nil
        package.loaded["suwayomi/ui/list_menu"] = nil
        package.loaded["suwayomi/ui/menu_utils"] = nil
        package.loaded.gettext = nil
        package.loaded["ui/widget/menu"] = nil
        package.loaded["ui/widget/buttondialog"] = nil
        package.loaded["ui/widget/confirmbox"] = nil
        package.loaded["ui/widget/multiinputdialog"] = nil
        package.loaded["ui/widget/titlebar"] = nil
        package.loaded["ui/widget/checkmark"] = nil
        package.loaded["ui/widget/radiomark"] = nil
        package.loaded["ui/widget/pathchooser"] = nil
        package.loaded["ui/uimanager"] = nil
        package.loaded["suwayomi/ui/manga_menu"] = nil

        package.preload.gettext = function()
            return function(text)
                return text
            end
        end

        package.preload["ui/widget/menu"] = function()
            return {
                new = function(_, options)
                    return options
                end,
            }
        end

        package.preload["ui/widget/buttondialog"] = function()
            return {
                new = function(_, options)
                    return options
                end,
            }
        end

        package.preload["ui/widget/confirmbox"] = function()
            return {
                new = function(_, options)
                    return options
                end,
            }
        end

        package.preload["ui/widget/multiinputdialog"] = function()
            return {
                new = function(_, options)
                    options.getFields = function()
                        return {
                            "https://suwayomi.example",
                            "alice",
                            "secret",
                        }
                    end
                    options.onShowKeyboard = function() end
                    return options
                end,
            }
        end

        package.preload["ui/widget/titlebar"] = function()
            return {
                new = function(_, options)
                    return options
                end,
            }
        end

        package.preload["ui/widget/checkmark"] = function()
            return {
                new = function(_, options)
                    return {
                        mark_type = "check",
                        checked = options.checked,
                        dimen = { w = 20 },
                        getSize = function(self)
                            return self.dimen
                        end,
                    }
                end,
            }
        end

        package.preload["ui/widget/radiomark"] = function()
            return {
                new = function(_, options)
                    return {
                        mark_type = "radio",
                        checked = options.checked,
                        dimen = { w = 20 },
                        getSize = function(self)
                            return self.dimen
                        end,
                    }
                end,
            }
        end

        package.preload["ui/widget/pathchooser"] = function()
            local PathChooser = {}

            function PathChooser:extend(definition)
                definition.__index = definition
                return setmetatable(definition, { __index = self })
            end

            function PathChooser:new(options)
                options = options or {}
                setmetatable(options, self)
                return options
            end

            function PathChooser:genItemTable(_, _, path)
                return {
                    {
                        text = "Long-press here to choose current folder",
                        path = path .. "/.",
                    },
                }
            end

            function PathChooser:onMenuSelect(item)
                self.selected_path = item.path
                return true
            end

            function PathChooser:onMenuHold(item)
                self.held_path = item.path
                if self.onConfirm then
                    self.onConfirm((item.path:gsub("/%.$", "")))
                end
                return true
            end

            return PathChooser
        end

        package.preload["ui/uimanager"] = function()
            return {
                show = function(_, widget)
                    shown_dialog = widget
                end,
                close = function(_, widget)
                    closed_dialog = widget
                    table.insert(events, "close")
                end,
            }
        end

        package.preload["suwayomi/ui/list_menu"] = function()
            return {
                show = function(options)
                    options.renderer = "list_menu"
                    options.is_borderless = true
                    options.is_popout = false
                    options.title_bar_fm_style = true
                    options.items_max_lines = 3
                    options.multilines_show_more_text = true
                    shown_dialog = options
                    return options
                end,
                update = function(menu, options)
                    menu.renderer = "list_menu"
                    menu.item_table = options.item_table
                    menu.title = options.title or menu.title
                    menu.updated_options = options
                    if menu.title_bar and menu.title_bar.setTitle and options.title then
                        menu.title_bar:setTitle(options.title, true)
                    end
                    if menu.setTitleBarLeftIcon then
                        menu:setTitleBarLeftIcon(options.title_bar_left_icon)
                    end
                    if menu.updateItems then
                        menu:updateItems(nil, true)
                    end
                end,
            }
        end
    end)

    after_each(function()
        package.preload.gettext = nil
        package.preload["ui/widget/menu"] = nil
        package.preload["ui/widget/buttondialog"] = nil
        package.preload["ui/widget/confirmbox"] = nil
        package.preload["ui/widget/multiinputdialog"] = nil
        package.preload["ui/widget/titlebar"] = nil
        package.preload["ui/widget/checkmark"] = nil
        package.preload["ui/widget/radiomark"] = nil
        package.preload["ui/widget/pathchooser"] = nil
        package.preload["ui/uimanager"] = nil
        package.preload["suwayomi/ui/list_menu"] = nil
        package.preload["suwayomi/ui/manga_menu"] = nil
    end)

    local function assertFileManagerListStyle(menu)
        assert.is_true(menu.is_borderless)
        assert.is_false(menu.is_popout)
        assert.is_true(menu.title_bar_fm_style)
        assert.are.equal(3, menu.items_max_lines)
        assert.is_true(menu.multilines_show_more_text)
        assert.is_nil(menu.items_mandatory_font_size)
    end

    it("preserves facade access to browse menus", function()
        local ui = require("suwayomi/ui")
        local selected

        ui.showMangaMenu({
            { id = "m1", title = "One Piece" },
        }, function(manga)
            selected = manga
        end)

        assert.are.equal("Suwayomi Manga", shown_dialog.title)
        assert.are.equal("list_menu", shown_dialog.renderer)
        assert.are.equal("One Piece", shown_dialog.item_table[1].text)
        assert.is_nil(shown_dialog.item_table[1].mandatory)

        shown_dialog.item_table[1].callback()

        assert.are.same({ id = "m1", title = "One Piece" }, selected)
    end)

    it("preserves facade access to downloads menus", function()
        local ui = require("suwayomi/ui")
        local retried_key

        ui.showDownloadsMenu({
            failed = {
                {
                    key = "m-failed:205",
                    manga = { title = "Chainsaw Man" },
                    chapter = { name = "Ch. 205" },
                },
            },
        }, {
            onRetryFailed = function(job)
                retried_key = job.key
            end,
        })

        assert.are.equal("Suwayomi Downloads", shown_dialog.title)
        assert.are.equal("list_menu", shown_dialog.renderer)
        assert.are.equal("Chainsaw Man / Ch. 205", shown_dialog.item_table[1].text)
        assert.are.equal("Failed", shown_dialog.item_table[1].mandatory)

        shown_dialog.item_table[1].callback()

        assert.are.equal("m-failed:205", retried_key)
    end)

    it("preserves facade access to the directory chooser", function()
        local ui = require("suwayomi/ui")
        local chosen_path

        ui.showDirectoryChooser(function(path)
            chosen_path = path
        end, "/storage/emulated/0/Books/Manga")

        assert.are.equal("Choose download directory", shown_dialog.title)
        assert.is_true(shown_dialog.select_directory)

        local item_table = shown_dialog:genItemTable({}, {}, "/storage/emulated/0/Books/Manga")
        shown_dialog:onMenuSelect(item_table[1])

        assert.are.equal("/storage/emulated/0/Books/Manga", chosen_path)
    end)

    it("closes the dialog before running the save callback", function()
        local ui = require("suwayomi/ui")

        ui.showLoginDialog({
            onSave = function(credentials)
                table.insert(events, "save")
                assert.are.equal("https://suwayomi.example", credentials.server_url)
                assert.are.equal("alice", credentials.username)
                assert.are.equal("secret", credentials.password)
                assert.are.equal("basic_auth", credentials.auth_method)
            end,
        })

        shown_dialog.buttons[1][2].callback()

        assert.are.same({"close", "save"}, events)
        assert.are.equal(shown_dialog, closed_dialog)
    end)

    it("shows a chapter menu", function()
        local ui = require("suwayomi/ui")
        local selected = {}
        local held = {}

        ui.showChapterMenu({
            title = "Sousou no Frieren",
            chapters = {
                { id = "c1", name = "Chapter 1", menu_text = "Chapter 1", menu_status = "Read · Downloaded" },
                { id = "c2", name = "Chapter 2" },
            },
        }, function(chapter)
            table.insert(selected, chapter)
        end, function(chapter)
            table.insert(held, chapter)
        end)

        assert.are.equal("Sousou no Frieren", shown_dialog.title)
        assertFileManagerListStyle(shown_dialog)
        assert.are.equal("Chapter 1", shown_dialog.item_table[1].text)
        assert.are.equal("Read · Downloaded", shown_dialog.item_table[1].mandatory)
        assert.are.equal("Chapter 2", shown_dialog.item_table[2].text)
        assert.is_nil(shown_dialog.item_table[2].mandatory)

        shown_dialog.item_table[1].callback()
        shown_dialog.item_table[2].callback()
        shown_dialog:onMenuHold(shown_dialog.item_table[1])

        assert.are.same({
            { id = "c1", name = "Chapter 1", menu_text = "Chapter 1", menu_status = "Read · Downloaded" },
            { id = "c2", name = "Chapter 2" },
        }, selected)
        assert.are.same({
            { id = "c1", name = "Chapter 1", menu_text = "Chapter 1", menu_status = "Read · Downloaded" },
        }, held)
    end)

    it("uses KOReader native file-manager title-bar style for chapter bulk actions", function()
        local ui = require("suwayomi/ui")
        local tapped = false

        ui.showChapterMenu({
            title = "Sousou no Frieren",
            title_bar_left_icon = "appbar.menu",
            on_title_bar_left_tap = function()
                tapped = true
                return true
            end,
            chapters = {
                { id = "c1", name = "Chapter 1" },
            },
        })

        assert.is_nil(shown_dialog.custom_title_bar)
        assert.are.equal("appbar.menu", shown_dialog.title_bar_left_icon)
        assertFileManagerListStyle(shown_dialog)

        shown_dialog.onLeftButtonTap()

        assert.is_true(tapped)
    end)

    it("keeps chapter menus current when selecting a row", function()
        local ui = require("suwayomi/ui")
        local selected
        local closed = false

        ui.showChapterMenu({
            title = "Sousou no Frieren",
            chapters = {
                { id = "c1", name = "Chapter 1" },
            },
            close_callback = function()
                closed = true
            end,
        }, function(chapter)
            selected = chapter
        end)

        shown_dialog:onMenuSelect(shown_dialog.item_table[1])

        assert.are.same({ id = "c1", name = "Chapter 1" }, selected)
        assert.is_false(closed)
    end)

    it("shows a generic action menu", function()
        local ui = require("suwayomi/ui")
        local selected = {}
        local closed = false

        ui.showActionMenu({
            title = "Title actions",
            actions = {
                { id = "home", text = "Suwayomi home" },
                { id = "refresh", text = "Refresh" },
                { id = "cancel", text = "Cancel search" },
            },
            close_callback = function()
                closed = true
            end,
        }, function(action)
            table.insert(selected, action)
        end)

        assert.are.equal("Title actions", shown_dialog.title)
        assert.are.equal("Suwayomi home", shown_dialog.buttons[1][1].text)
        assert.are.equal("Refresh", shown_dialog.buttons[1][2].text)
        assert.are.equal("Cancel search", shown_dialog.buttons[2][1].text)

        shown_dialog.buttons[1][1].callback()
        shown_dialog.buttons[2][1].callback()

        assert.are.same({
            { id = "home", text = "Suwayomi home" },
            { id = "cancel", text = "Cancel search" },
        }, selected)

        shown_dialog.close_callback()

        assert.is_true(closed)
    end)

    it("marks submenu action buttons without changing the selected action", function()
        local ui = require("suwayomi/ui")
        local selected

        ui.showActionMenu({
            title = "Title actions",
            actions = {
                { id = "select_all", text = "Select all" },
                { id = "bulk_downloads", text = "Bulk downloads", submenu = true },
            },
        }, function(action)
            selected = action
        end)

        assert.are.equal("Select all", shown_dialog.buttons[1][1].text)
        assert.are.equal("Bulk downloads >", shown_dialog.buttons[1][2].text)

        shown_dialog.buttons[1][2].callback()

        assert.are.equal("bulk_downloads", selected.id)
        assert.are.equal("Bulk downloads", selected.text)
        assert.is_true(selected.submenu)
    end)

    it("adds a shared back action for nested action menus", function()
        local ui = require("suwayomi/ui")
        local selected

        ui.showActionMenu({
            title = "Bulk downloads",
            actions = {
                { id = "download_next_5_unread", text = "Download 5 unread" },
            },
            on_back = function()
                table.insert(events, "back")
            end,
        }, function(action)
            selected = action
        end)

        assert.are.equal("< Back", shown_dialog.buttons[1][1].text)
        assert.are.same({}, shown_dialog.buttons[2])
        assert.are.equal("Download 5 unread", shown_dialog.buttons[3][1].text)

        shown_dialog.buttons[1][1].callback()

        assert.are.same({ "close", "back" }, events)
        assert.are.equal(shown_dialog, closed_dialog)
        assert.is_nil(selected)
    end)

    it("passes action menu anchors through to ButtonDialog", function()
        local ui = require("suwayomi/ui")
        local anchor = function()
            return { x = 8, y = 12, w = 40, h = 40 }
        end

        ui.showActionMenu({
            title = "Title actions",
            actions = {
                { id = "home", text = "Suwayomi home" },
            },
            anchor = anchor,
        })

        assert.are.equal(anchor, shown_dialog.anchor)
    end)

    it("shows a chapter actions menu through the generic action renderer", function()
        local ui = require("suwayomi/ui")

        ui.showChapterActionsMenu({
            actions = {
                { id = "open", text = "Open" },
            },
        })

        assert.are.equal("Chapter actions", shown_dialog.title)
        assert.are.equal("Open", shown_dialog.buttons[1][1].text)
    end)

    it("shows manga and chapter actions as vertical menus with destructive actions separated", function()
        local ui = require("suwayomi/ui")

        ui.showChapterActionsMenu({
            actions = {
                { id = "open", text = "Open" },
                { id = "mark_read", text = "Mark as read" },
                { id = "delete", text = "Delete from device", destructive = true },
            },
        })

        assert.are.equal("Open", shown_dialog.buttons[1][1].text)
        assert.are.equal("Mark as read", shown_dialog.buttons[2][1].text)
        assert.are.same({}, shown_dialog.buttons[3])
        assert.are.equal("Delete from device", shown_dialog.buttons[4][1].text)
        assert.is_true(shown_dialog.buttons[4][1].destructive)

        ui.showMangaActionsMenu({
            actions = {
                { id = "open_chapters", text = "Open chapters" },
                { id = "more", text = "More...", submenu = true },
                { id = "remove_from_library", text = "Remove from library", destructive = true },
            },
        })

        assert.are.equal("Open chapters", shown_dialog.buttons[1][1].text)
        assert.are.equal("More... >", shown_dialog.buttons[2][1].text)
        assert.are.same({}, shown_dialog.buttons[3])
        assert.are.equal("Remove from library", shown_dialog.buttons[4][1].text)
        assert.is_true(shown_dialog.buttons[4][1].destructive)
    end)

    it("refreshes chapter menus with a dimension recalculation for changed row statuses", function()
        local ui = require("suwayomi/ui")
        local updated = false
        local menu = {
            title = "Old chapters",
            updateItems = function()
                updated = true
            end,
        }

        ui.updateChapterMenu(menu, {
            title = "New chapters",
            chapters = {
                { id = "c1", name = "Chapter 1", menu_status = "Queued" },
            },
        })

        assert.are.equal("list_menu", menu.renderer)
        assert.are.equal("New chapters", menu.title)
        assert.are.equal("Queued", menu.item_table[1].mandatory)
        assert.is_true(updated)
    end)

    it("shows the Suwayomi home hub as two-column buttons", function()
        local ui = require("suwayomi/ui")
        local selected = {}

        ui.showHomeDialog({
            actions = {
                { id = "library", text = "Library" },
                { id = "browse", text = "Browse" },
                { id = "downloads", text = "Downloads" },
            },
            onClose = function()
                table.insert(events, "home-close")
            end,
        }, function(action)
            table.insert(selected, action.id)
            table.insert(events, action.id)
        end)

        assert.are.equal("Suwayomi", shown_dialog.title)
        assert.are.equal("Library", shown_dialog.buttons[1][1].text)
        assert.are.equal("Browse", shown_dialog.buttons[1][2].text)
        assert.are.equal("Downloads", shown_dialog.buttons[2][1].text)

        shown_dialog.buttons[1][2].callback()

        assert.are.same({ "close", "home-close", "browse" }, events)
        assert.are.equal(shown_dialog, closed_dialog)
        assert.are.same({ "browse" }, selected)
    end)

    it("passes menu close callbacks through chapter menus", function()
        local ui = require("suwayomi/ui")
        local closed = false

        ui.showChapterMenu({
            title = "Chapters",
            chapters = {
                { id = "c1", name = "Chapter 1" },
            },
            close_callback = function()
                closed = true
            end,
        })

        shown_dialog.close_callback()

        assert.is_true(closed)
    end)

    it("passes the native settings menu instance to setting callbacks", function()
        local ui = require("suwayomi/ui")
        local callback_menu

        ui.showSettingsMenu({
            {
                text = "Connection",
                sub_item_table = {
                    {
                        text = "Login information",
                        callback = function(menu)
                            callback_menu = menu
                        end,
                    },
                },
            },
        })

        shown_dialog.item_table[1].sub_item_table[1].callback()

        assert.are.equal(shown_dialog, callback_menu)
    end)

    it("shows a confirmation dialog", function()
        local ui = require("suwayomi/ui")
        local confirmed = false

        ui.showConfirm({
            text = "Queue 50 unread chapter downloads?",
            ok_text = "Queue",
            ok_callback = function()
                confirmed = true
            end,
        })

        assert.are.equal("Queue 50 unread chapter downloads?", shown_dialog.text)
        assert.are.equal("Queue", shown_dialog.ok_text)

        shown_dialog.ok_callback()

        assert.is_true(confirmed)
    end)

    it("shows a parallel chapter downloads menu", function()
        local ui = require("suwayomi/ui")
        local selected

        ui.showParallelDownloadsMenu({
            current = 2,
            choices = { 1, 2, 3 },
            onSelect = function(value)
                selected = value
            end,
        })

        assert.are.equal("Parallel chapter downloads", shown_dialog.title)
        assert.are.equal(32, shown_dialog.state_w)
        assert.are.equal("1", shown_dialog.item_table[1].text)
        assert.is_true(shown_dialog.item_table[1].radio)
        assert.is_false(shown_dialog.item_table[1].checked_func())
        assert.are.equal("2", shown_dialog.item_table[2].text)
        assert.is_true(shown_dialog.item_table[2].checked_func())
        assert.is_true(shown_dialog.item_table[2].state.checked)

        shown_dialog.item_table[3].callback()

        assert.are.equal(3, selected)
    end)

    it("closes the language menu from Done before running the close callback", function()
        local ui = require("suwayomi/ui")

        ui.showLanguageMenu({
            title = "Source languages",
            languages = {
                { code = "en", label = "English", enabled = true },
                { code = "ru", label = "Russian", enabled = false },
            },
            onClose = function()
                table.insert(events, "summary")
            end,
        })

        assert.are.equal("Source languages", shown_dialog.title)
        assert.are.equal(32, shown_dialog.state_w)
        assert.are.equal("check", shown_dialog.item_table[1].state.mark_type)
        assert.is_true(shown_dialog.item_table[1].state.checked)
        assert.is_false(shown_dialog.item_table[2].state.checked)

        shown_dialog.item_table[3].callback()

        assert.are.same({ "close", "summary" }, events)
        assert.are.equal(shown_dialog, closed_dialog)
    end)

    it("can show a language menu without a Done row", function()
        local ui = require("suwayomi/ui")

        ui.showLanguageMenu({
            title = "Source languages",
            show_done = false,
            languages = {
                { code = "en", label = "English", enabled = true },
                { code = "es", label = "Español", enabled = false },
            },
        })

        assert.are.equal(2, #shown_dialog.item_table)
        assert.are.equal("English", shown_dialog.item_table[1].text)
        assert.are.equal("Español", shown_dialog.item_table[2].text)
    end)

    it("does not run the language close callback during an in-place menu refresh", function()
        local ui = require("suwayomi/ui")
        local summary_count = 0
        local menu = {
            close_callback = function()
                summary_count = summary_count + 10
            end,
            updateItems = function(self)
                if self.close_callback then
                    self.close_callback()
                end
            end,
        }

        ui.updateLanguageMenu(menu, {
            languages = {
                { code = "en", label = "EN", enabled = true },
                { code = "ru", label = "RU", enabled = true },
            },
            onClose = function()
                summary_count = summary_count + 1
            end,
        }, function() end)

        assert.are.equal(0, summary_count)

        menu.close_callback()

        assert.are.equal(1, summary_count)
    end)
end)
