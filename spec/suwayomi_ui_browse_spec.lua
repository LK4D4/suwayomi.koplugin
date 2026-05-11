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
        package.loaded["suwayomi/ui/list_menu"] = nil
        package.loaded["suwayomi/ui/menu_utils"] = nil
        package.loaded.gettext = nil
        package.loaded["ui/widget/menu"] = nil
        package.loaded["ui/widget/multiinputdialog"] = nil
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
    end)

    after_each(function()
        package.preload.gettext = nil
        package.preload["ui/widget/menu"] = nil
        package.preload["ui/widget/multiinputdialog"] = nil
        package.preload["ui/uimanager"] = nil
        package.preload["suwayomi/ui/list_menu"] = nil
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
        assert.are.equal("MangaDex", shown_dialog.item_table[1].text)
        assert.are.equal("EN", shown_dialog.item_table[1].subtitle)
        assert.are.equal("18+", shown_dialog.item_table[1].mandatory)
        assert.are.equal("/icons/md.png", shown_dialog.item_table[1].thumbnail_url)
        assert.are.same({ server_url = "http://127.0.0.1:4567" }, shown_dialog.thumbnail_credentials)
        assert.are.equal("ComicK", shown_dialog.item_table[2].text)
        assert.are.equal("JA", shown_dialog.item_table[2].subtitle)
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

    it("shows a source mode menu and hides latest when unsupported", function()
        local browse = require("suwayomi/ui/browse")
        local selected = {}

        browse.showSourceModeMenu({
            id = "s1",
            name = "MangaDex",
            supports_latest = false,
        }, function(mode)
            table.insert(selected, mode)
        end)

        assert.are.equal("MangaDex", shown_dialog.title)
        assert.are.equal("Popular", shown_dialog.item_table[1].text)
        assert.are.equal("Search", shown_dialog.item_table[2].text)
        assert.is_nil(shown_dialog.item_table[3])

        shown_dialog.item_table[1].callback()
        shown_dialog.item_table[2].callback()

        assert.are.same({ "POPULAR", "SEARCH" }, selected)
    end)

    it("shows latest for unknown source support and collects search queries", function()
        local browse = require("suwayomi/ui/browse")
        local selected_mode
        local searched_query
        local global_query

        browse.showSourceModeMenu({
            id = "s1",
            name = "MangaDex",
        }, function(mode)
            selected_mode = mode
        end)

        assert.are.equal("Latest", shown_dialog.item_table[2].text)
        shown_dialog.item_table[2].callback()
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
        assert.are.equal("MangaDex: 1 result", shown_dialog.item_table[1].text)
        assert.are.equal("More Source: 2+ results", shown_dialog.item_table[2].text)
        assert.are.equal("Searching Source: searching", shown_dialog.item_table[3].text)
        assert.are.equal("Slow Source: timed out", shown_dialog.item_table[4].text)
        assert.are.equal("ComicK: No results", shown_dialog.item_table[5].text)
        assert.are.equal("Some Source: Error - Timed out", shown_dialog.item_table[6].text)

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

        assert.are.equal("Local source: searching", shown_dialog.item_table[1].text)

        browse.updateGlobalSearchResultsMenu(shown_dialog, {
            { source = { id = "s1", name = "Local source" }, status = "ok", result_count = 1 },
        }, function(summary)
            table.insert(selected, summary)
        end, {
            on_cancel_search = function()
                canceled = true
            end,
        })

        assert.are.equal("Local source: 1 result", shown_dialog.item_table[1].text)
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
        assert.are.equal("JA", menu.item_table[1].subtitle)
        assert.are.equal("/icons/ck.png", menu.item_table[1].thumbnail_url)
        assert.are.same({ server_url = "http://127.0.0.1:4567" }, menu.updated_options.thumbnail_credentials)

        menu.item_table[1].callback()
        assert.are.equal("s2", selected.id)
    end)

    it("shows compact browse result library status, title, and paging rows", function()
        local browse = require("suwayomi/ui/browse")
        local selected = {}
        local paging = {}

        browse.showMangaMenu({
            { id = "m1", title = "Already Added", in_library = true },
            { id = "m2", title = "New Find", in_library = false },
            { id = "m3", title = "Unknown State" },
        }, function(manga)
            table.insert(selected, manga.id)
        end, {
            title = "MangaDex (EN) - Search: frieren - Page 2",
            on_previous_page = function()
                table.insert(paging, "previous")
            end,
            on_next_page = function()
                table.insert(paging, "next")
            end,
        })

        assert.are.equal("MangaDex (EN) - Search: frieren - Page 2", shown_dialog.title)
        assert.are.equal("list_menu", shown_dialog.renderer)
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
        local menu = {
            title = "MangaDex - Popular - Page 1",
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
            title = "MangaDex - Popular - Page 2",
            title_bar_left_icon = "appbar.menu",
            close_callback = function()
                closed = true
            end,
        })

        assert.are.equal("MangaDex - Popular - Page 2", menu.title)
        assert.are.equal("list_menu", menu.renderer)
        assert.are.same({ title = "MangaDex - Popular - Page 2", refresh = true }, title_bar_title)
        assert.are.equal("appbar.menu", left_icon)
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
        assert.are.equal("Default (2)", shown_dialog.item_table[1].text)
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
