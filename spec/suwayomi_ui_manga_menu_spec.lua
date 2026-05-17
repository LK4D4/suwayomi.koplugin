describe("suwayomi/ui/manga_menu", function()
    local shown_menu
    local dirty_count
    local started_jobs
    local canceled_jobs
    local cache_paths
    local decoded_images
    local image_errors

    local function clearModules()
        for _, name in ipairs({
            "suwayomi/ui/manga_menu",
            "suwayomi/ui/list_menu",
            "ui/bidi",
            "ffi/blitbuffer",
            "ui/widget/container/centercontainer",
            "device",
            "ui/font",
            "ui/widget/container/framecontainer",
            "ui/geometry",
            "ui/gesturerange",
            "ui/widget/horizontalgroup",
            "ui/widget/horizontalspan",
            "ui/widget/imagewidget",
            "ui/widget/container/inputcontainer",
            "ui/widget/container/leftcontainer",
            "ui/widget/menu",
            "ui/widget/overlapgroup",
            "ui/widget/container/rightcontainer",
            "ui/size",
            "ui/widget/textboxwidget",
            "ui/widget/textwidget",
            "ui/uimanager",
            "ui/widget/container/underlinecontainer",
            "ui/widget/verticalgroup",
            "ui/widget/verticalspan",
            "ffi/util",
            "suwayomi/subprocess/job",
            "suwayomi/ui/thumbnail_cache",
            "suwayomi/ui/thumbnail_worker",
            "suwayomi/ui/menu_utils",
        }) do
            package.loaded[name] = nil
            package.preload[name] = nil
        end
    end

    local function widgetModule(kind)
        return {
            new = function(_, options)
                options = options or {}
                options.kind = kind
                return options
            end,
        }
    end

    local function newGroup()
        local group = {}
        function group:clear()
            for index = #self, 1, -1 do
                self[index] = nil
            end
        end
        return group
    end

    local function installStubs()
        clearModules()
        shown_menu = nil
        dirty_count = 0
        started_jobs = {}
        canceled_jobs = {}
        cache_paths = {}
        decoded_images = {}
        image_errors = {}

        package.preload["ui/bidi"] = function()
            return { auto = function(text) return text end }
        end
        package.preload["ffi/blitbuffer"] = function()
            return {
                COLOR_BLACK = "black",
                COLOR_DARK_GRAY = "dark_gray",
            }
        end
        package.preload.device = function()
            return {
                screen = {
                    scaleBySize = function(_, value) return value end,
                    getWidth = function() return 480 end,
                    getHeight = function() return 800 end,
                },
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
            local Geom = {}
            function Geom:new(options)
                options = options or {}
                function options:copy()
                    return Geom:new{ x = self.x, y = self.y, w = self.w, h = self.h }
                end
                function options:combine(other)
                    return other or self
                end
                return options
            end
            return Geom
        end
        package.preload["ui/gesturerange"] = function() return widgetModule("gesture_range") end
        package.preload["ui/widget/container/centercontainer"] = function() return widgetModule("center") end
        package.preload["ui/widget/container/framecontainer"] = function() return widgetModule("frame") end
        package.preload["ui/widget/horizontalgroup"] = function() return widgetModule("horizontal_group") end
        package.preload["ui/widget/horizontalspan"] = function() return widgetModule("horizontal_span") end
        package.preload["ui/widget/imagewidget"] = function()
            return {
                new = function(_, options)
                    if image_errors[options and options.file] then
                        error(image_errors[options.file])
                    end
                    options = options or {}
                    options.kind = "image"
                    return options
                end,
            }
        end
        package.preload["ui/widget/container/leftcontainer"] = function() return widgetModule("left") end
        package.preload["ui/widget/overlapgroup"] = function() return widgetModule("overlap") end
        package.preload["ui/widget/container/rightcontainer"] = function() return widgetModule("right") end
        package.preload["ui/widget/container/underlinecontainer"] = function() return widgetModule("underline") end
        package.preload["ui/widget/verticalgroup"] = function() return widgetModule("vertical_group") end
        package.preload["ui/widget/verticalspan"] = function() return widgetModule("vertical_span") end
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
        package.preload["ui/size"] = function()
            return {
                border = { thin = 1 },
                line = { thin = 1 },
                padding = { fullscreen = 4 },
                span = {
                    horizontal_default = 3,
                    horizontal_small = 1,
                    vertical_default = 3,
                },
            }
        end
        package.preload["ui/widget/textboxwidget"] = function()
            return {
                getFontSizeToFitHeight = function(_, height, lines)
                    return math.floor((height or 0) / math.max(lines or 1, 1))
                end,
                new = function(_, options)
                    options = options or {}
                    options.kind = "textbox"
                    local font_size = options.face and options.face.size or 12
                    function options:getSize()
                        local width = options.width or #(options.text or "")
                        local chars_per_line = math.max(1, math.floor(width / math.max(font_size, 1)))
                        local lines = math.max(1, math.ceil(#(options.text or "") / chars_per_line))
                        local height = options.height or lines * font_size
                        return { w = math.min(width, #(options.text or "") * font_size), h = height }
                    end
                    return options
                end,
            }
        end
        package.preload["ui/widget/textwidget"] = function()
            return {
                new = function(_, options)
                    options = options or {}
                    options.kind = "text"
                    local font_size = options.face and options.face.size or 12
                    function options:getSize()
                        return { w = #(options.text or "") * font_size, h = font_size }
                    end
                    function options:getWidth()
                        return self:getSize().w
                    end
                    return options
                end,
            }
        end
        package.preload["ui/uimanager"] = function()
            return {
                show = function(_, menu)
                    shown_menu = menu
                end,
                setDirty = function(_, _, callback)
                    dirty_count = dirty_count + 1
                    if callback then
                        callback()
                    end
                end,
            }
        end
        package.preload["ffi/util"] = function()
            return {
                runInSubProcess = function() return 42 end,
                terminateSubProcess = function() end,
            }
        end
        package.preload["suwayomi/subprocess/job"] = function()
            return {
                buildResultPath = function(prefix)
                    return "/settings/" .. prefix .. ".json"
                end,
                start = function(options)
                    local active = options.active or {}
                    active.on_finish = options.on_finish
                    active.on_timeout = options.on_timeout
                    table.insert(started_jobs, active)
                    return active
                end,
                cancel = function(active)
                    table.insert(canceled_jobs, active)
                    active.canceled = true
                end,
            }
        end
        package.preload["suwayomi/ui/thumbnail_cache"] = function()
            return {
                getKey = function(credentials, thumbnail_url)
                    return (credentials and credentials.server_url or "") .. "|" .. tostring(thumbnail_url)
                end,
                find = function(_, thumbnail_url)
                    return cache_paths[thumbnail_url]
                end,
                isDecodedPath = function(path)
                    return tostring(path or ""):match("%.bb$") ~= nil
                end,
                loadDecoded = function(path)
                    return decoded_images[path]
                end,
            }
        end
        package.preload["suwayomi/ui/thumbnail_worker"] = function()
            return {
                run = function() end,
                readResult = function() end,
            }
        end
        package.preload["suwayomi/ui/menu_utils"] = function()
            return {
                applyNativeTitleBarStyle = function(options) return options end,
                applyTitleBarOptions = function(menu, options)
                    menu.applied_title = options and options.title
                end,
                applyCloseCallback = function(menu, options)
                    menu.close_callback = options and options.close_callback
                end,
            }
        end
        package.preload["ui/widget/menu"] = function()
            local Menu = {}
            function Menu:new(options)
                options = options or {}
                options.page = 1
                options.perpage = options.items_per_page or 10
                options.itemnumber = 1
                options.item_group = newGroup()
                options.inner_dimen = { w = 480, h = 641 }
                options.page_info = {
                    resetLayout = function() end,
                    getSize = function() return { h = 0 } end,
                }
                options.return_button = { resetLayout = function() end }
                options.content_group = { resetLayout = function() end }
                options.item_dimen = {
                    copy = function()
                        return {
                            w = 200,
                            h = 40,
                            copy = function(dimen) return { w = dimen.w, h = dimen.h, copy = dimen.copy } end,
                        }
                    end,
                }
                options.dimen = {
                    copy = function(dimen) return dimen end,
                    combine = function(_, other) return other end,
                }
                options.font_size = 18
                options.line_color = "line"
                options.show_parent = options
                function options:_recalculateDimen()
                    self.recalculated = true
                end
                function options:updatePageInfo(select_number)
                    self.updated_select_number = select_number
                end
                function options:mergeTitleBarIntoLayout()
                    self.merged_title_bar = true
                end
                return options
            end
            function Menu.getMenuText(item)
                return item.text
            end
            return Menu
        end
    end

    before_each(installStubs)
    after_each(clearModules)

    local function findWidgetByKind(widget, kind, seen)
        if type(widget) ~= "table" then
            return nil
        end
        seen = seen or {}
        if seen[widget] then
            return nil
        end
        seen[widget] = true
        if widget.kind == kind then
            return widget
        end
        for _, child in pairs(widget) do
            local found = findWidgetByKind(child, kind, seen)
            if found then
                return found
            end
        end
        return nil
    end

    local function collectWidgetsByKind(widget, kind, widgets, seen)
        if type(widget) ~= "table" then
            return widgets
        end
        widgets = widgets or {}
        seen = seen or {}
        if seen[widget] then
            return widgets
        end
        seen[widget] = true
        if widget.kind == kind then
            table.insert(widgets, widget)
        end
        for _, child in pairs(widget) do
            collectWidgetsByKind(child, kind, widgets, seen)
        end
        return widgets
    end

    it("uses KOReader detailed-list sizing and cfont row text", function()
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Results",
            item_table = {
                {
                    text = "Manga title",
                    subtitle = "MangaDex",
                    mandatory = "12 chapters",
                    manga = { id = "m1" },
                },
            },
        }

        assert.is_true(menu.is_borderless)
        assert.is_false(menu.is_popout)
        assert.is_true(menu.title_bar_fm_style)
        assert.are.equal(10, menu.perpage)
        assert.are.equal(63, menu.item_dimen.h)

        local textboxes = collectWidgetsByKind(menu.item_group[1], "textbox")
        local saw_title = false
        local saw_subtitle = false
        local saw_metadata = false
        for _, widget in ipairs(textboxes) do
            if widget.text == "Manga title" then
                saw_title = widget.bold ~= true and widget.face.name == "cfont" and widget.face.size == 19
            elseif widget.text == "MangaDex" then
                saw_subtitle = widget.face.name == "cfont" and widget.face.size == 17
            elseif widget.text == "12 chapters" then
                saw_metadata = widget.face.name == "cfont" and widget.face.size == 13
            end
        end
        assert.is_true(saw_title)
        assert.is_true(saw_subtitle)
        assert.is_true(saw_metadata)
    end)

    it("gives long names more row height like File Manager multiline rows", function()
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Results",
            item_table = {
                {
                    text = "A very long manga title that needs wrapping instead of being cut short",
                    mandatory = "12 chapters",
                    thumbnail_placeholder = true,
                    manga = { id = "long" },
                },
                {
                    text = "Short",
                    mandatory = "1 chapter",
                    thumbnail_placeholder = true,
                    manga = { id = "short" },
                },
            },
        }

        assert.is_true(menu.items_max_lines >= 2)
        assert.is_true(menu.item_table[1].height > menu.item_table[2].height)
        assert.are.equal(menu.item_table[1].height, menu.item_group[1].dimen.h)
        assert.are.equal(menu.item_table[2].height, menu.item_group[2].dimen.h)
    end)

    it("opens the page containing the requested initial item", function()
        local list_menu = require("suwayomi/ui/list_menu")

        local menu = list_menu.show{
            title = "Chapters",
            itemnumber = 5,
            items_per_page = 2,
            item_table = {
                { text = "Chapter 1" },
                { text = "Chapter 2" },
                { text = "Chapter 3" },
                { text = "Chapter 4" },
                { text = "Chapter 5" },
            },
        }

        assert.are.equal(3, menu.page)
        assert.are.equal(5, menu.itemnumber)
        assert.are.equal(1, menu.updated_select_number)
        assert.are.equal("Chapter 5", menu.item_group[1].entry.text)
    end)

    it("passes state marker width into shared list menus before layout", function()
        local list_menu = require("suwayomi/ui/list_menu")

        local menu = list_menu.show{
            title = "Choices",
            state_w = 32,
            item_table = {
                {
                    text = "* 2",
                    state = { mark_type = "radio", checked = true },
                },
            },
        }

        assert.are.equal(32, menu.state_w)
    end)

    it("renders chapter rows with the shared row widget and no thumbnail gutter", function()
        local list_menu = require("suwayomi/ui/list_menu")

        local menu = list_menu.show{
            title = "Chapters",
            item_table = {
                {
                    text = "Chapter 1",
                    subtitle = "Official",
                    mandatory = "Read · Downloaded",
                    chapter = { id = "c1" },
                },
            },
        }

        local row_group = menu.item_group[1][1][1]
        local left_padding = row_group[1]
        assert.are.equal("horizontal_group", row_group.kind)
        assert.are.equal("horizontal_span", left_padding.kind)
        assert.are.equal(10, left_padding.width)
        assert.is_nil(findWidgetByKind(menu.item_group[1], "text"))
        assert.are.equal(0, #started_jobs)

        local textboxes = collectWidgetsByKind(menu.item_group[1], "textbox")
        local saw_title = false
        local saw_subtitle = false
        local saw_metadata = false
        for _, widget in ipairs(textboxes) do
            if widget.text == "Chapter 1" then
                saw_title = widget.face.name == "cfont"
            elseif widget.text == "Official" then
                saw_subtitle = widget.face.name == "cfont"
            elseif widget.text == "Read · Downloaded" then
                saw_metadata = widget.face.name == "cfont"
            end
        end
        assert.is_true(saw_title)
        assert.is_true(saw_subtitle)
        assert.is_true(saw_metadata)
    end)

    it("shows menu rows, discovers cached thumbnails, and schedules only visible uncached thumbnails", function()
        cache_paths["/cached.jpg"] = "/settings/cached.jpg"
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Results",
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                { text = "Cached", manga = { id = "cached" }, thumbnail_url = "/cached.jpg" },
                { text = "Remote A", manga = { id = "a" }, thumbnail_url = "/a.jpg" },
                { text = "Remote B", manga = { id = "b" }, thumbnail_url = "/b.jpg" },
                { text = "Remote C", manga = { id = "c" }, thumbnail_url = "/c.jpg" },
                { text = "Next page" },
            },
            items_per_page = 5,
        }

        assert.are.same(menu, shown_menu)
        assert.are.equal("/settings/cached.jpg", menu.item_table[1].thumbnail_path)
        assert.are.equal(2, #started_jobs)
        assert.are.equal("/a.jpg", started_jobs[1].thumbnail_url)
        assert.are.equal("/b.jpg", started_jobs[2].thumbnail_url)
        assert.are.equal(5, #menu.item_group)
        assert.are.equal(1, dirty_count)
    end)

    it("renders source rows with thumbnail placeholders and remote icon jobs", function()
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Sources",
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                {
                    text = "MangaDex",
                    subtitle = "EN",
                    mandatory = "18+",
                    source = { id = "s1" },
                    thumbnail_placeholder = true,
                    thumbnail_url = "/icons/mangadex.png",
                },
            },
        }

        assert.is_not_nil(findWidgetByKind(menu.item_group[1], "text"))
        assert.are.equal(1, #started_jobs)
        assert.are.equal("/icons/mangadex.png", started_jobs[1].thumbnail_url)
    end)

    it("renders decoded cached thumbnails as in-memory images", function()
        local decoded_image = { kind = "decoded_bitmap" }
        cache_paths["/cached.webp"] = "/settings/cached.bb"
        decoded_images["/settings/cached.bb"] = decoded_image
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Results",
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                { text = "Cached", manga = { id = "cached" }, thumbnail_url = "/cached.webp" },
            },
        }

        local image = findWidgetByKind(menu.item_group[1], "image")
        assert.are.same(decoded_image, image.image)
        assert.is_nil(image.file)
    end)

    it("uses the placeholder when decoded cached thumbnails cannot be loaded", function()
        cache_paths["/cached.webp"] = "/settings/cached.bb"
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Results",
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                { text = "Cached", manga = { id = "cached" }, thumbnail_url = "/cached.webp" },
            },
        }

        assert.is_nil(findWidgetByKind(menu.item_group[1], "image"))
        assert.is_not_nil(findWidgetByKind(menu.item_group[1], "text"))
    end)

    it("uses the placeholder instead of rendering raw cached thumbnail files", function()
        cache_paths["/cached.jpg"] = "/settings/cached.jpg"
        local manga_menu = require("suwayomi/ui/manga_menu")

        local menu = manga_menu.show{
            title = "Results",
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                { text = "Cached", manga = { id = "cached" }, thumbnail_url = "/cached.jpg" },
            },
        }

        assert.is_nil(findWidgetByKind(menu.item_group[1], "image"))
        assert.is_not_nil(findWidgetByKind(menu.item_group[1], "text"))
    end)

    it("cancels active thumbnail jobs when menu contents are replaced", function()
        local manga_menu = require("suwayomi/ui/manga_menu")
        local menu = manga_menu.show{
            thumbnail_credentials = { server_url = "https://old.example" },
            item_table = {
                { text = "Old", manga = { id = "old" }, thumbnail_url = "/same.jpg" },
            },
        }
        assert.are.equal(1, #started_jobs)

        manga_menu.update(menu, {
            thumbnail_credentials = { server_url = "https://new.example" },
            item_table = {
                { text = "New", manga = { id = "new" }, thumbnail_url = "/same.jpg" },
            },
        })

        assert.are.equal(1, #canceled_jobs)
        assert.is_true(started_jobs[1].canceled)
        assert.are.equal(2, #started_jobs)
    end)

    it("ignores stale thumbnail finishes from previous menu generations", function()
        local manga_menu = require("suwayomi/ui/manga_menu")
        local menu = manga_menu.show{
            thumbnail_credentials = { server_url = "https://old.example" },
            item_table = {
                { text = "Old", manga = { id = "old" }, thumbnail_url = "/same.jpg" },
            },
        }
        local old_job = started_jobs[1]

        manga_menu.update(menu, {
            thumbnail_credentials = { server_url = "https://new.example" },
            item_table = {
                { text = "New", manga = { id = "new" }, thumbnail_url = "/same.jpg" },
            },
        })
        old_job.on_finish(old_job, { ok = true, path = "/settings/old.jpg" })

        assert.is_nil(menu.item_table[1].thumbnail_path)
    end)

    it("does not retry thumbnails that finish with a worker failure", function()
        local manga_menu = require("suwayomi/ui/manga_menu")
        local menu = manga_menu.show{
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
            item_table = {
                { text = "Remote", manga = { id = "remote" }, thumbnail_url = "/remote.webp" },
            },
        }
        local failed_job = started_jobs[1]

        failed_job.on_finish(failed_job, { ok = false, error = "Unsupported thumbnail image type." })

        assert.is_true(menu.item_table[1].thumbnail_failed)
        assert.are.equal(1, #started_jobs)
    end)

    it("cancels active thumbnail jobs on close", function()
        local manga_menu = require("suwayomi/ui/manga_menu")
        local menu = manga_menu.show{
            item_table = {
                { text = "Remote", manga = { id = "remote" }, thumbnail_url = "/remote.jpg" },
            },
            thumbnail_credentials = { server_url = "https://suwayomi.example" },
        }

        menu:onCloseWidget()

        assert.are.equal(1, #canceled_jobs)
        assert.is_true(started_jobs[1].canceled)
    end)
end)
