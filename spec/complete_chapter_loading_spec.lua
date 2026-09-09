package.path = "?.lua;" .. package.path

-- Exercise the asynchronous public load/action path through real API parsing,
-- worker result files, chapter context, ledger, menu data, and queue persistence.
describe("complete stored chapter loading", function()
    local json = require("dkjson")
    local plugin, manga, queue, messages, scheduled, workers, requests
    local saved_ledger, saved_jobs, respond, settings, saved_filter, ledger_path, confirmation
    local subprocess_done, loading, fake_time, original_time, worker_ids, poll_ids, pending_pid, next_pid
    local directory_callback, download_directory, chapter_action_callback, error_details
    local archive_directory, archive_path, restore_native, refill_directory
    local modules = {
        "gettext", "ffi/util", "ffi/archiver", "ui/uimanager", "ssl.https",
        "socket.http", "suwayomi/api", "suwayomi/api/queries", "suwayomi/api/parsers",
        "suwayomi/api/transport", "suwayomi/settings", "suwayomi/ui", "suwayomi/i18n",
        "suwayomi/debug", "suwayomi/network/request_job", "suwayomi/network/request_worker",
        "suwayomi/subprocess/job", "suwayomi/manga/controller", "suwayomi/manga/action_menu",
        "suwayomi/chapters/context", "suwayomi/chapters/menu", "suwayomi/chapters/actions",
        "suwayomi/chapters/local_downloads", "suwayomi/chapters/read_actions",
        "suwayomi/chapters/delete_actions", "suwayomi/readsync/ledger",
        "suwayomi/downloads/queue", "suwayomi/downloads/active_jobs",
        "suwayomi/downloads/job_store", "suwayomi/downloads/status_formatter",
        "suwayomi/downloads/downloader", "suwayomi/downloads/progress_file",
        "suwayomi/downloads/archive", "ffi/libarchive_h",
        "suwayomi/downloads/service", "suwayomi/downloads/refill", "suwayomi/downloads/cleanup_adapter",
        "suwayomi/chapters/manual_deletion", "suwayomi/chapters/archive_identity",
        "suwayomi/paths", "suwayomi/downloads/controller",
        "datastorage", "luasettings", "suwayomi/settings/store", "suwayomi/source_filters",
        "suwayomi/downloads/directory", "suwayomi/reader_return",
        "apps/reader/readerui", "apps/filemanager/filemanager",
        "suwayomi/plugin/home", "suwayomi/plugin/title_menu", "ui/widget/infomessage",
        "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/menu", "ui/widget/multiinputdialog",
        "suwayomi/ui/menu_utils", "suwayomi/ui/browse", "suwayomi/ui/choice_dialogs", "suwayomi/ui/directory",
        "suwayomi/ui/downloads", "suwayomi/ui/list_rows", "suwayomi/ui/manga_info",
        "suwayomi/settings/retention_labels",
    }

    local function clearModules()
        for _, name in ipairs(modules) do
            package.loaded[name], package.preload[name] = nil, nil
        end
    end

    local function nodes(first, last)
        local result = {}
        for id = first, last do
            result[#result + 1] = {
                id = id, sourceOrder = id, name = "Chapter " .. id,
                isRead = id <= 200,
            }
        end
        return result
    end

    local function page(chapters, total, continuation)
        return { data = { chapters = {
            nodes = chapters, totalCount = total, pageInfo = { hasNextPage = continuation },
        } } }
    end

    local function chapterIds(chapters)
        local ids = {}
        for _, chapter in ipairs(chapters) do ids[#ids + 1] = chapter.id end
        return ids
    end

    local function admittedIds()
        local ids = {}
        for _, job in ipairs(settings:loadDownloadQueue()) do ids[#ids + 1] = job.chapter.id end
        return ids
    end

    local function finishJob(active)
        assert.is_table(active)
        -- Queue/refill callbacks can precede the requested load's poll.
        -- Complete only this subprocess, including canceled older requests.
        local run, poll
        for index, callback in ipairs(workers) do
            if worker_ids[callback] == active.pid then run = table.remove(workers, index); break end
        end
        assert.is_function(run)
        run()
        local result = require("suwayomi/network/request_worker"):readResult(active.result_path)
        -- Archive inspection uses the queue's poller, not the one-shot request poll.
        if active == queue.verification then
            queue:pollVerification()
            return result
        end
        for index, callback in ipairs(scheduled) do
            if poll_ids[callback] == active.pid then poll = table.remove(scheduled, index); break end
        end
        assert.is_function(poll)
        poll()
        return result
    end

    local function finishRequest(token)
        local active = token or plugin.active_manga_network_requests.chapter_context
            or plugin.active_manga_network_requests.chapter_menu
        return finishJob(active.active)
    end

    local function prepareRefill()
        refill_directory = os.tmpname()
        os.remove(refill_directory)
        assert(require("lfs").mkdir(refill_directory))
        download_directory = refill_directory
        manga.source = { id = "fixture-source", name = "Fixture source" }
        queue.refill:start()
    end

    local function finishRefill()
        local callback = queue.refill.scheduled
        assert.is_function(callback)
        for index, scheduled_callback in ipairs(scheduled) do
            if scheduled_callback == callback then table.remove(scheduled, index); break end
        end
        callback()
        return finishJob(queue.refill.active)
    end

    before_each(function()
        clearModules()
        messages, scheduled, workers, requests = {}, {}, {}, {}
        worker_ids, poll_ids, pending_pid, next_pid = {}, {}, nil, 0
        saved_ledger, saved_jobs = "{}", "[]"
        saved_filter = nil
        confirmation = nil
        directory_callback, download_directory = nil, "./nonexistent-test-library"
        chapter_action_callback, error_details = nil, nil
        subprocess_done, fake_time = true, 100
        original_time = os.time
        os.time = function() return fake_time end
        manga = { id = "17", title = "Example manga", initialized = true }
        settings = {
            load = function() return { server_url = "https://suwayomi.example" } end,
            getSettingsDir = function() return "." end,
            loadDownloadDirectory = function() return download_directory end,
            saveDownloadDirectory = function(_, path) download_directory = path; return path end,
            loadMangaScanlatorFilter = function() return saved_filter end,
        }
        package.preload.datastorage = function() return { getSettingsDir = function() return "." end } end
        package.preload.luasettings = function() return { open = function() return { data = {} } end } end
        local persisted = dofile("suwayomi/settings.lua")
        local checked = require("spec/support/checked_queue_settings")()
        for name, method in pairs(persisted) do
            if settings[name] == nil then settings[name] = method end
        end
        settings:setStore(checked:getStore())
        local store = settings:getStore()
        local saveDocument = store.saveDocument
        function store:saveDocument(mutator)
            local ok, err = saveDocument(self, mutator)
            if ok then
                saved_jobs = json.encode(self:readKey("download_queue", {}))
                saved_ledger = json.encode(self:readKey("chapter_ledger", {}))
            end
            return ok, err
        end
        package.preload["suwayomi/settings"] = function() return settings end
        package.preload.gettext = function() return function(value) return value end end
        package.preload["ffi/archiver"] = function() return {} end
        local host = {
            template = function(text, ...)
                local values = { ... }
                return (text:gsub("%%(%d+)", function(index) return tostring(values[tonumber(index)]) end))
            end,
            joinPath = function(...) return table.concat({ ... }, "/") end,
            runInSubProcess = function(run)
                next_pid = next_pid + 1
                pending_pid, worker_ids[run] = next_pid, next_pid
                workers[#workers + 1] = run
                return next_pid
            end,
            isSubProcessDone = function() return subprocess_done end,
            terminateSubProcess = function() end,
        }
        local ui = { scheduleIn = function(_, _, callback)
                scheduled[#scheduled + 1] = callback
                poll_ids[callback], pending_pid = pending_pid, nil
            end,
            unschedule = function(_, callback)
                for index, scheduled_callback in ipairs(scheduled) do
                    if scheduled_callback == callback then table.remove(scheduled, index); break end
                end
            end,
            nextTick = function(_, callback) scheduled[#scheduled + 1] = callback end,
            show = function(_, widget) loading = widget end,
            close = function(_, widget) if widget.dismiss_callback then widget.dismiss_callback() end end }
        package.preload["ffi/util"] = function() return host end
        package.preload["ui/uimanager"] = function() return ui end
        package.preload["ui/widget/infomessage"] = function() return { new = function(_, options) return options end } end
        package.preload["suwayomi/ui"] = function()
            return { formatRefillStatus = require("suwayomi/ui/downloads").formatRefillStatus,
                showChapterMenu = function(options) return options end,
                showConfirm = function(options) confirmation = options.ok_callback; return true end,
                showChapterActionsMenu = function(_, callback) chapter_action_callback = callback end,
                showDownloadErrorDetails = function(_, options) error_details = options; return true end,
                showDirectoryChooser = function(callback) directory_callback = callback end }
        end
        package.preload["ssl.https"] = function()
            return { request = function(options)
                assert.are.equal(15, options.timeout)
                local request = json.decode(options.source())
                requests[#requests + 1] = request
                assert.is_true(#requests <= 10, "Stored load must not spin or restart automatically")
                local response, code = respond(request, #requests)
                local ok, err = options.sink(type(response) == "string" and response or json.encode(response))
                if not ok then return nil, err end
                return 1, code or 200
            end }
        end
        queue = require("suwayomi/downloads/service"):new{
            settings = settings, downloader = require("suwayomi/downloads/downloader"),
            ffi_util = host, ui_manager = ui,
        }.queue
        plugin = { max_batch_queue_chapters = 50 }
        for _, module in ipairs({ "suwayomi/manga/controller", "suwayomi/chapters/context",
            "suwayomi/chapters/menu", "suwayomi/chapters/actions", "suwayomi/readsync/ledger",
            "suwayomi/downloads/controller", "suwayomi/downloads/directory" }) do
            for name, method in pairs(require(module).methods) do plugin[name] = method end
        end
        function plugin:getDownloadQueue() return queue end
        function plugin:showMessage(message) messages[#messages + 1] = message end
        plugin.showLoadingMessage = require("suwayomi/plugin/home").methods.showLoadingMessage
        plugin.closeLoadingMessage = require("suwayomi/plugin/home").methods.closeLoadingMessage
        function plugin:isChapterPathFinishedInKoreader() return false end
        function plugin:withChapterMenuRefreshSuppressed(callback) return callback() end
    end)

    after_each(function()
        if plugin then plugin:cancelMangaNetworkRequests() end
        if queue then queue.refill:shutdown(fake_time + 1, os.time) end
        if refill_directory then require("lfs").rmdir(refill_directory); refill_directory = nil end
        os.time = original_time
        if ledger_path then os.remove(ledger_path); ledger_path = nil end
        if archive_path then os.remove(archive_path); archive_path = nil end
        if archive_directory then
            local lfs = require("lfs")
            lfs.rmdir(archive_directory .. "/Unknown source/Example manga")
            lfs.rmdir(archive_directory .. "/Unknown source")
            lfs.rmdir(archive_directory)
            archive_directory = nil
        end
        if restore_native then restore_native(); restore_native = nil end
        os.remove("./suwayomi_manga_request_1.json")
        os.remove("./suwayomi_manga_request_1.json.tmp")
        clearModules()
    end)

    it("reopens all 205 chapters and queues five unread chapters beyond page one", function()
        respond = function(request)
            local offset = request.variables.offset or 0
            return page(nodes(offset + 1, math.min(offset + 200, 205)), 205, offset + 200 < 205)
        end
        assert.is_true(plugin:showChaptersForManga(manga))
        assert.is_nil(plugin.current_chapter_context)
        assert.are.same({}, requests)
        finishRequest()
        assert.are.equal(205, #plugin.current_chapter_menu.chapters)
        assert.are.equal("201", plugin:getFirstUnreadChapterForManga(manga).id)
        assert.are.same({ "201", "202", "203", "204", "205" },
            chapterIds(plugin:getNextUnreadChaptersForDownload(manga, 5)))
        assert.are.equal(200, #plugin:getChaptersBefore(plugin.current_chapter_context.chapters[201]))
        assert.is_true(json.decode(saved_ledger)["17:200"].read)
        assert.is_nil(json.decode(saved_ledger)["17:201"])
        plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
        assert.are.same({ "201", "202", "203", "204", "205" }, admittedIds())
        assert.are.same({}, messages)
    end)

    it("preserves the complete view and selection after rejected archive reconciliation", function()
        saved_filter = "Group A"
        respond = function()
            local items = nodes(201, 201)
            items[1].scanlator = "Group A"
            return page(items, 1, false)
        end
        plugin:showChaptersForManga(manga)
        finishRequest()
        local context, menu = plugin.current_chapter_context, plugin.current_chapter_menu
        local chapter = context.chapters[1]
        plugin:toggleChapterSelection(manga, chapter)
        saved_filter = "Group B"
        respond = function()
            local items = nodes(202, 202)
            items[1].scanlator = "Group B"
            return page(items, 1, false)
        end
        queue.downloader.chapterExists = function() return true end
        settings:getStore().io.write = function() return false, "injected write failure" end
        plugin:showChaptersForManga(manga)
        finishRequest()
        assert.are.equal(context, plugin.current_chapter_context)
        assert.are.equal(menu, plugin.current_chapter_menu)
        assert.are.equal("Group A", plugin.current_scanlator_filter)
        assert.is_true(plugin:isChapterSelected(manga, chapter))
        assert.is_true(plugin.selection_mode)
        assert.are.same({ "201" }, chapterIds(plugin.current_chapter_context.chapters))
    end)

    it("preserves the complete view and read ledger without admitting a failed reload action", function()
        respond = function() return page(nodes(1, 1), 1, false) end
        plugin:showChaptersForManga(manga)
        finishRequest()
        local previous_context, previous_menu = plugin.current_chapter_context, plugin.current_chapter_menu
        local previous_ledger, previous_jobs = saved_ledger, saved_jobs
        respond = function(request)
            if request.query:find("GET_MANGA_CHAPTERS_FETCH", 1, true) then
                return { data = { fetchChapters = { chapters = nodes(201, 205) } } }
            end
            if request.variables.offset == 0 then return page(nodes(1, 200), 205, true) end
            return { errors = { { message = "Later page failed." } } }
        end
        plugin:startLoadMangaChapterContext(manga, function()
            plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
        end)
        finishRequest()
        assert.are.equal(previous_context, plugin.current_chapter_context)
        assert.are.equal(previous_menu, plugin.current_chapter_menu)
        assert.are.equal(previous_ledger, saved_ledger)
        assert.are.equal(previous_jobs, saved_jobs)
        assert.matches("Later page failed", messages[#messages])
        assert.are.equal(3, #requests)
    end)

    for _, route in ipairs({ "reopen", "fallback", "initial", "refresh" }) do
        it("shares complete numeric tie order and selection through " .. route, function()
            local chapters = nodes(1, 205)
            chapters[201].sourceOrder = 200
            chapters[201].id = 999
            chapters[202].sourceOrder = 200
            chapters[202].id = 1000
            respond = function(request)
                if request.query:find("GET_CHAPTERS_MANGA", 1, true) then
                    if route == "fallback" then return page({}, 0, false) end
                    local offset, selected = request.variables.offset, {}
                    for index = offset + 1, math.min(offset + 200, #chapters) do
                        selected[#selected + 1] = chapters[index]
                    end
                    return page(selected, #chapters, offset + #selected < #chapters)
                end
                local reversed = {}
                for index = #chapters, 1, -1 do reversed[#reversed + 1] = chapters[index] end
                return { data = { fetchManga = { manga = { id = 17, title = "Example manga" } },
                    fetchChapters = { chapters = reversed } } }
            end
            if route == "initial" then manga.initialized = false end
            if route == "refresh" then plugin:refreshMangaChapters(manga)
            else plugin:showChaptersForManga(manga) end
            finishRequest()
            assert.are.equal(205, #plugin.current_chapter_menu.chapters)
            assert.are.equal("1", plugin.current_chapter_menu.chapters[1].id)
            assert.are.equal("999", plugin:getFirstUnreadChapterForManga(manga).id)
            assert.are.equal(200, #plugin:getChaptersBefore(plugin.current_chapter_context.chapters[201]))
            plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
            assert.are.same({ "999", "1000", "203", "204", "205" }, admittedIds())
            assert.is_true(json.decode(saved_ledger)["17:200"].read)
            assert.are.same({}, messages)
        end)
    end

    for _, filter in ipairs({ "Late group", "Absent group" }) do
        it("keeps exact saved " .. filter .. " across complete reopen and refresh", function()
            saved_filter = filter
            prepareRefill()
            respond = function(request)
                local chapters = nodes(1, 205)
                for index, chapter in ipairs(chapters) do
                    chapter.scanlator = index >= 201 and "Late group" or "Other group"
                end
                if request.query:find("GET_CHAPTERS_MANGA", 1, true) then
                    local offset, selected = request.variables.offset, {}
                    for index = offset + 1, math.min(offset + 200, 205) do selected[#selected + 1] = chapters[index] end
                    return page(selected, 205, offset + #selected < 205)
                end
                return { data = { fetchManga = { manga = { id = 17 } }, fetchChapters = { chapters = chapters } } }
            end
            local expected = filter == "Late group" and { "201", "202", "203", "204", "205" } or {}
            for _, refresh in ipairs({ false, true }) do
                if refresh then plugin:refreshMangaChapters(manga) else plugin:showChaptersForManga(manga) end
                finishRequest()
                assert.are.equal(filter, plugin.current_scanlator_filter)
                assert.are.same(expected, chapterIds(plugin.current_chapter_menu.chapters))
                assert.are.same(expected, chapterIds(plugin:getNextUnreadChaptersForDownload(manga, 5)))
                assert.is_true(json.decode(saved_ledger)["17:200"].read)
            end
            if filter == "Absent group" then
                assert.matches("No chapters match the saved scanlator filter", messages[#messages])
            end
            plugin:keepNextUnreadChaptersForManga(manga, 5)
            assert.are.same({}, admittedIds())
            finishRefill()
            assert.are.same(expected, admittedIds())
        end)
    end

    for _, origin in ipairs({ "chapter title", "chapter bulk" }) do
        for _, dataset in ipairs({ "unlabeled chapters", "empty result", "labeled chapters", "unrestricted unlabeled chapters" }) do
            it("offers explicit saved-filter recovery from " .. origin .. " with " .. dataset, function()
                for name, method in pairs(require("suwayomi/plugin/title_menu").methods) do plugin[name] = method end
                local restricted = dataset ~= "unrestricted unlabeled chapters"
                saved_filter = restricted and "Saved group" or nil
                local filter_writes = 0
                settings.saveMangaScanlatorFilter = function(_, target, filter)
                    assert.are.equal("17", target.id)
                    saved_filter, filter_writes = filter, filter_writes + 1
                    return filter
                end
                respond = function(request)
                    if not request.query:find("GET_CHAPTERS_MANGA", 1, true) then
                        return { data = { fetchChapters = { chapters = {} } } }
                    end
                    if dataset == "empty result" then return page({}, 0, false) end
                    local chapters = nodes(201, 202)
                    chapters[1].scanlator, chapters[2].scanlator = json.null, ""
                    if dataset == "labeled chapters" then
                        chapters[1].scanlator, chapters[2].scanlator = "Saved group", "Other group"
                    end
                    return page(chapters, 2, false)
                end
                local facade = require("suwayomi/ui")
                require("spec/support/controller_module_spec_helper").stubControllerDependencies()
                package.loaded["suwayomi/ui"], package.preload["suwayomi/ui"] = nil, nil
                local real_ui = require("suwayomi/ui")
                facade.showActionMenu, facade.showChapterActionsMenu = real_ui.showActionMenu, real_ui.showChapterActionsMenu
                facade.updateChapterMenu = function(menu, options)
                    menu.title, menu.chapters = options.title, options.chapters
                end
                plugin:showChaptersForManga(manga)
                finishRequest()
                local initial_ids = not restricted and { "201", "202" }
                    or (dataset == "labeled chapters" and { "201" } or {})
                assert.are.same(initial_ids, chapterIds(plugin.current_chapter_menu.chapters))
                assert.are.same(initial_ids, chapterIds(plugin:getNextUnreadChaptersForDownload(manga, 5)))
                assert.are.equal(restricted and "Saved group" or nil, saved_filter)
                assert.are.equal(saved_filter, plugin.current_scanlator_filter)
                assert.are.equal(0, filter_writes)
                assert.are.same({}, admittedIds())
                assert.are.same({}, queue:getSnapshot().queued)
                assert.are.same({}, json.decode(saved_ledger))
                if dataset ~= "labeled chapters" then
                    assert.are.same({}, plugin:getChapterScanlatorChoices(plugin.current_chapter_context.chapters))
                    if restricted then assert.matches("No chapters match the saved scanlator filter", messages[1])
                    else assert.are.same({}, messages) end
                end
                local menu = plugin.current_chapter_menu
                local function open_action_menu()
                    if origin == "chapter title" then plugin.current_chapter_options.on_title_bar_left_tap(menu)
                    else plugin:showBulkChapterActions() end
                end
                local function find_action(id)
                    for _, row in ipairs(loading.buttons) do
                        for _, button in ipairs(row) do
                            if button.id == id then return button end
                        end
                    end
                end
                local function select_action(id)
                    local selected = find_action(id)
                    assert.is_table(selected, "Missing public action: " .. id)
                    selected.callback()
                    local dispatch = table.remove(scheduled)
                    assert.is_function(dispatch)
                    dispatch()
                end
                open_action_menu()
                if not restricted then
                    assert.is_nil(find_action("scanlator_filter"))
                    assert.are.equal(0, filter_writes)
                    return
                end
                if dataset ~= "labeled chapters" then
                    select_action("bulk_downloads")
                    select_action("download_next_5_unread")
                    assert.are.same({}, admittedIds())
                    assert.are.same({}, queue:getSnapshot().queued)
                    assert.are.equal("Saved group", saved_filter)
                    assert.are.same({}, chapterIds(menu.chapters))
                    assert.are.equal(0, #workers)
                    open_action_menu()
                end
                select_action("scanlator_filter")
                assert.are.equal("Scanlator filter", loading.title)
                assert.are.equal("Saved group", saved_filter)
                assert.are.same(initial_ids, chapterIds(menu.chapters))
                select_action("scanlator_filter_all")
                local expected_ids = dataset == "empty result" and {} or { "201", "202" }
                assert.is_nil(saved_filter)
                assert.is_nil(plugin.current_scanlator_filter)
                assert.are.equal(1, filter_writes)
                assert.are.equal(menu, plugin.current_chapter_menu)
                assert.are.same(expected_ids, chapterIds(menu.chapters))
                assert.are.same(expected_ids, chapterIds(plugin:getNextUnreadChaptersForDownload(manga, 5)))
                assert.are.same({}, admittedIds())
                assert.are.same({}, json.decode(saved_ledger))
                open_action_menu()
                if dataset ~= "labeled chapters" then assert.is_nil(find_action("scanlator_filter"))
                else assert.is_table(find_action("scanlator_filter")) end
                select_action("bulk_downloads")
                select_action("download_next_5_unread")
                assert.are.same(expected_ids, admittedIds())
                assert.are.same({}, json.decode(saved_ledger))
                assert.are.equal(0, #workers)
            end)
        end
    end

    it("preserves pending choices and unrelated ledger fields through persisted reopen and refresh", function()
        ledger_path = os.tmpname()
        os.remove(ledger_path)
        package.preload.datastorage = function() return { getSettingsDir = function() return "." end } end
        package.preload.luasettings = function() return {} end
        local real_settings = dofile("suwayomi/settings.lua")
        real_settings:setStore(require("suwayomi/settings/store"):new({ path = ledger_path }))
        local entries = {}
        for _, id in ipairs({ 199, 200, 201, 202 }) do
            entries["17:" .. id] = { manga_id = "17", chapter_id = tostring(id),
                read = id == 201 or id == 202, pending_read_sync = id ~= 202,
                pending_read_state = id == 201 and true or false,
                archive_generation = { id = "generation-" .. id }, manual_intent = { revision = id } }
        end
        assert.is_table(real_settings:saveChapterLedger(entries))
        settings:setStore(real_settings:getStore())
        respond = function(request)
            local chapters = nodes(1, 205)
            chapters[200].isRead = false -- Acknowledges pending local unread without dropping pathless extras.
            if request.query:find("GET_CHAPTERS_MANGA", 1, true) then
                local offset, selected = request.variables.offset, {}
                for index = offset + 1, math.min(offset + 200, 205) do selected[#selected + 1] = chapters[index] end
                return page(selected, 205, offset + #selected < 205)
            end
            return { data = { fetchManga = { manga = { id = 17 } }, fetchChapters = { chapters = chapters } } }
        end
        for _, refresh in ipairs({ false, true }) do
            if refresh then plugin:refreshMangaChapters(manga) else plugin:showChaptersForManga(manga) end
            finishRequest()
            assert.are.equal(205, #plugin.current_chapter_menu.chapters)
            assert.are.same({ "199", "200", "202", "203", "204" },
                chapterIds(plugin:getNextUnreadChaptersForDownload(manga, 5)))
            -- Reopen the serialized store to verify normalization and actual persistence together.
            real_settings:setStore(require("suwayomi/settings/store"):new({ path = ledger_path }))
            local persisted = real_settings:loadChapterLedger()
            for _, id in ipairs({ 199, 200, 201, 202 }) do
                assert.are.same({ id = "generation-" .. id }, persisted["17:" .. id].archive_generation)
                assert.are.same({ revision = id }, persisted["17:" .. id].manual_intent)
            end
            assert.is_false(persisted["17:199"].read)
            assert.is_true(persisted["17:199"].pending_read_sync)
            assert.is_nil(persisted["17:200"].pending_read_sync)
            assert.is_true(persisted["17:201"].read)
            assert.is_true(persisted["17:201"].pending_read_sync)
            assert.is_false(persisted["17:202"].read)
        end
        plugin:upsertChapterLedgerEntry(manga, { id = "202", name = "Chapter 202" }, { path = "example.cbz" })
        assert.are.same({ revision = 202 }, real_settings:loadChapterLedger()["17:202"].manual_intent)
        plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
        assert.are.same({ "199", "200", "202", "203", "204" }, admittedIds())
        assert.are.same({}, messages)
    end)

    for _, route in ipairs({ "reopen", "refresh", "action" }) do
        it("replaces a prior nonempty view with verified empty through " .. route, function()
            respond = function() return page(nodes(201, 205), 5, false) end
            plugin:showChaptersForManga(manga)
            finishRequest()
            plugin:selectAllChapters()
            plugin:downloadNextUnreadChaptersForManga(manga, 5, true)
            assert.is_function(confirmation)
            local old_chapter = plugin.current_chapter_context.chapters[1]
            respond = function(request)
                if request.query:find("GET_CHAPTERS_MANGA", 1, true) then return page({}, 0, false) end
                return { data = { fetchManga = { manga = { id = 17 } }, fetchChapters = { chapters = {} } } }
            end
            if route == "refresh" then plugin:refreshMangaChapters(manga)
            elseif route == "action" then
                plugin:startLoadMangaChapterContext(manga, function()
                    plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
                end)
            else plugin:showChaptersForManga(manga) end
            finishRequest()
            assert.are.same({}, plugin.current_chapter_context.chapters)
            assert.are.same({}, plugin.current_chapter_menu.chapters)
            assert.are.equal(0, plugin:getSelectedChapterCount())
            assert.are.equal("This manga has no chapters.", messages[#messages])
            confirmation()
            plugin:enqueueChapterDownload(manga, old_chapter)
            plugin:toggleChapterSelection(manga, old_chapter)
            assert.are.equal(0, plugin:getSelectedChapterCount())
            plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
            assert.are.same({}, admittedIds())
            assert.are.same({}, json.decode(saved_ledger))
            assert.are.equal(0, #workers)
        end)
    end

    for _, origin in ipairs({ "chapter menu", "chapter error details" }) do
        for _, invalidation in ipairs({ "empty replacement", "another manga", "newer request", "cancellation", "retired host", "manga identity" }) do
            it("keeps failed jobs unchanged after " .. invalidation .. " invalidates " .. origin .. " Retry", function()
                assert(settings:saveChapterLedger({ ["17:200"] = { manga_id = "17", chapter_id = "200", read = true } }))
                respond = function() return page(nodes(201, 201), 1, false) end
                plugin:showChaptersForManga(manga)
                finishRequest()
                local chapter = plugin.current_chapter_context.chapters[1]
                local failed = queue:buildPersistentJob(manga, chapter, download_directory, "failed", {
                    error = "Example transfer failure.", retry_count = 3,
                })
                assert(queue:savePersistentJobs({ failed }))
                queue:setStatus(manga, chapter, { state = "failed" })
                plugin:showChapterActions(manga, chapter)
                local retry = function() return chapter_action_callback({ id = "retry_download" }) end
                if origin == "chapter error details" then
                    chapter_action_callback({ id = "download_error" })
                    retry = error_details.onRetry
                end
                assert.is_function(retry)
                local ledger, jobs = saved_ledger, saved_jobs
                local visible_ids = { "201" }
                if invalidation == "empty replacement" then
                    respond = function(request)
                        if request.query:find("GET_CHAPTERS_MANGA", 1, true) then return page({}, 0, false) end
                        return { data = { fetchChapters = { chapters = {} } } }
                    end
                    plugin:showChaptersForManga(manga)
                    finishRequest()
                    visible_ids = {}
                elseif invalidation == "another manga" then
                    respond = function() return page(nodes(301, 301), 1, false) end
                    plugin:showChaptersForManga({ id = "18", title = "Other manga" })
                    finishRequest()
                    visible_ids = { "301" }
                elseif invalidation == "newer request" then
                    plugin:showChaptersForManga(manga)
                elseif invalidation == "cancellation" then
                    plugin:cancelMangaNetworkRequests()
                elseif invalidation == "retired host" then
                    plugin:retireChapterHost()
                else
                    manga.id = "18"
                end
                retry()
                if invalidation == "empty replacement" then
                    assert.is_false(plugin:performChapterAction(manga, chapter, "retry_download"))
                end
                assert.are.same(visible_ids, chapterIds(plugin.current_chapter_menu.chapters))
                assert.are.same(visible_ids, chapterIds(plugin.current_chapter_context.chapters))
                assert.are.same(json.decode(ledger), json.decode(saved_ledger))
                assert.are.same(json.decode(jobs), json.decode(saved_jobs))
                assert.are.equal("failed", queue:findPersistentJob(failed.key).state)
                assert.are.same({}, queue:getSnapshot().queued)

                if invalidation == "empty replacement" then
                    plugin:showFailedDownloadActions(failed)
                    assert.is_true(error_details.onRetry())
                    assert.are.equal("queued", queue:findPersistentJob(failed.key).state)
                    assert.are.same({ "201" }, admittedIds())
                    assert.are.same(json.decode(ledger), json.decode(saved_ledger))
                    assert.are.same({}, plugin.current_chapter_menu.chapters)
                end
            end)
        end
    end

    for _, origin in ipairs({ "manga menu", "manga information", "public dispatch", "chapter title", "chapter bulk" }) do
        local invalidations = origin == "public dispatch" and { "current", "retired host" }
            or { "current", "retired host", "cancellation", "newer request", "another manga", "manga identity" }
        if origin == "chapter title" or origin == "chapter bulk" then
            invalidations[#invalidations + 1] = "failed reload"
            invalidations[#invalidations + 1] = "filter change"
        end
        for _, invalidation in ipairs(invalidations) do
            it("guards loaded first-unread dispatch from " .. origin .. " after " .. invalidation, function()
                if origin == "chapter title" then
                    for name, method in pairs(require("suwayomi/plugin/title_menu").methods) do plugin[name] = method end
                end
                respond = function() return page(nodes(201, 201), 1, false) end
                if invalidation == "filter change" then
                    saved_filter = "First group"
                    respond = function()
                        local chapters = nodes(201, 202)
                        chapters[1].scanlator, chapters[2].scanlator = "First group", "Second group"
                        return page(chapters, 2, false)
                    end
                end
                archive_directory = os.tmpname()
                os.remove(archive_directory)
                assert(require("lfs").mkdir(archive_directory))
                download_directory = archive_directory
                plugin:showChaptersForManga(manga)
                finishRequest()
                local chapter = plugin.current_chapter_context.chapters[1]
                local chapter_path = plugin:getChapterPath(manga, chapter)
                archive_path = chapter_path
                local Native = require("spec/support/native_archiver")
                restore_native = Native.install()
                assert(queue.downloader:ensureDirectory(chapter_path:match("^(.*)/[^/]+$")))
                local writer = Native.Writer:new()
                assert(writer:open(chapter_path, "zip"))
                assert(writer:addFileFromMemory("001.jpg", "fixture image"))
                assert(writer:close())
                local downloaded_paths = { [chapter_path] = true }
                if invalidation == "filter change" then
                    downloaded_paths[plugin:getChapterPath(manga, plugin.current_chapter_context.chapters[2])] = true
                end
                require("suwayomi/downloads/downloader").chapterExists = function(_, path) return downloaded_paths[path] == true end
                if origin == "chapter title" then plugin:refreshChapterMenu({ quick = true }) end
                local return_contexts, return_writes, reader_opens = "{}", 0, {}
                settings.loadReaderReturnContexts = function() return json.decode(return_contexts) end
                settings.saveReaderReturnContexts = function(_, contexts)
                    return_contexts = json.encode(contexts)
                    return_writes = return_writes + 1
                    return true
                end
                plugin.saveReaderReturnContext = require("suwayomi/reader_return").methods.saveReaderReturnContext
                package.preload["apps/reader/readerui"] = function()
                    return { instance = { switchDocument = function(_, path) reader_opens[#reader_opens + 1] = path end },
                        showReader = function(_, path) reader_opens[#reader_opens + 1] = path end }
                end
                local function finishVerification()
                    assert.are.same({}, reader_opens)
                    finishJob(queue.verification)
                end
                local dispatch = function() return plugin:performMangaAction(manga, "open_first_unread") end
                local open_action_menu
                local facade = require("suwayomi/ui")
                if origin == "manga information" then
                    facade.showMangaInformation = function(_, options)
                        dispatch = function() return options.onAction({ id = "open_first_unread" }) end
                        return {}
                    end
                    plugin:showMangaActions(manga)
                elseif origin ~= "public dispatch" then
                    require("spec/support/controller_module_spec_helper").stubControllerDependencies()
                    package.loaded["suwayomi/ui"], package.preload["suwayomi/ui"] = nil, nil
                    local real_ui = require("suwayomi/ui")
                    facade.showMangaActionsMenu, facade.showChapterActionsMenu, facade.showActionMenu =
                        real_ui.showMangaActionsMenu, real_ui.showChapterActionsMenu, real_ui.showActionMenu
                    local retained_title_options = plugin.current_chapter_options
                    open_action_menu = function()
                        local dialog
                        if origin == "chapter title" then
                            retained_title_options.on_title_bar_left_tap(plugin.current_chapter_menu)
                            dialog = loading
                        elseif origin == "chapter bulk" then
                            plugin:showBulkChapterActions()
                            dialog = loading
                        else dialog = plugin:showMangaActions(manga) end
                        for _, row in ipairs(dialog.buttons) do
                            for _, button in ipairs(row) do
                                if button.text == "Open first unread" then button.callback() end
                            end
                        end
                        local selected = table.remove(scheduled)
                        assert.is_function(selected)
                        return selected
                    end
                    dispatch = open_action_menu()
                end
                if invalidation == "retired host" then plugin:retireChapterHost()
                elseif invalidation == "cancellation" then plugin:cancelMangaNetworkRequests()
                elseif invalidation == "newer request" then plugin:showChaptersForManga(manga)
                elseif invalidation == "another manga" then
                    respond = function() return page(nodes(301, 301), 1, false) end
                    plugin:showChaptersForManga({ id = "18", title = "Other manga" })
                    finishRequest()
                    local replacement = plugin.current_chapter_context
                    downloaded_paths[plugin:getChapterPath(replacement.manga, replacement.chapters[1])] = true
                elseif invalidation == "failed reload" then
                    respond = function() return { errors = { { message = "Reload failed." } } } end
                    plugin:showChaptersForManga(manga)
                    finishRequest()
                    assert.matches("Reload failed", messages[#messages])
                elseif invalidation == "filter change" then plugin:setScanlatorFilter("Second group")
                elseif invalidation == "manga identity" then manga.id = "18" end
                local ledger, jobs = saved_ledger, saved_jobs
                local context, menu = plugin.current_chapter_context, plugin.current_chapter_menu
                local visible = chapterIds(menu.chapters)
                local worker_count = #workers
                local message_count = #messages
                dispatch()
                if invalidation == "current" then
                    finishVerification()
                    assert.are.same({ chapter_path }, reader_opens, table.concat(messages, "\n"))
                    assert.are.equal(chapter_path, json.decode(saved_ledger)["17:201"].path)
                    assert.are.equal("201", json.decode(return_contexts)[chapter_path].chapter_id)
                    assert.are.equal(1, return_writes)
                else
                    assert.are.same({}, reader_opens)
                    assert.are.same(json.decode(ledger), json.decode(saved_ledger))
                    assert.are.equal("{}", return_contexts)
                    assert.are.equal(0, return_writes)
                    assert.are.equal(message_count, #messages)
                end
                assert.are.same(json.decode(jobs), json.decode(saved_jobs))
                assert.are.same({}, queue:getSnapshot().queued)
                assert.are.equal(context, plugin.current_chapter_context)
                assert.are.same(visible, chapterIds(plugin.current_chapter_menu.chapters))
                assert.are.equal(worker_count, #workers)
                if invalidation == "failed reload" then
                    local fresh_dispatch = open_action_menu()
                    fresh_dispatch()
                    finishVerification()
                    assert.are.same({ chapter_path }, reader_opens)
                    assert.are.equal(chapter_path, json.decode(saved_ledger)["17:201"].path)
                    assert.are.equal("201", json.decode(return_contexts)[chapter_path].chapter_id)
                    assert.are.equal(1, return_writes)
                    assert.are.same(json.decode(jobs), json.decode(saved_jobs))
                    assert.are.same(visible, chapterIds(menu.chapters))
                    assert.are.equal(worker_count, #workers)
                end
            end)
        end
    end

    for _, method in ipairs({ "showBulkDownloadMangaActions", "showKeepDownloadedMangaActions" }) do
        for _, invalidation in ipairs({ "current", "retired host", "cancellation", "newer request",
            "another manga", "manga identity", "failed reload", "filter change" }) do
            it("guards delayed manga submenu Back from " .. method .. " after " .. invalidation, function()
                respond = function()
                    local chapters = nodes(201, 202)
                    chapters[1].scanlator, chapters[2].scanlator = "First group", "Second group"
                    return page(chapters, 2, false)
                end
                saved_filter = "First group"
                plugin:showChaptersForManga(manga)
                finishRequest()
                local return_contexts, return_writes, reader_opens = "{}", 0, {}
                settings.loadReaderReturnContexts = function() return json.decode(return_contexts) end
                settings.saveReaderReturnContexts = function(_, contexts)
                    return_contexts = json.encode(contexts)
                    return_writes = return_writes + 1
                    return true
                end
                plugin.saveReaderReturnContext = require("suwayomi/reader_return").methods.saveReaderReturnContext
                package.preload["apps/reader/readerui"] = function()
                    return { instance = { switchDocument = function(_, path) reader_opens[#reader_opens + 1] = path end },
                        showReader = function(_, path) reader_opens[#reader_opens + 1] = path end }
                end
                local tracked_menu
                function plugin:trackSuwayomiScreen(_, menu) tracked_menu = menu end
                local facade = require("suwayomi/ui")
                require("spec/support/controller_module_spec_helper").stubControllerDependencies()
                package.loaded["suwayomi/ui"], package.preload["suwayomi/ui"] = nil, nil
                facade.showMangaActionsMenu = require("suwayomi/ui").showMangaActionsMenu
                local function select_back()
                    local dialog = plugin[method](plugin, manga)
                    for _, row in ipairs(dialog.buttons) do
                        for _, button in ipairs(row) do
                            if button.id == "back" then button.callback() end
                        end
                    end
                    local dispatch = table.remove(scheduled)
                    assert.is_function(dispatch)
                    return dispatch
                end
                local dispatch = select_back()
                if invalidation == "retired host" then plugin:retireChapterHost()
                elseif invalidation == "cancellation" then plugin:cancelMangaNetworkRequests()
                elseif invalidation == "newer request" then plugin:showChaptersForManga(manga)
                elseif invalidation == "another manga" then
                    respond = function() return page(nodes(301, 301), 1, false) end
                    plugin:showChaptersForManga({ id = "18", title = "Other manga" })
                    finishRequest()
                elseif invalidation == "manga identity" then manga.id = "18"
                elseif invalidation == "failed reload" then
                    respond = function() return { errors = { { message = "Reload failed." } } } end
                    plugin:showChaptersForManga(manga)
                    finishRequest()
                    assert.matches("Reload failed", messages[#messages])
                elseif invalidation == "filter change" then plugin:setScanlatorFilter("Second group") end
                local ledger, jobs, last_widget, last_tracked = saved_ledger, saved_jobs, loading, tracked_menu
                local context, menu = plugin.current_chapter_context, plugin.current_chapter_menu
                local visible = chapterIds(menu.chapters)
                local worker_count, request_count, scheduled_count = #workers, #requests, #scheduled
                local message_count = #messages
                dispatch()
                if invalidation == "current" then
                    assert.are_not.equal(last_widget, loading)
                    assert.are.equal("Example manga", loading.title)
                    assert.are.equal(loading, tracked_menu)
                else
                    assert.are.equal(last_widget, loading)
                    assert.are.equal(last_tracked, tracked_menu)
                end
                assert.are.same(json.decode(ledger), json.decode(saved_ledger))
                assert.are.same(json.decode(jobs), json.decode(saved_jobs))
                assert.are.equal("{}", return_contexts)
                assert.are.equal(0, return_writes)
                assert.are.same({}, reader_opens)
                assert.are.same({}, queue:getSnapshot().queued)
                assert.are.equal(context, plugin.current_chapter_context)
                assert.are.equal(menu, plugin.current_chapter_menu)
                assert.are.same(visible, chapterIds(menu.chapters))
                assert.are.equal(worker_count, #workers)
                assert.are.equal(request_count, #requests)
                assert.are.equal(scheduled_count, #scheduled)
                assert.are.equal(message_count, #messages)
                if invalidation == "failed reload" then
                    select_back()()
                    assert.are.equal("Example manga", loading.title)
                    assert.are.equal(loading, tracked_menu)
                    assert.are.same(json.decode(ledger), json.decode(saved_ledger))
                    assert.are.same(json.decode(jobs), json.decode(saved_jobs))
                    assert.are.equal("{}", return_contexts)
                    assert.are.equal(0, return_writes)
                    assert.are.same({}, reader_opens)
                    assert.are.same({}, queue:getSnapshot().queued)
                    assert.are.equal(context, plugin.current_chapter_context)
                    assert.are.equal(menu, plugin.current_chapter_menu)
                    assert.are.same(visible, chapterIds(menu.chapters))
                    assert.are.equal(worker_count, #workers)
                    assert.are.equal(request_count, #requests)
                    assert.are.equal(scheduled_count, #scheduled)
                    assert.are.equal(message_count, #messages)
                end
            end)
        end
    end

    for _, route in ipairs({
        { method = "showBulkDownloadActions", text = "Download first unread" },
        { method = "showKeepDownloadedActions", text = "Stop download ahead" },
        { method = "showScanlatorFilterActions", text = "All scanlators" },
    }) do
        for _, back in ipairs({ false, true }) do
            it("does not retarget a delayed " .. route.method .. (back and " Back" or " action"), function()
                respond = function() return page(nodes(201, 201), 1, false) end
                plugin:showChaptersForManga(manga)
                finishRequest()
                local policy_writes, filter_writes = 0, 0
                settings.saveMangaKeepNextUnreadDownloads = function() policy_writes = policy_writes + 1; return true end
                settings.saveMangaScanlatorFilter = function() filter_writes = filter_writes + 1; return true end
                local facade = require("suwayomi/ui")
                require("spec/support/controller_module_spec_helper").stubControllerDependencies()
                package.loaded["suwayomi/ui"], package.preload["suwayomi/ui"] = nil, nil
                facade.showChapterActionsMenu = require("suwayomi/ui").showChapterActionsMenu
                plugin[route.method](plugin)
                for _, row in ipairs(loading.buttons) do
                    for _, button in ipairs(row) do
                        if button.text == (back and "< Back" or route.text) then button.callback() end
                    end
                end
                local dispatch = table.remove(scheduled)
                assert.is_function(dispatch)
                respond = function() return page(nodes(301, 301), 1, false) end
                plugin:showChaptersForManga({ id = "18", title = "Other manga" })
                finishRequest()
                local ledger, jobs, last_widget = saved_ledger, saved_jobs, loading
                local menu, context = plugin.current_chapter_menu, plugin.current_chapter_context
                dispatch()
                assert.are.same(json.decode(ledger), json.decode(saved_ledger))
                assert.are.same(json.decode(jobs), json.decode(saved_jobs))
                assert.are.same({}, queue:getSnapshot().queued)
                assert.are.equal(0, policy_writes)
                assert.are.equal(0, filter_writes)
                assert.are.equal(last_widget, loading)
                assert.are.equal(menu, plugin.current_chapter_menu)
                assert.are.equal(context, plugin.current_chapter_context)
                assert.are.same({ "301" }, chapterIds(menu.chapters))
                assert.are.equal(0, #workers)
            end)
        end
    end

    for _, different_manga in ipairs({ false, true }) do
        it("ignores old action completion after newer menu success, different manga " .. tostring(different_manga), function()
            respond = function() return page(nodes(1, 1), 1, false) end
            plugin:showChaptersForManga(manga)
            finishRequest()
            plugin:startLoadMangaChapterContext(manga, function()
                plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
            end)
            local older = plugin.active_manga_network_requests.chapter_context
            local target = different_manga and { id = "18", title = "Other manga" } or manga
            plugin:showChaptersForManga(target)
            respond = function() return page(nodes(301, 301), 1, false) end
            finishRequest()
            local context, menu, ledger = plugin.current_chapter_context, plugin.current_chapter_menu, saved_ledger
            respond = function() return page(nodes(201, 205), 5, false) end
            finishRequest(older)
            assert.are.equal(context, plugin.current_chapter_context)
            assert.are.equal(menu, plugin.current_chapter_menu)
            assert.are.same({ "301" }, chapterIds(plugin.current_chapter_menu.chapters))
            assert.are.same(json.decode(ledger), json.decode(saved_ledger))
            assert.are.same({}, admittedIds())
            assert.are.same({}, messages)
        end)
    end

    for _, invalidation in ipairs({ "cancel", "timeout", "manga identity", "retired host" }) do
        it("preserves prior view without action after " .. invalidation, function()
            respond = function() return page(nodes(1, 1), 1, false) end
            plugin:showChaptersForManga(manga)
            finishRequest()
            local context, menu, ledger = plugin.current_chapter_context, plugin.current_chapter_menu, saved_ledger
            plugin:startLoadMangaChapterContext(manga, function()
                plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
            end)
            local token = plugin.active_manga_network_requests.chapter_context
            if invalidation == "cancel" then
                assert.is_function(loading.dismiss_callback)
                loading.dismiss_callback()
            elseif invalidation == "timeout" then
                subprocess_done, fake_time = false, 200
                for index, callback in ipairs(scheduled) do
                    if poll_ids[callback] == token.active.pid then
                        pending_pid = token.active.pid
                        table.remove(scheduled, index)()
                        break
                    end
                end
                subprocess_done = true
            elseif invalidation == "manga identity" then manga.id = "18"
            else plugin:retireChapterHost() end
            respond = function() return page(nodes(201, 205), 5, false) end
            finishRequest(token)
            assert.are.equal(context, plugin.current_chapter_context)
            assert.are.equal(menu, plugin.current_chapter_menu)
            assert.are.same(json.decode(ledger), json.decode(saved_ledger))
            assert.are.same({ "1" }, chapterIds(plugin.current_chapter_menu.chapters))
            assert.are.same({}, admittedIds())
            if invalidation == "timeout" then assert.are.same({ "Could not load chapters." }, messages)
            else assert.are.same({}, messages) end
        end)
    end

    it("does not revive a captured directory action after complete empty replacement", function()
        respond = function() return page(nodes(201, 205), 5, false) end
        plugin:showChaptersForManga(manga)
        finishRequest()
        download_directory = nil
        plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
        assert.is_function(directory_callback)
        respond = function(request)
            if request.query:find("GET_CHAPTERS_MANGA", 1, true) then return page({}, 0, false) end
            return { data = { fetchChapters = { chapters = {} } } }
        end
        plugin:showChaptersForManga(manga)
        finishRequest()
        messages = {}
        directory_callback("./nonexistent-test-library")
        assert.are.same({ "Suwayomi download directory saved." }, messages)
        assert.are.same({}, plugin.current_chapter_menu.chapters)
        assert.are.same({}, admittedIds())
        assert.are.same({}, json.decode(saved_ledger))
        assert.are.equal(0, #workers)
    end)

    it("does not cancel a newer load from an already dismissed loading message", function()
        respond = function() return page(nodes(201, 201), 1, false) end
        plugin:showChaptersForManga(manga)
        local old_loading, dismiss = loading, loading.dismiss_callback
        finishRequest()
        assert.is_nil(old_loading.dismiss_callback)
        plugin:showChaptersForManga(manga)
        dismiss()
        respond = function() return page(nodes(301, 301), 1, false) end
        finishRequest()
        assert.are.same({ "301" }, chapterIds(plugin.current_chapter_menu.chapters))
        assert.are.same({}, admittedIds())
        assert.are.same({}, json.decode(saved_ledger))
        assert.are.same({}, messages)
    end)

    it("explains an absent filter after a fresh Download ahead load without running its action", function()
        saved_filter = "Absent group"
        respond = function() return page(nodes(201, 205), 5, false) end
        plugin:keepNextUnreadChaptersForManga(manga, 5)
        finishRequest()
        assert.are.same({}, plugin:getVisibleChapters(plugin.current_chapter_context.chapters))
        assert.matches("No chapters match the saved scanlator filter", messages[#messages])
        assert.are.equal(1, #messages)
        assert.are.same({}, admittedIds())
        assert.are.same({}, json.decode(saved_ledger))
    end)

    for _, total in ipairs({ 0, 205 }) do
        it("hands complete reader return of " .. total .. " chapters to the live FileManager host", function()
            local reader_context = { path = "example.cbz", manga_id = "17", chapter_id = "201" }
            settings.loadReaderReturnContexts = function() return { ["example.cbz"] = reader_context } end
            for name, method in pairs(require("suwayomi/reader_return").methods) do plugin[name] = method end
            local destination = { max_batch_queue_chapters = 50 }
            for name, method in pairs(plugin) do if type(method) == "function" then destination[name] = method end end
            local filemanager = { suwayomi = destination, reinit = function() end }
            destination.ui = filemanager
            destination:setCurrentMangaChapterContext(manga, { { id = "999", name = "Old", is_read = false } })
            destination.current_chapter_menu = { chapters = destination.current_chapter_context.chapters }
            local reader = { document = { file = "example.cbz" }, onClose = function() plugin:retireChapterHost() end }
            plugin.ui = reader
            package.preload["apps/reader/readerui"] = function() return { instance = reader } end
            package.preload["apps/filemanager/filemanager"] = function() return { instance = filemanager } end
            respond = function(request)
                if request.query:find("GET_CHAPTERS_MANGA", 1, true) then
                    local offset = request.variables.offset
                    return page(nodes(offset + 1, math.min(offset + 200, total)), total, offset + 200 < total)
                end
                if request.query:find("GET_MANGA_CHAPTERS_FETCH", 1, true) then
                    return { data = { fetchChapters = { chapters = {} } } }
                end
                return { data = { mangas = { totalCount = 1, nodes = { { id = 17 } } } } }
            end
            plugin:returnToSuwayomiChapters(reader_context)
            local token = plugin.active_reader_return_request
            finishRequest(token)
            assert.is_nil(plugin.current_chapter_context)
            assert.is_function(scheduled[1])
            table.remove(scheduled, 1)()
            assert.is_true(plugin.suwayomi_host_retired)
            assert.is_nil(plugin.current_chapter_context)
            assert.are.equal(total, #destination.current_chapter_menu.chapters)
            destination:downloadNextUnreadChaptersForManga(destination.current_chapter_context.manga, 5, false)
            assert.are.same(total == 0 and {} or { "201", "202", "203", "204", "205" }, admittedIds())
            assert.are.equal(total > 0, json.decode(saved_ledger)["17:200"] ~= nil)
        end)
    end

    it("accepts nullable metadata while normalizing explicit source refresh", function()
        respond = function()
            return { data = { fetchManga = { manga = { id = 17, title = "Example manga", firstUnreadChapter = json.null,
                author = json.null, source = json.null } }, fetchChapters = { chapters = {
                    { id = 201, sourceOrder = 1, name = json.null, scanlator = json.null, isRead = false },
                } } } }
        end
        plugin:refreshMangaChapters(manga)
        finishRequest()
        assert.are.same({ "201" }, chapterIds(plugin.current_chapter_menu.chapters))
        assert.is_nil(manga.author)
        plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
        assert.are.same({ "201" }, admittedIds())
        assert.are.same({}, json.decode(saved_ledger))
        assert.are.same({}, messages)
    end)

    for _, route in ipairs({ "fallback", "refresh" }) do
        for _, malformed in ipairs({
            { "duplicate ID", function(value) value.data.fetchChapters.chapters[2].id = 201 end },
            { "missing ID", function(value) value.data.fetchChapters.chapters[1].id = nil end },
            { "string ID", function(value) value.data.fetchChapters.chapters[1].id = "201" end },
            { "missing source order", function(value) value.data.fetchChapters.chapters[1].sourceOrder = nil end },
            { "fractional source order", function(value) value.data.fetchChapters.chapters[1].sourceOrder = 1.5 end },
            { "null chapter", function(value) value.data.fetchChapters.chapters[1] = json.null end },
            { "object list", function(value) value.data.fetchChapters.chapters = { chapter = nodes(201, 201)[1] } end },
            { "GraphQL partial failure", function(value) value.errors = { { message = "Source refresh failed." } } end },
        }) do
            it("rejects " .. route .. " " .. malformed[1] .. " without replacing the valid view", function()
                respond = function() return page(nodes(1, 1), 1, false) end
                plugin:showChaptersForManga(manga)
                finishRequest()
                local context, menu, ledger = plugin.current_chapter_context, plugin.current_chapter_menu, saved_ledger
                respond = function(request)
                    if request.query:find("GET_CHAPTERS_MANGA", 1, true) then return page({}, 0, false) end
                    local result = { data = { fetchManga = { manga = { id = 17 } }, fetchChapters = { chapters = nodes(201, 205) } } }
                    malformed[2](result)
                    return result
                end
                if route == "refresh" then plugin:refreshMangaChapters(manga)
                else plugin:startLoadMangaChapterContext(manga, function()
                    plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
                end) end
                finishRequest()
                assert.are.equal(context, plugin.current_chapter_context)
                assert.are.equal(menu, plugin.current_chapter_menu)
                assert.are.same(json.decode(ledger), json.decode(saved_ledger))
                assert.are.same({}, admittedIds())
                assert.are.equal(1, #messages)
                assert.is_string(messages[1])
            end)
        end
    end

    for _, malformed in ipairs({
        { "missing total", function(value) value.data.chapters.totalCount = nil end },
        { "negative total", function(value) value.data.chapters.totalCount = -1 end },
        { "fractional total", function(value) value.data.chapters.totalCount = 205.5 end },
        { "string total", function(value) value.data.chapters.totalCount = "205" end },
        { "missing continuation", function(value) value.data.chapters.pageInfo = nil end },
        { "string continuation", function(value) value.data.chapters.pageInfo.hasNextPage = "false" end },
        { "malformed metadata", function(value) value.data.chapters.pageInfo = true end },
        { "object nodes", function(value) value.data.chapters.nodes = { chapter = nodes(1, 1)[1] } end },
        { "null node", function(value) value.data.chapters.nodes[3] = json.null end },
        { "missing ID", function(value) value.data.chapters.nodes[1].id = nil end },
        { "nonnumeric ID", function(value) value.data.chapters.nodes[1].id = "invalid" end },
        { "fractional ID", function(value) value.data.chapters.nodes[1].id = 201.5 end },
        { "zero ID", function(value) value.data.chapters.nodes[1].id = 0 end },
        { "missing order", function(value) value.data.chapters.nodes[1].sourceOrder = nil end },
        { "string order", function(value) value.data.chapters.nodes[1].sourceOrder = "201" end },
        { "fractional order", function(value) value.data.chapters.nodes[1].sourceOrder = 201.5 end },
        { "GraphQL error with nodes", function(value) value.errors = { { message = "Partial GraphQL failure." } } end },
        { "changed total", function(value) value.data.chapters.totalCount = 206 end },
        { "duplicate ID", function(value) value.data.chapters.nodes[2].id = 201 end },
        { "overlapping page", function(value) value.data.chapters.nodes[1].id = 200 end },
        { "backward order", function(value) value.data.chapters.nodes[1].sourceOrder = 199 end },
        { "backward numeric tie", function(value)
            value.data.chapters.nodes[1].sourceOrder = 200
            value.data.chapters.nodes[1].id = 199
        end },
        { "count overrun", function(value) value.data.chapters.nodes = nodes(201, 206) end },
        { "premature end", function(value) value.data.chapters.nodes = nodes(201, 203) end },
        { "continuation after total", function(value) value.data.chapters.pageInfo.hasNextPage = true end },
        { "empty nonterminal page", function(value)
            value.data.chapters.nodes = {}
            value.data.chapters.pageInfo.hasNextPage = true
        end },
        { "oversized page", function(value) value.data.chapters.nodes = nodes(201, 401) end },
        { "null nodes", function(value) value.data.chapters.nodes = json.null end },
        { "null ID", function(value) value.data.chapters.nodes[1].id = json.null end },
        { "negative ID", function(value) value.data.chapters.nodes[1].id = -1 end },
        { "unrepresentable ID", function(value) value.data.chapters.nodes[1].id = 1e20 end },
        { "unrepresentable order", function(value) value.data.chapters.nodes[1].sourceOrder = 1e20 end },
    }) do
        it("rejects " .. malformed[1] .. " without publishing, reconciling, or admitting downloads", function()
            respond = function() return page(nodes(1, 1), 1, false) end
            plugin:showChaptersForManga(manga)
            finishRequest()
            local previous_context, previous_menu = plugin.current_chapter_context, plugin.current_chapter_menu
            local previous_ledger, previous_jobs = saved_ledger, saved_jobs
            respond = function(request)
                if request.variables.offset == 0 then return page(nodes(1, 200), 205, true) end
                local value = page(nodes(201, 205), 205, false)
                malformed[2](value)
                return value
            end
            plugin:startLoadMangaChapterContext(manga, function()
                plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
            end)
            finishRequest()
            assert.is_true(previous_context == plugin.current_chapter_context)
            assert.is_true(previous_menu == plugin.current_chapter_menu)
            assert.are.equal(previous_ledger, saved_ledger)
            assert.are.equal(previous_jobs, saved_jobs)
            assert.matches("Incomplete chapter load", messages[#messages])
            assert.are.equal(3, #requests)
        end)
    end

    for _, total in ipairs({ 0, 1, 199, 200, 201, 400, 401 }) do
        it("publishes exactly " .. total .. " stored chapters before dependent selection", function()
            respond = function(request)
                if request.query:find("GET_MANGA_CHAPTERS_FETCH", 1, true) then
                    return { data = { fetchChapters = { chapters = {} } } }
                end
                local offset = request.variables.offset
                assert.are.equal(200, request.variables.first)
                assert.are.same({ { by = "SOURCE_ORDER", byType = "ASC" }, { by = "ID", byType = "ASC" } },
                    request.variables.order)
                assert.matches("pageInfo { hasNextPage }", request.query, 1, true)
                return page(nodes(offset + 1, math.min(offset + 200, total)), total, offset + 200 < total)
            end
            plugin:showChaptersForManga(manga)
            finishRequest()
            if total == 0 then
                assert.are.equal("This manga has no chapters.", messages[#messages])
                assert.are.same({}, plugin.current_chapter_context.chapters)
                assert.are.equal(2, #requests)
            else
                assert.are.equal(total, #plugin.current_chapter_menu.chapters)
                assert.are.equal(tostring(total), plugin.current_chapter_menu.chapters[total].id)
                assert.are.equal(math.ceil(total / 200), #requests)
                plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
            end
            local expected = total > 200 and { "201" } or {}
            if total >= 205 then expected = { "201", "202", "203", "204", "205" } end
            assert.are.same(expected, admittedIds())
            assert.are.equal(total > 0, json.decode(saved_ledger)["17:1"] ~= nil)
        end)
    end

    it("advances by short nonterminal pages and preserves numeric ID ties across pages", function()
        local chapters = nodes(1, 201)
        chapters[200] = { id = 999, sourceOrder = 199, name = "Tie one", isRead = false }
        chapters[201] = { id = 1000, sourceOrder = 199, name = "Tie two", isRead = false }
        respond = function(request)
            local offset, selected = request.variables.offset, {}
            for index = offset + 1, math.min(offset + 100, #chapters) do selected[#selected + 1] = chapters[index] end
            return page(selected, #chapters, offset + #selected < #chapters)
        end
        plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
        finishRequest()
        assert.are.same({ "999", "1000" }, admittedIds())
        assert.are.same({ "999", "1000" }, chapterIds(plugin:getUnreadChaptersForManga(manga)))
        assert.are.equal(201, #plugin.current_chapter_context.chapters)
        assert.is_true(json.decode(saved_ledger)["17:199"].read)
        assert.are.same({ 0, 100, 200 }, { requests[1].variables.offset, requests[2].variables.offset, requests[3].variables.offset })
        assert.are.same({}, messages)
    end)

    it("reports aggregate result size before handoff without discarding a complete view", function()
        respond = function() return page(nodes(1, 1), 1, false) end
        plugin:showChaptersForManga(manga)
        finishRequest()
        local previous_context, previous_menu = plugin.current_chapter_context, plugin.current_chapter_menu
        local previous_ledger, previous_jobs = saved_ledger, saved_jobs
        require("suwayomi/subprocess/job").max_result_bytes = 50000
        respond = function(request)
            local offset = request.variables.offset
            local chapters = nodes(offset + 1, math.min(offset + 200, 401))
            for _, chapter in ipairs(chapters) do chapter.name = string.rep("x", 70) end
            local response = page(chapters, 401, offset + 200 < 401)
            assert.is_true(#json.encode(response) < 50000)
            return response
        end
        plugin:startLoadMangaChapterContext(manga, function()
            plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
        end)
        local result = finishRequest()
        assert.are.equal("too_large", result.error_kind)
        assert.is_true(previous_context == plugin.current_chapter_context)
        assert.is_true(previous_menu == plugin.current_chapter_menu)
        assert.are.equal(previous_ledger, saved_ledger)
        assert.are.equal(previous_jobs, saved_jobs)
        assert.matches("too large", messages[#messages])
        assert.is_true(#requests < 4)
    end)

    it("keeps nullable chapter fields usable after complete page validation", function()
        respond = function()
            return page({ { id = 201, sourceOrder = 0, name = json.null, chapterNumber = json.null,
                scanlator = json.null, isRead = false } }, 1, false)
        end
        plugin:showChaptersForManga(manga)
        finishRequest()
        assert.are.equal("201", plugin.current_chapter_menu.chapters[1].name)
        assert.are.same({}, plugin:getChapterScanlatorChoices(plugin.current_chapter_context.chapters))
        plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
        assert.are.same({ "201" }, admittedIds())
        assert.are.same({}, json.decode(saved_ledger))
        assert.are.same({}, messages)
    end)

    it("preserves transport failure details through worker handoff and prevents a failed ahead action", function()
        respond = function() return page(nodes(1, 1), 1, false) end
        plugin:showChaptersForManga(manga)
        finishRequest()
        local previous_context, previous_menu = plugin.current_chapter_context, plugin.current_chapter_menu
        local previous_ledger, previous_jobs = saved_ledger, saved_jobs
        respond = function(request)
            if request.variables.offset == 0 then return page(nodes(1, 200), 205, true) end
            return {}, 503
        end
        plugin:startLoadMangaChapterContext(manga, function() plugin:keepNextUnreadChaptersForManga(manga, 5) end)
        local result = finishRequest()
        assert.are.equal("incomplete", result.error_kind)
        assert.are.equal(503, result.status_code)
        assert.is_true(result.retryable)
        assert.is_true(previous_context == plugin.current_chapter_context)
        assert.is_true(previous_menu == plugin.current_chapter_menu)
        assert.are.equal(previous_ledger, saved_ledger)
        assert.are.equal(previous_jobs, saved_jobs)
        assert.matches("Incomplete chapter load", messages[#messages])
    end)

    it("admits the complete next-unread buffer after verified empty stored source fallback", function()
        prepareRefill()
        respond = function(request)
            if request.query:find("GET_MANGA_CHAPTERS_FETCH", 1, true) then
                return { data = { fetchChapters = { chapters = nodes(201, 205) } } }
            end
            return page({}, 0, false)
        end
        plugin:keepNextUnreadChaptersForManga(manga, 5)
        finishRequest()
        assert.are.equal(5, #plugin.current_chapter_context.chapters)
        assert.are.same({}, admittedIds())
        assert.are.equal(2, #requests)
        finishRefill()
        assert.are.same({ "201", "202", "203", "204", "205" }, admittedIds())
        assert.are.same({}, json.decode(saved_ledger))
        assert.are.equal(4, #requests)
        assert.are.same({}, messages)
    end)

    it("loads all stored pages before admitting a fresh Download ahead action", function()
        prepareRefill()
        respond = function(request)
            local offset = request.variables.offset
            return page(nodes(offset + 1, math.min(offset + 200, 205)), 205, offset + 200 < 205)
        end
        plugin:keepNextUnreadChaptersForManga(manga, 5)
        assert.are.same({}, admittedIds())
        local result = finishRequest()
        assert.are.equal(205, result.total_count)
        assert.is_false(result.has_next_page)
        assert.are.equal(205, #plugin.current_chapter_context.chapters)
        assert.are.same({}, admittedIds())
        assert.are.equal(2, #requests)
        finishRefill()
        assert.are.same({ "201", "202", "203", "204", "205" }, admittedIds())
        assert.is_true(json.decode(saved_ledger)["17:200"].read)
        assert.are.equal(4, #requests)
        assert.are.same({}, messages)
    end)

    for _, action in ipairs({ "fetch_chapters_for_manga", "refresh_manga", "fetch_reader_return_chapters_for_manga" }) do
        it("bounds the final chapter result envelope for " .. action, function()
            require("suwayomi/subprocess/job").max_result_bytes = 1000
            respond = function(request)
                if request.query:find("GET_CHAPTERS_MANGA", 1, true) then
                    if action == "fetch_chapters_for_manga" then return page({}, 0, false) end
                    return page(nodes(201, 201), 1, false)
                end
                local large_manga = { id = 17, title = string.rep("x", 1500) }
                if action == "fetch_reader_return_chapters_for_manga" then
                    return { data = { mangas = { totalCount = 1, nodes = { large_manga } } } }
                end
                local chapters = nodes(201, 201)
                chapters[1].name = string.rep("x", 1500)
                return { data = { fetchManga = { manga = large_manga }, fetchChapters = { chapters = chapters } } }
            end
            plugin:startMangaNetworkRequest(manga, { action = action, manga_id = manga.id }, "Loading", function(result)
                plugin:handleChapterContextResult(manga, result, function()
                    plugin:downloadNextUnreadChaptersForManga(manga, 5, false)
                end)
            end, "Timeout", "chapter_context")
            local result = finishRequest()
            assert.are.equal("too_large", result.error_kind)
            assert.is_nil(plugin.current_chapter_context)
            assert.is_nil(plugin.current_chapter_menu)
            assert.are.same({}, json.decode(saved_ledger))
            assert.are.same({}, admittedIds())
            assert.matches("too large", messages[#messages])
        end)
    end
end)
