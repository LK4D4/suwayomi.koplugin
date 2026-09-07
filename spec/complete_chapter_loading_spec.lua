package.path = "?.lua;" .. package.path

-- Exercise the asynchronous public load/action path through real API parsing,
-- worker result files, chapter context, ledger, menu data, and queue persistence.
describe("complete stored chapter loading", function()
    local json = require("dkjson")
    local plugin, manga, queue, messages, scheduled, workers, requests
    local saved_ledger, saved_jobs, respond, settings
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
        "suwayomi/paths", "suwayomi/downloads/controller",
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
        for _, job in ipairs(json.decode(saved_jobs)) do ids[#ids + 1] = job.chapter.id end
        return ids
    end

    local function finishRequest()
        local run = table.remove(workers, 1)
        assert.is_function(run)
        run()
        local active = plugin.active_manga_network_requests.chapter_context
            or plugin.active_manga_network_requests.chapter_menu
        local result = require("suwayomi/network/request_worker"):readResult(active.active.result_path)
        local poll = table.remove(scheduled, 1)
        assert.is_function(poll)
        poll()
        return result
    end

    before_each(function()
        clearModules()
        messages, scheduled, workers, requests = {}, {}, {}, {}
        saved_ledger, saved_jobs = "{}", "[]"
        manga = { id = "17", title = "Example manga", initialized = true }
        settings = {
            load = function() return { server_url = "https://suwayomi.example" } end,
            getSettingsDir = function() return "." end,
            loadChapterLedger = function() return json.decode(saved_ledger) end,
            saveChapterLedger = function(_, value) saved_ledger = json.encode(value); return value end,
            loadDownloadQueue = function() return json.decode(saved_jobs) end,
            saveDownloadQueue = function(_, value) saved_jobs = json.encode(value); return true end,
            loadDownloadDirectory = function() return "./nonexistent-test-library" end,
            normalizeMangaKeepNextUnreadDownloads = function(_, limit) return limit end,
            saveMangaKeepNextUnreadDownloads = function(_, _, limit) return limit end,
        }
        package.preload["suwayomi/settings"] = function() return settings end
        package.preload.gettext = function() return function(value) return value end end
        package.preload["ffi/archiver"] = function() return {} end
        local host = {
            joinPath = function(...) return table.concat({ ... }, "/") end,
            runInSubProcess = function(run) workers[#workers + 1] = run; return #workers end,
            isSubProcessDone = function() return true end,
            terminateSubProcess = function() end,
        }
        local ui = { scheduleIn = function(_, _, callback) scheduled[#scheduled + 1] = callback end }
        package.preload["ffi/util"] = function() return host end
        package.preload["ui/uimanager"] = function() return ui end
        package.preload["suwayomi/ui"] = function()
            return { showChapterMenu = function(options) return options end }
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
        queue = require("suwayomi/downloads/queue"):new{
            settings = settings, downloader = require("suwayomi/downloads/downloader"),
            ffi_util = host, ui_manager = ui,
        }
        plugin = { max_batch_queue_chapters = 50 }
        for _, module in ipairs({ "suwayomi/manga/controller", "suwayomi/chapters/context",
            "suwayomi/chapters/menu", "suwayomi/chapters/actions", "suwayomi/readsync/ledger",
            "suwayomi/downloads/controller" }) do
            for name, method in pairs(require(module).methods) do plugin[name] = method end
        end
        function plugin:getDownloadQueue() return queue end
        function plugin:showMessage(message) messages[#messages + 1] = message end
        function plugin:showLoadingMessage(message) return { text = message } end
        function plugin:closeLoadingMessage() end
        function plugin:loadKoreaderHistoryPaths() return {} end
        function plugin:getDownloadDirectoryOrChoose() return settings:loadDownloadDirectory() end
        function plugin:withChapterMenuRefreshSuppressed(callback) return callback() end
    end)

    after_each(function()
        if plugin then plugin:cancelMangaNetworkRequests() end
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
                assert.is_nil(plugin.current_chapter_context)
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
        assert.are.equal("{}", saved_ledger)
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
        respond = function(request)
            if request.query:find("GET_MANGA_CHAPTERS_FETCH", 1, true) then
                return { data = { fetchChapters = { chapters = nodes(201, 205) } } }
            end
            return page({}, 0, false)
        end
        plugin:keepNextUnreadChaptersForManga(manga, 5)
        finishRequest()
        assert.are.equal(5, #plugin.current_chapter_context.chapters)
        assert.are.same({ "201", "202", "203", "204", "205" }, admittedIds())
        assert.are.equal("{}", saved_ledger)
        assert.are.equal(2, #requests)
        assert.are.same({}, messages)
    end)

    it("loads all stored pages before admitting a fresh Download ahead action", function()
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
        assert.are.same({ "201", "202", "203", "204", "205" }, admittedIds())
        assert.is_true(json.decode(saved_ledger)["17:200"].read)
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
            assert.are.equal("{}", saved_ledger)
            assert.are.same({}, admittedIds())
            assert.matches("too large", messages[#messages])
        end)
    end
end)
