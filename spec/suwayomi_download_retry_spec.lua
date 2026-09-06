package.path = "?.lua;" .. package.path

local runtime_helper = require("spec/support/plugin_runtime_spec_helper")

describe("download retry across live menus", function()
    local extra_modules = {
        "suwayomi/ui/downloads", "suwayomi/ui/list_menu", "suwayomi/ui/menu_utils",
        "suwayomi/ui/list_rows", "suwayomi/downloads/active_jobs",
        "suwayomi/downloads/job_store", "suwayomi/downloads/status_formatter",
        "ui/widget/textviewer",
    }
    local plugin, queue, stack, scheduled, saved, ui, home, downloads_menu, chapters_menu
    local manga = { id = "retry-manga", title = "Retry manga" }
    local chapter = { id = "retry-chapter", name = "Retry chapter" }
    local full_error = "HTTP 503\n" .. string.rep("Complete error details\n", 80)

    local function clearExtras()
        for _, name in ipairs(extra_modules) do
            package.loaded[name], package.preload[name] = nil, nil
        end
    end

    local function click(id)
        local viewer = stack[#stack]
        for _, row in ipairs(viewer.buttons_table or {}) do
            for _, button in ipairs(row) do
                if button.id == id then return button.callback() end
            end
        end
        error("Missing button: " .. id)
    end

    local function selectAction(id)
        local menu = stack[#stack]
        for _, action in ipairs(menu.actions) do
            if action.id == id then
                ui:close(menu)
                return menu.select(action)
            end
        end
        error("Missing action: " .. id)
    end

    local function failure(error_message)
        return queue:buildPersistentJob(manga, chapter, os.getenv("TEMP") or "/tmp", "failed", {
            progress = { state = "failed", error = error_message or full_error },
        })
    end

    local function showScreens()
        home = plugin:showHome()
        assert.are.equal("Downloads · 1 failed", home.actions[3].text)
        chapters_menu = { item_table = {} }
        plugin.current_chapter_context = { manga = manga, chapters = { chapter } }
        plugin.current_chapter_menu = chapters_menu
        plugin:trackSuwayomiScreen("chapters", chapters_menu)
        ui:show(chapters_menu)
        plugin:refreshChapterMenu({ quick = true })
        downloads_menu = plugin:showDownloads()
    end

    local function assertStatus(state, label)
        assert.are.equal(state, queue:getStatus(manga, chapter).state)
        assert.are.equal(state, queue:findPersistentJob(queue:getKey(manga, chapter)).state)
        assert.are.equal(label, chapters_menu.item_table[1].mandatory)
        local found = false
        for _, row in ipairs(downloads_menu.item_table) do
            if row.text and row.text:find("Retry chapter", 1, true) then
                assert.are.equal(label, row.mandatory)
                found = true
            end
        end
        assert.is_true(found)
        assert.are.equal("Downloads", home.actions[3].text)
        assert.are.equal(0, queue:getFailedCount())
    end

    before_each(function()
        runtime_helper.install({ max_parallel_chapter_downloads = 1 })
        clearExtras()
        stack, scheduled, saved = {}, {}, "[]"
        package.preload["suwayomi/downloads/queue"] = nil
        local settings = require("suwayomi/settings")
        local json = require("dkjson")
        settings.loadDownloadQueue = function() return json.decode(saved) end
        settings.saveDownloadQueue = function(_, jobs) saved = json.encode(jobs) end
        local debug = require("suwayomi/debug")
        debug.now, debug.elapsedMs = function() return 0 end, function() return 0 end
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
        ui.scheduleIn = function(_, delay, callback)
            table.insert(scheduled, { delay = delay, callback = callback })
        end
        package.preload["ui/widget/textviewer"] = function()
            return { new = function(_, options)
                options.onClose = function(self) ui:close(self) end
                return options
            end }
        end
        package.preload["suwayomi/ui/list_menu"] = function()
            return {
                show = function(options) ui:show(options); return options end,
                update = function(menu, options) menu.item_table = options.item_table end,
            }
        end
        local facade = require("suwayomi/ui")
        for name, method in pairs(require("suwayomi/ui/downloads")) do facade[name] = method end
        local rows = require("suwayomi/ui/list_rows")
        facade.updateChapterMenu = function(menu, options, onSelect)
            menu.item_table = rows.buildChapterMenuTable(options.chapters, { on_select = onSelect })
        end
        facade.showChapterActionsMenu = function(options, onSelect)
            options.select = onSelect
            ui:show(options)
            return options
        end
        local showHome = facade.showHomeDialog
        facade.showHomeDialog = function(options)
            local dialog = showHome(options)
            ui:show(dialog)
            return dialog
        end
        plugin = require("main")({})
        plugin.getTitleBarMenuOptions = function() return {} end
        plugin.getVisibleChapters = function(_, chapters) return chapters end
        plugin.getSelectedChapterCount = function() return 0 end
        plugin.isChapterDownloaded = function() return false end
        plugin.loadKoreaderHistoryPaths = function() return {} end
        queue = plugin:getDownloadQueue()
        queue:upsertPersistentJob(failure())
        queue:recover()
    end)

    after_each(function()
        runtime_helper.teardown()
        clearExtras()
    end)

    for _, origin in ipairs({ "Downloads", "chapters" }) do
        it("retries from " .. origin .. " details and updates both existing menus", function()
            showScreens()
            if origin == "Downloads" then
                downloads_menu.item_table[1].callback()
            else
                chapters_menu.item_table[1].callback()
                selectAction("download_error")
            end
            assert.is_truthy(stack[#stack].text:find(full_error, 1, true))
            local before = #stack - 1
            click("retry")
            assert.are.equal(before, #stack)
            assert.are.equal(1, #queue.items)
            assertStatus("queued", "Queued")
            queue:process()
            assertStatus("downloading", "Downloading")
        end)
    end

    it("offers Retry directly for a failed chapter and uses the live retry path", function()
        showScreens()
        plugin:showChapterActions(manga, chapter)
        assert.are.equal("Retry", stack[#stack].actions[1].text)
        selectAction("retry_download")
        assert.are.equal(1, #queue.items)
        assertStatus("queued", "Queued")
    end)

    it("keeps an accepted retry queued while a worker is occupied, then displays its start", function()
        local other = { id = "other", name = "Other" }
        queue:enqueue(manga, other, os.getenv("TEMP") or "/tmp")
        queue:process()
        showScreens()
        plugin:showChapterDownloadError(manga, chapter)
        click("retry")
        queue:process()
        assertStatus("queued", "Queued")
        queue.active_job_lifecycle:removeJob(queue:getActiveJob(queue:getKey(manga, other)))
        queue:process()
        assertStatus("downloading", "Downloading")
    end)

    it("closes details without changing the origin or the complete stored error", function()
        showScreens()
        for _, origin in ipairs({ "downloads", "chapters" }) do
            local before = #stack
            if origin == "downloads" then downloads_menu.item_table[1].callback()
            else plugin:showChapterDownloadError(manga, chapter) end
            click("close")
            assert.are.equal(before, #stack)
            assert.are.equal(full_error, queue:findPersistentJob(queue:getKey(manga, chapter)).progress.error)
        end
    end)

    it("keeps ordinary queued and scheduled retry actions distinct from terminal Retry", function()
        showScreens()
        for _, scheduled_retry in ipairs({ false, true }) do
            queue.statuses[queue:getKey(manga, chapter)] = { state = "queued", retry_at = scheduled_retry and 130 or nil }
            local actions = plugin:getChapterActions(manga, chapter)
            assert.are.equal("cancel_download", actions[1].id)
            assert.are.equal(scheduled_retry and "download_error" or "mark_read", actions[2].id)
        end
        queue.statuses[queue:getKey(manga, chapter)] = nil
        queue:removePersistentJob(queue:getKey(manga, chapter))
        assert.are.equal("download", plugin:getChapterActions(manga, chapter)[1].id)
        plugin.isChapterDownloaded = function() return true end
        assert.are.equal("open", plugin:getChapterActions(manga, chapter)[1].id)
        queue.statuses[queue:getKey(manga, chapter)] = { state = "failed" }
        assert.are.equal("open", plugin:getChapterActions(manga, chapter)[1].id)
        queue.statuses[queue:getKey(manga, chapter)] = { state = "downloading" }
        local actions = plugin:getChapterActions(manga, chapter)
        assert.are.equal("cancel_download", actions[1].id)
        assert.are.equal("mark_read", actions[2].id)
    end)

    it("does not duplicate a queued job through a stale chapter Retry action", function()
        showScreens()
        chapters_menu.item_table[1].callback()
        queue:retryFailed(queue:getKey(manga, chapter))
        selectAction("retry_download")
        assert.are.equal(1, #queue.items)
        assertStatus("queued", "Queued")
    end)

    it("uses the current queue when an open retry dialog outlives its queue", function()
        showScreens()
        plugin:showChapterDownloadError(manga, chapter)
        local old_queue = queue
        queue = plugin:createDownloadQueue()
        plugin.download_queue = queue
        queue:recover()
        click("retry")
        assert.are.equal(0, #old_queue.items)
        assert.are.equal(1, #queue.items)
        assertStatus("queued", "Queued")
    end)

    it("revalidates a replaced failed record and queues only its current chapter metadata", function()
        showScreens()
        plugin:showChapterDownloadError(manga, chapter)
        local replacement = failure("Replacement error")
        replacement.chapter.name = "Replacement chapter"
        queue:upsertPersistentJob(replacement)
        click("retry")
        assert.are.equal(1, #queue.items)
        assert.are.equal("Replacement chapter", queue.items[1].chapter.name)
        assert.are.equal("queued", queue:findPersistentJob(queue:getKey(manga, chapter)).state)
        assert.are.equal("Queued", chapters_menu.item_table[1].mandatory)
        assert.are.equal(0, queue:getFailedCount())
    end)

    for _, state in ipairs({ "queued", "downloading", "downloaded", "cleared" }) do
        it("refreshes a stale retry after the job becomes " .. state, function()
            showScreens()
            plugin:showChapterDownloadError(manga, chapter)
            local key = queue:getKey(manga, chapter)
            if state == "cleared" then
                queue:clearFailed()
            elseif state == "queued" or state == "downloading" then
                queue:retryFailed(key)
                if state == "downloading" then queue:process() end
            else
                queue:removePersistentJob(key)
                queue:setStatus(manga, chapter, { state = "downloaded" })
            end
            local pending, active = #queue.items, queue:getActiveCount()
            click("retry")
            assert.are.equal(pending, #queue.items)
            assert.are.equal(active, queue:getActiveCount())
            assert.are.equal(0, queue:getFailedCount())
            assert.are.equal("Downloads", home.actions[3].text)
            if state == "queued" or state == "downloading" then
                assertStatus(state, state == "queued" and "Queued" or "Downloading")
            else
                assert.are.equal(state == "downloaded" and "Downloaded" or nil,
                    chapters_menu.item_table[1].mandatory)
                assert.are.equal("No downloads queued.", downloads_menu.item_table[3].text)
                assert.is_nil(queue:findPersistentJob(key))
            end
        end)
    end
end)
