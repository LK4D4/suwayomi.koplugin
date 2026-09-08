package.path = "?.lua;" .. package.path

-- Public actions compose real selection, confirmations, queue admission, and the
-- checked settings store. Only host widgets, workers, and filesystem IO are fake.
describe("bounded bulk download actions", function()
    local plugin, queue, settings, stack, messages, files, failure, archives
    local settings_path = "/bulk-test/suwayomi.lua"
    local manga = { id = "m1", title = "Example manga" }
    local saved_modules = {}
    local original_remove
    local marker_installed = false
    local modules = {
        "gettext", "ffi/util", "datastorage", "luasettings", "ui/uimanager",
        "ui/widget/infomessage", "ui/widget/confirmbox", "ui/widget/buttondialog",
        "ui/widget/multiinputdialog", "ui/widget/menu",
        "suwayomi/settings", "suwayomi/settings/store", "suwayomi/i18n", "suwayomi/ui",
        "suwayomi/ui/menu_utils", "suwayomi/ui/browse", "suwayomi/ui/choice_dialogs",
        "suwayomi/ui/directory", "suwayomi/ui/downloads", "suwayomi/ui/list_rows", "suwayomi/ui/manga_info",
        "suwayomi/chapters/actions", "suwayomi/chapters/context", "suwayomi/chapters/menu",
        "suwayomi/chapters/local_downloads", "suwayomi/chapters/delete_actions", "suwayomi/chapters/read_actions",
        "suwayomi/manga/controller", "suwayomi/manga/action_menu", "suwayomi/downloads/queue",
        "suwayomi/downloads/downloader",
        "suwayomi/downloads/active_jobs", "suwayomi/downloads/job_store", "suwayomi/downloads/status_formatter",
    }

    local function chapters(count)
        local result = {}
        for index = 1, count do
            result[index] = { id = "c" .. index, name = "Chapter " .. index, source_order = index }
        end
        return result
    end

    local function openChapters(items)
        plugin:setCurrentMangaChapterContext(manga, items)
        plugin.current_chapter_menu = { title = "Chapters" }
        return items
    end

    local function storedJobs()
        return assert(loadstring(files[settings_path]))().download_queue or {}
    end

    before_each(function()
        for _, name in ipairs(modules) do
            saved_modules[name] = { loaded = package.loaded[name], preload = package.preload[name] }
            package.loaded[name], package.preload[name] = nil, nil
        end
        stack, messages, files, archives, failure = {}, {}, {}, {}, nil
        original_remove = os.remove
        os.remove = function(path) files[path] = nil; return true end
        files[settings_path] = 'return { download_directory = "/books", download_queue = {} }'
        package.preload.datastorage = function() return { getSettingsDir = function() return "/bulk-test" end } end
        package.preload.luasettings = function()
            return { open = function()
                local data = assert(loadstring(files[settings_path]))()
                return { data = data, readSetting = function(_, key, default) return data[key] or default end }
            end }
        end
        require("spec/support/controller_module_spec_helper").stubControllerDependencies()
        local ui = {
            show = function(_, widget) stack[#stack + 1] = widget end,
            close = function(_, widget)
                for index = #stack, 1, -1 do
                    if stack[index] == widget then table.remove(stack, index) end
                end
            end,
            scheduleIn = function() end,
        }
        package.preload["ui/uimanager"] = function() return ui end
        settings = require("suwayomi/settings")
        settings:setStore(require("suwayomi/settings/store"):new{
            path = settings_path,
            luasettings = settings:open(),
            io = {
                read = function(path) return files[path] end,
                open = function(path) return { path = path } end,
                write = function(handle, text)
                    if failure == "write" then return false, "injected write failure" end
                    handle.text = text
                    return true
                end,
                flush = function() return true end,
                sync_file = function() return true end,
                close = function(handle) files[handle.path] = handle.text; return true end,
                rename = function(from, to) files[to], files[from] = files[from], nil; return true end,
                sync_dir = function()
                    if failure == "sync_dir" then return false, "injected sync failure" end
                    return true
                end,
                remove = function(path) files[path] = nil; return true end,
                dir_exists = function() return true end,
            },
        })
        queue = require("suwayomi/downloads/queue"):new{
            settings = settings, ui_manager = ui,
            downloader = {
                getTargetPath = function(_, directory, target_manga, chapter)
                    return directory, directory .. "/" .. target_manga.id .. "-" .. chapter.id .. ".cbz"
                end,
                chapterExists = function(_, path) return archives[path] == true end,
            },
            ffi_util = { runInSubProcess = function() return 123 end, isSubProcessDone = function() return false end },
        }
        package.preload["suwayomi/downloads/downloader"] = function() return queue.downloader end
        plugin = { max_batch_queue_chapters = 50 }
        for _, module in ipairs({ "suwayomi/chapters/context", "suwayomi/chapters/actions",
            "suwayomi/chapters/menu", "suwayomi/manga/controller" }) do
            for name, method in pairs(require(module).methods) do plugin[name] = method end
        end
        function plugin:getDownloadQueue() return queue end
        function plugin:getDownloadDirectoryOrChoose() return settings:loadDownloadDirectory() end
        function plugin:showMessage(text) messages[#messages + 1] = text end
        function plugin:refreshChapterMenu() end
        function plugin:withChapterMenuRefreshSuppressed(callback) return callback() end
    end)

    after_each(function()
        if marker_installed then
            require("spec/support/i18n_marker").uninstall()
            marker_installed = false
        end
        os.remove = original_remove
        for _, name in ipairs(modules) do
            package.loaded[name], package.preload[name] = saved_modules[name].loaded, saved_modules[name].preload
        end
    end)

    it("discloses and commits only the first 50 of 51 eligible all-chapter downloads", function()
        openChapters(chapters(51))
        plugin:performMangaAction(manga, "download_all_chapters")
        local dialog = stack[#stack]
        assert.is_truthy(dialog.text:find("Download all chapters (up to 50 new)", 1, true))
        assert.is_truthy(dialog.text:find("Queue up to 50 new chapter downloads?", 1, true))
        assert.is_truthy(dialog.text:find("0 already downloaded or in the download queue.", 1, true))
        assert.is_truthy(dialog.text:find("1 eligible chapter left outside this batch.", 1, true))
        assert.are.same({}, storedJobs())
        dialog.ok_callback()
        assert.are.equal(50, #storedJobs())
        assert.are.equal("c50", storedJobs()[50].chapter.id)
        assert.is_nil(queue:findPersistentJob("m1:c51"))
        assert.is_truthy(messages[#messages]:find("Queued 50 chapter downloads.", 1, true))
        assert.is_truthy(messages[#messages]:find("1 eligible chapter left outside this batch.", 1, true))
    end)

    it("revalidates captured unread identities without backfilling after availability changes", function()
        local items = openChapters(chapters(51))
        plugin:performMangaAction(manga, "download_all_unread")
        local dialog = stack[#stack]
        assert.is_truthy(dialog.text:find("Queue up to 50 new chapter downloads?", 1, true))
        items[1].is_read = true
        assert.is_true(queue:enqueue(manga, items[2], "/books"))
        archives["/books/m1-c3.cbz"] = true
        dialog.ok_callback()
        assert.is_truthy(messages[#messages]:find("Queued 47 chapter downloads.", 1, true))
        assert.is_truthy(messages[#messages]:find("Skipped 3 chapters.", 1, true))
        assert.is_truthy(messages[#messages]:find("1 eligible chapter left outside this batch.", 1, true))
        assert.are.equal(48, #storedJobs())
        assert.is_nil(queue:findPersistentJob("m1:c1"))
        assert.is_nil(queue:findPersistentJob("m1:c3"))
        assert.is_nil(queue:findPersistentJob("m1:c51"))
    end)

    for _, stale in ipairs({ false, true }) do
        it("bounds traversal for a large filtered batch, stale " .. tostring(stale), function()
            local count = 10000
            settings:saveMangaScanlatorFilter(manga, "Saved group")
            local items = chapters(count)
            for index, item in ipairs(items) do item.scanlator = index % 10 == 0 and "Other group" or "Saved group" end
            openChapters(items)
            archives["/books/m1-c1.cbz"] = true
            assert.is_true(queue:enqueue(manga, items[2], "/books"))
            local visible = plugin.getVisibleChapters
            local visited = 0
            function plugin:getVisibleChapters(source)
                visited = visited + #source
                assert.is_true(visited <= count * 5, "Batch confirmation must traverse the complete context a bounded number of times")
                return visible(self, source)
            end
            plugin:performMangaAction(manga, "download_all_chapters")
            local dialog = stack[#stack]
            assert.is_truthy(dialog.text:find("Queue up to 50 new chapter downloads?", 1, true))
            assert.is_truthy(dialog.text:find("2 already downloaded or in the download queue.", 1, true))
            assert.is_truthy(dialog.text:find("8948 eligible chapters left outside this batch.", 1, true))
            assert.are.equal(1, #storedJobs())
            if stale then plugin:setCurrentMangaChapterContext(manga, {}) end
            dialog.ok_callback()
            local expected = { "c2" }
            if not stale then
                for index = 3, count do
                    if index % 10 ~= 0 then expected[#expected + 1] = "c" .. index end
                    if #expected == 51 then break end
                end
            end
            local admitted = {}
            for _, job in ipairs(storedJobs()) do admitted[#admitted + 1] = job.chapter.id end
            assert.are.same(expected, admitted)
            assert.is_truthy(messages[#messages]:find(stale and "Queued 0 chapter downloads." or "Queued 50 chapter downloads.", 1, true))
            assert.is_truthy(messages[#messages]:find(stale and "Skipped 52 chapters." or "Skipped 2 chapters.", 1, true))
            assert.is_truthy(messages[#messages]:find("8948 eligible chapters left outside this batch.", 1, true))
        end)
    end

    it("captures capped selection, discloses its limit, and keeps the menu on acceptance", function()
        local items = openChapters(chapters(52))
        plugin:selectAllChapters()
        local menu = plugin.current_chapter_menu
        local action = plugin:getBulkChapterActions()[1]
        assert.are.equal("Download selected (up to 50 new)", action.text)
        plugin:performBulkChapterAction(action.id)
        local dialog = stack[#stack]
        assert.is_truthy(dialog.text:find("Queue up to 50 new chapter downloads?", 1, true))
        assert.is_truthy(dialog.text:find("2 eligible chapters left outside this batch.", 1, true))
        assert.are.same({}, storedJobs())
        plugin:clearChapterSelection(true)
        plugin:toggleChapterSelection(manga, items[52])
        dialog.ok_callback()
        assert.are.equal(50, #storedJobs())
        assert.is_nil(queue:findPersistentJob("m1:c52"))
        assert.are.equal(menu, plugin.current_chapter_menu)
        assert.are.equal(0, plugin:getSelectedChapterCount())
    end)

    for _, stale_change in ipairs({ "manga", "filter", "retired menu", "reloaded context", "mutated manga identity", "newer request", "cancellation", "retired host" }) do
        it("rejects a confirmation after " .. stale_change .. " without touching the new selection", function()
            local items = openChapters(chapters(51))
            plugin:selectAllChapters()
            plugin:performMangaAction(manga, "download_all_chapters")
            local dialog = stack[#stack]
            if stale_change == "manga" then
                plugin:setCurrentMangaChapterContext({ id = "m2", title = "Other manga" }, items)
            elseif stale_change == "filter" then
                plugin.current_scanlator_filter = "Other group"
            elseif stale_change == "retired menu" then
                plugin.current_chapter_menu = nil
            elseif stale_change == "reloaded context" then
                plugin:setCurrentMangaChapterContext(manga, chapters(52))
            elseif stale_change == "mutated manga identity" then
                plugin.current_chapter_context.manga = { id = "m2", title = "Other manga" }
            elseif stale_change == "newer request" then
                plugin.chapter_request_revision = (plugin.chapter_request_revision or 0) + 1
            elseif stale_change == "cancellation" then
                plugin:cancelMangaNetworkRequests()
            else
                plugin:retireChapterHost()
            end
            plugin:selectAllChapters()
            local selected = plugin:getSelectedChapterCount()
            dialog.ok_callback()
            if stale_change == "retired host" then
                assert.are.same({}, messages)
            else
                assert.is_truthy(messages[#messages]:find("Chapter view changed. Run this download action again.", 1, true))
                assert.is_truthy(messages[#messages]:find("Queued 0 chapter downloads.", 1, true))
                assert.is_truthy(messages[#messages]:find("Skipped 50 chapters.", 1, true))
            end
            assert.are.same({}, storedJobs())
            assert.are.equal(selected, plugin:getSelectedChapterCount())
        end)
    end

    for _, entrypoint in ipairs({ "manga", "chapter" }) do
        it("bounds next 60 from " .. entrypoint .. " after shared eligibility without changing next semantics", function()
            local items = chapters(70)
            items[1].is_read = true
            openChapters(items)
            archives["/books/m1-c2.cbz"] = true
            assert.is_true(queue:enqueue(manga, items[3], "/books"))
            if entrypoint == "manga" then
                plugin:performMangaAction(manga, "download_next_60_unread")
            else
                plugin.performMangaAction = nil
                plugin:performBulkChapterAction("download_next_60_unread")
            end
            local dialog = stack[#stack]
            assert.is_truthy(dialog.text:find("Download next 60 (up to 50 new)", 1, true))
            assert.is_truthy(dialog.text:find("Queue up to 50 new chapter downloads?", 1, true))
            assert.is_truthy(dialog.text:find("2 already downloaded or in the download queue.", 1, true))
            assert.is_truthy(dialog.text:find("10 eligible chapters left outside this batch.", 1, true))
            dialog.ok_callback()
            assert.are.equal(51, #storedJobs())
            assert.is_not_nil(queue:findPersistentJob("m1:c53"))
            assert.is_nil(queue:findPersistentJob("m1:c54"))
            assert.is_truthy(messages[#messages]:find("Queued 50 chapter downloads.", 1, true))
        end)
    end

    for _, action in ipairs({ "download_all_chapters", "download_all_unread", "download_selected", "download_next_50_unread" }) do
        it("keeps a missing saved scanlator restriction for " .. action, function()
            assert.are.equal("Saved group", settings:saveMangaScanlatorFilter(manga, "Saved group"))
            local items = chapters(51)
            for _, item in ipairs(items) do item.scanlator = "Other group" end
            openChapters(items)
            assert.are.equal("Saved group", plugin.current_scanlator_filter)
            if action == "download_selected" then
                plugin:selectAllChapters()
                plugin:performBulkChapterAction(action)
            else
                plugin:performMangaAction(manga, action)
            end
            assert.are.same({}, stack)
            assert.are.same({}, storedJobs())
            assert.is_truthy(messages[1]:find("saved scanlator filter", 1, true))
        end)
    end

    it("keeps failed retry artifacts when bulk admission is rejected", function()
        local items = openChapters(chapters(1))
        assert.is_truthy(queue:savePersistentJobs({ queue:buildPersistentJob(manga, items[1], "/books", "failed") }))
        assert.is_true(queue:recover())
        local progress_path = "/books/unknown-attempt.progress"
        files[progress_path], files["/books/m1-c1.cbz.part"] = "old progress", "old partial"
        plugin:performMangaAction(manga, "download_all_chapters")
        assert.is_truthy(stack[#stack].text:find("Queue up to 1 new chapter download?", 1, true))
        failure = "write"
        stack[#stack].ok_callback()
        assert.are.equal("old progress", files[progress_path])
        assert.are.equal("old partial", files["/books/m1-c1.cbz.part"])
        assert.are.equal("failed", storedJobs()[1].state)
        assert.is_truthy(messages[#messages]:find("Failed to queue 1 chapter download.", 1, true))
    end)

    for _, action in ipairs({ "download_all_chapters", "download_all_unread" }) do
        for _, size in ipairs({ 0, 1, 49, 50, 51, 137 }) do
            it(action .. " reports and persists a batch of " .. size .. " eligible chapters", function()
                openChapters(chapters(math.max(size, 1)))
                if size == 0 then archives["/books/m1-c1.cbz"] = true end
                plugin:performMangaAction(manga, action)
                if size == 0 then
                    assert.are.same({}, stack)
                    assert.are.same({}, storedJobs())
                    assert.are.equal("No new downloads available: chapters are already downloaded or in the download queue.", messages[#messages])
                    return
                end
                local expected_count = math.min(size, 50)
                local dialog = stack[#stack]
                assert.is_truthy(dialog.text:find("Queue up to " .. expected_count .. " new chapter download", 1, true))
                assert.are.same({}, storedJobs())
                dialog.ok_callback()
                assert.are.equal(expected_count, #storedJobs())
                assert.are.equal(expected_count, #queue:getSnapshot().queued)
                assert.is_truthy(messages[#messages]:find("Queued " .. expected_count .. " chapter download", 1, true))
                assert.is_truthy(messages[#messages]:find(size > 50 and (size - 50) .. " eligible chapter" or "0 eligible chapters", 1, true))
            end)
        end

        it(action .. " excludes files and every owned state before counting the cap, while allowing explicit failed retries", function()
            local items = openChapters(chapters(60))
            items[1].is_read = true
            archives["/books/m1-c2.cbz"] = true
            queue.max_active_chapters = 1
            assert.is_true(queue:enqueue(manga, items[4], "/books"))
            assert.is_true(queue:enqueue(manga, items[3], "/books"))
            queue:process()
            assert.are.equal(1, queue:getActiveCount())
            local owner = queue:getActiveJob("m1:c4")
            queue:setStatus(manga, items[4], { state = "failed" })
            for index, state in ipairs({ "stopping", "finalizing", "running", "downloaded", "skipped" }) do
                queue:setStatus(manga, items[index + 4], { state = state })
            end
            archives["/books/m1-c8.cbz"], archives["/books/m1-c9.cbz"] = true, true
            assert.is_truthy(queue:upsertPersistentJob(queue:buildPersistentJob(manga, items[10], "/books", "failed")))
            queue:setStatus(manga, items[10], { state = "failed" })
            local owner_progress = owner.progress_path
            local retry_progress = "/books/unknown-attempt.progress"
            files[owner_progress], files[retry_progress] = "owned progress", "failed progress"
            plugin:performMangaAction(manga, action)
            local dialog = stack[#stack]
            assert.is_truthy(dialog.text:find("Queue up to 50 new chapter downloads?", 1, true))
            assert.is_truthy(dialog.text:find("8 already downloaded or in the download queue.", 1, true))
            assert.is_truthy(dialog.text:find(action == "download_all_chapters"
                and "2 eligible chapters left outside this batch." or "1 eligible chapter left outside this batch.", 1, true))
            dialog.ok_callback()
            assert.are.equal(52, #storedJobs())
            assert.are.equal(owner, queue:getActiveJob("m1:c4"))
            assert.are.equal("owned progress", files[owner_progress])
            assert.are.equal("failed progress", files[retry_progress])
            assert.are.equal("queued", queue:findPersistentJob("m1:c10").state)
            assert.is_nil(queue:findPersistentJob("m1:c60"))
            assert.are.equal(action == "download_all_chapters", queue:findPersistentJob("m1:c1") ~= nil)
            assert.is_truthy(messages[#messages]:find("Queued 50 chapter downloads.", 1, true))
            assert.is_truthy(messages[#messages]:find("Skipped 8 chapters.", 1, true))
        end)
    end

    it("does not admit a canceled selected batch or clear selection", function()
        openChapters(chapters(51))
        plugin:selectAllChapters()
        local menu = plugin.current_chapter_menu
        plugin:performBulkChapterAction("download_selected")
        assert.is_truthy(stack[#stack].text:find("1 eligible chapter left outside this batch.", 1, true))
        require("ui/uimanager"):close(stack[#stack])
        assert.are.same({}, stack)
        assert.are.same({}, storedJobs())
        assert.are.equal(51, plugin:getSelectedChapterCount())
        assert.are.equal(menu, plugin.current_chapter_menu)
        assert.are.same({}, messages)
    end)

    it("deduplicates captured identities and racing confirmations, and requires another explicit action for the remainder", function()
        local items = chapters(51)
        table.insert(items, 1, items[1])
        openChapters(items)
        plugin:performMangaAction(manga, "download_all_chapters")
        local first = stack[#stack]
        plugin:performMangaAction(manga, "download_all_chapters")
        local second = stack[#stack]
        assert.is_truthy(first.text:find("1 eligible chapter left outside this batch.", 1, true))
        first.ok_callback()
        second.ok_callback()
        second.ok_callback()
        assert.are.equal(50, #storedJobs())
        assert.are.equal(50, #queue:getSnapshot().queued)
        assert.is_truthy(messages[#messages]:find("Queued 0 chapter downloads.", 1, true))
        assert.is_truthy(messages[#messages]:find("Skipped 50 chapters.", 1, true))
        assert.is_nil(queue:findPersistentJob("m1:c51"))
        plugin:performMangaAction(manga, "download_all_chapters")
        assert.is_truthy(stack[#stack].text:find("Queue up to 1 new chapter download?", 1, true))
        stack[#stack].ok_callback()
        assert.are.equal(51, #storedJobs())
        assert.is_truthy(messages[#messages]:find("Queued 1 chapter download.", 1, true))
    end)

    it("retains authoritative single and batch admission guards for files, ownership, and duplicate identities", function()
        local items = openChapters(chapters(4))
        archives["/books/m1-c1.cbz"] = true
        assert.is_false(queue:enqueue(manga, items[1], "/books"))
        assert.is_true(queue:enqueue(manga, items[2], "/books"))
        queue:process()
        local owner = queue:getActiveJob("m1:c2")
        queue:setStatus(manga, items[2], { state = "failed" })
        assert.is_false(queue:enqueue(manga, items[2], "/books"))
        local queued, err, outcome = queue:enqueueBatch(manga, { items[1], items[2], items[3], items[3], items[4] }, "/books")
        assert.are.equal(2, queued)
        assert.is_nil(err)
        assert.are.same({ skipped = 3, failed = 0, unconfirmed = 0 }, outcome)
        assert.are.equal(3, #storedJobs())
        assert.are.equal(owner, queue:getActiveJob("m1:c2"))
    end)

    for _, terminal_state in ipairs({ "downloaded", "skipped" }) do
        it("keeps active ownership authoritative over stale " .. terminal_state .. " status without an archive", function()
            local items = openChapters(chapters(1))
            assert.is_true(queue:enqueue(manga, items[1], "/books"))
            queue:process()
            local owner = queue:getActiveJob("m1:c1")
            assert.is_not_nil(owner)
            queue:setStatus(manga, items[1], { state = terminal_state })
            assert.is_false(queue:enqueue(manga, items[1], "/books"))
            local queued, err, outcome = queue:enqueueBatch(manga, items, "/books")
            assert.are.equal(0, queued)
            assert.is_nil(err)
            assert.are.same({ skipped = 1, failed = 0, unconfirmed = 0 }, outcome)
            assert.are.equal(1, #storedJobs())
            assert.are.equal(owner, queue:getActiveJob("m1:c1"))
            assert.are.equal(0, #queue:getSnapshot().queued)
        end)

        for _, change in ipairs({ "archive removal", "directory change" }) do
            for _, entrypoint in ipairs({ "chapter", "bulk" }) do
                it("re-admits " .. terminal_state .. " through " .. entrypoint .. " after " .. change, function()
                    local items = openChapters(chapters(1))
                    local old_path = "/books/m1-c1.cbz"
                    archives[old_path] = true
                    queue:setStatus(manga, items[1], { state = terminal_state, path = old_path })
                    assert.are.equal("open", plugin:getChapterActions(manga, items[1])[1].id)
                    assert.is_false(queue:enqueue(manga, items[1], "/books"))
                    local directory = "/books"
                    if change == "archive removal" then
                        archives[old_path] = nil
                    else
                        directory = "/new-books"
                        settings:saveDownloadDirectory(directory)
                    end
                    local action = plugin:getChapterActions(manga, items[1])[1]
                    assert.are.equal("download", action.id)
                    assert.are.equal("Download", action.text)
                    if entrypoint == "chapter" then
                        plugin:performChapterAction(manga, items[1], action.id)
                    else
                        plugin:performMangaAction(manga, "download_all_chapters")
                        local dialog = stack[#stack]
                        assert.is_not_nil(dialog)
                        assert.is_truthy(dialog.text:find("Queue up to 1 new chapter download?", 1, true))
                        dialog.ok_callback()
                        assert.is_truthy(messages[#messages]:find("Queued 1 chapter download.", 1, true))
                    end
                    local jobs = storedJobs()
                    assert.are.equal(1, #jobs)
                    assert.are.equal("m1:c1", jobs[1].key)
                    assert.are.equal("queued", jobs[1].state)
                    assert.are.equal(directory, jobs[1].download_directory)
                    assert.are.equal(1, #queue:getSnapshot().queued)
                    assert.are.equal(change == "directory change", archives[old_path] == true)
                end)
            end
        end
    end

    for _, action in ipairs({ "download_selected", "download_next_5_unread" }) do
        it("keeps " .. action .. " immediate when a small batch fits", function()
            local items = openChapters(chapters(10))
            archives["/books/m1-c1.cbz"] = true
            assert.is_true(queue:enqueue(manga, items[2], "/books"))
            if action == "download_selected" then
                for index = 1, 5 do plugin:toggleChapterSelection(manga, items[index]) end
                plugin:performBulkChapterAction(action)
            else
                plugin:performMangaAction(manga, action)
            end
            assert.are.same({}, stack)
            assert.are.equal(action == "download_selected" and 4 or 6, #storedJobs())
            assert.is_truthy(messages[#messages]:find(action == "download_selected"
                and "Queued 3 chapter downloads." or "Queued 5 chapter downloads.", 1, true))
            assert.is_truthy(messages[#messages]:find("Skipped 2 chapters.", 1, true))
            assert.are.equal(0, plugin:getSelectedChapterCount())
        end)
    end

    it("keeps unconfirmed retry artifacts and reports a later store-fenced command as rejected", function()
        local items = openChapters(chapters(1))
        assert.is_truthy(queue:savePersistentJobs({ queue:buildPersistentJob(manga, items[1], "/books", "failed") }))
        assert.is_true(queue:recover())
        local progress_path = "/books/unknown-attempt.progress"
        files[progress_path] = "old progress"
        plugin:performMangaAction(manga, "download_all_chapters")
        failure = "sync_dir"
        stack[#stack].ok_callback()
        assert.is_truthy(messages[#messages]:find("Could not confirm 1 chapter download.", 1, true))
        assert.are.equal("old progress", files[progress_path])
        assert.are.equal("queued", storedJobs()[1].state)
        assert.are.equal("failed", queue:getSnapshot().failed[1].state)
        local unconfirmed_document = files[settings_path]
        plugin:performMangaAction(manga, "download_all_chapters")
        stack[#stack].ok_callback()
        assert.is_truthy(messages[#messages]:find("Failed to queue 1 chapter download.", 1, true))
        assert.is_nil(messages[#messages]:find("Could not confirm", 1, true))
        assert.are.equal(unconfirmed_document, files[settings_path])
        assert.are.equal("old progress", files[progress_path])
    end)

    it("counts unique next candidates before the requested amount and the 50-new cap", function()
        local items = chapters(51)
        for _ = 1, 20 do table.insert(items, 1, items[1]) end
        openChapters(items)
        plugin:performMangaAction(manga, "download_next_60_unread")
        local dialog = stack[#stack]
        assert.is_truthy(dialog.text:find("Queue up to 50 new chapter downloads?", 1, true))
        assert.is_truthy(dialog.text:find("1 eligible chapter left outside this batch.", 1, true))
        dialog.ok_callback()
        assert.are.equal(50, #storedJobs())
        assert.is_nil(queue:findPersistentJob("m1:c51"))
        assert.is_truthy(messages[#messages]:find("Queued 50 chapter downloads.", 1, true))
    end)

    it("does not replace a captured chapter with its mutated or newly inserted identity", function()
        local items = openChapters(chapters(51))
        plugin:performMangaAction(manga, "download_all_chapters")
        local dialog = stack[#stack]
        items[1].id = "unrelated"
        table.insert(items, { id = "new", name = "New chapter" })
        dialog.ok_callback()
        assert.are.equal(49, #storedJobs())
        assert.is_nil(queue:findPersistentJob("m1:unrelated"))
        assert.is_nil(queue:findPersistentJob("m1:new"))
        assert.is_nil(queue:findPersistentJob("m1:c51"))
        assert.is_truthy(messages[#messages]:find("Queued 49 chapter downloads.", 1, true))
        assert.is_truthy(messages[#messages]:find("Skipped 1 chapter.", 1, true))
    end)

    for _, action in ipairs({ "download_all_chapters", "download_all_unread", "download_selected", "download_next_5_unread" }) do
        it("applies the saved scanlator before capacity even when the visible filter differs for " .. action, function()
            settings:saveMangaScanlatorFilter(manga, "Saved group")
            local items = chapters(60)
            for index, item in ipairs(items) do item.scanlator = index <= 9 and "Other group" or "Saved group" end
            items[10].is_read = true
            openChapters(items)
            plugin.current_scanlator_filter = nil
            if action == "download_selected" then
                plugin:selectAllChapters()
                plugin:performBulkChapterAction(action)
            else
                plugin:performMangaAction(manga, action)
            end
            if action ~= "download_next_5_unread" then
                assert.is_truthy(stack[#stack].text:find("Scanlator: Saved group", 1, true))
                stack[#stack].ok_callback()
            end
            assert.are.equal(action == "download_next_5_unread" and 5 or 50, #storedJobs())
            for _, job in ipairs(storedJobs()) do assert.are.equal("Saved group", job.chapter.scanlator) end
            assert.are.equal(action == "download_all_chapters" or action == "download_selected", queue:findPersistentJob("m1:c10") ~= nil)
            assert.is_truthy(messages[#messages]:find("Skipped 0 chapters.", 1, true))
        end)
    end

    for _, storage_failure in ipairs({ "write", "sync_dir" }) do
        it("partitions skipped, capped, and " .. storage_failure .. " results without counting any failed candidate as admitted", function()
            local items = openChapters(chapters(52))
            archives["/books/m1-c1.cbz"] = true
            plugin:performMangaAction(manga, "download_all_chapters")
            local dialog = stack[#stack]
            assert.is_truthy(dialog.text:find("Queue up to 50 new chapter downloads?", 1, true))
            assert.is_truthy(dialog.text:find("1 already downloaded or in the download queue.", 1, true))
            assert.is_truthy(dialog.text:find("1 eligible chapter left outside this batch.", 1, true))
            assert.is_true(queue:enqueue(manga, items[2], "/books"))
            failure = storage_failure
            dialog.ok_callback()
            assert.is_truthy(messages[#messages]:find("Queued 0 chapter downloads.", 1, true))
            assert.is_truthy(messages[#messages]:find("Skipped 2 chapters.", 1, true))
            assert.is_truthy(messages[#messages]:find("1 eligible chapter left outside this batch.", 1, true))
            assert.is_truthy(messages[#messages]:find(storage_failure == "write"
                and "Failed to queue 49 chapter downloads." or "Could not confirm 49 chapter downloads.", 1, true))
            assert.are.equal(storage_failure == "write" and 1 or 50, #storedJobs())
            assert.are.equal(1, #queue:getSnapshot().queued)
        end)

        it("preserves artifacts and admission state for a rejected single retry with " .. storage_failure, function()
            local items = openChapters(chapters(1))
            queue:savePersistentJobs({ queue:buildPersistentJob(manga, items[1], "/books", "failed") })
            queue:recover()
            local progress_path = "/books/unknown-attempt.progress"
            files[progress_path] = "old progress"
            failure = storage_failure
            local accepted, state = queue:enqueue(manga, items[1], "/books")
            assert.is_false(accepted)
            assert.is_truthy(state:match(storage_failure == "write" and "write_failed" or "ambiguous_post_replacement"))
            assert.are.equal("old progress", files[progress_path])
            assert.are.equal(0, #queue:getSnapshot().queued)
        end)
    end

    it("localizes plural confirmations and results while keeping manga and scanlator names as external data", function()
        require("spec/support/i18n_marker").install()
        marker_installed = true
        for _, module in ipairs({ "suwayomi/chapters/actions", "suwayomi/chapters/context", "suwayomi/manga/controller" }) do
            package.loaded[module] = nil
            for name, method in pairs(require(module).methods) do plugin[name] = method end
        end
        settings:saveMangaScanlatorFilter(manga, "Saved group")
        local items = chapters(52)
        for _, item in ipairs(items) do item.scanlator = "Saved group" end
        openChapters(items)
        archives["/books/m1-c1.cbz"] = true
        plugin:performMangaAction(manga, "download_all_chapters")
        local dialog = stack[#stack]
        assert.is_truthy(dialog.text:find("tx:Queue up to 50 new chapter downloads?", 1, true))
        assert.is_truthy(dialog.text:find("tx:1 already downloaded or in the download queue.", 1, true))
        assert.is_truthy(dialog.text:find("tx:1 eligible chapter left outside this batch.", 1, true))
        assert.is_truthy(dialog.text:find("\nExample manga\n", 1, true))
        assert.is_truthy(dialog.text:find("tx:Scanlator: Saved group", 1, true))
        assert.are.equal("tx:Queue", dialog.ok_text)
        dialog.ok_callback()
        assert.are.equal(50, #storedJobs())
        assert.is_truthy(messages[#messages]:find("tx:Queued 50 chapter downloads.", 1, true))
        assert.is_truthy(messages[#messages]:find("tx:Skipped 1 chapter.", 1, true))
    end)

    for _, storage_failure in ipairs({ "write", "sync_dir" }) do
        it("reports " .. storage_failure .. " without claiming admission or clearing selection", function()
            openChapters(chapters(2))
            plugin:selectAllChapters()
            plugin:performMangaAction(manga, "download_all_chapters")
            local dialog = stack[#stack]
            assert.is_truthy(dialog.text:find("Queue up to 2 new chapter downloads?", 1, true))
            failure = storage_failure
            dialog.ok_callback()
            assert.is_truthy(messages[#messages]:find("Queued 0 chapter downloads.", 1, true))
            assert.is_truthy(messages[#messages]:find(storage_failure == "write"
                and "Failed to queue 2 chapter downloads."
                or "Could not confirm 2 chapter downloads.", 1, true))
            assert.is_truthy(messages[#messages]:find("Skipped 0 chapters.", 1, true))
            assert.are.equal(storage_failure == "write" and 0 or 2, #storedJobs())
            assert.are.equal(0, #queue:getSnapshot().queued)
            assert.are.equal(storage_failure == "sync_dir", settings:isBlocked())
            assert.are.equal(2, plugin:getSelectedChapterCount())
            if storage_failure == "write" then
                failure = nil
                assert.are.equal(3, settings:saveMaxParallelChapterDownloads(3))
                assert.are.same({}, storedJobs())
            end
        end)
    end
end)
