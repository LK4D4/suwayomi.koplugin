package.path = "?.lua;" .. package.path

-- Browse UI specs cover menu/widget construction only. Controller specs own the
-- business decisions behind source selection, searches, and library navigation.
describe("suwayomi/ui/browse", function()
    local shown_dialog
    local closed_dialog
    local events

    before_each(function()
        shown_dialog = nil
        closed_dialog = nil
        events = {}

        package.loaded["suwayomi/ui/browse"] = nil
        package.loaded["suwayomi/ui"] = nil
        package.loaded["suwayomi/ui/list_menu"] = nil
        package.loaded["suwayomi/ui/menu_utils"] = nil
        package.loaded.gettext = nil
        package.loaded["ui/widget/menu"] = nil
        package.loaded["ui/widget/buttondialog"] = nil
        package.loaded["ui/widget/confirmbox"] = nil
        package.loaded["ui/widget/multiinputdialog"] = nil
        package.loaded["ui/uimanager"] = nil
        package.loaded["suwayomi/ui/directory"] = nil
        package.loaded["suwayomi/ui/downloads"] = nil
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
                    options.is_button_dialog = true
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
                        return { "frieren" }
                    end
                    options.onShowKeyboard = function() end
                    return options
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

        package.preload["suwayomi/ui/list_menu"] = function()
            return {
                show = function(options)
                    options.renderer = "list_menu"
                    shown_dialog = options
                    return options
                end,
                update = function(menu, options)
                    menu.renderer = "list_menu"
                    menu.updated_options = options
                    menu.item_table = options.item_table
                    menu.title = options.title or menu.title
                    menu.close_callback = options.close_callback
                    if menu.title_bar and menu.title_bar.setTitle and options.title then
                        menu.title_bar:setTitle(options.title, true)
                    end
                    if menu.setTitleBarLeftIcon then
                        menu:setTitleBarLeftIcon(options.title_bar_left_icon)
                    end
                    if menu.updateItems then
                        menu:updateItems()
                    end
                end,
            }
        end

        package.preload["suwayomi/ui/directory"] = function()
            return {}
        end

        package.preload["suwayomi/ui/downloads"] = function()
            return {}
        end
    end)

    after_each(function()
        package.preload.gettext = nil
        package.preload["ui/widget/menu"] = nil
        package.preload["ui/widget/buttondialog"] = nil
        package.preload["ui/widget/confirmbox"] = nil
        package.preload["ui/widget/multiinputdialog"] = nil
        package.preload["ui/uimanager"] = nil
        package.preload["suwayomi/ui/list_menu"] = nil
        package.preload["suwayomi/ui/directory"] = nil
        package.preload["suwayomi/ui/downloads"] = nil
        package.preload["suwayomi/ui/manga_menu"] = nil
    end)

    it("shows a sources menu with source thumbnails, metadata, callbacks, and no global search row", function()
        local browse = require("suwayomi/ui/browse")
        local selected = {}

        browse.showSourcesMenu({
            { id = "s1", name = "MangaDex", lang = "en", icon_url = "/icons/md.png", is_nsfw = true },
            { id = "s2", name = "ComicK", lang = "ja", icon_url = "/icons/ck.png" },
        }, function(source)
            table.insert(selected, source)
        end, {
            on_global_search = function() end,
            thumbnail_credentials = { server_url = "http://127.0.0.1:4567" },
        })

        assert.are.equal("Suwayomi Sources", shown_dialog.title)
        assert.are.equal("list_menu", shown_dialog.renderer)
        assert.is_true(shown_dialog.fixed_item_heights)
        assert.are.equal("MangaDex", shown_dialog.item_table[1].text)
        assert.are.equal("English", shown_dialog.item_table[1].subtitle)
        assert.are.equal("18+", shown_dialog.item_table[1].mandatory)
        assert.are.equal("/icons/md.png", shown_dialog.item_table[1].thumbnail_url)
        assert.are.same({ server_url = "http://127.0.0.1:4567" }, shown_dialog.thumbnail_credentials)
        assert.are.equal("ComicK", shown_dialog.item_table[2].text)
        assert.are.equal("日本語", shown_dialog.item_table[2].subtitle)
        assert.is_nil(shown_dialog.item_table[3])

        shown_dialog.item_table[1].callback()
        shown_dialog.item_table[2].callback()

        assert.are.same({
            { id = "s1", name = "MangaDex", lang = "en", icon_url = "/icons/md.png", is_nsfw = true },
            { id = "s2", name = "ComicK", lang = "ja", icon_url = "/icons/ck.png" },
        }, selected)
    end)

    it("passes close callbacks through source menus", function()
        local browse = require("suwayomi/ui/browse")
        local closed = false

        browse.showSourcesMenu({}, function() end, {
            title_bar_left_icon = "appbar.menu",
            close_callback = function()
                closed = true
            end,
        })

        assert.are.equal("appbar.menu", shown_dialog.title_bar_left_icon)
        assert.are.equal("list_menu", shown_dialog.renderer)

        shown_dialog.close_callback()

        assert.is_true(closed)
    end)

    it("shows extension rows", function()
        local browse = require("suwayomi/ui/browse")
        local selected = {}

        browse.showExtensionsMenu({
            {
                pkg_name = "pkg.mangadex",
                name = "MangaDex",
                lang = "all",
                version_name = "1.4.0",
                icon_url = "/icons/md.png",
                is_nsfw = true,
                is_installed = false,
            },
            {
                pkg_name = "pkg.comick",
                name = "Comick",
                lang = "en",
                version_name = "1.2.0",
                is_installed = true,
                has_update = true,
            },
        }, function(extension)
            table.insert(selected, extension)
        end, {
            title_bar_left_icon = "appbar.menu",
        })

        assert.are.equal("Suwayomi Extensions", shown_dialog.title)
        assert.are.equal("list_menu", shown_dialog.renderer)
        assert.is_true(shown_dialog.fixed_item_heights)
        assert.are.equal("appbar.menu", shown_dialog.title_bar_left_icon)
        assert.are.equal("Updates (1)", shown_dialog.item_table[1].text)
        assert.is_false(shown_dialog.item_table[1].select_enabled)
        assert.are.equal("Update available\nv1.2.0", shown_dialog.item_table[2].mandatory)
        assert.are.equal("Available (1)", shown_dialog.item_table[3].text)
        assert.are.equal("MangaDex", shown_dialog.item_table[4].text)
        assert.are.equal("All", shown_dialog.item_table[4].subtitle)
        assert.are.equal("Not installed\n18+ · v1.4.0", shown_dialog.item_table[4].mandatory)
        assert.are.equal("/icons/md.png", shown_dialog.item_table[4].thumbnail_url)

        shown_dialog.item_table[4].callback()

        assert.are.equal("pkg.mangadex", selected[1].pkg_name)
    end)

    it("focuses a refreshed extension row by package name", function()
        local browse = require("suwayomi/ui/browse")
        local menu = { title = "Suwayomi Extensions" }

        browse.updateExtensionsMenu(menu, {
            {
                pkg_name = "pkg.orchid",
                name = "Orchid Gate",
                is_installed = true,
            },
            {
                pkg_name = "pkg.quartz",
                name = "Quartz Node",
                is_installed = true,
            },
            {
                pkg_name = "pkg.fallback",
                name = "Fallback",
                is_installed = false,
            },
        }, function() end, {
            focus_extension_pkg_name = "pkg.quartz",
            show_empty_extension_sections = true,
        })

        assert.are.equal(3, menu.updated_options.itemnumber)
        assert.are.equal("Installed (2)", menu.item_table[1].text)
        assert.are.equal("Orchid Gate", menu.item_table[2].text)
        assert.are.equal("Quartz Node", menu.item_table[3].text)
        assert.are.equal("Available (1)", menu.item_table[4].text)
    end)

    it("keeps installed and available section headers visible during extension search updates", function()
        local browse = require("suwayomi/ui/browse")
        local menu = { title = "Suwayomi Extensions" }

        browse.updateExtensionsMenu(menu, {
            {
                pkg_name = "pkg.quartz",
                name = "Quartz Node",
                is_installed = true,
            },
        }, function() end, {
            show_empty_extension_sections = true,
        })

        assert.are.equal("Installed (1)", menu.item_table[1].text)
        assert.are.equal("Quartz Node", menu.item_table[2].text)
        assert.are.equal("Available (0)", menu.item_table[3].text)
    end)

    it("shows extension actions through the shared action dialog", function()
        local browse = require("suwayomi/ui/browse")
        local selected = {}
        local closed = false
        local anchor = function()
            return { x = 4, y = 8, w = 16, h = 32 }
        end

        local actions = {}
        browse.showExtensionActionMenu({
            pkg_name = "pkg.mangadex",
            name = "MangaDex",
            is_installed = false,
        }, function(action)
            table.insert(actions, action)
            table.insert(selected, action)
        end, {
            anchor = anchor,
            close_callback = function()
                closed = true
            end,
        })
        assert.is_true(shown_dialog.is_button_dialog)
        assert.are.equal("MangaDex", shown_dialog.title)
        assert.are.equal(anchor, shown_dialog.anchor)
        shown_dialog.close_callback()
        assert.is_true(closed)
        assert.are.equal("Install", shown_dialog.buttons[1][1].text)
        assert.are.equal("install", shown_dialog.buttons[1][1].id)
        shown_dialog.buttons[1][1].callback()

        browse.showExtensionActionMenu({
            pkg_name = "pkg.comick",
            name = "Comick",
            is_installed = true,
            has_update = true,
        }, function(action)
            table.insert(actions, action)
        end)
        assert.is_true(shown_dialog.is_button_dialog)
        assert.are.equal("Update", shown_dialog.buttons[1][1].text)
        assert.are.equal("update", shown_dialog.buttons[1][1].id)
        shown_dialog.buttons[1][1].callback()
        assert.are.same({}, shown_dialog.buttons[2])
        assert.are.equal("Uninstall", shown_dialog.buttons[3][1].text)
        assert.are.equal("uninstall", shown_dialog.buttons[3][1].id)
        assert.is_true(shown_dialog.buttons[3][1].destructive)
        shown_dialog.buttons[3][1].callback()

        browse.showExtensionActionMenu({
            pkg_name = "pkg.installed",
            name = "Installed Source",
            is_installed = true,
            has_update = false,
        }, function(action)
            table.insert(actions, action)
        end)
        assert.is_true(shown_dialog.is_button_dialog)
        assert.are.equal("Uninstall", shown_dialog.buttons[1][1].text)
        assert.are.equal("uninstall", shown_dialog.buttons[1][1].id)
        assert.is_true(shown_dialog.buttons[1][1].destructive)
        shown_dialog.buttons[1][1].callback()

        browse.showExtensionActionMenu(nil, function(action)
            table.insert(actions, action)
        end)
        assert.is_true(shown_dialog.is_button_dialog)
        assert.are.equal("No actions available", shown_dialog.buttons[1][1].text)
        shown_dialog.buttons[1][1].callback()

        assert.are.same({ "install", "update", "uninstall", "uninstall" }, actions)
        assert.are.same({ "install" }, selected)
    end)

    it("shows a source mode action dialog with source filters and hides latest when unsupported", function()
        local browse = require("suwayomi/ui/browse")
        local selected = {}
        local closed = false
        local went_back = false

        browse.showSourceModeMenu({
            id = "s1",
            name = "MangaDex",
            supports_latest = false,
        }, function(mode)
            table.insert(selected, mode)
        end, {
            close_callback = function()
                closed = true
            end,
            on_back = function()
                went_back = true
            end,
        })

        assert.is_true(shown_dialog.is_button_dialog)
        assert.are.equal("MangaDex", shown_dialog.title)
        assert.are.equal("< Back", shown_dialog.buttons[1][1].text)
        assert.are.same({}, shown_dialog.buttons[2])
        assert.are.equal("Popular", shown_dialog.buttons[3][1].text)
        assert.are.equal("POPULAR", shown_dialog.buttons[3][1].id)
        assert.are.equal("Search", shown_dialog.buttons[3][2].text)
        assert.are.equal("SEARCH", shown_dialog.buttons[3][2].id)
        assert.are.equal("Source filters", shown_dialog.buttons[4][1].text)
        assert.are.equal("FILTERS", shown_dialog.buttons[4][1].id)

        shown_dialog.close_callback()
        shown_dialog.buttons[1][1].callback()
        shown_dialog.buttons[3][1].callback()
        shown_dialog.buttons[3][2].callback()
        shown_dialog.buttons[4][1].callback()

        assert.is_true(closed)
        assert.is_true(went_back)
        assert.are.same({ "POPULAR", "SEARCH", "FILTERS" }, selected)
    end)

    it("shows source filter editor rows and title actions", function()
        local browse = require("suwayomi/ui/browse")
        local applied
        local reset = false
        local search_text = false

        browse.showSourceFilterEditor({
            id = "s1",
            name = "Random Source",
        }, {
            { type = "HeaderFilter", name = "Genres" },
            { type = "CheckBoxFilter", name = "Completed", default = false },
            { type = "TriStateFilter", name = "Licensed", default = "IGNORE" },
            { type = "SelectFilter", name = "Length", values = { "Any", "Long" }, default = 0 },
            { type = "TextFilter", name = "Author", default = "" },
            { type = "SortFilter", name = "Sort by", values = { "Name", "Updated" }, default = { index = 0, ascending = true } },
            {
                type = "GroupFilter",
                name = "Small group",
                filters = {
                    { type = "CheckBoxFilter", name = "Awarded", default = false },
                    { type = "CheckBoxFilter", name = "Licensed", default = false },
                },
            },
            {
                type = "GroupFilter",
                name = "Large group",
                filters = {
                    { type = "CheckBoxFilter", name = "One", default = false },
                    { type = "CheckBoxFilter", name = "Two", default = false },
                    { type = "CheckBoxFilter", name = "Three", default = false },
                    { type = "CheckBoxFilter", name = "Four", default = false },
                    { type = "CheckBoxFilter", name = "Five", default = false },
                    { type = "CheckBoxFilter", name = "Six", default = false },
                    { type = "CheckBoxFilter", name = "Seven", default = false },
                    { type = "CheckBoxFilter", name = "Eight", default = false },
                    { type = "CheckBoxFilter", name = "Nine", default = false },
                },
            },
            {
                type = "GroupFilter",
                name = "Complex group",
                filters = {
                    { type = "TextFilter", name = "Publisher", default = "" },
                },
            },
            { type = "UnknownFilter", name = "Mystery", unsupported = true },
        }, {
            filters = {
                { position = 2, type = "checkBoxState", state = true },
            },
        }, {
            on_apply = function(draft)
                applied = draft
            end,
            on_reset = function()
                reset = true
            end,
            on_search_text = function()
                search_text = true
            end,
        })

        assert.are.equal("Random Source filters", shown_dialog.title)
        assert.are.equal("Genres", shown_dialog.item_table[1].text)
        assert.is_false(shown_dialog.item_table[1].select_enabled)
        assert.are.equal("Completed", shown_dialog.item_table[2].text)
        assert.are.equal("On", shown_dialog.item_table[2].mandatory)
        assert.are.equal("Licensed", shown_dialog.item_table[3].text)
        assert.are.equal("IGNORE", shown_dialog.item_table[3].mandatory)
        assert.are.equal("Length", shown_dialog.item_table[4].text)
        assert.are.equal("Any", shown_dialog.item_table[4].mandatory)
        assert.are.equal("Author", shown_dialog.item_table[5].text)
        assert.are.equal("", shown_dialog.item_table[5].mandatory)
        assert.are.equal("Sort by", shown_dialog.item_table[6].text)
        assert.are.equal("Name - Ascending", shown_dialog.item_table[6].mandatory)
        assert.is_nil(shown_dialog.item_table[6].sub_item_table)
        assert.are.equal("Small group", shown_dialog.item_table[7].text)
        assert.are.equal("Group", shown_dialog.item_table[7].mandatory)
        assert.is_nil(shown_dialog.item_table[7].sub_item_table)
        assert.are.equal("Large group", shown_dialog.item_table[8].text)
        assert.are.equal("One", shown_dialog.item_table[8].sub_item_table[1].text)
        assert.are.equal("Complex group", shown_dialog.item_table[9].text)
        assert.are.equal("Publisher", shown_dialog.item_table[9].sub_item_table[1].text)
        assert.are.equal("Mystery", shown_dialog.item_table[10].text)
        assert.are.equal("Unsupported", shown_dialog.item_table[10].mandatory)
        assert.is_false(shown_dialog.item_table[10].select_enabled)
        assert.are.equal("Apply filters", shown_dialog.item_table[11].text)
        assert.are.equal("Reset filters", shown_dialog.item_table[12].text)
        assert.are.equal("Search text", shown_dialog.item_table[13].text)

        local editor = shown_dialog
        shown_dialog.item_table[2].callback()
        editor.item_table[3].callback()
        assert.is_nil(editor.item_table[4].sub_item_table)
        editor.item_table[4].callback()
        assert.are.equal("Length", shown_dialog.title)
        assert.are.equal("Any", shown_dialog.buttons[1][1].text)
        assert.is_true(shown_dialog.buttons[1][1].checked_func())
        shown_dialog.buttons[2][1].callback()
        assert.are.equal("Long", editor.item_table[4].mandatory)
        editor.item_table[5].callback()
        shown_dialog.getFields = function()
            return { "isekai" }
        end
        shown_dialog.buttons[1][2].callback()
        editor.item_table[6].callback()
        assert.are.equal("Sort by", shown_dialog.title)
        assert.truthy(shown_dialog.buttons[1][1].text:match("Name"))
        assert.truthy(shown_dialog.buttons[3][1].text:match("Ascending"))
        shown_dialog.buttons[2][1].callback()
        assert.are.equal("Updated - Ascending", editor.item_table[6].mandatory)
        editor.item_table[6].callback()
        shown_dialog.buttons[4][1].callback()
        assert.are.equal("Updated - Descending", editor.item_table[6].mandatory)
        editor.item_table[7].callback()
        assert.are.equal("Small group", shown_dialog.title)
        assert.are.equal("Awarded", shown_dialog.buttons[1][1].text)
        assert.is_false(shown_dialog.buttons[1][1].checked_func())
        assert.are.equal("Licensed", shown_dialog.buttons[2][1].text)
        assert.is_false(shown_dialog.buttons[2][1].checked_func())
        assert.are.equal("Done", shown_dialog.buttons[3][1].text)
        shown_dialog.buttons[1][1].callback()
        assert.are.equal("Modified", editor.item_table[7].mandatory)
        assert.is_true(shown_dialog.buttons[1][1].checked_func())
        assert.is_false(shown_dialog.buttons[2][1].checked_func())
        shown_dialog.buttons[2][1].callback()
        assert.is_true(shown_dialog.buttons[2][1].checked_func())
        shown_dialog.buttons[3][1].callback()
        editor.item_table[11].callback()
        assert.are.same({
            query = "",
            filters = {
                { position = 2, type = "checkBoxState", state = false },
                { position = 3, type = "triState", state = "INCLUDE" },
                { position = 4, type = "selectState", state = 1 },
                { position = 5, type = "textState", state = "isekai" },
                { position = 6, type = "sortState", state = { index = 1, ascending = false } },
                {
                    position = 7,
                    group_change = { position = 1, type = "checkBoxState", state = true },
                },
                {
                    position = 7,
                    group_change = { position = 2, type = "checkBoxState", state = true },
                },
            },
        }, applied)

        editor.item_table[12].callback()
        editor.item_table[13].callback()
        assert.is_true(reset)
        assert.is_true(search_text)
    end)

    it("omits source filter fallback action rows when title callbacks are present", function()
        local browse = require("suwayomi/ui/browse")

        browse.showSourceFilterEditor({
            id = "s1",
            name = "Random Source",
        }, {
            { type = "CheckBoxFilter", name = "Completed", default = false },
        }, nil, {
            title_options = {
                title_bar_left_icon = "appbar.menu",
                on_title_bar_left_tap = function() end,
                on_title_bar_left_hold = function() end,
            },
        })

        assert.are.equal("Completed", shown_dialog.item_table[1].text)
        assert.is_nil(shown_dialog.item_table[2])
    end)

    it("passes edited draft to title action callbacks", function()
        local browse = require("suwayomi/ui/browse")
        local applied

        browse.showSourceFilterEditor({
            id = "s1",
            name = "Random Source",
        }, {
            { type = "SelectFilter", name = "Length", values = { "Any", "Long" }, default = 0 },
        }, {
            filters = {},
        }, {
            title_options = {
                title_bar_left_icon = "appbar.menu",
                on_title_bar_left_tap = function(menu)
                    applied = menu.suwayomi_source_filter_draft
                    return true
                end,
            },
        })

        local editor = shown_dialog
        editor.item_table[1].callback()
        shown_dialog.buttons[2][1].callback()
        editor.on_title_bar_left_tap(editor)

        assert.are.same({
            query = "",
            filters = {
                { position = 1, type = "selectState", state = 1 },
            },
        }, applied)
    end)

    it("refreshes source filter select rows after modal edits", function()
        local browse = require("suwayomi/ui/browse")
        local refreshes = {}

        browse.showSourceFilterEditor({
            id = "s1",
            name = "Random Source",
        }, {
            { type = "SelectFilter", name = "Length", values = { "Any", "Long" }, default = 0 },
        })

        local editor = shown_dialog
        editor.updateItems = function(_, select_number, no_recalculate_dimen)
            table.insert(refreshes, { select_number = select_number, no_recalculate_dimen = no_recalculate_dimen })
        end

        editor.item_table[1].callback(editor)
        shown_dialog.buttons[2][1].callback()

        assert.are.equal("Long", editor.item_table[1].mandatory)
        assert.are.same({ { select_number = nil, no_recalculate_dimen = true } }, refreshes)
    end)

    it("refreshes source filter sort rows after modal edits", function()
        local browse = require("suwayomi/ui/browse")
        local refreshes = {}

        browse.showSourceFilterEditor({
            id = "s1",
            name = "Random Source",
        }, {
            { type = "SortFilter", name = "Sort by", values = { "Name", "Updated" }, default = { index = 0, ascending = true } },
        })

        local editor = shown_dialog
        editor.updateItems = function(_, select_number, no_recalculate_dimen)
            table.insert(refreshes, { select_number = select_number, no_recalculate_dimen = no_recalculate_dimen })
        end

        editor.item_table[1].callback(editor)
        shown_dialog.buttons[2][1].callback()

        assert.are.equal("Updated - Ascending", editor.item_table[1].mandatory)
        assert.are.same({ { select_number = nil, no_recalculate_dimen = true } }, refreshes)
    end)

    it("refreshes small source filter group rows after modal edits", function()
        local browse = require("suwayomi/ui/browse")
        local refreshes = {}

        browse.showSourceFilterEditor({
            id = "s1",
            name = "Random Source",
        }, {
            {
                type = "GroupFilter",
                name = "Small group",
                filters = {
                    { type = "CheckBoxFilter", name = "Awarded", default = false },
                    { type = "CheckBoxFilter", name = "Licensed", default = false },
                },
            },
            {
                type = "GroupFilter",
                name = "Large group",
                filters = {
                    { type = "CheckBoxFilter", name = "One", default = false },
                    { type = "CheckBoxFilter", name = "Two", default = false },
                    { type = "CheckBoxFilter", name = "Three", default = false },
                    { type = "CheckBoxFilter", name = "Four", default = false },
                    { type = "CheckBoxFilter", name = "Five", default = false },
                    { type = "CheckBoxFilter", name = "Six", default = false },
                    { type = "CheckBoxFilter", name = "Seven", default = false },
                    { type = "CheckBoxFilter", name = "Eight", default = false },
                    { type = "CheckBoxFilter", name = "Nine", default = false },
                },
            },
        })

        local editor = shown_dialog
        editor.updateItems = function(_, select_number, no_recalculate_dimen)
            table.insert(refreshes, { select_number = select_number, no_recalculate_dimen = no_recalculate_dimen })
        end

        assert.is_nil(editor.item_table[1].sub_item_table)
        assert.are.equal("One", editor.item_table[2].sub_item_table[1].text)

        editor.item_table[1].callback(editor)
        shown_dialog.buttons[1][1].callback()

        assert.are.equal("Modified", editor.item_table[1].mandatory)
        assert.is_true(shown_dialog.buttons[1][1].checked_func())
        assert.are.same({ { select_number = nil, no_recalculate_dimen = true } }, refreshes)
    end)

    it("shows latest for unknown source support and collects search queries", function()
        local browse = require("suwayomi/ui/browse")
        local selected_mode
        local searched_query
        local global_query
        local extension_query

        browse.showSourceModeMenu({
            id = "s1",
            name = "MangaDex",
        }, function(mode)
            selected_mode = mode
        end)

        assert.is_true(shown_dialog.is_button_dialog)
        assert.are.equal("Popular", shown_dialog.buttons[1][1].text)
        assert.are.equal("Latest", shown_dialog.buttons[1][2].text)
        assert.are.equal("Search", shown_dialog.buttons[2][1].text)
        shown_dialog.buttons[1][2].callback()
        assert.are.equal("LATEST", selected_mode)

        browse.showSourceSearchPrompt({
            id = "s1",
            name = "MangaDex",
        }, function(query)
            searched_query = query
        end)

        assert.are.equal("Search MangaDex", shown_dialog.title)
        shown_dialog.getFields = function()
            return { " frieren " }
        end
        shown_dialog.buttons[1][2].callback()
        assert.are.equal(" frieren ", searched_query)
        assert.are.equal(shown_dialog, closed_dialog)

        browse.showGlobalSearchPrompt(function(query)
            global_query = query
        end)
        assert.are.equal("Global search", shown_dialog.title)
        shown_dialog.getFields = function()
            return { "dandadan" }
        end
        shown_dialog.buttons[1][2].callback()
        assert.are.equal("dandadan", global_query)

        browse.showExtensionSearchPrompt("akuma", function(query)
            extension_query = query
        end)
        assert.are.equal("Search extensions", shown_dialog.title)
        assert.are.equal("akuma", shown_dialog.fields[1].text)
        shown_dialog.getFields = function()
            return { "buon dua" }
        end
        shown_dialog.buttons[1][2].callback()
        assert.are.equal("buon dua", extension_query)

        browse.showExtensionSearchPrompt("buon", function(query)
            extension_query = query
        end)
        shown_dialog.buttons[1][1].callback()
        assert.are.equal("", extension_query)

        browse.showExtensionSearchPrompt("akuma", function(query)
            extension_query = query
        end)
        shown_dialog.close_callback()
        assert.are.equal("", extension_query)
    end)

    it("does not render title menu callbacks as action rows in source mode menus", function()
        local browse = require("suwayomi/ui/browse")

        browse.showSourceModeMenu({
            id = "s1",
            name = "MangaDex",
        }, function() end, {
            title_bar_left_icon = "appbar.menu",
            on_title_bar_left_tap = function()
                return true
            end,
            on_title_bar_left_hold = function()
                return true
            end,
        })

        assert.is_true(shown_dialog.is_button_dialog)
        assert.are.equal("Popular", shown_dialog.buttons[1][1].text)
        assert.are.equal("POPULAR", shown_dialog.buttons[1][1].id)
        assert.are.equal("Latest", shown_dialog.buttons[1][2].text)
        assert.are.equal("LATEST", shown_dialog.buttons[1][2].id)
    end)

    it("shows global search summaries and opens only successful or pageable source rows", function()
        local browse = require("suwayomi/ui/browse")
        local selected = {}

        browse.showGlobalSearchResultsMenu({
            {
                source = { id = "s1", name = "MangaDex" },
                status = "ok",
                result_count = 1,
            },
            {
                source = { id = "s4", name = "More Source" },
                status = "ok",
                result_count = 2,
                has_next_page = true,
                query = "frieren",
            },
            {
                source = { id = "s5", name = "Searching Source" },
                status = "searching",
            },
            {
                source = { id = "s6", name = "Slow Source" },
                status = "timed_out",
            },
            {
                source = { id = "s2", name = "ComicK" },
                status = "empty",
            },
            {
                source = { id = "s3", name = "Some Source" },
                status = "error",
                error = "Timed out",
            },
        }, function(summary)
            table.insert(selected, summary)
        end)

        assert.are.equal("Global search", shown_dialog.title)
        assert.are.equal("list_menu", shown_dialog.renderer)
        assert.are.equal("MangaDex", shown_dialog.item_table[1].text)
        assert.are.equal("1 result", shown_dialog.item_table[1].mandatory)
        assert.are.equal("More Source", shown_dialog.item_table[2].text)
        assert.are.equal("2+ results", shown_dialog.item_table[2].mandatory)
        assert.are.equal("Searching Source", shown_dialog.item_table[3].text)
        assert.are.equal("searching", shown_dialog.item_table[3].mandatory)
        assert.are.equal("Slow Source", shown_dialog.item_table[4].text)
        assert.are.equal("timed out", shown_dialog.item_table[4].mandatory)
        assert.are.equal("ComicK", shown_dialog.item_table[5].text)
        assert.are.equal("No results", shown_dialog.item_table[5].mandatory)
        assert.are.equal("Some Source", shown_dialog.item_table[6].text)
        assert.are.equal("Error", shown_dialog.item_table[6].mandatory)
        assert.are.equal("Timed out", shown_dialog.item_table[6].subtitle)

        shown_dialog.item_table[1].callback()
        shown_dialog.item_table[2].callback()
        shown_dialog.item_table[3].callback()
        shown_dialog.item_table[4].callback()
        shown_dialog.item_table[5].callback()
        shown_dialog.item_table[6].callback()

        assert.are.equal("s1", selected[1].source.id)
        assert.are.equal("s4", selected[2].source.id)
        assert.are.equal(2, #selected)
    end)

    it("updates global search summaries in place without an inline cancel row", function()
        local browse = require("suwayomi/ui/browse")
        local canceled = false
        local selected = {}

        browse.showGlobalSearchResultsMenu({
            { source = { id = "s1", name = "Local source" }, status = "searching" },
        }, function(summary)
            table.insert(selected, summary)
        end, {
            on_cancel_search = function()
                canceled = true
            end,
        })

        assert.are.equal("list_menu", shown_dialog.renderer)
        assert.are.equal("Local source", shown_dialog.item_table[1].text)
        assert.are.equal("searching", shown_dialog.item_table[1].mandatory)

        browse.updateGlobalSearchResultsMenu(shown_dialog, {
            { source = { id = "s1", name = "Local source" }, status = "ok", result_count = 1 },
        }, function(summary)
            table.insert(selected, summary)
        end, {
            on_cancel_search = function()
                canceled = true
            end,
        })

        assert.are.equal("list_menu", shown_dialog.renderer)
        assert.are.equal("Local source", shown_dialog.item_table[1].text)
        assert.are.equal("1 result", shown_dialog.item_table[1].mandatory)
        shown_dialog.item_table[1].callback()

        assert.is_false(canceled)
        assert.are.equal("s1", selected[1].source.id)
    end)

    it("updates source rows in place", function()
        local browse = require("suwayomi/ui/browse")
        local selected
        local menu = {
            title = "Suwayomi Sources",
            updateItems = function(self)
                self.updated = true
            end,
        }

        browse.updateSourcesMenu(menu, {
            { id = "s2", name = "ComicK", lang = "ja", icon_url = "/icons/ck.png" },
        }, function(source)
            selected = source
        end, {
            thumbnail_credentials = { server_url = "http://127.0.0.1:4567" },
        })

        assert.are.equal("list_menu", menu.renderer)
        assert.is_true(menu.updated)
        assert.are.equal("ComicK", menu.item_table[1].text)
        assert.are.equal("日本語", menu.item_table[1].subtitle)
        assert.are.equal("/icons/ck.png", menu.item_table[1].thumbnail_url)
        assert.are.same({ server_url = "http://127.0.0.1:4567" }, menu.updated_options.thumbnail_credentials)

        menu.item_table[1].callback()
        assert.are.equal("s2", selected.id)
    end)

    it("shows compact browse result library status, title, and paging rows", function()
        local browse = require("suwayomi/ui/browse")
        local selected = {}
        local paging = {}
        local on_page_changed = function() end

        browse.showMangaMenu({
            { id = "m1", title = "Already Added", in_library = true },
            { id = "m2", title = "New Find", in_library = false },
            { id = "m3", title = "Unknown State" },
        }, function(manga)
            table.insert(selected, manga.id)
        end, {
            title = "MangaDex (EN) - Search: frieren",
            on_previous_page = function()
                table.insert(paging, "previous")
            end,
            on_next_page = function()
                table.insert(paging, "next")
            end,
            on_page_changed = on_page_changed,
        })

        assert.are.equal("MangaDex (EN) - Search: frieren", shown_dialog.title)
        assert.are.equal("list_menu", shown_dialog.renderer)
        assert.is_true(shown_dialog.fixed_item_heights)
        assert.are.equal(on_page_changed, shown_dialog.on_page_changed)
        assert.are.equal("Previous page", shown_dialog.item_table[1].text)
        assert.are.equal("Already Added", shown_dialog.item_table[2].text)
        assert.are.equal("In Library", shown_dialog.item_table[2].mandatory)
        assert.are.equal("New Find", shown_dialog.item_table[3].text)
        assert.is_nil(shown_dialog.item_table[3].mandatory)
        assert.are.equal("Unknown State", shown_dialog.item_table[4].text)
        assert.is_nil(shown_dialog.item_table[4].mandatory)
        assert.are.equal("Next page", shown_dialog.item_table[5].text)

        shown_dialog.item_table[1].callback()
        shown_dialog.item_table[2].callback()
        shown_dialog.item_table[5].callback()

        assert.are.same({ "previous", "next" }, paging)
        assert.are.same({ "m1" }, selected)
    end)

    it("updates a manga menu title bar in place", function()
        local browse = require("suwayomi/ui/browse")
        local title_bar_title
        local left_icon
        local closed = false
        local on_page_changed = function() end
        local menu = {
            title = "MangaDex - Popular",
            title_bar = {
                setTitle = function(_, title, refresh)
                    title_bar_title = { title = title, refresh = refresh }
                end,
            },
            setTitleBarLeftIcon = function(_, icon)
                left_icon = icon
            end,
            updateItems = function(self)
                self.updated = true
            end,
        }

        browse.updateMangaMenu(menu, {
            { id = "m2", title = "Page 2" },
        }, function() end, {
            title = "MangaDex - Latest",
            title_bar_left_icon = "appbar.menu",
            close_callback = function()
                closed = true
            end,
            on_page_changed = on_page_changed,
        })

        assert.are.equal("MangaDex - Latest", menu.title)
        assert.are.equal("list_menu", menu.renderer)
        assert.are.same({ title = "MangaDex - Latest", refresh = true }, title_bar_title)
        assert.are.equal("appbar.menu", left_icon)
        assert.are.equal(on_page_changed, menu.updated_options.on_page_changed)
        assert.is_true(menu.updated)

        menu.close_callback()

        assert.is_true(closed)
    end)

    it("shows library category and manga menus", function()
        local browse = require("suwayomi/ui/browse")
        local selected_category
        local selected_manga

        browse.showLibraryCategoryMenu({
            { id = 0, name = "Default", manga_count = 2 },
            { id = 7, name = "Favorites" },
        }, function(category)
            selected_category = category
        end)

        assert.are.equal("Suwayomi Library", shown_dialog.title)
        assert.are.equal("list_menu", shown_dialog.renderer)
        assert.are.equal("Default", shown_dialog.item_table[1].text)
        assert.are.equal("2 manga", shown_dialog.item_table[1].mandatory)
        assert.are.equal("Favorites", shown_dialog.item_table[2].text)
        shown_dialog.item_table[1].callback()
        assert.are.same({ id = 0, name = "Default", manga_count = 2 }, selected_category)

        browse.showLibraryMangaMenu({
            { id = "m1", title = "Sousou no Frieren", unread_count = 12 },
        }, function(manga)
            selected_manga = manga
        end)

        assert.are.equal("Suwayomi Library", shown_dialog.title)
        assert.are.equal("list_menu", shown_dialog.renderer)
        assert.are.equal("Sousou no Frieren", shown_dialog.item_table[1].text)
        assert.is_nil(shown_dialog.item_table[1].mandatory)
        shown_dialog.item_table[1].callback()
        assert.are.same({ id = "m1", title = "Sousou no Frieren", unread_count = 12 }, selected_manga)
    end)
end)
