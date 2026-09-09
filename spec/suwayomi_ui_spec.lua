package.path = "?.lua;" .. package.path

local Marker = require("spec/support/i18n_marker")

describe("suwayomi/ui", function()
    local shown_dialog
    local closed_dialog
    local events
    local record_next_tick
    local run_close_callback_on_close
    local dialog_fields
    local screen_width
    local screen_height

    before_each(function()
        shown_dialog = nil
        closed_dialog = nil
        events = {}
        record_next_tick = false
        run_close_callback_on_close = false
        screen_width = 600
        screen_height = 900
        dialog_fields = {
            "https://suwayomi.example",
            "alice",
            "secret",
        }

        package.loaded["suwayomi/ui"] = nil
        package.loaded["suwayomi/i18n"] = nil
        package.loaded["suwayomi/settings/retention_labels"] = nil
        package.loaded["suwayomi/ui/browse"] = nil
        package.loaded["suwayomi/ui/choice_dialogs"] = nil
        package.loaded["suwayomi/ui/directory"] = nil
        package.loaded["suwayomi/ui/downloads"] = nil
        package.loaded["suwayomi/ui/list_menu"] = nil
        package.loaded["suwayomi/ui/menu_utils"] = nil
        package.loaded["suwayomi/ui/manga_info"] = nil
        package.loaded["suwayomi/subprocess/job"] = nil
        package.loaded["suwayomi/ui/thumbnail_worker"] = nil
        package.loaded["ffi/util"] = nil
        package.loaded.gettext = nil
        package.loaded["ui/widget/buttontable"] = nil
        package.loaded["ui/widget/menu"] = nil
        package.loaded["ui/widget/buttondialog"] = nil
        package.loaded["ui/widget/confirmbox"] = nil
        package.loaded["ui/widget/multiinputdialog"] = nil
        package.loaded["ui/widget/textviewer"] = nil
        package.loaded["ui/widget/titlebar"] = nil
        package.loaded["ui/widget/container/centercontainer"] = nil
        package.loaded["ui/widget/container/framecontainer"] = nil
        package.loaded["ui/widget/container/inputcontainer"] = nil
        package.loaded["ui/widget/container/movablecontainer"] = nil
        package.loaded["ui/widget/container/scrollablecontainer"] = nil
        package.loaded["ui/widget/container/widgetcontainer"] = nil
        package.loaded["ui/widget/horizontalgroup"] = nil
        package.loaded["ui/widget/horizontalspan"] = nil
        package.loaded["ui/widget/htmlboxwidget"] = nil
        package.loaded["ui/widget/imagewidget"] = nil
        package.loaded["ui/widget/linewidget"] = nil
        package.loaded["ui/widget/scrollhtmlwidget"] = nil
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
        package.preload["suwayomi/i18n"] = nil

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

        package.preload["ui/widget/buttontable"] = function()
            return {
                new = function(_, options)
                    options = options or {}
                    options.kind = "buttontable"
                    options.getSize = function()
                        return { w = options.width or 0, h = 52 }
                    end
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
                    options.renderer = "textviewer"
                    return options
                end,
            }
        end

        package.preload["ui/widget/titlebar"] = function()
            return {
                new = function(_, options)
                    options = options or {}
                    options.kind = "titlebar"
                    options.getHeight = function()
                        return 50
                    end
                    options.getSize = function()
                        return { w = options.width or 0, h = 50 }
                    end
                    return options
                end,
            }
        end

        package.preload.device = function()
            return {
                screen = {
                    getWidth = function()
                        return screen_width
                    end,
                    getHeight = function()
                        return screen_height
                    end,
                    scaleBySize = function(_, value)
                        return value
                    end,
                },
                openLink = function(_, link)
                    events.opened_link = link
                end,
                canOpenLink = function()
                    return true
                end,
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
                line = { thick = 3 },
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

        package.preload["ui/widget/container/inputcontainer"] = function()
            local InputContainer = {}
            function InputContainer:extend(definition)
                definition.__index = definition
                function definition:new(options)
                    options = options or {}
                    setmetatable(options, definition)
                    if options.init then
                        options:init()
                    end
                    return options
                end
                return definition
            end
            return InputContainer
        end

        package.preload["ui/widget/container/movablecontainer"] = function()
            return widgetFactory("movablecontainer")
        end

        package.preload["ui/widget/container/scrollablecontainer"] = function()
            return widgetFactory("scrollablecontainer")
        end

        package.preload["ui/widget/container/widgetcontainer"] = function()
            return widgetFactory("widgetcontainer")
        end

        package.preload["ui/widget/horizontalgroup"] = function()
            return widgetFactory("horizontalgroup")
        end

        package.preload["ui/widget/horizontalspan"] = function()
            return widgetFactory("horizontalspan")
        end

        package.preload["ui/widget/htmlboxwidget"] = function()
            local HtmlBoxWidget = widgetFactory("htmlboxwidget")
            local new = HtmlBoxWidget.new
            function HtmlBoxWidget.new(_, options)
                options = new(HtmlBoxWidget, options)
                options.setContent = function(self, html_body, css, default_font_size)
                    self.html_body = html_body
                    self.css = css
                    self.default_font_size = default_font_size
                    self.single_page_height = (select(2, tostring(html_body):gsub("<p>", "<p>"))
                        + select(2, tostring(html_body):gsub("<li>", "<li>"))) * 32
                end
                options.getSinglePageHeight = function(self)
                    return self.single_page_height or self.height or (self.dimen and self.dimen.h) or 0
                end
                return options
            end
            return HtmlBoxWidget
        end

        package.preload["ui/widget/imagewidget"] = function()
            return widgetFactory("imagewidget")
        end

        package.preload["ui/widget/linewidget"] = function()
            return widgetFactory("linewidget")
        end

        package.preload["ui/widget/scrollhtmlwidget"] = function()
            return widgetFactory("scrollhtmlwidget")
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
                find = function(credentials, thumbnail_url, options)
                    if thumbnail_url == "thumb://cached" or (thumbnail_url == "thumb://missing" and events.poster_cache_ready) then
                        events.thumbnail_lookup = {
                            credentials = credentials,
                            thumbnail_url = thumbnail_url,
                            options = options,
                        }
                        return "/tmp/poster.bb"
                    end
                    events.thumbnail_lookup = {
                        credentials = credentials,
                        thumbnail_url = thumbnail_url,
                        options = options,
                    }
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

        package.preload["suwayomi/subprocess/job"] = function()
            return {
                buildResultPath = function(prefix)
                    return "/tmp/" .. tostring(prefix) .. ".json"
                end,
                start = function(options)
                    events.poster_job_starts = (events.poster_job_starts or 0) + 1
                    events.poster_job = options
                    if options.run then
                        options.run(options.active.result_path)
                    end
                    return options.active
                end,
                cancel = function(active)
                    events.canceled_poster_job = active
                end,
            }
        end

        package.preload["suwayomi/ui/thumbnail_worker"] = function()
            return {
                run = function(_, credentials, thumbnail_url, result_path, options)
                    events.poster_worker_run = {
                        credentials = credentials,
                        thumbnail_url = thumbnail_url,
                        result_path = result_path,
                        options = options,
                    }
                    return {
                        ok = true,
                        path = "/tmp/poster.bb",
                    }
                end,
                readResult = function()
                    return {
                        ok = true,
                        path = "/tmp/poster.bb",
                    }
                end,
            }
        end

        package.preload["ffi/util"] = function()
            return {
                runInSubProcess = function(callback)
                    if callback then
                        callback()
                    end
                    return 1234
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
                setDirty = function(_, widget, callback)
                    events.dirty_widget = widget
                    if type(callback) == "function" then
                        local mode, region = callback()
                        events.dirty_mode = mode
                        events.dirty_region = region
                    else
                        events.dirty_mode = callback
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

    it("shows the complete download error in a text viewer through the public facade", function()
        Marker.install()
        local ui = require("suwayomi/ui")
        local error_message = string.rep("First line of error\nNext line of error\n", 200) .. "last detail"

        assert.is_function(ui.showDownloadErrorDetails)
        local viewer = ui.showDownloadErrorDetails({ progress = { error = error_message } }, { context = "Manga / Chapter" })

        assert.are.equal(viewer, shown_dialog)
        assert.are.equal("textviewer", viewer.renderer)
        assert.are.equal("tx:Error details", viewer.title)
        assert.are.equal("Manga / Chapter\n\n" .. error_message, viewer.text)
        assert.are.equal("tx:Retry", viewer.buttons_table[1][1].text)
        assert.are.equal("tx:Close", viewer.buttons_table[1][2].text)
    end)

    it("updates the Downloads home button in place and preserves its callback", function()
        local ui = require("suwayomi/ui")
        local selected = false
        local closed = false
        local dialog = ui.showHomeDialog({
            actions = {{ id = "downloads", text = "Downloads", callback = function() selected = true end }},
            onClose = function() closed = true end,
        })
        local button = dialog.buttons[1][1]
        assert.are.equal("downloads", button.id)
        button.width = 400
        function button:setText(text, width)
            assert.are.equal(400, width)
            self.text = text
        end
        function dialog:getButtonById(id)
            if button.id == id then return button end
        end
        assert.is_true(ui.updateHomeDownloadsLabel(dialog, "Downloads · 3 failed"))
        assert.are.equal("Downloads · 3 failed", button.text)
        assert.are.equal(dialog, events.dirty_widget)
        assert.are.equal("ui", events.dirty_mode)
        assert.are.equal(dialog, shown_dialog)
        button.callback()
        assert.is_true(selected)
        assert.is_true(closed)
        assert.are.equal(dialog, closed_dialog)
        assert.is_function(dialog.tap_close_callback)
    end)

    after_each(function()
        Marker.uninstall()
    end)

    after_each(function()
        package.loaded["suwayomi/i18n"] = nil
        package.loaded["suwayomi/settings/retention_labels"] = nil
        package.loaded["suwayomi/ui/choice_dialogs"] = nil
        package.preload.gettext = nil
        package.preload["suwayomi/i18n"] = nil
        package.preload["ui/widget/menu"] = nil
        package.preload["ui/widget/buttondialog"] = nil
        package.preload["ui/widget/confirmbox"] = nil
        package.preload["ui/widget/multiinputdialog"] = nil
        package.preload["ui/widget/container/centercontainer"] = nil
        package.preload["ui/widget/container/framecontainer"] = nil
        package.preload["ui/widget/container/scrollablecontainer"] = nil
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
        package.preload["suwayomi/subprocess/job"] = nil
        package.preload["suwayomi/ui/thumbnail_worker"] = nil
        package.preload["ffi/util"] = nil
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

    local function setScreenDimensions(width, height)
        screen_width = width
        screen_height = height
    end

    it("preserves facade access to browse menus", function()
        local ui = require("suwayomi/ui")
        local selected

        assert.is_function(ui.showSourceFilterEditor)
        assert.is_function(ui.showSavedFiltersMenu)
        assert.is_function(ui.showSavedFilterNamePrompt)
        assert.is_function(ui.showDeleteSavedFilterConfirm)
        assert.is_function(ui.showOverwriteSavedFilterConfirm)
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
            status = "COMPLETED",
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
            "Status: Completed",
            "Author: Author One, Author Two",
            "Artist: Artist One",
            "Chapters: 12",
            "Unread: 4",
            "Downloaded: 2",
            "Library: Not in library",
            "Categories: Reading, 2",
            "Genres: Action, Mystery",
            "First unread: Chapter 5",
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

    local function countWidgets(widget, kind)
        if widget == nil then
            return 0
        end
        local count = widget.kind == kind and 1 or 0
        for _, child in ipairs(widget) do
            count = count + countWidgets(child, kind)
        end
        return count
    end

    local function sampleManga()
        return {
            id = 42,
            title = "Manga Title",
            source = { displayName = "Source A" },
            author = "Writer",
            artist = "Artist",
            status = "ONGOING",
            chapter_count = 120,
            unread_count = 12,
            download_count = 4,
            in_library = true,
            categories = { "Reading", "Favorites" },
            genres = { "Action", "Mystery" },
            first_unread_chapter = { name = "Chapter 5" },
            latest_fetched_chapter = { name = "Chapter 8" },
            description = "Synopsis with [Site](https://example.invalid).",
            thumbnail_url = "thumb://cached",
        }
    end

    it("shows manga information in a framed poster dialog", function()
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
            actions = {
                { id = "open_chapters", text = "Open chapters" },
                { id = "open_first_unread", text = "Open next unread" },
            },
            onAction = function(action)
                events.selected_manga_info_action = action
            end,
        })

        assert.are.equal(dialog, shown_dialog)
        assert.is_nil(dialog.title)
        assert.is_true(dialog.width > 0)
        assert.are.equal("thumb://cached", events.thumbnail_lookup.thumbnail_url)
        assert.are.equal(credentials, events.thumbnail_lookup.credentials)
        assert.are.same({
            variant = "poster",
            width = 240,
            height = 360,
        }, events.thumbnail_lookup.options)

        local title = findWidget(dialog, "titlebar")
        local title_separator = findWidget(dialog, "linewidget")
        local buttons = findWidget(dialog, "buttontable")
        assert.are.equal("Manga Title", title.title)
        assert.are.equal("tfont", title.title_face.name)
        assert.is_false(title.with_bottom_line)
        assert.are.equal(3, title_separator.dimen.h)
        assert.are.equal(dialog.width, title_separator.dimen.w)
        assert.are.equal("Open chapters", buttons.buttons[1][1].text)
        assert.are.equal("Open next unread", buttons.buttons[1][2].text)
        assert.is_nil(buttons.buttons[2])

        local image = findWidget(dialog, "imagewidget")
        local metadata = findWidget(dialog, "textboxwidget")
        local description = findWidget(dialog, "scrollhtmlwidget")
        assert.is_not_nil(description)
        assert.is_true(description.width < dialog.width)
        assert.is_not_nil(metadata)
        assert.is_nil(metadata.text:match("Genres:"))
        assert.are.same({ decoded = true }, image.image)
        assert.are.equal(0, image.scale_factor)
        assert.is_true(image.width > 0)
        assert.is_true(image.height > image.width)
        assert.are.equal("<p>Synopsis</p>", description.html_body)
        assert.is_not_nil(description.css)
        assert.matches("@page%s*{[^}]*margin:%s*0", description.css)
        assert.matches("margin:%s*0", description.css)
        assert.matches("font%-family:%s*'Noto Sans'", description.css)
        assert.is_true(description.default_font_size >= 28)
        assert.is_true(description.height >= 300)
        assert.are.equal(dialog, description.dialog)

        title.close_callback()
        assert.are.equal(dialog, closed_dialog)

        closed_dialog = nil
        buttons.buttons[1][1].callback()

        assert.are.equal(dialog, closed_dialog)
        assert.are.equal("open_chapters", events.selected_manga_info_action.id)
    end)

    it("shows manga information with a loading poster while the poster worker runs", function()
        local ui = require("suwayomi/ui")

        local dialog = ui.showMangaInformation({
            id = 42,
            title = "Manga Title",
            description = "",
            thumbnail_url = "thumb://missing",
            thumbnail_path = "/tmp/row-thumb.bb",
        }, {
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
        })

        local poster_text = findWidget(dialog, "textwidget")
        local description = findWidget(dialog, "scrollhtmlwidget")
        local title = findWidget(dialog, "titlebar")
        assert.is_not_nil(description)
        assert.are.equal("Loading...", poster_text.text)
        assert.are.equal("<p>No description available.</p>", description.html_body)
        assert.are.equal("thumb://missing", events.poster_worker_run.thumbnail_url)
        assert.are.equal("/tmp/manga_info_poster.json", events.poster_worker_run.result_path)
        assert.are.same({
            variant = "poster",
            width = 240,
            height = 360,
        }, events.poster_worker_run.options)
        assert.is_nil(findWidget(dialog, "imagewidget"))
        assert.is_nil(events.canceled_poster_job)
        events.poster_cache_ready = true
        events.poster_job.on_finish(events.poster_job.active, {
            ok = true,
            path = "/tmp/poster.bb",
        })

        local refreshed_image = findWidget(dialog, "imagewidget")
        local refreshed_description = findWidget(dialog, "scrollhtmlwidget")
        assert.are.same({ decoded = true }, refreshed_image.image)
        assert.are.equal(dialog, refreshed_description.dialog)

        events.poster_job.active.pid = 1234
        dialog.poster_job = events.poster_job.active
        title.close_callback()
        assert.are.equal(events.poster_job.active, events.canceled_poster_job)
    end)

    it("routes manga information chrome through i18n while keeping metadata raw", function()
        Marker.install()
        package.loaded["suwayomi/ui"] = nil
        package.loaded["suwayomi/ui/manga_info"] = nil
        package.loaded["suwayomi/i18n"] = nil
        local ui = require("suwayomi/ui")

        local manga = {
            id = "m1",
            title = "Sousou no Frieren",
            source = { name = "MangaDex" },
            status = "ONGOING",
            authors = { "Kanehito Yamada" },
            artists = { "Tsukasa Abe" },
            chapter_count = 128,
            unread_count = 7,
            download_count = 3,
            in_library = true,
            categories = { "Reading" },
            genres = { "Adventure" },
            first_unread_chapter = { name = "Chapter 118" },
            description = "",
        }

        local dialog = ui.showMangaInformation(manga, {
            poster_loading = true,
            actions = {
                { id = "open_chapters", text = "tx:Open chapters" },
            },
        })
        local text = ui.buildMangaInformationText(manga)

        assert.truthy(text:find("tx:Source: MangaDex", 1, true))
        assert.truthy(text:find("tx:Status: tx:Ongoing", 1, true))
        assert.truthy(text:find("tx:Author: Kanehito Yamada", 1, true))
        assert.truthy(text:find("tx:Library: tx:In library", 1, true))
        assert.truthy(text:find("tx:No description available.", 1, true))
        assert.are.equal("Sousou no Frieren", findWidget(dialog, "titlebar").title)
        assert.are.equal("tx:Open chapters", findWidget(dialog, "buttontable").buttons[1][1].text)
    end)

    it("routes additional manga status labels through i18n while keeping metadata raw", function()
        Marker.install()
        package.loaded["suwayomi/ui"] = nil
        package.loaded["suwayomi/ui/manga_info"] = nil
        package.loaded["suwayomi/i18n"] = nil
        local ui = require("suwayomi/ui")

        local text = ui.buildMangaInformationText({
            source = { name = "MangaDex" },
            status = "ON_HIATUS",
            description = "",
        })
        local raw_text = ui.buildMangaInformationText({
            source = { name = "MangaDex" },
            status = "LICENSED_PLUS",
            description = "",
        })

        assert.truthy(text:find("tx:Status: tx:On hiatus", 1, true))
        assert.truthy(text:find("tx:Source: MangaDex", 1, true))
        assert.truthy(raw_text:find("tx:Status: LICENSED_PLUS", 1, true))
    end)

    it("routes manga poster placeholders and default title through i18n", function()
        Marker.install()
        package.loaded["suwayomi/ui"] = nil
        package.loaded["suwayomi/ui/manga_info"] = nil
        package.loaded["suwayomi/i18n"] = nil
        local ui = require("suwayomi/ui")

        local raw_id_dialog = ui.showMangaInformation({
            id = "m1",
            title = nil,
            description = "",
            thumbnail_url = "thumb://missing",
        }, {
            poster_loading = true,
        })
        assert.are.equal("tx:Loading...", findWidget(raw_id_dialog, "textwidget").text)
        assert.are.equal("m1", findWidget(raw_id_dialog, "titlebar").title)

        package.loaded["suwayomi/ui"] = nil
        package.loaded["suwayomi/ui/manga_info"] = nil
        package.loaded["suwayomi/i18n"] = nil
        ui = require("suwayomi/ui")

        local loading_dialog = ui.showMangaInformation({
            id = "",
            title = "",
            description = "",
            thumbnail_url = "thumb://missing",
        }, {
            poster_loading = true,
        })
        assert.are.equal("tx:Loading...", findWidget(loading_dialog, "textwidget").text)
        assert.are.equal("tx:Manga information", findWidget(loading_dialog, "titlebar").title)

        package.loaded["suwayomi/ui"] = nil
        package.loaded["suwayomi/ui/manga_info"] = nil
        package.loaded["suwayomi/i18n"] = nil
        ui = require("suwayomi/ui")

        local no_poster_dialog = ui.showMangaInformation({
            id = "",
            title = "",
            description = "",
        }, {})
        assert.are.equal("tx:No poster", findWidget(no_poster_dialog, "textwidget").text)
        assert.are.equal("tx:Manga information", findWidget(no_poster_dialog, "titlebar").title)
    end)

    it("shows manga information without a poster when there is no thumbnail URL", function()
        local ui = require("suwayomi/ui")

        local dialog = ui.showMangaInformation({
            id = 42,
            title = "Manga Title",
            description = "",
        }, {
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
        })

        local poster_text = findWidget(dialog, "textwidget")
        assert.are.equal("No poster", poster_text.text)
        assert.is_nil(events.poster_worker_run)
    end)

    it("adapts manga information layout across screen shapes", function()
        local cases = {
            { name = "small landscape", width = 640, height = 360, mode = "stacked", bucket = { width = 160, height = 240 } },
            { name = "very small landscape", width = 480, height = 320, mode = "stacked", bucket = { width = 160, height = 240 } },
            { name = "phone portrait", width = 360, height = 640, mode = "stacked", bucket = { width = 160, height = 240 } },
            { name = "e-reader portrait", width = 758, height = 1024, mode = "split", bucket = { width = 240, height = 360 } },
            { name = "large display", width = 1200, height = 1600, mode = "split", bucket = { width = 320, height = 480 } },
        }

        for _, case in ipairs(cases) do
            package.loaded["suwayomi/ui"] = nil
            package.loaded["suwayomi/ui/manga_info"] = nil
            events = {}
            setScreenDimensions(case.width, case.height)
            local ui = require("suwayomi/ui")

            local dialog = ui.showMangaInformation(sampleManga(), {
                thumbnail_credentials = { server_url = "https://suwayomi.example" },
            })
            local layout = dialog.content_layout
            local description_kind = case.mode == "stacked" and "htmlboxwidget" or "scrollhtmlwidget"
            local description = findWidget(dialog, description_kind)
            local poster = findWidget(dialog, "imagewidget")

            assert.are.equal(case.mode, layout.mode, case.name)
            assert.is_true(dialog.width <= case.width, case.name)
            assert.is_true(dialog.height <= case.height, case.name)
            assert.is_true(layout.body_width > 0, case.name)
            assert.is_true(layout.body_height > 0, case.name)
            assert.is_true(layout.poster_width > 0, case.name)
            assert.is_true(layout.poster_height > 0, case.name)
            assert.is_true(layout.metadata_width > 0, case.name)
            assert.is_true(layout.metadata_height > 0, case.name)
            assert.is_true(layout.description_width > 0, case.name)
            assert.is_true(layout.description_height > 0, case.name)
            assert.are.equal(layout.poster_width, poster.width, case.name)
            assert.are.equal(layout.poster_height, poster.height, case.name)
            assert.are.equal(layout.description_width, description.width, case.name)
            assert.are.equal(layout.description_height, description.height, case.name)
            assert.are.equal(dialog, description.dialog, case.name)
            assert.are.same({
                variant = "poster",
                width = case.bucket.width,
                height = case.bucket.height,
            }, events.thumbnail_lookup.options, case.name)

            if case.mode == "stacked" then
                assert.are.equal("body", layout.scroll_mode, case.name)
                assert.is_not_nil(findWidget(dialog, "scrollablecontainer"), case.name)
                assert.is_nil(findWidget(dialog, "scrollhtmlwidget"), case.name)
                assert.are.equal(1, countWidgets(dialog, "scrollablecontainer"), case.name)
                assert.is_not_nil(findWidget(dialog, "textboxwidget"), case.name)
            else
                assert.are.equal("description", layout.scroll_mode, case.name)
                assert.is_not_nil(findWidget(dialog, "horizontalgroup"), case.name)
            end
        end
    end)

    it("keeps e-reader manga information poster placement stable with long metadata", function()
        setScreenDimensions(758, 1024)
        local ui = require("suwayomi/ui")
        local manga = sampleManga()
        manga.genres = {
            "Action Mystery Drama Historical Supernatural Psychological Adventure Slice of Life",
            "Another Very Long Genre Label That Wraps Across Several Lines On Ereader Screens",
            "**Bold**",
            "[Label](https://example.invalid)",
            "https://example.invalid/raw",
        }

        local dialog = ui.showMangaInformation(manga, {
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
        })

        assert.are.equal("split", dialog.content_layout.mode)
        assert.are.equal("description", dialog.content_layout.scroll_mode)
        assert.is_not_nil(findWidget(dialog, "horizontalgroup"))
        assert.is_nil(findWidget(dialog, "scrollablecontainer"))

        local metadata = findWidget(dialog, "textboxwidget")
        local description = findWidget(dialog, "scrollhtmlwidget")
        assert.is_not_nil(metadata)
        assert.is_not_nil(description)
        assert.is_nil(metadata.text:match("Genres:"))
        assert.matches("<h3>Details</h3>", description.html_body)
        assert.matches("Genres: Action Mystery Drama Historical", description.html_body)
        assert.is_not_nil(description.html_body:match("%*%*Bold%*%*"))
        assert.is_not_nil(description.html_body:match("%[Label%]%(https://example%.invalid%)"))
        assert.is_not_nil(description.html_body:match("https://example%.invalid/raw"))
        assert.is_nil(description.html_body:match("<strong>Bold</strong>"))
        assert.is_nil(description.html_body:match("<a href=\"https://example%.invalid/raw\""))
    end)

    it("uses stacked manga information layout when primary metadata would clip", function()
        setScreenDimensions(758, 1024)
        local ui = require("suwayomi/ui")
        local manga = sampleManga()
        manga.author = table.concat({
            "Very Long Author Name With Many Words",
            "Another Very Long Author Name With Many Words",
            "Third Very Long Author Name With Many Words",
            "Fourth Very Long Author Name With Many Words",
            "Fifth Very Long Author Name With Many Words",
            "Sixth Very Long Author Name With Many Words",
        }, ", ")

        local dialog = ui.showMangaInformation(manga, {
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
        })

        assert.are.equal("stacked", dialog.content_layout.mode)
        assert.are.equal("body", dialog.content_layout.scroll_mode)
    end)

    it("gives stacked manga information descriptions useful space", function()
        setScreenDimensions(360, 640)
        local ui = require("suwayomi/ui")

        local manga = sampleManga()
        manga.description = table.concat({
            "First paragraph.",
            "Second paragraph.",
            "Third paragraph.",
            "Fourth paragraph.",
            "Fifth paragraph.",
            "Sixth paragraph.",
        }, "\n")

        local dialog = ui.showMangaInformation(manga, {
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
        })
        local description = findWidget(dialog, "htmlboxwidget")

        assert.are.equal("stacked", dialog.content_layout.mode)
        assert.is_true(dialog.content_layout.description_height >= 120)
        assert.is_not_nil(description)
        assert.is_true(description.height > dialog.content_layout.description_height)
        assert.is_nil(findWidget(dialog, "scrollhtmlwidget"))
    end)

    it("recomputes manga information layout after screen dimensions change", function()
        setScreenDimensions(640, 360)
        local ui = require("suwayomi/ui")
        local manga = sampleManga()
        manga.thumbnail_url = "thumb://missing"
        local dialog = ui.showMangaInformation(manga, {
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
        })

        assert.are.equal("stacked", dialog.content_layout.mode)
        local old_width = dialog.width
        assert.are.equal(1, events.poster_job_starts)

        setScreenDimensions(758, 1024)
        dialog:onSetDimensions()

        assert.are.equal("split", dialog.content_layout.mode)
        assert.is_true(dialog.width > old_width)
        assert.are.equal(758, dialog.region.w)
        assert.are.equal(1024, dialog.region.h)
        assert.are.equal(dialog, events.dirty_widget)
        assert.are.equal("ui", events.dirty_mode)
        assert.are.equal(758, events.dirty_region.w)
        assert.are.equal(1024, events.dirty_region.h)
        assert.are.equal(1, events.poster_job_starts)
    end)

    it("formats manga information description markup and opens links", function()
        local ui = require("suwayomi/ui")

        local dialog = ui.showMangaInformation({
            title = "Manga Title",
            description = table.concat({
                "# Heading",
                "Line one<br><br><i>Italic</i> and <b>bold</b>",
                "**Strong** and _emphasis_",
                "- First item",
                "- Second [Site](https://example.invalid/path?one=1&two=2)",
                "Bare https://example.invalid/bare?x=1&y=2",
                "2 < 3 and <unknown>tag</unknown>",
                "[Site](https://example.invalid/path?one=1&two=2)",
                "<a href=\"javascript:alert(1)\">Bad JS</a>",
                "<a href='data:text/html,boom'>Bad data</a>",
                "<script>alert('x')</script><img src='x'>",
            }, "\n"),
        })

        local description = findWidget(dialog, "scrollhtmlwidget")
        assert.is_not_nil(description)
        assert.are.equal(table.concat({
            "<h3>Heading</h3>",
            "<p>Line one<br/><br/><i>Italic</i> and <b>bold</b></p>",
            "<p><strong>Strong</strong> and <em>emphasis</em></p>",
            "<ul><li>First item</li><li>Second <a href=\"https://example.invalid/path?one=1&amp;two=2\">Site</a></li></ul>",
            "<p>Bare <a href=\"https://example.invalid/bare?x=1&amp;y=2\">https://example.invalid/bare?x=1&amp;y=2</a></p>",
            "<p>2 &lt; 3 and &lt;unknown&gt;tag&lt;/unknown&gt;</p>",
            "<p><a href=\"https://example.invalid/path?one=1&amp;two=2\">Site</a></p>",
            "<p>Bad JS</p>",
            "<p>Bad data</p>",
            "<p>&lt;img src='x'&gt;</p>",
        }), description.html_body)

        description.html_link_tapped_callback({ uri = "https://example.invalid/path" })

        assert.are.equal("https://example.invalid/path", events.opened_link)
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

    it("routes login dialog labels through i18n", function()
        Marker.install()
        local ui = require("suwayomi/ui")

        ui.showLoginDialog({
            credentials = {
                server_url = "https://saved.example",
                username = "saved-user",
                password = "saved-pass",
            },
        })

        assert.are.equal("tx:Suwayomi login", shown_dialog.title)
        assert.are.equal("tx:Server URL", shown_dialog.fields[1].hint)
        assert.are.equal("https://saved.example", shown_dialog.fields[1].text)
        assert.are.equal("tx:Username", shown_dialog.fields[2].hint)
        assert.are.equal("saved-user", shown_dialog.fields[2].text)
        assert.are.equal("tx:Password", shown_dialog.fields[3].hint)
        assert.are.equal("saved-pass", shown_dialog.fields[3].text)
        assert.are.equal("tx:Cancel", shown_dialog.buttons[1][1].text)
        assert.are.equal("tx:Save", shown_dialog.buttons[1][2].text)
        assert.are.equal("tx:Authentication: tx:Basic Auth", shown_dialog.buttons[2][1].text)
        shown_dialog.buttons[2][1].callback()
        assert.are.equal("tx:Authentication method", shown_dialog.title)
        assert.are.equal("tx:Basic Auth", shown_dialog.buttons[1][1].text)
        assert.are.equal("tx:Simple Login", shown_dialog.buttons[2][1].text)
    end)

    it("preserves entered login fields across method selection and reopening", function()
        local ui = require("suwayomi/ui")
        local saved_credentials
        ui.showLoginDialog({
            onSave = function(credentials)
                saved_credentials = credentials
            end,
        })
        local login_dialog = shown_dialog
        local entered_fields = { "https://edited.example", "edited-user", "edited-password" }
        dialog_fields = entered_fields
        login_dialog.buttons[2][1].callback()
        local picker = shown_dialog
        assert.is_true(picker.buttons[1][1].checked_func())
        picker.buttons[2][1].callback()
        assert.are.equal(picker, closed_dialog)
        assert.are.same(entered_fields, login_dialog:getFields())
        login_dialog.buttons[1][2].callback()

        assert.are.same({
            server_url = entered_fields[1],
            username = entered_fields[2],
            password = entered_fields[3],
            auth_method = "simple_login",
        }, saved_credentials)
        ui.showLoginDialog({ credentials = saved_credentials })
        shown_dialog.buttons[2][1].callback()
        assert.is_true(shown_dialog.buttons[2][1].checked_func())
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

    it("requires a new onboarding test after changing the authentication method", function()
        local ui = require("suwayomi/ui")
        local passed_method
        local tested_credentials
        local continued_credentials
        local dialog = ui.showOnboardingConnectionDialog({
            onTestConnection = function(credentials)
                tested_credentials = credentials
                passed_method = credentials.auth_method
            end,
            canContinue = function(credentials)
                return credentials.auth_method == passed_method
            end,
            onAuthMethodChanged = function()
                passed_method = nil
            end,
            onContinue = function(credentials)
                continued_credentials = credentials
            end,
        })
        local test_button = dialog.buttons[1][2]
        local continue_button = dialog.buttons[2][1]
        local auth_button = dialog.buttons[3][1]
        test_button.callback()
        ui.updateOnboardingConnectionDialogStatus(dialog, "passed")
        assert.is_true(continue_button.enabled_func())
        auth_button.callback()
        shown_dialog.buttons[2][1].callback()
        assert.is_false(continue_button.enabled_func())
        continue_button.callback()
        assert.is_nil(continued_credentials)

        auth_button.callback()
        shown_dialog.buttons[1][1].callback()
        assert.is_false(continue_button.enabled_func())
        auth_button.callback()
        shown_dialog.buttons[2][1].callback()
        test_button.callback()
        assert.are.same({
            server_url = dialog_fields[1],
            username = dialog_fields[2],
            password = dialog_fields[3],
            auth_method = "simple_login",
        }, tested_credentials)
        assert.is_true(continue_button.enabled_func())
        continue_button.callback()
        assert.are.same(tested_credentials, continued_credentials)
        assert.are.equal(dialog, closed_dialog)
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

    it("routes onboarding connection labels and statuses through i18n", function()
        Marker.install()
        local ui = require("suwayomi/ui")

        ui.showOnboardingConnectionDialog({
            credentials = {
                server_url = "https://saved.example",
                username = "saved-user",
                password = "saved-pass",
            },
            connection_status = "untested",
        })

        assert.are.equal("tx:Suwayomi setup: connection (tx:not tested)", shown_dialog.title)
        assert.are.equal("tx:Server URL", shown_dialog.fields[1].hint)
        assert.are.equal("https://saved.example", shown_dialog.fields[1].text)
        assert.are.equal("tx:Username", shown_dialog.fields[2].hint)
        assert.are.equal("tx:Password", shown_dialog.fields[3].hint)
        assert.are.equal("tx:Cancel", shown_dialog.buttons[1][1].text)
        assert.are.equal("tx:Test connection", shown_dialog.buttons[1][2].text)
        assert.are.equal("tx:Continue", shown_dialog.buttons[2][1].text)
        assert.are.equal("tx:Authentication: tx:Basic Auth", shown_dialog.buttons[3][1].text)

        ui.updateOnboardingConnectionDialogStatus(shown_dialog, "passed")
        assert.are.equal("tx:Suwayomi setup: connection (tx:tested)", shown_dialog.title)
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

    it("shows a generic action menu as single-column actions by default", function()
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
        assert.are.equal("Refresh", shown_dialog.buttons[2][1].text)
        assert.are.equal("Cancel search", shown_dialog.buttons[3][1].text)

        shown_dialog.buttons[1][1].callback()
        shown_dialog.buttons[3][1].callback()

        assert.are.same({
            { id = "home", text = "Suwayomi home" },
            { id = "cancel", text = "Cancel search" },
        }, selected)

        shown_dialog.close_callback()

        assert.is_true(closed)
    end)

    it("routes the default action menu title through i18n", function()
        Marker.install()
        package.loaded.gettext = nil
        package.loaded["suwayomi/ui"] = nil

        local ui = require("suwayomi/ui")

        ui.showActionMenu({
            actions = {
                { id = "home", text = "Suwayomi home" },
            },
        })

        assert.are.equal("tx:Actions", shown_dialog.title)
    end)

    it("routes shared menu default labels through i18n", function()
        Marker.install()

        local ui = require("suwayomi/ui")

        ui.showSettingsMenu({})
        assert.are.equal("tx:Suwayomi Settings", shown_dialog.title)

        ui.showChapterMenu({})
        assert.are.equal("tx:Suwayomi Chapters", shown_dialog.title)

        ui.showLibraryCategoryPickerBehaviorMenu({
            current = "always",
            choices = { "automatic", "always", "never" },
        })
        assert.are.equal("tx:Library category picker", shown_dialog.title)
        assert.are.equal("tx:Automatic", shown_dialog.buttons[1][1].text)
        assert.are.equal("tx:Always ask", shown_dialog.buttons[2][1].text)
    end)

    it("honors explicit action menu columns", function()
        local ui = require("suwayomi/ui")

        ui.showActionMenu({
            title = "Title actions",
            columns = 2,
            actions = {
                { id = "home", text = "Suwayomi home" },
                { id = "refresh", text = "Refresh" },
                { id = "cancel", text = "Cancel search" },
            },
        })

        assert.are.equal("Suwayomi home", shown_dialog.buttons[1][1].text)
        assert.are.equal("Refresh", shown_dialog.buttons[1][2].text)
        assert.are.equal("Cancel search", shown_dialog.buttons[2][1].text)
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
        assert.are.equal("Bulk downloads >", shown_dialog.buttons[2][1].text)

        shown_dialog.buttons[2][1].callback()

        assert.are.equal("bulk_downloads", selected.id)
        assert.are.equal("Bulk downloads", selected.text)
        assert.is_true(selected.submenu)
    end)

    it("shows fresh per-manga download-ahead state when retained menus reopen", function()
        local ui = require("suwayomi/ui")
        package.loaded["suwayomi/manga/action_menu"] = nil
        local actions = require("suwayomi/manga/action_menu")
        local limits = { m1 = 5, m2 = 10 }
        local owner = {
            getMangaKeepNextUnreadDownloadsLimit = function(_, manga)
                return limits[manga.id] or 0
            end,
        }
        local manga = { id = "m1" }
        local retained = actions.buildMainActions(owner, manga)
        local function parentLabel()
            ui.showChapterActionsMenu({ actions = retained })
            for _, row in ipairs(shown_dialog.buttons) do
                if row[1] and row[1].id == "keep_downloaded" then return row[1].text end
            end
        end
        local function selectedChoice(target)
            ui.showMangaActionsMenu({ actions = actions.buildKeepDownloadedActions(owner, target) })
            local selected = {}
            for _, row in ipairs(shown_dialog.buttons) do
                local button = row[1]
                if button and button.checked_func and button.checked_func() then
                    selected[#selected + 1] = button.id
                end
            end
            return selected
        end

        assert.are.equal("Download ahead: 5 >", parentLabel())
        assert.are.same({ "keep_next_5_unread" }, selectedChoice(manga))
        assert.are.same({ "keep_next_10_unread" }, selectedChoice({ id = "m2" }))
        limits.m1 = 50
        assert.are.equal("Download ahead: 50 >", parentLabel())
        assert.are.same({ "keep_next_50_unread" }, selectedChoice(manga))
        limits.m1 = 0
        assert.are.equal("Download ahead: Off >", parentLabel())
        assert.are.same({ "keep_next_0_unread" }, selectedChoice(manga))
        package.loaded["suwayomi/manga/action_menu"] = nil
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

    it("shows the Suwayomi home hub as single-column actions by default", function()
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
        assert.are.equal("Browse", shown_dialog.buttons[2][1].text)
        assert.are.equal("Downloads", shown_dialog.buttons[3][1].text)

        shown_dialog.buttons[2][1].callback()

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
        local tapped = false

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
        }, {
            title_bar_left_icon = "appbar.menu",
            on_title_bar_left_tap = function(menu)
                tapped = menu
            end,
        })

        assert.are.equal("Suwayomi Settings", shown_dialog.title)
        assert.are.equal("list_menu", shown_dialog.renderer)
        assert.are.equal("appbar.menu", shown_dialog.title_bar_left_icon)
        shown_dialog.onLeftButtonTap()
        assert.are.equal(shown_dialog, tapped)
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
        record_next_tick = true

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
        assert.are.equal("left", shown_dialog.buttons[1][1].align)
        assert.is_false(shown_dialog.buttons[1][1].checked_func())
        assert.is_true(shown_dialog.buttons[1][1].no_refresh_checkmark)
        assert.are.equal("2", shown_dialog.buttons[2][1].text)
        assert.is_true(shown_dialog.buttons[2][1].checked_func())
        assert.is_true(shown_dialog.buttons[2][1].no_refresh_checkmark)

        shown_dialog.buttons[1][1].callback()

        assert.are.same({ "next-tick", "close" }, events)
        assert.are.equal(shown_dialog, closed_dialog)
        assert.are.equal(1, selected)
    end)

    it("shows a checklist dialog and toggles selected values", function()
        local ui = require("suwayomi/ui")
        local selected = { en = true }
        local toggles = {}
        local done = false
        local close_count = 0
        record_next_tick = true
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

        assert.are.equal("English", shown_dialog.buttons[1][1].text)
        assert.are.equal("left", shown_dialog.buttons[1][1].align)
        assert.is_true(shown_dialog.buttons[1][1].checked_func())
        assert.is_nil(shown_dialog.buttons[1][1].no_refresh_checkmark)
        assert.are.equal("Japanese", shown_dialog.buttons[2][1].text)
        assert.is_false(shown_dialog.buttons[2][1].checked_func())
        assert.is_nil(shown_dialog.buttons[2][1].no_refresh_checkmark)

        local first_dialog = shown_dialog
        shown_dialog.buttons[2][1].callback()
        assert.are.same({ value = "ja", selected = true }, toggles[1])
        assert.is_nil(closed_dialog)
        assert.are.equal(first_dialog, shown_dialog)
        assert.is_true(shown_dialog.buttons[2][1].checked_func())
        assert.are.equal(0, close_count)

        shown_dialog.buttons[2][1].callback()
        assert.are.same({ value = "ja", selected = false }, toggles[2])
        assert.is_false(shown_dialog.buttons[2][1].checked_func())
        assert.are.equal(0, close_count)

        shown_dialog.buttons[3][1].callback()
        assert.is_true(done)
        assert.are.same({ "next-tick", "close" }, events)
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
        assert.is_false(shown_dialog.buttons[1][1].checked_func())
        assert.are.equal("2", shown_dialog.buttons[2][1].text)
        assert.is_true(shown_dialog.buttons[2][1].checked_func())

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
        assert.is_false(shown_dialog.buttons[1][1].checked_func())
        assert.are.equal("Always ask", shown_dialog.buttons[2][1].text)
        assert.is_true(shown_dialog.buttons[2][1].checked_func())

        shown_dialog.buttons[3][1].callback()

        assert.are.equal("never", selected)
    end)

    it("preserves all six retention choices through repeated picker navigation", function()
        Marker.install()
        local ui = require("suwayomi/ui")
        local current = 0
        local labels = {
            [0] = "tx:Off",
            "tx:Keep 0 newest completions",
            "tx:Keep 1 newest completion",
            "tx:Keep 2 newest completions",
            "tx:Keep 3 newest completions",
            "tx:Keep 4 newest completions",
        }
        for value = 0, 5 do
            ui.showDeleteFinishedWhileReadingMenu({
                current = current,
                onSelect = function(selected) current = selected end,
            })
            for choice = 0, 5 do
                local button = shown_dialog.buttons[choice + 1][1]
                assert.are.equal(labels[choice], button.text)
                assert.are.equal(choice == current, button.checked_func())
            end
            local picker = shown_dialog
            picker.buttons[value + 1][1].callback()
            assert.are.equal(picker, closed_dialog)
            assert.are.equal(value, current)
        end
    end)

    it("routes setup and settings choice dialog labels through i18n", function()
        Marker.install()
        local ui = require("suwayomi/ui")

        ui.showParallelDownloadsMenu({
            current = 2,
            choices = { 1, 2 },
        })
        assert.are.equal("tx:Parallel chapter downloads", shown_dialog.title)
        assert.are.equal("1", shown_dialog.buttons[1][1].text)

        ui.showLibraryCategoryPickerBehaviorMenu({
            current = "always",
            choices = { "automatic", "always", "never" },
        })
        assert.are.equal("tx:Library category picker", shown_dialog.title)
        assert.are.equal("tx:Automatic", shown_dialog.buttons[1][1].text)
        assert.are.equal("tx:Always ask", shown_dialog.buttons[2][1].text)
        assert.are.equal("tx:Never ask", shown_dialog.buttons[3][1].text)

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
        assert.are.equal("English", shown_dialog.buttons[1][1].text)
        assert.is_true(shown_dialog.buttons[1][1].checked_func())
        assert.are.equal("Russian", shown_dialog.buttons[2][1].text)
        assert.is_false(shown_dialog.buttons[2][1].checked_func())

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

        assert.are.equal("English", shown_dialog.buttons[1][1].text)
        assert.is_true(shown_dialog.buttons[1][1].checked_func())
        assert.are.equal("Español", shown_dialog.buttons[2][1].text)
        assert.is_false(shown_dialog.buttons[2][1].checked_func())

        local first_dialog = shown_dialog
        shown_dialog.buttons[2][1].callback()

        assert.are.same({ code = "es", enabled = true }, toggles[1])
        assert.is_nil(closed_dialog)
        assert.are.equal(first_dialog, shown_dialog)
        assert.is_true(shown_dialog.buttons[2][1].checked_func())
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
