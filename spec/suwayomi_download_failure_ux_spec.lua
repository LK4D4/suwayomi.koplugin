package.path = "?.lua;" .. package.path

-- Compose real queue persistence, controller actions, and UI row builders.
-- Only KOReader widgets, scheduling, and download workers are substituted.
describe("download failure user actions", function()
    local modules = {
        "gettext", "suwayomi/i18n", "suwayomi/settings", "suwayomi/ui",
        "suwayomi/ui/downloads", "suwayomi/ui/list_menu", "suwayomi/ui/menu_utils",
        "suwayomi/downloads/controller", "suwayomi/downloads/queue",
        "suwayomi/downloads/active_jobs", "suwayomi/downloads/job_store",
        "suwayomi/downloads/status_formatter", "ui/uimanager", "ui/widget/textviewer",
        "suwayomi/plugin/home", "ui/widget/infomessage",
        "suwayomi/chapters/delete_actions",
    }
    local saved, stack, scheduled, messages, plugin, queue, now, ui, downloads
    local save_error, blocked, terminated
    local manga = { id = "m1", title = "Example manga" }
    local chapter = { id = "c1", name = "Chapter 1" }
    local full_error = "HTTP 503\n" .. string.rep("診断 details with 100% certainty\n", 200) .. "last detail"

    local function clearModules()
        for _, name in ipairs(modules) do
            package.loaded[name] = nil
            package.preload[name] = nil
        end
    end

    local function job(state, error_message, retry_at)
        return {
            key = "m1:c1", state = state, manga = manga, chapter = chapter,
            download_directory = os.getenv("TEMP") or "/tmp",
            progress = error_message and { error = error_message, state = state } or nil,
            retry_count = retry_at and 1 or nil, retry_at = retry_at,
        }
    end

    local function newQueue()
        local json = require("dkjson")
        local settings = require("spec/support/checked_queue_settings")(json.decode(saved))
        local store = settings:getStore()
        local write, rename = store.io.write, store.io.rename
        store.io.write = function(handle, content)
            if save_error and not save_error:match("^ambiguous_post_replacement") then
                return nil, save_error:gsub("^write_failed: ", "")
            end
            return write(handle, content)
        end
        store.io.rename = function(from, to)
            local ok = rename(from, to)
            saved = json.encode(assert(loadstring(store.io.read(to)))().download_queue)
            return ok
        end
        store.io.sync_dir = function()
            if save_error and save_error:match("^ambiguous_post_replacement") then
                blocked = true
                return nil, "injected directory sync failure"
            end
            return true
        end
        return require("suwayomi/downloads/queue"):new{
            settings = settings,
            downloader = {
                chapterExists = function() return false end,
                getTargetPath = function() return "/unused", "/unused/chapter.cbz" end,
            },
            ffi_util = {
                runInSubProcess = function() return 123 end,
                isSubProcessDone = function() return true end,
                terminateSubProcess = function() terminated = terminated + 1 end,
            },
            ui_manager = ui,
            now = function() return now end,
            onStatusChanged = function()
                if plugin then
                    plugin:refreshDownloadsMenu()
                    plugin:refreshHomeDownloads()
                end
            end,
            onMessage = function(text) table.insert(messages, text) end,
        }
    end

    local function restoreSession(jobs)
        saved = require("dkjson").encode(jobs)
        queue = newQueue()
        plugin.queue = queue
        assert(queue:reconcile())
    end

    local function button(viewer, id)
        for _, row in ipairs(viewer.buttons_table or {}) do
            for _, item in ipairs(row) do
                if item.id == id then return item end
            end
        end
        error("Missing viewer button: " .. id)
    end

    before_each(function()
        clearModules()
        saved, stack, scheduled, messages, now = "[]", {}, {}, {}, 100
        save_error, blocked, terminated = nil, false, 0
        package.preload.gettext = function() return function(text) return text end end
        ui = {
            show = function(_, widget) table.insert(stack, widget) end,
            close = function(_, widget)
                for index = #stack, 1, -1 do
                    if stack[index] == widget then table.remove(stack, index) end
                end
                if widget.close_callback then widget.close_callback() end
            end,
            scheduleIn = function(_, delay, callback)
                table.insert(scheduled, { delay = delay, callback = callback })
            end,
        }
        package.preload["ui/uimanager"] = function() return ui end
        package.preload["ui/widget/textviewer"] = function()
            return { new = function(_, options)
                options.onClose = function(self) ui:close(self) end
                return options
            end }
        end
        package.preload["suwayomi/ui/list_menu"] = function()
            return {
                show = function(options) ui:show(options); return options end,
                update = function(menu, options) menu.item_table = options.item_table; return true end,
            }
        end
        package.preload["suwayomi/settings"] = function()
            return { loadDownloadDirectory = function() return "/books" end }
        end
        package.preload["ui/widget/infomessage"] = function() return {} end
        downloads = require("suwayomi/ui/downloads")
        package.preload["suwayomi/ui"] = function()
            return setmetatable({
                showHomeDialog = function(options)
                    ui:show(options)
                    return options
                end,
                updateHomeDownloadsLabel = function(dialog, text)
                    dialog.actions[3].text = text
                    return true
                end,
                showChapterActionsMenu = function(options, onSelect)
                    options.select = function(id)
                        for _, action in ipairs(options.actions) do
                            if action.id == id then
                                ui:close(options)
                                return onSelect(action)
                            end
                        end
                        error("Missing action: " .. id)
                    end
                    ui:show(options)
                    return options
                end,
            }, { __index = downloads })
        end
        plugin = { queue = nil }
        for name, method in pairs(require("suwayomi/downloads/controller").methods) do
            plugin[name] = method
        end
        local home = require("suwayomi/plugin/home").methods
        for _, name in ipairs({ "showHome", "buildHomeActions", "refreshHomeDownloads" }) do
            plugin[name] = home[name]
        end
        function plugin:getDownloadQueue() return self.queue end
        function plugin:showMessage(text) table.insert(messages, text) end
        function plugin:closeMenu(menu) if menu then ui:close(menu) end end
        queue = newQueue()
        plugin.queue = queue
    end)

    after_each(clearModules)

    for _, title_action in ipairs({ false, true }) do
        it("reports rejected Clear failed from " .. (title_action and "title" or "menu") .. " action", function()
            restoreSession({ job("failed", "network failure") })
            local committed = saved
            local menu = plugin:showDownloads()
            save_error = "write_failed: injected clear failure"
            if title_action then
                plugin:performDownloadsTitleAction({ id = "clear_failed" }, menu)
            else
                plugin:getDownloadsMenuCallbacks().onClearFailed(menu)
            end
            assert.are.equal("Could not clear failed downloads: " .. save_error, messages[#messages])
            assert.are.equal(committed, saved)
            assert.are.equal(1, queue:getFailedCount())
            assert.are.equal("Failed", plugin.current_downloads_menu.item_table[1].mandatory)
        end)
    end

    for _, failure in ipairs({ "write_failed: injected cancellation failure",
        "ambiguous_post_replacement: injected directory sync failure" }) do
        it("preserves archives and ledger when deletion cancellation returns " .. failure, function()
            restoreSession({ job("queued") })
            for name, method in pairs(require("suwayomi/chapters/delete_actions").methods) do
                plugin[name] = method
            end
            local archive_exists = true
            local ledger = { ["m1:c1"] = { path = "/books/chapter.cbz", read = true } }
            function plugin:isChapterDownloaded() return archive_exists, "/books/chapter.cbz" end
            function plugin:getKoreaderMetadataPathForDocument() return "/books/chapter.sdr/metadata.lua" end
            function plugin:removeChapterArchiveAndSidecars() archive_exists = false; return true end
            function plugin:loadChapterLedger() return ledger end
            function plugin:getChapterLedgerKey() return "m1:c1" end
            function plugin:saveChapterLedger(value) ledger = value end
            function plugin:refreshChapterMenu() end
            save_error = failure
            local ok, state = plugin:deleteChapterFromDevice(manga, chapter)
            assert.is_false(ok)
            assert.are.equal(blocked and "store_blocked" or "delete_failed", state)
            assert.is_true(archive_exists)
            assert.are.equal("/books/chapter.cbz", ledger["m1:c1"].path)
            assert.are.equal("queued", queue:getSnapshot().queued[1].state)
            assert.are.equal(blocked and "Cannot delete chapter: storage is ambiguous"
                or "Could not delete this chapter from device.", messages[#messages])
        end)
    end

    for _, active in ipairs({ false, true }) do
        it("reports rejected " .. (active and "active" or "queued") .. " cancellation without losing its row", function()
            restoreSession({ job("queued") })
            if active then queue:process() end
            local committed = saved
            local menu = plugin:showDownloads()
            save_error = "write_failed: injected cancellation failure"
            menu.item_table[1].callback()
            stack[2].select(active and "cancel_download" or "cancel_queued")
            assert.are.equal("Could not cancel download: " .. save_error, messages[#messages])
            assert.are.equal(committed, saved)
            assert.are.equal(active and 1 or 0, queue:getActiveCount())
            assert.are.equal(0, terminated)
            assert.are.equal(active and "Downloading" or "Queued",
                plugin.current_downloads_menu.item_table[1].mandatory)
        end)
    end

    it("opens full multiline details directly and closes back to the same Downloads menu", function()
        restoreSession({ job("failed", full_error) })
        local menu = plugin:showDownloads()
        assert.are.equal(1, #stack)
        assert.are.equal("Failed", menu.item_table[1].mandatory)
        assert.is_true(#menu.item_table[1].subtitle < 200)
        assert.is_nil(menu.item_table[1].subtitle:find("\n", 1, true))
        menu.item_table[1].callback()
        local viewer = stack[2]
        assert.is_not_nil(viewer)
        assert.is_truthy(viewer.text:find("Example manga / Chapter 1", 1, true))
        assert.is_truthy(viewer.text:find(full_error, 1, true))
        assert.are.equal(full_error, queue:findPersistentJob("m1:c1").progress.error)
        button(viewer, "close").callback()
        assert.are.same({ menu }, stack)
        assert.are.equal("failed", queue:getStatus(manga, chapter).state)
        assert.are.same({}, messages)
    end)

    it("retries from chapter details and keeps the originating chapter screen", function()
        restoreSession({ job("failed", full_error) })
        local chapter_screen = { name = "chapters" }
        ui:show(chapter_screen)
        plugin:showChapterDownloadError(manga, chapter)
        local viewer = stack[2]
        assert.is_truthy(viewer.text:find(full_error, 1, true))
        button(viewer, "retry").callback()
        assert.are.same({ chapter_screen }, stack)
        assert.are.equal("queued", queue:getStatus(manga, chapter).state)
        assert.are.equal(1, #queue.items)
        assert.are.equal("queued", queue:findPersistentJob("m1:c1").state)
        assert.are.equal(0, queue:getFailedCount())
    end)

    it("refreshes the existing Downloads row after Retry", function()
        restoreSession({ job("failed", "network failure") })
        local menu = plugin:showDownloads()
        menu.item_table[1].callback()
        button(stack[2], "retry").callback()
        assert.are.same({ menu }, stack)
        assert.are.equal("Queued", menu.item_table[1].mandatory)
        assert.are.equal(1, #queue.items)
        assert.are.equal(0, queue:getFailedCount())
    end)

    it("provides a missing-error fallback from both entry points", function()
        for _, error_message in ipairs({ false, "", " \n\t" }) do
            restoreSession({ job("failed", error_message or nil) })
            local menu = plugin:showDownloads()
            assert.are.equal("No error details were recorded.", menu.item_table[1].subtitle)
            menu.item_table[1].callback()
            assert.is_truthy(stack[#stack].text:find("No error details were recorded.", 1, true))
            button(stack[#stack], "close").callback()
            ui:close(menu)
            plugin:showChapterDownloadError(manga, chapter)
            assert.is_truthy(stack[#stack].text:find("No error details were recorded.", 1, true))
            button(stack[#stack], "close").callback()
        end
    end)

    it("keeps scheduled retry errors during the session without adding countdown refreshes", function()
        restoreSession({ job("queued", full_error, 130) })
        local menu = plugin:showDownloads()
        assert.are.equal("Retry scheduled", menu.item_table[1].mandatory)
        assert.is_truthy(menu.item_table[1].subtitle:find(os.date("%Y-%m-%d %H:%M:%S", 130), 1, true))
        assert.are.equal(full_error, queue:getSnapshot().queued[1].progress.error)
        local schedule_count = #scheduled
        menu.item_table[1].callback()
        local actions = stack[2]
        assert.are.equal("cancel_queued", actions.actions[1].id)
        assert.are.equal("open_chapter_list", actions.actions[2].id)
        actions.select("download_error")
        local viewer = stack[2]
        assert.is_truthy(viewer.text:find(full_error, 1, true))
        assert.is_false(button(viewer, "retry").enabled)
        button(viewer, "close").callback()
        assert.are.equal(schedule_count, #scheduled)
        assert.are.equal(130, queue:findPersistentJob("m1:c1").retry_at)
        assert.are.equal(0, queue:getFailedCount())
        ui:close(menu)
        plugin:showChapterDownloadError(manga, chapter)
        assert.is_truthy(stack[1].text:find(full_error, 1, true))
        button(stack[1], "close").callback()
        queue = newQueue()
        plugin.queue = queue
        assert(queue:reconcile())
        assert.are.equal(full_error, queue:getSnapshot().queued[1].progress.error)
        queue:process()
        assert.are.equal(0, queue:getActiveCount())
        now = 130
        queue:process()
        assert.are.equal(1, queue:getActiveCount())
        assert.are.equal("downloading", queue:getStatus(manga, chapter).state)
    end)

    it("keeps individual cancellation available while a retry is scheduled", function()
        restoreSession({ job("queued", full_error, 130) })
        local menu = plugin:showDownloads()
        menu.item_table[1].callback()
        stack[2].select("cancel_queued")
        assert.are.equal(0, #queue.items)
        assert.is_nil(queue:findPersistentJob("m1:c1"))
        assert.is_nil(queue:getStatus(manga, chapter))
        assert.are.equal("No downloads queued.", plugin.current_downloads_menu.item_table[3].text)
    end)

    it("revalidates Retry after jobs become queued, active, completed, cleared, or replaced", function()
        for _, state in ipairs({ "queued", "downloading", "downloaded", "cleared", "failed" }) do
            restoreSession({ job("failed", "old error") })
            local menu = plugin:showDownloads()
            menu.item_table[1].callback()
            local viewer = stack[#stack]
            if state == "cleared" then
                queue:clearFailed()
            elseif state == "failed" then
                queue:upsertPersistentJob(job("failed", "new error"))
            else
                queue:upsertPersistentJob(job(state))
                queue:setStatus(manga, chapter, { state = state })
            end
            button(viewer, "retry").callback()
            assert.are.equal(state == "failed" and 1 or 0, #queue.items)
            assert.are.same({ menu }, stack)
            ui:close(menu)
        end
    end)

    it("revalidates Retry against a replaced queue instance", function()
        restoreSession({ job("failed", "old error") })
        plugin:showChapterDownloadError(manga, chapter)
        local viewer = stack[1]
        local old_queue = queue
        restoreSession({ job("queued", "scheduled error", 130) })
        button(viewer, "retry").callback()
        assert.are.equal(0, #old_queue.items)
        assert.are.equal(1, #queue.items)
        assert.are.equal(130, queue:findPersistentJob("m1:c1").retry_at)
    end)

    it("refreshes the visible home failure count after real failure, retry, and clear actions", function()
        local home = plugin:showHome()
        assert.are.equal("Downloads", home.actions[3].text)
        local active = job("downloading")
        active.progress_path = os.tmpname()
        queue:setActiveJob(active)
        queue.active_job_lifecycle:finishWithFailure(active, full_error)
        assert.are.same({ home }, stack)
        assert.are.equal("Downloads · 1 failed", home.actions[3].text)
        plugin:showChapterDownloadError(manga, chapter)
        button(stack[2], "retry").callback()
        assert.are.equal("queued", queue:getStatus(manga, chapter).state)
        assert.are.equal("Downloads", home.actions[3].text)
        queue:cancelPending(manga, chapter)
        active.progress_path = os.tmpname()
        queue:setActiveJob(active)
        queue.active_job_lifecycle:finishFromProgress(active, { state = "failed", error = "terminal error" })
        assert.are.equal("Downloads · 1 failed", home.actions[3].text)
        plugin:performDownloadsTitleAction({ id = "clear_failed" })
        assert.are.equal("Downloads", home.actions[3].text)
        assert.are.equal(0, queue:getFailedCount())
        assert.are.same({}, messages)
    end)

    it("publishes terminal and scheduled failures only after complete queue state is available", function()
        local menu = plugin:showDownloads()
        local active = job("downloading")
        active.progress_path = os.tmpname()
        active.downloader = queue.downloader
        queue:setActiveJob(active)
        queue.active_job_lifecycle:finishWithoutProgress(active)
        assert.are.equal(1, queue:getFailedCount())
        assert.are.equal("Failed", menu.item_table[1].mandatory)
        menu.item_table[#menu.item_table].callback()
        assert.are.equal(0, queue:getFailedCount())
        assert.are.same({}, messages)
        local current_menu = plugin.current_downloads_menu
        active.progress_path = os.tmpname()
        queue:setActiveJob(active)
        queue.active_job_lifecycle:scheduleTransientRetry(active, { error = full_error })
        assert.are.equal("Retry scheduled", current_menu.item_table[1].mandatory)
        assert.are.equal(full_error, queue:getSnapshot().queued[1].progress.error)
        assert.are.same({}, messages)
    end)
end)
