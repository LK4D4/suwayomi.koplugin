package.path = "?.lua;" .. package.path

describe("suwayomi_ui", function()
    local shown_dialog
    local closed_dialog
    local events

    before_each(function()
        shown_dialog = nil
        closed_dialog = nil
        events = {}

        package.loaded.suwayomi_ui = nil
        package.loaded.gettext = nil
        package.loaded["ui/widget/menu"] = nil
        package.loaded["ui/widget/buttondialog"] = nil
        package.loaded["ui/widget/confirmbox"] = nil
        package.loaded["ui/widget/multiinputdialog"] = nil
        package.loaded["ui/widget/checkmark"] = nil
        package.loaded["ui/widget/radiomark"] = nil
        package.loaded["ui/widget/pathchooser"] = nil
        package.loaded["ui/downloadmgr"] = nil
        package.loaded["ui/uimanager"] = nil

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
                return setmetatable(definition, {
                    __index = self,
                    __call = function(class, instance)
                        instance = instance or {}
                        setmetatable(instance, class)
                        if instance.init then
                            instance:init()
                        end
                        return instance
                    end,
                })
            end

            function PathChooser:new(options)
                options = options or {}
                setmetatable(options, self)
                if options.init then
                    options:init()
                end
                return options
            end

            function PathChooser:init()
                if self.select_directory then
                    self.show_current_dir_for_hold = true
                end
            end

            function PathChooser:genItemTable(_, _, path)
                return {
                    {
                        text = "Long-press here to choose current folder",
                        bold = true,
                        path = path .. "/.",
                    },
                    {
                        text = "Sousou no Frieren/",
                        path = path .. "/Sousou no Frieren",
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

        package.preload["ui/downloadmgr"] = function()
            return {
                new = function(_, options)
                    return {
                        chooseDir = function()
                            chooser_start_dir = nil
                            shown_dialog = options
                        end,
                    }
                end,
            }
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
    end)

    after_each(function()
        package.preload.gettext = nil
        package.preload["ui/widget/menu"] = nil
        package.preload["ui/widget/buttondialog"] = nil
        package.preload["ui/widget/confirmbox"] = nil
        package.preload["ui/widget/multiinputdialog"] = nil
        package.preload["ui/widget/checkmark"] = nil
        package.preload["ui/widget/radiomark"] = nil
        package.preload["ui/widget/pathchooser"] = nil
        package.preload["ui/downloadmgr"] = nil
        package.preload["ui/uimanager"] = nil
    end)

    it("closes the dialog before running the save callback", function()
        local ui = require("suwayomi_ui")

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

    it("shows a manga menu", function()
        local ui = require("suwayomi_ui")
        local selected = {}

        ui.showMangaMenu({
            { id = "m1", title = "One Piece" },
            { id = "m2", title = "Frieren" },
        }, function(manga)
            table.insert(selected, manga)
        end)

        assert.are.equal("Suwayomi Manga", shown_dialog.title)
        assert.are.equal("One Piece", shown_dialog.item_table[1].text)
        assert.are.equal("Frieren", shown_dialog.item_table[2].text)

        shown_dialog.item_table[1].callback()
        shown_dialog.item_table[2].callback()

        assert.are.same({
            { id = "m1", title = "One Piece" },
            { id = "m2", title = "Frieren" },
        }, selected)
    end)

    it("shows a chapter menu", function()
        local ui = require("suwayomi_ui")
        local selected = {}
        local held = {}

        ui.showChapterMenu({
            title = "Sousou no Frieren",
            chapters = {
                { id = "c1", name = "Chapter 1", menu_text = "Chapter 1", menu_status = "✓↓" },
                { id = "c2", name = "Chapter 2" },
            },
        }, function(chapter)
            table.insert(selected, chapter)
        end, function(chapter)
            table.insert(held, chapter)
        end)

        assert.are.equal("Sousou no Frieren", shown_dialog.title)
        assert.are.equal("Chapter 1", shown_dialog.item_table[1].text)
        assert.are.equal("✓↓", shown_dialog.item_table[1].mandatory)
        assert.are.equal("Chapter 2", shown_dialog.item_table[2].text)
        assert.is_nil(shown_dialog.item_table[2].mandatory)

        shown_dialog.item_table[1].callback()
        shown_dialog.item_table[2].callback()
        shown_dialog:onMenuHold(shown_dialog.item_table[1])

        assert.are.same({
            { id = "c1", name = "Chapter 1", menu_text = "Chapter 1", menu_status = "✓↓" },
            { id = "c2", name = "Chapter 2" },
        }, selected)
        assert.are.same({
            { id = "c1", name = "Chapter 1", menu_text = "Chapter 1", menu_status = "✓↓" },
        }, held)
    end)

    it("shows a chapter actions menu", function()
        local ui = require("suwayomi_ui")
        local selected = {}

        ui.showChapterActionsMenu({
            title = "Chapter 1",
            actions = {
                { id = "open", text = "Open" },
                { id = "delete", text = "Delete from device" },
                { id = "mark_read", text = "Mark as read" },
            },
        }, function(action)
            table.insert(selected, action)
        end)

        assert.are.equal("Chapter 1", shown_dialog.title)
        assert.are.equal("Open", shown_dialog.buttons[1][1].text)
        assert.are.equal("Delete from device", shown_dialog.buttons[1][2].text)
        assert.are.equal("Mark as read", shown_dialog.buttons[2][1].text)

        shown_dialog.buttons[1][1].callback()
        shown_dialog.buttons[2][1].callback()

        assert.are.same({
            { id = "open", text = "Open" },
            { id = "mark_read", text = "Mark as read" },
        }, selected)
    end)

    it("closes the chapter actions dialog before running the action callback", function()
        local ui = require("suwayomi_ui")
        local selected

        ui.showChapterActionsMenu({
            title = "Chapter 1",
            actions = {
                { id = "open", text = "Open" },
            },
        }, function(action)
            selected = action
            table.insert(events, "action")
        end)

        shown_dialog.buttons[1][1].callback()

        assert.are.same({ "close", "action" }, events)
        assert.are.equal(shown_dialog, closed_dialog)
        assert.are.same({ id = "open", text = "Open" }, selected)
    end)

    it("shows the Suwayomi home hub as two-column buttons", function()
        local ui = require("suwayomi_ui")
        local selected = {}

        ui.showHomeDialog({
            actions = {
                { id = "library", text = "Library" },
                { id = "browse", text = "Browse" },
                { id = "downloads", text = "Downloads" },
                { id = "sync", text = "Sync" },
                { id = "settings", text = "Settings" },
                { id = "close", text = "Close" },
            },
        }, function(action)
            table.insert(selected, action.id)
            table.insert(events, action.id)
        end)

        assert.are.equal("Suwayomi", shown_dialog.title)
        assert.are.equal("Library", shown_dialog.buttons[1][1].text)
        assert.are.equal("Browse", shown_dialog.buttons[1][2].text)
        assert.are.equal("Downloads", shown_dialog.buttons[2][1].text)
        assert.are.equal("Sync", shown_dialog.buttons[2][2].text)
        assert.are.equal("Settings", shown_dialog.buttons[3][1].text)
        assert.are.equal("Close", shown_dialog.buttons[3][2].text)

        shown_dialog.buttons[1][2].callback()

        assert.are.same({ "close", "browse" }, events)
        assert.are.equal(shown_dialog, closed_dialog)
        assert.are.same({ "browse" }, selected)
    end)

    it("shows downloads menu rows for active queued and failed items", function()
        local ui = require("suwayomi_ui")
        local cancelled_key
        local retried_key
        local cleared = false

        ui.showDownloadsMenu({
            active = {
                {
                    key = "m-active:144",
                    state = "downloading",
                    manga = { title = "Frieren" },
                    chapter = { name = "Ch. 144" },
                    progress = { current = 3, total = 24 },
                },
            },
            queued = {
                {
                    key = "m-queued:192",
                    state = "queued",
                    manga = { title = "Dandadan" },
                    chapter = { name = "Ch. 192" },
                },
            },
            failed = {
                {
                    key = "m-failed:205",
                    state = "failed",
                    manga = { title = "Chainsaw Man" },
                    chapter = { name = "Ch. 205" },
                    progress = { error = "network timeout" },
                },
            },
        }, {
            onSelectQueued = function(job)
                cancelled_key = job.key
            end,
            onRetryFailed = function(job)
                retried_key = job.key
            end,
            onClearFailed = function()
                cleared = true
            end,
        })

        assert.are.equal("Suwayomi Downloads", shown_dialog.title)
        assert.are.equal("Downloading 3/24  Frieren / Ch. 144", shown_dialog.item_table[1].text)
        assert.are.equal("Queued  Dandadan / Ch. 192", shown_dialog.item_table[2].text)
        assert.are.equal("Failed  Chainsaw Man / Ch. 205 - network timeout", shown_dialog.item_table[3].text)
        assert.are.equal("Clear failed", shown_dialog.item_table[4].text)

        shown_dialog.item_table[2].callback()
        shown_dialog.item_table[3].callback()
        shown_dialog.item_table[4].callback()

        assert.are.equal("m-queued:192", cancelled_key)
        assert.are.equal("m-failed:205", retried_key)
        assert.is_true(cleared)
    end)

    it("passes the native settings menu instance to setting callbacks", function()
        local ui = require("suwayomi_ui")
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
        local ui = require("suwayomi_ui")
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

    it("shows a sources menu", function()
        local ui = require("suwayomi_ui")
        local selected = {}

        ui.showSourcesMenu({
            { id = "s1", name = "MangaDex" },
            { id = "s2", name = "ComicK" },
            { id = "s3", name = "Local source" },
        }, function(source)
            table.insert(selected, source)
        end)

        assert.are.equal("Suwayomi Sources", shown_dialog.title)
        assert.are.equal("MangaDex", shown_dialog.item_table[1].text)
        assert.are.equal("ComicK", shown_dialog.item_table[2].text)
        assert.are.equal("Local source", shown_dialog.item_table[3].text)

        shown_dialog.item_table[1].callback()
        shown_dialog.item_table[2].callback()
        shown_dialog.item_table[3].callback()

        assert.are.same({
            { id = "s1", name = "MangaDex" },
            { id = "s2", name = "ComicK" },
            { id = "s3", name = "Local source" },
        }, selected)
    end)

    it("adds a home title-bar action to sources menus when requested", function()
        local ui = require("suwayomi_ui")
        local tapped_home = false

        ui.showSourcesMenu({
            { id = "s1", name = "MangaDex" },
        }, nil, {
            title_bar_left_icon = "appbar.filebrowser",
            on_title_bar_left_tap = function()
                tapped_home = true
                return true
            end,
        })

        assert.are.equal("appbar.filebrowser", shown_dialog.title_bar_left_icon)

        shown_dialog.onLeftButtonTap()

        assert.is_true(tapped_home)
    end)

    it("adds a home title-bar action to library manga menus when requested", function()
        local ui = require("suwayomi_ui")
        local tapped_home = false

        ui.showLibraryMangaMenu({
            { id = "m1", title = "Sousou no Frieren" },
        }, nil, {
            title_bar_left_icon = "appbar.filebrowser",
            on_title_bar_left_tap = function()
                tapped_home = true
                return true
            end,
        })

        assert.are.equal("appbar.filebrowser", shown_dialog.title_bar_left_icon)

        shown_dialog.onLeftButtonTap()

        assert.is_true(tapped_home)
    end)

    it("updates a sources menu in place", function()
        local ui = require("suwayomi_ui")
        local selected
        local menu = {
            updateItems = function(self)
                self.updated = true
            end,
        }

        ui.updateSourcesMenu(menu, {
            { id = "s4", name = "Local source" },
        }, function(source)
            selected = source
        end)

        assert.is_true(menu.updated)
        assert.are.equal("Local source", menu.item_table[1].text)

        menu.item_table[1].callback()

        assert.are.same({ id = "s4", name = "Local source" }, selected)
    end)

    it("uses KOReader path chooser to choose a directory", function()
        local ui = require("suwayomi_ui")
        local chosen_path

        ui.showDirectoryChooser(function(path)
            chosen_path = path
        end)

        assert.are.equal("Choose download directory", shown_dialog.title)
        assert.is_true(shown_dialog.select_directory)
        assert.is_false(shown_dialog.select_file)
        assert.is_false(shown_dialog.show_files)
        shown_dialog.onConfirm("/storage/emulated/0/Books/Manga")
        assert.are.equal("/storage/emulated/0/Books/Manga", chosen_path)
    end)

    it("starts the directory chooser in the provided directory", function()
        local ui = require("suwayomi_ui")

        ui.showDirectoryChooser(function() end, "/storage/emulated/0/Books/Manga")

        assert.are.equal("/storage/emulated/0/Books/Manga", shown_dialog.path)
    end)

    it("keeps KOReader-style current path visibility in the directory chooser", function()
        local ui = require("suwayomi_ui")

        ui.showDirectoryChooser(function() end, "/storage/emulated/0/Books/Manga")

        assert.is_true(shown_dialog.show_path)
    end)

    it("shows a visible use-this-folder action for the current directory", function()
        local ui = require("suwayomi_ui")
        local chosen_path

        ui.showDirectoryChooser(function(path)
            chosen_path = path
        end, "/storage/emulated/0/Books/Manga")

        local item_table = shown_dialog:genItemTable({}, {}, "/storage/emulated/0/Books/Manga")

        assert.are.equal("Use this folder", item_table[1].text)
        assert.are.equal("/storage/emulated/0/Books/Manga/.", item_table[1].path)

        shown_dialog:onMenuSelect(item_table[1])

        assert.are.equal("/storage/emulated/0/Books/Manga/.", shown_dialog.held_path)
        assert.are.equal("/storage/emulated/0/Books/Manga", chosen_path)
    end)

    it("keeps current folder selection under KOReader path chooser hold handling", function()
        local ui = require("suwayomi_ui")
        local chosen_path
        local instance_hold_called = false

        ui.showDirectoryChooser(function(path)
            chosen_path = path
        end, "/storage/emulated/0/Books/Manga")

        local item_table = shown_dialog:genItemTable({}, {}, "/storage/emulated/0/Books/Manga")
        shown_dialog.onMenuHold = function()
            instance_hold_called = true
            return true
        end

        shown_dialog:onMenuSelect(item_table[1])

        assert.is_false(instance_hold_called)
        assert.are.equal("/storage/emulated/0/Books/Manga/.", shown_dialog.held_path)
        assert.are.equal("/storage/emulated/0/Books/Manga", chosen_path)
    end)

    it("keeps child folder taps under KOReader path chooser navigation handling", function()
        local ui = require("suwayomi_ui")
        local chosen_path

        ui.showDirectoryChooser(function(path)
            chosen_path = path
        end, "/storage/emulated/0/Books/Manga")

        local item_table = shown_dialog:genItemTable({}, {}, "/storage/emulated/0/Books/Manga")

        shown_dialog:onMenuSelect(item_table[2])

        assert.are.equal("/storage/emulated/0/Books/Manga/Sousou no Frieren", shown_dialog.selected_path)
        assert.is_nil(shown_dialog.held_path)
        assert.is_nil(chosen_path)
    end)

    it("shows a parallel chapter downloads menu", function()
        local ui = require("suwayomi_ui")
        local selected

        ui.showParallelDownloadsMenu({
            current = 2,
            choices = { 1, 2, 3, 4 },
            onSelect = function(value)
                selected = value
            end,
        })

        assert.are.equal("Parallel chapter downloads", shown_dialog.title)
        assert.are.equal(32, shown_dialog.state_w)
        assert.are.equal("1", shown_dialog.item_table[1].text)
        assert.is_true(shown_dialog.item_table[1].radio)
        assert.is_false(shown_dialog.item_table[1].checked_func())
        assert.are.same({ mark_type = "radio", checked = false, dimen = { w = 20 }, getSize = shown_dialog.item_table[1].state.getSize }, shown_dialog.item_table[1].state)
        assert.are.equal("2", shown_dialog.item_table[2].text)
        assert.is_true(shown_dialog.item_table[2].radio)
        assert.is_true(shown_dialog.item_table[2].checked_func())
        assert.is_true(shown_dialog.item_table[2].state.checked)
        assert.are.equal("3", shown_dialog.item_table[3].text)
        assert.is_true(shown_dialog.item_table[3].radio)
        assert.is_false(shown_dialog.item_table[3].checked_func())
        assert.are.equal("4", shown_dialog.item_table[4].text)
        assert.is_true(shown_dialog.item_table[4].radio)
        assert.is_false(shown_dialog.item_table[4].checked_func())

        shown_dialog.item_table[3].callback()

        assert.are.equal(3, selected)
    end)

    it("closes the language menu from Done before running the close callback", function()
        local ui = require("suwayomi_ui")

        ui.showLanguageMenu({
            languages = {
                { code = "en", label = "EN", enabled = true },
                { code = "ru", label = "RU", enabled = false },
            },
            onClose = function()
                table.insert(events, "summary")
            end,
        })

        assert.are.equal("Suwayomi source languages", shown_dialog.title)
        assert.are.equal(32, shown_dialog.state_w)
        assert.are.equal("check", shown_dialog.item_table[1].state.mark_type)
        assert.is_true(shown_dialog.item_table[1].state.checked)
        assert.is_false(shown_dialog.item_table[2].state.checked)

        shown_dialog.item_table[3].callback()

        assert.are.same({ "close", "summary" }, events)
        assert.are.equal(shown_dialog, closed_dialog)
    end)

    it("runs the language menu close callback when KOReader closes the menu natively", function()
        local ui = require("suwayomi_ui")

        ui.showLanguageMenu({
            languages = {
                { code = "en", label = "EN", enabled = true },
            },
            onClose = function()
                table.insert(events, "summary")
            end,
        })

        shown_dialog.close_callback()
        shown_dialog.item_table[2].callback()

        assert.are.same({ "summary" }, events)
        assert.is_nil(closed_dialog)
    end)

    it("does not run the language close callback after toggling a checkbox row", function()
        local ui = require("suwayomi_ui")
        local toggled

        ui.showLanguageMenu({
            languages = {
                { code = "en", label = "EN", enabled = true },
                { code = "ru", label = "RU", enabled = false },
            },
            onToggle = function(code, enabled)
                toggled = { code = code, enabled = enabled }
            end,
            onClose = function()
                table.insert(events, "summary")
            end,
        })

        shown_dialog.item_table[2].callback()
        shown_dialog.close_callback()

        assert.are.same({ code = "ru", enabled = true }, toggled)
        assert.are.same({}, events)
    end)

    it("updates an existing language menu instead of requiring a new menu", function()
        local ui = require("suwayomi_ui")
        local update_count = 0
        local summary_count = 0
        local menu = {
            updateItems = function()
                update_count = update_count + 1
            end,
        }

        ui.updateLanguageMenu(menu, {
            languages = {
                { code = "en", label = "EN", enabled = true },
                { code = "ru", label = "RU", enabled = false },
            },
            onClose = function()
                summary_count = summary_count + 1
            end,
        }, function() end)

        assert.are.equal("EN", menu.item_table[1].text)
        assert.is_true(menu.item_table[1].checked_func())
        assert.are.equal("check", menu.item_table[1].state.mark_type)
        assert.is_true(menu.item_table[1].state.checked)
        assert.are.equal("RU", menu.item_table[2].text)
        assert.is_false(menu.item_table[2].checked_func())
        assert.is_false(menu.item_table[2].state.checked)
        assert.are.equal("Done", menu.item_table[3].text)
        assert.are.equal(1, update_count)

        menu.item_table[3].callback()

        assert.are.equal(menu, closed_dialog)
        assert.are.equal(1, summary_count)
    end)

    it("does not run the language close callback during an in-place menu refresh", function()
        local ui = require("suwayomi_ui")
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
