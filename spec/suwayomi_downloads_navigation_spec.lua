package.path = "?.lua;" .. package.path

local runtime_helper = require("spec/support/plugin_runtime_spec_helper")

describe("Downloads chapter navigation", function()
    local widget_modules = {
        "ui/bidi", "ffi/blitbuffer", "ui/font", "ui/geometry", "ui/gesturerange", "ui/size",
        "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
        "ui/widget/container/inputcontainer", "ui/widget/container/leftcontainer",
        "ui/widget/container/rightcontainer", "ui/widget/container/underlinecontainer",
        "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/imagewidget",
        "ui/widget/overlapgroup", "ui/widget/verticalgroup", "ui/widget/verticalspan",
        "ui/widget/textboxwidget", "ui/widget/textwidget", "ui/widget/menu",
        "suwayomi/ui/thumbnail_cache", "suwayomi/ui/thumbnail_worker",
    }
    local extra_modules = {
        "suwayomi/ui", "suwayomi/ui/downloads", "suwayomi/ui/list_menu", "suwayomi/ui/menu_utils",
        "suwayomi/ui/list_rows", "suwayomi/ui/browse", "suwayomi/ui/directory", "suwayomi/ui/manga_info",
        "suwayomi/ui/choice_dialogs", "suwayomi/network/request_job", "suwayomi/manga/action_menu",
        "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/multiinputdialog",
    }
    for _, name in ipairs(widget_modules) do table.insert(extra_modules, name) end
    local plugin, queue, stack, saved, ui, request, messages
    local function clearExtras()
        for _, name in ipairs(extra_modules) do package.loaded[name], package.preload[name] = nil, nil end
    end
    local function selectAction(id)
        for _, row in ipairs(stack[#stack].buttons) do
            for _, button in ipairs(row) do
                if button.id == id then return button.callback() end
            end
        end
        error("Missing action: " .. id)
    end
    before_each(function()
        runtime_helper.install({ max_parallel_chapter_downloads = 1 })
        clearExtras()
        stack, saved, messages = {}, "[]", {}
        request = nil
        package.preload["suwayomi/downloads/queue"] = nil
        package.preload["suwayomi/navigation"] = nil
        local settings = require("suwayomi/settings")
        local json = require("dkjson")
        settings.loadDownloadQueue = function() return json.decode(saved) end
        settings.saveDownloadQueue = function(_, jobs) saved = json.encode(jobs) end
        local debug = require("suwayomi/debug")
        debug.now, debug.elapsedMs = function() return 0 end, function() return 0 end
        debug.time = function(_, _, callback) return callback() end
        local downloader = require("suwayomi/downloads/downloader")
        downloader.chapterExists = function() return false end
        downloader.getTargetPath = function() return "/unused", "/unused/chapter.cbz" end
        local ffi_util = require("ffi/util")
        ffi_util.runInSubProcess = function() return 123 end
        ffi_util.isSubProcessDone = function() return false end
        ui = require("ui/uimanager")
        ui.show = function(_, widget) table.insert(stack, widget) end
        ui.close = function(_, widget)
            for index = #stack, 1, -1 do
                if stack[index] == widget then table.remove(stack, index) end
            end
            if widget.close_callback then widget.close_callback() end
        end
        ui.scheduleIn = function() end
        for _, name in ipairs(widget_modules) do
            package.preload[name] = function()
                return { extend = function(_, definition) return definition end }
            end
        end
        package.preload["ui/font"] = function() return { getFace = function() return {} end } end
        package.preload["ui/widget/menu"] = function()
            return { new = function(_, options)
                function options:onMenuChoice(item) if item.callback then item.callback() end end
                -- KOReader Menu dispatch calls close_callback after selecting a
                -- leaf, even though the widget itself can remain on screen.
                function options:onMenuSelect(item)
                    if item.select_enabled == false then return true end
                    self:onMenuChoice(item)
                    if self.close_callback then self.close_callback() end
                    return true
                end
                function options:onClose() ui:close(self) end
                return options
            end }
        end
        local list_menu = require("suwayomi/ui/list_menu")
        -- Keep real show/update/install/dispatch; substitute only painting.
        list_menu.updateItems = function() end
        -- These screens are outside this navigation route.
        for _, name in ipairs({ "suwayomi/ui/browse", "suwayomi/ui/directory", "suwayomi/ui/manga_info" }) do
            package.preload[name] = function() return {} end
        end
        for _, name in ipairs({ "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/multiinputdialog" }) do
            package.preload[name] = function() return { new = function(_, options) return options end } end
        end
        -- Capture the external network request; resolve it on a later test step.
        package.preload["suwayomi/network/request_job"] = function()
            return { start = function(options) request = options; return {} end, cancel = function() end }
        end
        plugin = require("main")({})
        plugin.getTitleBarMenuOptions = function() return {} end
        plugin.getVisibleChapters = function(_, chapters) return chapters end
        plugin.getSelectedChapterCount = function() return 0 end
        plugin.isChapterDownloaded = function() return false end
        plugin.loadKoreaderHistoryPaths = function() return {} end
        plugin.showMessage = function(_, text) table.insert(messages, text) end
        queue = plugin:getDownloadQueue()
    end)
    after_each(function() runtime_helper.teardown(); clearExtras() end)

    local function openFrom(state, manga)
        local chapter = { id = "chapter", name = "Chapter from network" }
        assert(queue:enqueue(manga, chapter, os.getenv("TEMP") or "/tmp"))
        if state == "active" then queue:process() end
        local menu = plugin:showDownloads()
        assert.are.equal(state == "active" and "Downloading" or "Queued", menu.item_table[1].mandatory)
        menu:onMenuSelect(menu.item_table[1])
        assert.are.equal(menu, plugin.current_downloads_menu)
        assert.is_true(plugin:isSuwayomiScreenActive(menu))
        selectAction("open_chapter_list")
        assert.are.same({ menu }, stack)
        assert.is_not_nil(request)
        assert.are.equal(manga.id, request.request.manga_id)
        assert.is_nil(plugin.current_chapter_menu)
        return menu, chapter
    end

    for _, state in ipairs({ "queued", "active" }) do
        for _, sparse in ipairs({ false, true }) do
            it("loads chapters from " .. state .. (sparse and " restored sparse metadata" or " metadata") .. " and returns to Downloads", function()
                local manga = sparse and { id = "manga" } or { id = "manga", title = "Manga", initialized = true }
                local menu, chapter = openFrom(state, manga)
                assert.are.equal("fetch_chapters_for_manga", request.request.action)
                request.on_finish({ ok = true, chapters = { chapter } })
                local chapters = plugin.current_chapter_menu
                assert.is_not_nil(chapters)
                assert.are.equal("Chapter from network", chapters.item_table[1].text)
                assert.are.same({ menu, chapters }, stack)
                assert.are.equal(2, #plugin:getNavigation().entries)
                assert.are.equal(menu, plugin.current_downloads_menu)
                assert.is_nil(plugin.current_chapter_context.manga.in_library)
                if sparse then assert.is_nil(plugin.current_chapter_context.manga.initialized) end
                chapters:onClose()
                assert.are.same({ menu }, stack)
                assert.are.equal(1, #plugin:getNavigation().entries)
                assert.is_true(plugin:getNavigation():isCurrent(menu))
                assert.is_nil(plugin.current_chapter_menu)
                menu:onClose()
                assert.is_nil(plugin.current_downloads_menu)
                assert.are.equal(0, #plugin:getNavigation().entries)
            end)
        end
        it("keeps " .. state .. " Downloads origin after chapter loading failure", function()
            local menu = openFrom(state, { id = "manga" })
            request.on_finish({ ok = false, error = "Could not load chapters: HTTP 503" })
            assert.are.same({ "Could not load chapters: HTTP 503" }, messages)
            assert.are.same({ menu }, stack)
            assert.is_nil(plugin.current_chapter_menu)
            assert.are.equal(menu, plugin.current_downloads_menu)
            assert.are.equal(1, #plugin:getNavigation().entries)
        end)
    end
end)
