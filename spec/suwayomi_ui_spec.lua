package.path = "?.lua;" .. package.path

describe("suwayomi/ui", function()
    local shown_dialog
    local closed_dialog
    local events
    local record_next_tick
    local run_close_callback_on_close
    local dialog_fields

    before_each(function()
        shown_dialog = nil
        closed_dialog = nil
        events = {}
        record_next_tick = false
        run_close_callback_on_close = false
        dialog_fields = {
            "https://suwayomi.example",
            "alice",
            "secret",
        }

        package.loaded["suwayomi/ui"] = nil
        package.loaded["suwayomi/ui/browse"] = nil
        package.loaded["suwayomi/ui/directory"] = nil
        package.loaded["suwayomi/ui/downloads"] = nil
        package.loaded["suwayomi/ui/list_menu"] = nil
        package.loaded["suwayomi/ui/menu_utils"] = nil
        package.loaded["suwayomi/ui/manga_info"] = nil
        package.loaded.gettext = nil
        package.loaded["ui/widget/menu"] = nil
        package.loaded["ui/widget/buttondialog"] = nil
        package.loaded["ui/widget/confirmbox"] = nil
        package.loaded["ui/widget/multiinputdialog"] = nil
        package.loaded["ui/widget/textviewer"] = nil
        package.loaded["ui/widget/titlebar"] = nil
        package.loaded["ui/widget/container/centercontainer"] = nil
        package.loaded["ui/widget/container/framecontainer"] = nil
        package.loaded["ui/widget/horizontalgroup"] = nil
        package.loaded["ui/widget/horizontalspan"] = nil
        package.loaded["ui/widget/imagewidget"] = nil
        package.loaded["ui/widget/scrolltextwidget"] = nil
        package.loaded["ui/widget/textboxwidget"] = nil
        package.loaded["ui/widget/textwidget"] = nil
        package.loaded["ui/widget/verticalgroup"] = nil
        package.loaded["ui/widget/verticalspan"] = nil
        package.loaded["device"] = nil
        package.loaded["ffi/blitbuffer"] = nil
        package.loaded["ui/font"] = nil
        package.loaded["ui/geometry"] = nil
        package.loaded["ui/size"] = nil
        package.loaded["ui/widget/checkmark"] = nil
        package.loaded["ui/widget/radiomark"] = nil
        package.loaded["ui/widget/pathchooser"] = nil
        package.loaded["ui/uimanager"] = nil
        package.loaded["suwayomi/ui/thumbnail_cache"] = nil
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
                        return dialog_fields
                    end
                    options.onShowKeyboard = function() end
                    return options
                end,
            }
        end

        package.preload["ui/widget/textviewer"] = function()
            return {
                new = function(_, options)
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

        package.preload.device = function()
            return {
                screen = {
                    getWidth = function()
                        return 600
                    end,
                    getHeight = function()
                        return 900
                    end,
                    scaleBySize = function(_, value)
                        return value
                    end,
                },
            }
        end

        package.preload["ffi/blitbuffer"] = function()
            return {
                COLOR_BLACK = 0,
                COLOR_WHITE = 1,
                COLOR_LIGHT_GRAY = 2,
            }
        end

        package.preload["ui/font"] = function()
            return {
                getFace = function(_, name, size)
                    return { name = name, size = size }
                end,
            }
        end

        package.preload["ui/geometry"] = function()
            return {
                new = function(_, dimen)
                    return dimen
                end,
            }
        end

        package.preload["ui/size"] = function()
            return {
                border = { thin = 1 },
                padding = { small = 4, default = 8, large = 12 },
                margin = { default = 8 },
            }
        end

        local function widgetFactory(kind)
            return {
                new = function(_, options)
                    options = options or {}
                    options.kind = kind
                    options.getSize = function(self)
                        return {
                            w = self.width or (self.dimen and self.dimen.w) or 0,
                            h = self.height or (self.dimen and self.dimen.h) or 0,
                        }
                    end
                    return options
                end,
            }
        end

        package.preload["ui/widget/container/centercontainer"] = function()
            return widgetFactory("centercontainer")
        end

        package.preload["ui/widget/container/framecontainer"] = function()
            return widgetFactory("framecontainer")
        end

        package.preload["ui/widget/horizontalgroup"] = function()
            return widgetFactory("horizontalgroup")
        end

        package.preload["ui/widget/horizontalspan"] = function()
            return widgetFactory("horizontalspan")
        end

        package.preload["ui/widget/imagewidget"] = function()
            return widgetFactory("imagewidget")
        end

        package.preload["ui/widget/scrolltextwidget"] = function()
            return widgetFactory("scrolltextwidget")
        end

        package.preload["ui/widget/textboxwidget"] = function()
            return widgetFactory("textboxwidget")
        end

        package.preload["ui/widget/textwidget"] = function()
            return widgetFactory("textwidget")
        end

        package.preload["ui/widget/verticalgroup"] = function()
            return widgetFactory("verticalgroup")
        end

        package.preload["ui/widget/verticalspan"] = function()
            return widgetFactory("verticalspan")
        end

        package.preload["suwayomi/ui/thumbnail_cache"] = function()
            return {
                find = function(credentials, thumbnail_url)
                    if thumbnail_url == "thumb://cached" then
                        events.thumbnail_lookup = { credentials = credentials, thumbnail_url = thumbnail_url }
                        return "/tmp/poster.bb"
                    end
                    events.thumbnail_lookup = { credentials = credentials, thumbnail_url = thumbnail_url }
                    return nil
                end,
                isDecodedPath = function(path)
                    return path == "/tmp/poster.bb"
                end,
                loadDecoded = function(path)
                    if path == "/tmp/poster.bb" then
                        return { decoded = true }
                    end
                    return nil
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
                    if run_close_callback_on_close and widget and widget.close_callback then
                        widget.close_callback()
                    end
                end,
                nextTick = function(_, callback)
                    if record_next_tick then
                        table.insert(events, "next-tick")
                    end
                    if callback then
                        callback()
                    end
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
                    if options.items_max_lines == nil then
                        options.items_max_lines = 3
                    end
                    options.fixed_item_heights = options.fixed_item_heights or false
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
        package.preload["ui/widget/container/centercontainer"] = nil
        package.preload["ui/widget/container/framecontainer"] = nil
        package.preload["ui/widget/horizontalgroup"] = nil
        package.preload["ui/widget/horizontalspan"] = nil
        package.preload["ui/widget/imagewidget"] = nil
        package.preload["ui/widget/scrolltextwidget"] = nil
        package.preload["ui/widget/textboxwidget"] = nil
        package.preload["ui/widget/textwidget"] = nil
        package.preload["ui/widget/verticalgroup"] = nil
        package.preload["ui/widget/verticalspan"] = nil
        package.preload["ui/widget/titlebar"] = nil
        package.preload.device = nil
        package.preload["ffi/blitbuffer"] = nil
        package.preload["ui/font"] = nil
        package.preload["ui/geometry"] = nil
        package.preload["ui/size"] = nil
        package.preload["ui/widget/checkmark"] = nil
        package.preload["ui/widget/radiomark"] = nil
        package.preload["ui/widget/pathchooser"] = nil
        package.preload["ui/uimanager"] = nil
        package.preload["suwayomi/ui/thumbnail_cache"] = nil
        package.preload["suwayomi/ui/list_menu"] = nil
        package.preload["suwayomi/ui/manga_menu"] = nil
    end)

    local function assertFileManagerListStyle(menu, expected_items_max_lines, expected_fixed_item_heights)
        assert.is_true(menu.is_borderless)
        assert.is_false(menu.is_popout)
        assert.is_true(menu.title_bar_fm_style)
        assert.are.equal(expected_items_max_lines or 3, menu.items_max_lines)
        assert.are.equal(expected_fixed_item_heights or false, menu.fixed_item_heights)
        assert.is_true(menu.multilines_show_more_text)
        assert.is_nil(menu.items_mandatory_font_size)
    end

    it("preserves facade access to browse menus", function()
        local ui = require("suwayomi/ui")
        local selected

        assert.is_function(ui.showSourceFilterEditor)
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

    it("preserves facade access to extension menus", function()
        local ui = require("suwayomi/ui")

        assert.is_function(ui.showExtensionsMenu)
        assert.is_function(ui.updateExtensionsMenu)
        assert.is_function(ui.showExtensionActionMenu)
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

    it("builds manga information text from available metadata", function()
        local ui = require("suwayomi/ui")

        local text = ui.buildMangaInformationText({
            source = { displayName = "  Source A  " },
            status = "ONGOING",
            authors = {
                { name = "Author One" },
                " Author Two ",
                "",
            },
            artists = {
                { title = "Artist One" },
            },
            chapter_count = 12,
            unread_count = 4,
            download_count = 2,
            in_library = false,
            categories = {
                { name = "Reading" },
                { id = "2" },
            },
            genres = {
                "Action",
                { name = "Mystery" },
            },
            first_unread_chapter = { name = "Chapter 5" },
            latest_fetched_chapter = { name = "Chapter 8" },
            description = "  Plot text.  ",
        })

        assert.are.equal(table.concat({
            "Source: Source A",
            "Status: ONGOING",
            "Author: Author One, Author Two",
            "Artist: Artist One",
            "Chapters: 12",
            "Unread: 4",
            "Downloaded: 2",
            "Library: Not in library",
            "Categories: Reading, 2",
            "Genres: Action, Mystery",
            "First unread: Chapter 5",
            "Latest fetched: Chapter 8",
            "",
            "Plot text.",
        }, "\n"), text)
    end)

    local function findWidget(widget, kind)
        if widget == nil then
            return nil
        end
        if widget.kind == kind then
            return widget
        end
        for _, child in ipairs(widget) do
            local found = findWidget(child, kind)
            if found then
                return found
            end
        end
        return nil
    end

    it("shows manga information in a close-only poster dialog", function()
        local ui = require("suwayomi/ui")
        local credentials = { server_url = "https://suwayomi.example" }

        local dialog = ui.showMangaInformation({
            id = 42,
            title = "Manga Title",
            author = "Writer",
            status = "ONGOING",
            description = "Synopsis",
            thumbnail_url = "thumb://cached",
        }, {
            thumbnail_credentials = credentials,
        })

        assert.are.equal(dialog, shown_dialog)
        assert.are.equal("Manga Title", dialog.title)
        assert.are.equal("Close", dialog.buttons[1][1].text)
        assert.are.equal("thumb://cached", events.thumbnail_lookup.thumbnail_url)
        assert.are.equal(credentials, events.thumbnail_lookup.credentials)

        local content = dialog._added_widgets[1]
        local image = findWidget(content, "imagewidget")
        local description = findWidget(content, "scrolltextwidget")
        assert.are.same({ decoded = true }, image.image)
        assert.are.equal(0, image.scale_factor)
        assert.is_true(image.width > 0)
        assert.is_true(image.height > image.width)
        assert.are.equal("Synopsis", description.text)
        assert.are.equal(dialog, description.dialog)

        dialog.buttons[1][1].callback()

        assert.are.equal(dialog, closed_dialog)
    end)

    it("shows manga information without a cached poster", function()
        local ui = require("suwayomi/ui")

        local dialog = ui.showMangaInformation({
            id = 42,
            title = "Manga Title",
            description = "",
            thumbnail_url = "thumb://missing",
        }, {
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
        })

        local content = dialog._added_widgets[1]
        local poster_text = findWidget(content, "textwidget")
        local description = findWidget(content, "scrolltextwidget")
        assert.are.equal("No poster", poster_text.text)
        assert.are.equal("No description available.", description.text)
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

    it("shows onboarding connection dialog with test and continue actions", function()
        local ui = require("suwayomi/ui")
        local tested_credentials
        local continued_credentials

        ui.showOnboardingConnectionDialog({
            credentials = {
                server_url = "https://saved.example",
                username = "saved-user",
                password = "saved-pass",
            },
            onTestConnection = function(credentials)
                tested_credentials = credentials
            end,
            onContinue = function(credentials)
                continued_credentials = credentials
            end,
        })

        assert.are.equal("Suwayomi setup: connection (not tested)", shown_dialog.title)
        assert.are.equal("Server URL", shown_dialog.fields[1].hint)
        assert.are.equal("https://saved.example", shown_dialog.fields[1].text)
        assert.are.equal("Username", shown_dialog.fields[2].hint)
        assert.are.equal("Password", shown_dialog.fields[3].hint)
        assert.are.equal("Test connection", shown_dialog.buttons[1][2].text)
        assert.are.equal("Continue", shown_dialog.buttons[2][1].text)

        shown_dialog.buttons[1][2].callback()
        shown_dialog.buttons[2][1].callback()

        assert.are.equal("https://suwayomi.example", tested_credentials.server_url)
        assert.are.equal("alice", tested_credentials.username)
        assert.are.equal("secret", tested_credentials.password)
        assert.are.equal("basic_auth", tested_credentials.auth_method)
        assert.are.equal("https://suwayomi.example", continued_credentials.server_url)
        assert.are.equal(shown_dialog, closed_dialog)
    end)

    it("keeps onboarding dialog open when continue validation fails", function()
        local ui = require("suwayomi/ui")

        ui.showOnboardingConnectionDialog({
            credentials = {
                server_url = "https://saved.example",
            },
            onContinue = function()
                return false
            end,
        })

        shown_dialog.buttons[2][1].callback()

        assert.is_nil(closed_dialog)
    end)

    it("disables onboarding continue until current fields match a passed test", function()
        local ui = require("suwayomi/ui")
        local continued_credentials

        ui.showOnboardingConnectionDialog({
            credentials = {
                server_url = "https://saved.example",
            },
            canContinue = function(credentials)
                return credentials.server_url == "https://suwayomi.example"
                    and credentials.username == "alice"
                    and credentials.password == "secret"
            end,
            onContinue = function(credentials)
                continued_credentials = credentials
            end,
        })

        local continue_button = shown_dialog.buttons[2][1]
        assert.are.equal("continue", continue_button.id)
        assert.is_function(continue_button.enabled_func)
        assert.is_true(continue_button.enabled_func())

        dialog_fields = {
            "https://suwayomi.example",
            "alice",
            "changed",
        }

        assert.is_false(continue_button.enabled_func())
        continue_button.callback()

        assert.is_nil(continued_credentials)
        assert.is_nil(closed_dialog)
    end)

    it("keeps onboarding connection test status visible", function()
        local ui = require("suwayomi/ui")

        ui.showOnboardingConnectionDialog({
            credentials = {
                server_url = "https://saved.example",
            },
            connection_status = "testing",
        })

        assert.are.equal("Suwayomi setup: connection (testing...)", shown_dialog.title)

        ui.updateOnboardingConnectionDialogStatus(shown_dialog, "passed")
        assert.are.equal("Suwayomi setup: connection (tested)", shown_dialog.title)

        ui.updateOnboardingConnectionDialogStatus(shown_dialog, "failed")
        assert.are.equal("Suwayomi setup: connection (failed)", shown_dialog.title)
    end)

    it("runs onboarding close callback when setup dialog closes", function()
        local ui = require("suwayomi/ui")
        local close_count = 0

        ui.showOnboardingConnectionDialog({
            onClose = function()
                close_count = close_count + 1
            end,
        })

        shown_dialog.buttons[1][1].callback()
        shown_dialog.close_callback()

        assert.are.equal(shown_dialog, closed_dialog)
        assert.are.equal(1, close_count)
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
        assertFileManagerListStyle(shown_dialog, 3, true)
        assert.are.equal("Chapter 1", shown_dialog.item_table[1].text)
        assert.is_true(shown_dialog.item_table[1].title_bold)
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
        assertFileManagerListStyle(shown_dialog, 3, true)

        shown_dialog.onLeftButtonTap()

        assert.is_true(tapped)
    end)

    it("passes an initial chapter row to the shared list menu", function()
        local ui = require("suwayomi/ui")

        ui.showChapterMenu({
            title = "Sousou no Frieren",
            itemnumber = 2,
            chapters = {
                { id = "c1", name = "Chapter 1" },
                { id = "c2", name = "Chapter 2" },
            },
        })

        assert.are.equal(2, shown_dialog.itemnumber)
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

    it("runs generic action callbacks after the action dialog close tick", function()
        local ui = require("suwayomi/ui")
        record_next_tick = true

        ui.showActionMenu({
            title = "Title actions",
            actions = {
                { id = "home", text = "Suwayomi home" },
            },
        }, function(action)
            table.insert(events, action.id)
        end)

        shown_dialog.buttons[1][1].callback()

        assert.are.same({ "close", "next-tick", "home" }, events)
        assert.are.equal(shown_dialog, closed_dialog)
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
        record_next_tick = true

        ui.showActionMenu({
            title = "Bulk downloads",
            actions = {
                { id = "download_next_5_unread", text = "Download next 5" },
            },
            on_back = function()
                table.insert(events, "back")
            end,
        }, function(action)
            selected = action
        end)

        assert.are.equal("< Back", shown_dialog.buttons[1][1].text)
        assert.are.same({}, shown_dialog.buttons[2])
        assert.are.equal("Download next 5", shown_dialog.buttons[3][1].text)

        shown_dialog.buttons[1][1].callback()

        assert.are.same({ "close", "next-tick", "back" }, events)
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

    it("can leave Suwayomi home open so the action can close the plugin stack", function()
        local ui = require("suwayomi/ui")

        ui.showHomeDialog({
            actions = {
                { id = "close", text = "Close plugin", close_before_select = false },
            },
        }, function(action)
            table.insert(events, action.id)
        end)

        shown_dialog.buttons[1][1].callback()

        assert.are.same({ "close" }, events)
        assert.is_nil(closed_dialog)
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

    it("renders settings root with the shared list menu style", function()
        local ui = require("suwayomi/ui")

        ui.showSettingsMenu({
            {
                text = "Connection",
                sub_item_table = {
                    {
                        text = "Login information",
                        callback = function() end,
                    },
                },
            },
        })

        assert.are.equal("Suwayomi Settings", shown_dialog.title)
        assert.are.equal("list_menu", shown_dialog.renderer)
        assertFileManagerListStyle(shown_dialog)
        assert.are.equal("Connection", shown_dialog.item_table[1].text)
        assert.truthy(shown_dialog.item_table[1].sub_item_table)
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

    it("shows a choice dialog and marks the current value", function()
        local ui = require("suwayomi/ui")
        local selected

        ui.showChoiceDialog({
            title = "Pick count",
            current = 2,
            choices = {
                { value = 1, text = "1" },
                { value = 2, text = "2" },
            },
            onSelect = function(value)
                selected = value
            end,
        })

        assert.are.equal("Pick count", shown_dialog.title)
        assert.are.equal("1", shown_dialog.buttons[1][1].text)
        assert.are.equal("* 2", shown_dialog.buttons[2][1].text)

        shown_dialog.buttons[1][1].callback()

        assert.are.equal(shown_dialog, closed_dialog)
        assert.are.equal(1, selected)
    end)

    it("shows a checklist dialog and toggles selected values", function()
        local ui = require("suwayomi/ui")
        local selected = { en = true }
        local toggles = {}
        local done = false
        local close_count = 0
        run_close_callback_on_close = true

        ui.showChecklistDialog({
            title = "Languages",
            choices = {
                { value = "en", text = "English" },
                { value = "ja", text = "Japanese" },
            },
            isSelected = function(value)
                return selected[value] == true
            end,
            onToggle = function(value, is_selected)
                selected[value] = is_selected
                table.insert(toggles, { value = value, selected = is_selected })
            end,
            onDone = function()
                done = true
            end,
            close_callback = function()
                close_count = close_count + 1
            end,
        })

        assert.are.equal("* English", shown_dialog.buttons[1][1].text)
        assert.are.equal("Japanese", shown_dialog.buttons[2][1].text)

        local first_dialog = shown_dialog
        shown_dialog.buttons[2][1].callback()
        assert.are.same({ value = "ja", selected = true }, toggles[1])
        assert.are.equal(first_dialog, closed_dialog)
        assert.are_not.equal(first_dialog, shown_dialog)
        assert.are.equal("* Japanese", shown_dialog.buttons[2][1].text)
        assert.are.equal(0, close_count)

        local second_dialog = shown_dialog
        shown_dialog.buttons[2][1].callback()
        assert.are.same({ value = "ja", selected = false }, toggles[2])
        assert.are.equal(second_dialog, closed_dialog)
        assert.are_not.equal(second_dialog, shown_dialog)
        assert.are.equal("Japanese", shown_dialog.buttons[2][1].text)
        assert.are.equal(0, close_count)

        shown_dialog.buttons[3][1].callback()
        assert.is_true(done)
        assert.are.equal(shown_dialog, closed_dialog)
        assert.are.equal(1, close_count)
    end)

    it("shows a parallel chapter downloads choice dialog", function()
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
        assert.is_nil(shown_dialog.renderer)
        assert.are.equal("1", shown_dialog.buttons[1][1].text)
        assert.are.equal("* 2", shown_dialog.buttons[2][1].text)

        shown_dialog.buttons[3][1].callback()

        assert.are.equal(3, selected)
        assert.are.equal(shown_dialog, closed_dialog)
    end)

    it("renders library picker behavior as a choice dialog", function()
        local ui = require("suwayomi/ui")
        local selected

        ui.showLibraryCategoryPickerBehaviorMenu({
            current = "always",
            choices = { "automatic", "always", "never" },
            onSelect = function(value)
                selected = value
            end,
        })

        assert.are.equal("Library category picker", shown_dialog.title)
        assert.are.equal("Automatic", shown_dialog.buttons[1][1].text)
        assert.are.equal("* Always ask", shown_dialog.buttons[2][1].text)

        shown_dialog.buttons[3][1].callback()

        assert.are.equal("never", selected)
    end)

    it("renders delete-finished choices as a choice dialog", function()
        local ui = require("suwayomi/ui")
        local selected

        ui.showDeleteFinishedWhileReadingMenu({
            current = 2,
            choices = { 0, 1, 2 },
            onSelect = function(value)
                selected = value
            end,
        })

        assert.are.equal("Delete finished chapters", shown_dialog.title)
        assert.are.equal("Disabled", shown_dialog.buttons[1][1].text)
        assert.are.equal("* Second to last read chapter", shown_dialog.buttons[3][1].text)

        shown_dialog.buttons[2][1].callback()

        assert.are.equal(1, selected)
    end)

    it("shows the language menu as a checklist dialog", function()
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
        assert.is_nil(shown_dialog.renderer)
        assert.are.equal("* English", shown_dialog.buttons[1][1].text)
        assert.are.equal("Russian", shown_dialog.buttons[2][1].text)

        shown_dialog.buttons[3][1].callback()

        assert.are.same({ "close", "summary" }, events)
        assert.are.equal(shown_dialog, closed_dialog)
    end)

    it("refreshes checked language state without running close cleanup", function()
        local ui = require("suwayomi/ui")
        local toggles = {}
        local close_count = 0
        run_close_callback_on_close = true

        ui.showLanguageMenu({
            title = "Source languages",
            languages = {
                { code = "en", label = "English", enabled = true },
                { code = "es", label = "Español", enabled = false },
            },
            onToggle = function(code, enabled)
                table.insert(toggles, { code = code, enabled = enabled })
            end,
            onClose = function()
                close_count = close_count + 1
            end,
        })

        assert.are.equal("* English", shown_dialog.buttons[1][1].text)
        assert.are.equal("Español", shown_dialog.buttons[2][1].text)

        local first_dialog = shown_dialog
        shown_dialog.buttons[2][1].callback()

        assert.are.same({ code = "es", enabled = true }, toggles[1])
        assert.are.equal(first_dialog, closed_dialog)
        assert.are_not.equal(first_dialog, shown_dialog)
        assert.are.equal("* Español", shown_dialog.buttons[2][1].text)
        assert.are.equal(0, close_count)

        shown_dialog.buttons[3][1].callback()

        assert.are.equal(1, close_count)
    end)

    it("keeps updateLanguageMenu compatible as a no-op for checklist dialogs", function()
        local ui = require("suwayomi/ui")
        local menu = { kind = "language-dialog" }

        ui.updateLanguageMenu(menu, {
            languages = {
                { code = "en", label = "EN", enabled = true },
                { code = "ru", label = "RU", enabled = true },
            },
        }, function() end)

        assert.are.same({ kind = "language-dialog" }, menu)
    end)
end)
