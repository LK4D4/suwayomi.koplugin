package.path = "?.lua;" .. package.path

local runtime_helper = require("spec/support/plugin_runtime_spec_helper")

describe("download retry across live menus", function()
    local extra_modules = {
        "suwayomi/ui/downloads", "suwayomi/ui/list_menu", "suwayomi/ui/menu_utils",
        "suwayomi/ui/list_rows", "suwayomi/downloads/active_jobs",
        "suwayomi/downloads/job_store", "suwayomi/downloads/status_formatter",
        "ui/widget/textviewer",
    }
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
    for _, name in ipairs(widget_modules) do table.insert(extra_modules, name) end
    local plugin, queue, stack, scheduled, ui, home, downloads_menu, chapters_menu, settings
    local temporary_paths
    local manga = { id = "retry-manga", title = "Retry manga" }
    local chapter = { id = "retry-chapter", name = "Retry chapter" }
    local full_error = "HTTP 503\n" .. string.rep("Complete error details\n", 80)

    local function clearExtras()
        for _, name in ipairs(extra_modules) do
            package.loaded[name], package.preload[name] = nil, nil
        end
    end

    local function flushTimers()
        while true do
            local ready
            for index, timer in ipairs(scheduled) do
                if timer.delay == 0 then ready = index; break end
            end
            if not ready then return end
            table.remove(scheduled, ready).callback()
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

        local found = false
        for _, row in ipairs(downloads_menu.item_table) do
            if row.text and row.text:find("Retry chapter", 1, true) then
                assert.are.equal(label, row.mandatory)
                found = true
            end
        end
        assert.is_true(found)

        assert.are.equal(0, queue:getFailedCount())
    end

    before_each(function()
        runtime_helper.install({ max_parallel_chapter_downloads = 1 })
        clearExtras()
        stack, scheduled, temporary_paths = {}, {}, {}
        package.preload["suwayomi/downloads/queue"] = nil
        package.preload["suwayomi/navigation"] = nil
        package.preload["suwayomi/settings"] = nil
        package.preload.lfs, package.loaded.lfs = nil, nil
        settings = require("suwayomi/settings")
        local path = os.tmpname()
        os.remove(path)
        table.insert(temporary_paths, path)
        settings:setStore(require("suwayomi/settings/store"):new{ path = path })
        assert(settings:saveMaxParallelChapterDownloads(1))
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
        for _, name in ipairs(widget_modules) do
            package.preload[name] = function()
                return { extend = function(_, definition) return definition end }
            end
        end
        package.preload["ui/font"] = function() return { getFace = function() return {} end } end
        package.preload["ui/widget/textboxwidget"] = function()
            return { new = function()
                return {
                    getAllLineCount = function() return 1 end,
                    getVisLineCount = function() return 15 end,
                    free = function() end,
                }
            end }
        end
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
        queue:setStatus(manga, chapter, { state = 'failed' })
        plugin:init()
    end)

    after_each(function()
        for _, path in ipairs(temporary_paths) do os.remove(path) end
        runtime_helper.teardown()
        clearExtras()
    end)

    for _, terminal in ipairs({ "downloaded", "skipped" }) do
        for _, remaining in ipairs({ false, true }) do
            it("finalizes " .. terminal .. " retry before refreshing menus with remaining worker " .. tostring(remaining), function()
                showScreens()
                flushTimers()
                downloads_menu:onMenuSelect(downloads_menu.item_table[1])
                click("retry")
                queue:process(); flushTimers()
                assertStatus("downloading", "Downloading")
                local key = queue:getKey(manga, chapter)
                local active = queue:getActiveJob(key)
                active.progress_path = os.tmpname()
                os.remove(active.progress_path)
                table.insert(temporary_paths, active.progress_path)
                local archive = os.tmpname()
                os.remove(archive)
                archive = archive .. ".cbz"
                table.insert(temporary_paths, archive)
                local handle = assert(io.open(archive, "wb"))
                handle:write("PK\005\006", string.rep("\0", 18))
                handle:close()
                -- The filesystem is an external boundary; check the actual file.
                queue.downloader.chapterExists = function(_, path)
                    local file = io.open(path, "rb")
                    if not file then return false end
                    file:close()
                    return true
                end
                if remaining then
                    local other = { id = "other", name = "Other" }
                    local other_job = queue:buildPersistentJob(manga, other, active.download_directory, "downloading")
                    other_job.progress_path, other_job.pid = os.tmpname(), 456
                    table.insert(temporary_paths, other_job.progress_path)
                    queue:setActiveJob(other_job)
                    queue:upsertPersistentJob(other_job)
                end
                local observed, ready, archive_error = {}, {}, nil
                local changed, archiveReady = queue.onStatusChanged, queue.onChapterArchiveReady
                queue.onStatusChanged = function(...)
                    table.insert(observed, { active = queue:getActiveJob(key), persistent = queue:findPersistentJob(key) })
                    return changed(...)
                end
                queue.onChapterArchiveReady = function(...)
                    table.insert(ready, { ... })
                    local ok, result = pcall(archiveReady, ...)
                    if not ok then archive_error = result end
                end
                require("suwayomi/downloads/progress_file").writeFallback(active.progress_path, terminal, 20, 20, archive)
                queue.ffi_util.isSubProcessDone = function(pid) return pid == active.pid end
                queue:poll()
                flushTimers()
                assert.are.equal(remaining and 1 or 0, queue:getActiveCount())
                assert.are.equal(0, #queue.items)
                assert.is_nil(queue:findPersistentJob(key))
                assert.are.equal(terminal, queue:getStatus(manga, chapter).state)

                for _, row in ipairs(downloads_menu.item_table) do
                    assert.is_falsy(row.text and row.text:find("Retry chapter", 1, true))
                end
                if not remaining then
                    assert.are.equal("No downloads queued.", downloads_menu.item_table[3].text)
                    assert.is_false(queue.active_job_lifecycle.poll_scheduled)
                else
                    assert.are.equal("Downloading", downloads_menu.item_table[1].mandatory)
                    assert.is_true(queue.active_job_lifecycle.poll_scheduled)
                end
                assert.are.equal(1, #observed)
                assert.is_nil(observed[1].active)
                assert.is_nil(observed[1].persistent)
                assert.are.equal(1, #ready)
                assert.are.equal(archive, ready[1][3])
                assert.is_nil(archive_error)
                assert.are.equal(archive, plugin:loadChapterLedger()[key].path)
                assert.are.equal(chapter.id, require("suwayomi/settings"):loadReaderReturnContexts()[archive].chapter_id)

                assert.are.equal(0, queue:getFailedCount())
                assert.are.equal(remaining and 1 or 0, #settings:loadDownloadQueue())
            end)
        end
        it("rejects " .. terminal .. " without an archive before publishing success", function()
            showScreens()
            flushTimers()
            downloads_menu:onMenuSelect(downloads_menu.item_table[1])
            click("retry")
            queue:process(); flushTimers()
            local active = queue:getActiveJob(queue:getKey(manga, chapter))
            active.progress_path = os.tmpname()
            os.remove(active.progress_path)
            table.insert(temporary_paths, active.progress_path)
            local states, ready = {}, false
            local changed = queue.onStatusChanged
            queue.onStatusChanged = function(...)
                table.insert(states, queue:getStatus(manga, chapter).state)
                return changed(...)
            end
            queue.onChapterArchiveReady = function() ready = true end
            require("suwayomi/downloads/progress_file").writeFallback(active.progress_path, terminal, 20, 20, "/missing.cbz")
            queue.ffi_util.isSubProcessDone = function(pid) return pid == active.pid end
            queue:poll()
            flushTimers()
            assert.is_true(#states > 0)
            for _, state in ipairs(states) do assert.are.equal("failed", state) end
            assert.is_false(ready)
            assert.are.equal(0, queue:getActiveCount())
            assert.are.equal(0, #queue.items)
            assert.are.equal("failed", queue:findPersistentJob(active.key).state)

            assert.are.equal("Failed", downloads_menu.item_table[1].mandatory)
            assert.are.equal("Downloads · 1 failed", plugin:showHome().actions[3].text)
            assert.is_false(queue.active_job_lifecycle.poll_scheduled)
        end)
    end

    for _, origin in ipairs({ "Downloads", "chapters" }) do
        it("retries from " .. origin .. " details and updates the visible Downloads menu", function()
            showScreens()
            if origin == "Downloads" then
                flushTimers()
                downloads_menu:onMenuSelect(downloads_menu.item_table[1])
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
            assert.are.equal(downloads_menu, plugin.current_downloads_menu)
            queue:process(); flushTimers()
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
        queue:process(); flushTimers()
        showScreens()
        plugin:showChapterDownloadError(manga, chapter)
        click("retry")
        queue:process(); flushTimers()
        assertStatus("queued", "Queued")
        queue.active_job_lifecycle:removeJob(queue:getActiveJob(queue:getKey(manga, other)))
        queue:process(); flushTimers()
        assertStatus("downloading", "Downloading")
    end)

    for _, state in ipairs({ "queued", "downloading", "scheduled" }) do
        it("keeps Downloads tracked after dismissing " .. state .. " job actions", function()
            showScreens()
            queue:retryFailed(queue:getKey(manga, chapter))
            if state ~= "queued" then queue:process(); flushTimers() end
            if state == "scheduled" then
                queue.active_job_lifecycle:scheduleTransientRetry(
                    queue:getActiveJob(queue:getKey(manga, chapter)), { error = full_error })
            end
            flushTimers()
            downloads_menu:onMenuSelect(downloads_menu.item_table[1])
            if state == "scheduled" then
                selectAction("download_error")
                assert.is_truthy(stack[#stack].text:find(full_error, 1, true))
                click("close")
                assert.are.equal("Retry scheduled", downloads_menu.item_table[1].mandatory)
                assert.is_truthy(queue:findPersistentJob(queue:getKey(manga, chapter)).retry_at)
            else
                ui:close(stack[#stack])
            end
            assert.are.equal(downloads_menu, plugin.current_downloads_menu)
            assert.are.equal(downloads_menu, stack[#stack])
            if state == "queued" then
                queue:process(); flushTimers()
                assertStatus("downloading", "Downloading")
            elseif state == "downloading" then
                queue.active_job_lifecycle:finishWithFailure(
                    queue:getActiveJob(queue:getKey(manga, chapter)), full_error)
                flushTimers()
                assert.are.equal("Failed", downloads_menu.item_table[1].mandatory)

                assert.are.equal(1, queue:getFailedCount())
                assert.are.equal("Downloads · 1 failed", home.actions[3].text)
            end
            downloads_menu:onClose()
            assert.is_nil(plugin.current_downloads_menu)
            assert.is_false(plugin:isSuwayomiScreenActive(downloads_menu))
        end)
    end

    it("closes details without changing the origin or the complete stored error", function()
        showScreens()
        for _, origin in ipairs({ "downloads", "chapters" }) do
            local before = #stack
            if origin == "downloads" then downloads_menu:onMenuSelect(downloads_menu.item_table[1])
            else plugin:showChapterDownloadError(manga, chapter) end
            click("close")
            assert.are.equal(before, #stack)
            assert.are.equal(downloads_menu, plugin.current_downloads_menu)
            assert.are.equal(full_error, queue:findPersistentJob(queue:getKey(manga, chapter)).progress.error)
        end
    end)

    it("still clears failures and replaces Downloads through native selection", function()
        showScreens()
        downloads_menu:onMenuSelect(downloads_menu.item_table[2])
        assert.are.equal(0, queue:getFailedCount())
        assert.is_nil(queue:getStatus(manga, chapter))

        assert.are_not.equal(downloads_menu, plugin.current_downloads_menu)
        assert.are.equal("No downloads queued.", plugin.current_downloads_menu.item_table[3].text)
        assert.are.equal(plugin.current_downloads_menu, stack[#stack])
        for _, widget in ipairs(stack) do assert.are_not.equal(downloads_menu, widget) end
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

    it("keeps the process queue while an open retry dialog is retained", function()
        showScreens()
        plugin:showChapterDownloadError(manga, chapter)
        local old_queue = queue
        queue = plugin:createDownloadQueue()
        assert.are.equal(old_queue, queue)
        plugin:init()
        click("retry")
        assert.are.equal(1, #old_queue.items)
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
                if state == "downloading" then queue:process(); flushTimers() end
            else
                queue:removePersistentJob(key)
                queue:setStatus(manga, chapter, { state = "downloaded" })
            end
            local pending, active = #queue.items, queue:getActiveCount()
            click("retry")
            assert.are.equal(pending, #queue.items)
            assert.are.equal(active, queue:getActiveCount())
            assert.are.equal(0, queue:getFailedCount())

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
