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

        package.preload["ui/downloadmgr"] = function()
            return {
                new = function(_, options)
                    return {
                        chooseDir = function()
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
                { id = "c1", name = "Chapter 1", menu_text = "Chapter 1 [downloaded]" },
                { id = "c2", name = "Chapter 2" },
            },
        }, function(chapter)
            table.insert(selected, chapter)
        end, function(chapter)
            table.insert(held, chapter)
        end)

        assert.are.equal("Sousou no Frieren", shown_dialog.title)
        assert.are.equal("Chapter 1 [downloaded]", shown_dialog.item_table[1].text)
        assert.are.equal("Chapter 2", shown_dialog.item_table[2].text)

        shown_dialog.item_table[1].callback()
        shown_dialog.item_table[2].callback()
        shown_dialog:onMenuHold(shown_dialog.item_table[1])

        assert.are.same({
            { id = "c1", name = "Chapter 1", menu_text = "Chapter 1 [downloaded]" },
            { id = "c2", name = "Chapter 2" },
        }, selected)
        assert.are.same({
            { id = "c1", name = "Chapter 1", menu_text = "Chapter 1 [downloaded]" },
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

    it("uses KOReader download manager to choose a directory", function()
        local ui = require("suwayomi_ui")
        local chosen_path

        ui.showDirectoryChooser(function(path)
            chosen_path = path
        end)

        assert.are.equal("Choose download directory", shown_dialog.title)
        shown_dialog.onConfirm("/storage/emulated/0/Books/Manga")
        assert.are.equal("/storage/emulated/0/Books/Manga", chosen_path)
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
        assert.are.equal("[ ] 1", shown_dialog.item_table[1].text)
        assert.are.equal("[x] 2", shown_dialog.item_table[2].text)
        assert.are.equal("[ ] 3", shown_dialog.item_table[3].text)
        assert.are.equal("[ ] 4", shown_dialog.item_table[4].text)

        shown_dialog.item_table[3].callback()

        assert.are.equal(3, selected)
    end)

    it("updates an existing language menu instead of requiring a new menu", function()
        local ui = require("suwayomi_ui")
        local update_count = 0
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
        }, function() end)

        assert.are.equal("[x] EN", menu.item_table[1].text)
        assert.are.equal("[ ] RU", menu.item_table[2].text)
        assert.are.equal("Done", menu.item_table[3].text)
        assert.are.equal(1, update_count)
    end)
end)
