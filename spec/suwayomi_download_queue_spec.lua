package.path = "?.lua;" .. package.path

describe("suwayomi/downloads/queue", function()
    local original_io_open
    local original_os_remove
    local original_os_rename
    local removed_paths
    local renamed_paths
    local progress_files

    local function install_progress_file_mock()
        original_io_open = io.open
        original_os_remove = os.remove
        original_os_rename = os.rename
        removed_paths = {}
        renamed_paths = {}
        progress_files = {}

        io.open = function(path, mode)
            if tostring(path):match("%.suwayomi_dl_progress_") then
                if mode == "w" then
                    local chunks = {}
                    return {
                        write = function(_, ...)
                            for _, value in ipairs({...}) do
                                table.insert(chunks, value)
                            end
                        end,
                        close = function()
                            progress_files[path] = table.concat(chunks)
                        end,
                    }
                end

                local content = progress_files[path]
                if not content then
                    return nil
                end
                local lines = {}
                for line in content:gmatch("([^\n]*)\n?") do
                    if line ~= "" then
                        table.insert(lines, line)
                    end
                end
                local index = 0
                return {
                    lines = function()
                        return function()
                            index = index + 1
                            return lines[index]
                        end
                    end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end

        os.remove = function(path)
            table.insert(removed_paths, path)
            progress_files[path] = nil
            return true
        end

        os.rename = function(from, to)
            table.insert(renamed_paths, { from = from, to = to })
            progress_files[to] = progress_files[from]
            progress_files[from] = nil
            return true
        end
    end

    local function build_queue(options)
        options = options or {}
        package.loaded["suwayomi/downloads/queue"] = nil
        local DownloadQueue = require("suwayomi/downloads/queue")
        local scheduled = {}
        local saved_queue = options.saved_queue or {}
        local save_count = 0
        local now = options.now or 100
        local messages = {}
        local status_changes = 0
        local download_calls = 0
        local debug_events = {}
        local next_pid = 1233
        local subprocess_done = options.subprocess_done

        local downloader = options.downloader or {
            getTargetPath = function(_, download_directory, manga, chapter)
                return download_directory .. "/" .. manga.title,
                    download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
            end,
            getPartialPath = function(_, chapter_path)
                return chapter_path .. ".part"
            end,
            writeProgress = function(_, progress_path, state, current, total, path, error_message)
                local handle = assert(io.open(progress_path, "w"))
                handle:write("state=", tostring(state or ""), "\n")
                handle:write("current=", tostring(current or 0), "\n")
                handle:write("total=", tostring(total or 0), "\n")
                handle:write("path=", tostring(path or ""), "\n")
                if error_message then
                    handle:write("error=", tostring(error_message), "\n")
                end
                handle:close()
            end,
            downloadChapterWithProgress = function(self, _, download_directory, manga, chapter, progress_path)
                download_calls = download_calls + 1
                self:writeProgress(progress_path, "downloaded", 1, 1, download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz")
            end,
            chapterExists = function()
                return false
            end,
        }

        local queue = DownloadQueue:new{
            settings = {
                load = function()
                    return { server_url = "https://suwayomi.example" }
                end,
                loadDownloadQueue = function()
                    return saved_queue
                end,
                saveDownloadQueue = function(_, jobs)
                    save_count = save_count + 1
                    saved_queue = jobs
                    return jobs
                end,
            },
            downloader = downloader,
            ui_manager = {
                scheduleIn = function(_, delay, callback)
                    table.insert(scheduled, { delay = delay, callback = callback })
                end,
            },
            ffi_util = {
                runInSubProcess = function(callback)
                    if options.skip_subprocess_callback then
                        next_pid = next_pid + 1
                        return next_pid
                    end
                    callback()
                    next_pid = next_pid + 1
                    return next_pid
                end,
                isSubProcessDone = function(pid)
                    if type(subprocess_done) == "table" then
                        return subprocess_done[pid] == true
                    end
                    if type(subprocess_done) == "function" then
                        return subprocess_done(pid)
                    end
                    return subprocess_done ~= false
                end,
            },
            max_active_chapters = options.max_active_chapters,
            now = function()
                return now
            end,
            onStatusChanged = function()
                status_changes = status_changes + 1
            end,
            onMessage = function(message)
                table.insert(messages, message)
            end,
            debug_logger = function(event)
                table.insert(debug_events, event)
            end,
        }

        local context
        context = {
            queue = queue,
            scheduled = scheduled,
            saved_queue = function() return saved_queue end,
            save_count = function() return save_count end,
            messages = messages,
            debug_events = debug_events,
            status_changes = function() return status_changes end,
            download_calls = function() return download_calls end,
            progress_files = progress_files,
            renamed_paths = renamed_paths,
            advance = function(seconds)
                now = now + seconds
            end,
            set_subprocess_done = function(pid, done)
                if type(subprocess_done) ~= "table" then
                    subprocess_done = {}
                end
                subprocess_done[pid] = done
            end,
            active_count = function()
                local count = 0
                for _ in pairs(context.queue.active_jobs or {}) do
                    count = count + 1
                end
                return count
            end,
            active_job = function(manga, chapter)
                return context.queue.active_jobs[context.queue:getKey(manga, chapter)]
            end,
            write_progress = function(manga, chapter, state, current, total, path, error_message)
                local progress_path = context.queue:buildProgressPath(manga, chapter, "/books")
                local handle = assert(io.open(progress_path, "w"))
                handle:write("state=", tostring(state or ""), "\n")
                handle:write("current=", tostring(current or 0), "\n")
                handle:write("total=", tostring(total or 0), "\n")
                handle:write("path=", tostring(path or ""), "\n")
                if error_message then
                    handle:write("error=", tostring(error_message), "\n")
                end
                handle:close()
            end,
            run_scheduled = function()
                while #scheduled > 0 do
                    local item = table.remove(scheduled, 1)
                    item.callback()
                end
            end,
        }

        return context
    end

    before_each(function()
        install_progress_file_mock()
        package.loaded.gettext = nil
        package.loaded["ffi/util"] = nil
        package.preload.gettext = function()
            return function(text)
                return text
            end
        end
        package.preload["ffi/util"] = function()
            return {
                template = function(template_string, ...)
                    local result = template_string
                    local values = {...}
                    for index, value in ipairs(values) do
                        result = result:gsub("%%" .. index, tostring(value))
                    end
                    return result
                end,
            }
        end
    end)

    after_each(function()
        io.open = original_io_open
        os.remove = original_os_remove
        os.rename = original_os_rename
        package.loaded["suwayomi/downloads/queue"] = nil
        package.loaded.gettext = nil
        package.loaded["ffi/util"] = nil
        package.preload.gettext = nil
        package.preload["ffi/util"] = nil
    end)

    it("persists queued downloads and removes them after success", function()
        local context = build_queue()
        local ok = context.queue:enqueue(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1" },
            "/books"
        )

        assert.is_true(ok)
        assert.are.equal("queued", context.saved_queue()[1].state)
        assert.are.equal("m1:398", context.saved_queue()[1].key)

        context.run_scheduled()

        assert.are.same({}, context.saved_queue())
        assert.are.equal("downloaded", context.queue:getStatus(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1" }
        ).state)
    end)

    it("persists source metadata for queued downloads", function()
        local context = build_queue({ subprocess_done = false })
        local manga = {
            id = "m1",
            title = "Sousou no Frieren",
            source = {
                id = "mangadex",
                displayName = "MangaDex (EN)",
                name = "MangaDex",
                lang = "en",
            },
        }

        context.queue:enqueue(manga, { id = "398", name = "Official_Vol. 1 Ch. 1" }, "/books")

        assert.are.same({
            id = "mangadex",
            displayName = "MangaDex (EN)",
            name = "MangaDex",
            lang = "en",
        }, context.saved_queue()[1].manga.source)
    end)

    it("keeps read indication visible alongside download state", function()
        local context = build_queue()

        assert.are.equal(
            "✓↓",
            context.queue:formatChapterMenuStatus(
                { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true },
                { state = "downloaded" }
            )
        )
    end)

    it("puts compact status symbols after shortened chapter names", function()
        local context = build_queue()

        assert.are.equal(
            "Official_Vol. 25 Ch. 126 A Very Long Chapter Ti…  ✓ ↓ 3/12",
            context.queue:formatChapterMenuText(
                { id = "398", name = "Official_Vol. 25 Ch. 126 A Very Long Chapter Title", is_read = true },
                { state = "downloading", current = 3, total = 12 }
            )
        )
        assert.are.equal(
            "Official_Vol. 25 Ch. 126 A Very Long Chapter Title  ⌛",
            context.queue:formatChapterMenuText(
                { id = "398", name = "Official_Vol. 25 Ch. 126 A Very Long Chapter Title" },
                { state = "downloading", current = 0, total = 0 }
            )
        )
        assert.are.equal(
            "Official_Vol. 25 Ch. 127 Another Long Chapter Title  ⚠",
            context.queue:formatChapterMenuText(
                { id = "399", name = "Official_Vol. 25 Ch. 127 Another Long Chapter Title" },
                { state = "failed" }
            )
        )
    end)

    it("shortens unicode chapter names without splitting characters", function()
        local context = build_queue()

        assert.are.equal(
            "Очень длинное название главы с кириллицей для провер…  ✓ ↓",
            context.queue:formatChapterMenuText(
                { id = "401", name = "Очень длинное название главы с кириллицей для проверки", is_read = true },
                { state = "downloaded" }
            )
        )
    end)

    it("does not enqueue a duplicate while a chapter is queued", function()
        local context = build_queue({ subprocess_done = false })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        assert.is_true(context.queue:enqueue(manga, chapter, "/books"))
        assert.is_false(context.queue:enqueue(manga, chapter, "/books"))

        assert.are.equal(1, #context.saved_queue())
        assert.are.equal("Chapter download is already in progress.", context.messages[#context.messages])
    end)

    it("can suppress the duplicate download message for bulk enqueue", function()
        local context = build_queue({ subprocess_done = false })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        assert.is_true(context.queue:enqueue(manga, chapter, "/books"))
        assert.is_false(context.queue:enqueue(manga, chapter, "/books", { quiet_duplicate = true }))

        assert.are.equal(1, #context.saved_queue())
        assert.are.same({}, context.messages)
    end)

    it("cancels a queued download before it starts", function()
        local context = build_queue({ subprocess_done = false })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }
        local other_chapter = { id = "399", name = "Official_Vol. 1 Ch. 2" }

        assert.is_true(context.queue:enqueue(manga, chapter, "/books"))
        assert.is_true(context.queue:enqueue(manga, other_chapter, "/books"))

        local cancelled, state = context.queue:cancelPending(manga, chapter)

        assert.is_true(cancelled)
        assert.are.equal("queued", state)
        assert.are.equal(1, #context.saved_queue())
        assert.are.equal("m1:399", context.saved_queue()[1].key)
        assert.is_nil(context.queue:getStatus(manga, chapter))
        assert.are.equal("queued", context.queue:getStatus(manga, other_chapter).state)
        assert.are.equal(1, #context.queue.items)
        assert.are.equal("m1:399", context.queue.items[1].key)
    end)

    it("batch enqueues multiple chapters with one persistence write and process schedule", function()
        local context = build_queue({ subprocess_done = false })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapters = {
            { id = "398", name = "Official_Vol. 1 Ch. 1" },
            { id = "399", name = "Official_Vol. 1 Ch. 2" },
            { id = "400", name = "Official_Vol. 1 Ch. 3" },
        }

        local queued = context.queue:enqueueBatch(manga, chapters, "/books")

        assert.are.equal(3, queued)
        assert.are.equal(1, context.save_count())
        assert.are.equal(1, #context.scheduled)
        assert.are.equal(1, context.status_changes())
        assert.are.equal(3, #context.saved_queue())
        assert.are.equal("queued", context.queue:getStatus(manga, chapters[1]).state)
        assert.are.equal("queued", context.queue:getStatus(manga, chapters[2]).state)
        assert.are.equal("queued", context.queue:getStatus(manga, chapters[3]).state)
    end)

    it("clears a terminal chapter status without forcing a refresh", function()
        local context = build_queue()
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:setStatus(manga, chapter, { state = "downloaded" })
        assert.are.equal(1, context.status_changes())

        context.queue:clearStatus(manga, chapter, { quiet = true })

        assert.is_nil(context.queue:getStatus(manga, chapter))
        assert.are.equal(1, context.status_changes())
        assert.are.same({}, context.saved_queue())
    end)

    it("does not cancel an active download", function()
        local context = build_queue({ subprocess_done = false, skip_subprocess_callback = true })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        assert.is_true(context.queue:enqueue(manga, chapter, "/books"))
        context.scheduled[1].callback()

        local cancelled, state = context.queue:cancelPending(manga, chapter)

        assert.is_false(cancelled)
        assert.are.equal("downloading", state)
        assert.are.equal("downloading", context.queue:getStatus(manga, chapter).state)
        assert.are.equal(1, #context.saved_queue())
        assert.are.equal("downloading", context.saved_queue()[1].state)
    end)

    it("starts downloads up to the active chapter limit", function()
        local context = build_queue({
            max_active_chapters = 2,
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapters = {
            { id = "398", name = "Official_Vol. 1 Ch. 1" },
            { id = "399", name = "Official_Vol. 1 Ch. 2" },
            { id = "400", name = "Official_Vol. 1 Ch. 3" },
        }

        context.queue:enqueueBatch(manga, chapters, "/books")
        table.remove(context.scheduled, 1).callback()

        assert.are.equal(2, context.active_count())
        assert.is_not_nil(context.active_job(manga, chapters[1]))
        assert.is_not_nil(context.active_job(manga, chapters[2]))
        assert.is_nil(context.active_job(manga, chapters[3]))
        assert.are.equal("downloading", context.queue:getStatus(manga, chapters[1]).state)
        assert.are.equal("downloading", context.queue:getStatus(manga, chapters[2]).state)
        assert.are.equal("queued", context.queue:getStatus(manga, chapters[3]).state)
    end)

    it("persists initial progress when a queued job becomes active", function()
        local context = build_queue({
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        table.remove(context.scheduled, 1).callback()

        local persisted = context.saved_queue()[1]
        assert.are.equal("downloading", persisted.state)
        assert.are.equal(100, persisted.started_at)
        assert.are.equal(100, persisted.last_progress_at)
        assert.are.same({
            state = "downloading",
            current = 0,
            total = 0,
            updated_at = 100,
        }, persisted.progress)
        assert.is_nil(persisted.pid)
        assert.is_nil(persisted.credentials)
        assert.is_nil(persisted.downloader)
    end)

    it("persists changed active progress while a subprocess keeps running", function()
        local context = build_queue({
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        table.remove(context.scheduled, 1).callback()

        context.advance(3)
        context.write_progress(manga, chapter, "downloading", 2, 5, "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz")
        table.remove(context.scheduled, 1).callback()

        local persisted = context.saved_queue()[1]
        assert.are.equal("downloading", persisted.state)
        assert.are.equal(100, persisted.started_at)
        assert.are.equal(103, persisted.last_progress_at)
        assert.are.same({
            state = "downloading",
            current = 2,
            total = 5,
            path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
            updated_at = 103,
        }, persisted.progress)
    end)

    it("does not persist unchanged active progress on repeated polls", function()
        local context = build_queue({
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        table.remove(context.scheduled, 1).callback()

        context.advance(1)
        context.write_progress(manga, chapter, "downloading", 1, 5, "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz")
        table.remove(context.scheduled, 1).callback()
        local save_count_after_change = context.save_count()

        context.advance(1)
        table.remove(context.scheduled, 1).callback()

        assert.are.equal(save_count_after_change, context.save_count())
        assert.are.equal(101, context.saved_queue()[1].last_progress_at)
        assert.are.equal(101, context.saved_queue()[1].progress.updated_at)
    end)

    it("clamps the active chapter limit to the supported range", function()
        assert.are.equal(1, build_queue({ max_active_chapters = 0 }).queue.max_active_chapters)
        assert.are.equal(4, build_queue({ max_active_chapters = 99 }).queue.max_active_chapters)
        assert.are.equal(3, build_queue({ max_active_chapters = "3" }).queue.max_active_chapters)
    end)

    it("backfills a completed active slot while another chapter keeps downloading", function()
        local context = build_queue({
            max_active_chapters = 2,
            subprocess_done = {},
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapters = {
            { id = "398", name = "Official_Vol. 1 Ch. 1" },
            { id = "399", name = "Official_Vol. 1 Ch. 2" },
            { id = "400", name = "Official_Vol. 1 Ch. 3" },
        }

        context.queue:enqueueBatch(manga, chapters, "/books")
        table.remove(context.scheduled, 1).callback()
        local first = context.active_job(manga, chapters[1])
        local second = context.active_job(manga, chapters[2])
        context.write_progress(manga, chapters[1], "downloaded", 1, 1, "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz")
        context.write_progress(manga, chapters[2], "downloading", 1, 2, "/books/Sousou no Frieren/Official_Vol. 1 Ch. 2.cbz")
        context.set_subprocess_done(first.pid, true)
        context.set_subprocess_done(second.pid, false)

        table.remove(context.scheduled, 1).callback()

        assert.are.equal(2, context.active_count())
        assert.is_nil(context.active_job(manga, chapters[1]))
        assert.is_not_nil(context.active_job(manga, chapters[2]))
        assert.is_not_nil(context.active_job(manga, chapters[3]))
        assert.are.equal("downloaded", context.queue:getStatus(manga, chapters[1]).state)
        assert.are.equal("downloading", context.queue:getStatus(manga, chapters[2]).state)
        assert.are.equal("downloading", context.queue:getStatus(manga, chapters[3]).state)
    end)

    it("uses atomic progress writes so polling sees complete updates", function()
        local context = build_queue()
        local progress_path = context.queue:buildProgressPath(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1" },
            "/books"
        )

        context.queue:writeProgressFallback(progress_path, "failed", 0, 1, "", "network timeout")

        assert.are.equal(progress_path .. ".tmp", context.renamed_paths[#context.renamed_paths].from)
        assert.are.equal(progress_path, context.renamed_paths[#context.renamed_paths].to)
        assert.are.equal("state=failed\ncurrent=0\ntotal=1\npath=\nerror=network timeout\n", context.progress_files[progress_path])
        assert.is_nil(context.progress_files[progress_path .. ".tmp"])
    end)

    it("persists chapter details when the downloader reports failure", function()
        local context = build_queue({
            downloader = {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path) return chapter_path .. ".part" end,
                writeProgress = function(_, progress_path)
                    local handle = assert(io.open(progress_path, "w"))
                    handle:write("state=failed\ncurrent=0\ntotal=1\npath=\nerror=network timeout\n")
                    handle:close()
                end,
                downloadChapterWithProgress = function(self, _, _, _, _, progress_path)
                    self:writeProgress(progress_path)
                end,
                chapterExists = function() return false end,
            },
        })

        context.queue:enqueue({ id = "m1", title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" }, "/books")
        context.run_scheduled()

        assert.are.equal("failed", context.saved_queue()[1].state)
        local message = "Could not download \"Sousou no Frieren / Official_Vol. 1 Ch. 1\" (Suwayomi id 398): network timeout"
        assert.are.same({
            state = "failed",
            current = 0,
            total = 1,
            path = "",
            error = message,
            updated_at = 100,
        }, context.saved_queue()[1].progress)
        assert.are.equal(message, context.messages[#context.messages])
    end)

    it("uses the human chapter number in failure messages when available", function()
        local context = build_queue()

        local message = context.queue:formatFailureMessage(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "462", name = "Official_Vol. 7 Ch. 65", chapter_number = 65 },
            "network timeout"
        )

        assert.are.equal(
            "Could not download \"Sousou no Frieren / Official_Vol. 7 Ch. 65\" (Ch. 65): network timeout",
            message
        )
    end)

    it("labels fallback failure ids as Suwayomi ids", function()
        local context = build_queue()

        local message = context.queue:formatFailureMessage(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "462", name = "Official_Vol. 7 Ch. 65" },
            "network timeout"
        )

        assert.are.equal(
            "Could not download \"Sousou no Frieren / Official_Vol. 7 Ch. 65\" (Suwayomi id 462): network timeout",
            message
        )
    end)

    it("persists chapter number metadata for queued downloads", function()
        local context = build_queue()

        context.queue:enqueue(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "462", name = "Official_Vol. 7 Ch. 65", chapter_number = 65, source_order = 65 },
            "/books"
        )

        assert.are.same({
            id = "462",
            name = "Official_Vol. 7 Ch. 65",
            chapter_number = 65,
            source_order = 65,
        }, context.saved_queue()[1].chapter)
    end)

    it("reports retry state and clears failed artifacts before retrying", function()
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }
        local context = build_queue({
            saved_queue = {
                {
                    key = "m1:398",
                    state = "failed",
                    download_directory = "/books",
                    manga = manga,
                    chapter = chapter,
                    progress = {
                        state = "failed",
                        current = 0,
                        total = 1,
                        error = "network timeout",
                    },
                },
            },
        })
        local progress_path = context.queue:buildProgressPath(manga, chapter, "/books")
        context.progress_files[progress_path] = "state=failed\ncurrent=0\ntotal=1\npath=\nerror=network timeout\n"

        context.queue:recover()
        assert.are.equal("failed", context.queue:getStatus(manga, chapter).state)

        local ok, state = context.queue:enqueue(manga, chapter, "/books")

        assert.is_true(ok)
        assert.are.equal("retry", state)
        assert.are.equal("queued", context.saved_queue()[1].state)
        assert.is_nil(context.saved_queue()[1].progress)
        assert.are.equal("/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz.part", removed_paths[1])
        assert.are.equal(progress_path, removed_paths[2])
        assert.is_nil(context.progress_files[progress_path])

        context.run_scheduled()

        assert.are.same({}, context.saved_queue())
        assert.are.equal(1, context.download_calls())
        assert.are.equal("downloaded", context.queue:getStatus(manga, chapter).state)
    end)

    it("groups active queued and failed jobs in a download snapshot", function()
        local failed_manga = { id = "m-failed", title = "Chainsaw Man" }
        local failed_chapter = { id = "205", name = "Ch. 205" }
        local active_manga = { id = "m-active", title = "Frieren" }
        local active_chapter = { id = "144", name = "Ch. 144" }
        local queued_manga = { id = "m-queued", title = "Dandadan" }
        local queued_chapter = { id = "192", name = "Ch. 192" }
        local context = build_queue({
            saved_queue = {
                {
                    key = "m-failed:205",
                    state = "failed",
                    download_directory = "/books",
                    manga = failed_manga,
                    chapter = failed_chapter,
                    progress = {
                        state = "failed",
                        current = 0,
                        total = 1,
                        error = "network timeout",
                    },
                },
            },
        })

        context.queue:recover()
        context.queue.items = {
            {
                key = "m-queued:192",
                state = "queued",
                download_directory = "/books",
                manga = queued_manga,
                chapter = queued_chapter,
            },
        }
        context.queue:setActiveJob({
            key = "m-active:144",
            state = "downloading",
            download_directory = "/books",
            manga = active_manga,
            chapter = active_chapter,
            last_progress_current = 3,
            last_progress_total = 24,
            last_progress_state = "downloading",
        })

        local snapshot = context.queue:getSnapshot()

        assert.are.equal(1, #snapshot.active)
        assert.are.equal("m-active:144", snapshot.active[1].key)
        assert.are.equal("downloading", snapshot.active[1].state)
        assert.are.same({ state = "downloading", current = 3, total = 24 }, snapshot.active[1].progress)
        assert.are.equal(1, #snapshot.queued)
        assert.are.equal("m-queued:192", snapshot.queued[1].key)
        assert.are.equal("queued", snapshot.queued[1].state)
        assert.are.equal(1, #snapshot.failed)
        assert.are.equal("m-failed:205", snapshot.failed[1].key)
        assert.are.equal("network timeout", snapshot.failed[1].progress.error)
    end)

    it("retries a failed persistent job by key", function()
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }
        local context = build_queue({
            saved_queue = {
                {
                    key = "m1:398",
                    state = "failed",
                    download_directory = "/books",
                    manga = manga,
                    chapter = chapter,
                    progress = { state = "failed", error = "network timeout" },
                },
            },
        })

        context.queue:recover()

        local ok, state = context.queue:retryFailed("m1:398")

        assert.is_true(ok)
        assert.are.equal("retry", state)
        assert.are.equal("queued", context.saved_queue()[1].state)
        assert.are.equal("queued", context.queue:getStatus(manga, chapter).state)
    end)

    it("clears failed persistent jobs without clearing queued jobs", function()
        local failed_manga = { id = "m-failed", title = "Chainsaw Man" }
        local failed_chapter = { id = "205", name = "Ch. 205" }
        local queued_manga = { id = "m-queued", title = "Dandadan" }
        local queued_chapter = { id = "192", name = "Ch. 192" }
        local context = build_queue({
            saved_queue = {
                {
                    key = "m-failed:205",
                    state = "failed",
                    download_directory = "/books",
                    manga = failed_manga,
                    chapter = failed_chapter,
                },
                {
                    key = "m-queued:192",
                    state = "queued",
                    download_directory = "/books",
                    manga = queued_manga,
                    chapter = queued_chapter,
                },
            },
        })

        context.queue:recover()

        local cleared = context.queue:clearFailed()

        assert.are.equal(1, cleared)
        assert.are.equal(1, #context.saved_queue())
        assert.are.equal("m-queued:192", context.saved_queue()[1].key)
        assert.is_nil(context.queue:getStatus(failed_manga, failed_chapter))
        assert.are.equal("queued", context.queue:getStatus(queued_manga, queued_chapter).state)
    end)

    it("does not cancel a failed download record", function()
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }
        local context = build_queue({
            saved_queue = {
                {
                    key = "m1:398",
                    state = "failed",
                    download_directory = "/books",
                    manga = manga,
                    chapter = chapter,
                },
            },
        })

        context.queue:recover()
        local cancelled, state = context.queue:cancelPending(manga, chapter)

        assert.is_false(cancelled)
        assert.are.equal("failed", state)
        assert.are.equal("failed", context.saved_queue()[1].state)
        assert.are.equal("failed", context.queue:getStatus(manga, chapter).state)
    end)

    it("cancels all queued downloads without clearing active or failed jobs", function()
        local active_manga = { id = "m-active", title = "Frieren" }
        local active_chapter = { id = "144", name = "Ch. 144" }
        local queued_manga = { id = "m-queued", title = "Dandadan" }
        local queued_chapter = { id = "192", name = "Ch. 192" }
        local failed_manga = { id = "m-failed", title = "Chainsaw Man" }
        local failed_chapter = { id = "205", name = "Ch. 205" }
        local context = build_queue({
            saved_queue = {
                {
                    key = "m-active:144",
                    state = "downloading",
                    download_directory = "/books",
                    manga = active_manga,
                    chapter = active_chapter,
                },
                {
                    key = "m-queued:192",
                    state = "queued",
                    download_directory = "/books",
                    manga = queued_manga,
                    chapter = queued_chapter,
                },
                {
                    key = "m-failed:205",
                    state = "failed",
                    download_directory = "/books",
                    manga = failed_manga,
                    chapter = failed_chapter,
                },
            },
        })
        context.queue:recover()
        context.queue.items = {
            {
                key = "m-queued:192",
                state = "queued",
                download_directory = "/books",
                manga = queued_manga,
                chapter = queued_chapter,
            },
        }
        context.queue:setActiveJob({
            key = "m-active:144",
            state = "downloading",
            download_directory = "/books",
            manga = active_manga,
            chapter = active_chapter,
        })
        context.queue:setStatus(active_manga, active_chapter, {
            state = "downloading",
            current = 7,
            total = 24,
            path = "/books/Frieren/Ch. 144.cbz.part",
        })

        local cancelled = context.queue:cancelQueued()

        assert.are.equal(1, cancelled)
        assert.are.equal(0, #context.queue.items)
        assert.is_nil(context.queue:getStatus(queued_manga, queued_chapter))
        assert.are.same({
            state = "downloading",
            current = 7,
            total = 24,
            path = "/books/Frieren/Ch. 144.cbz.part",
        }, context.queue:getStatus(active_manga, active_chapter))
        assert.are.equal("failed", context.queue:getStatus(failed_manga, failed_chapter).state)
        assert.are.equal(2, #context.saved_queue())
        assert.are.equal("m-active:144", context.saved_queue()[1].key)
        assert.are.equal("m-failed:205", context.saved_queue()[2].key)
    end)

    it("requeues interrupted persistent downloads on recovery", function()
        local context = build_queue({
            saved_queue = {
                {
                    key = "m1:398",
                    state = "downloading",
                    download_directory = "/books",
                    manga = { id = "m1", title = "Sousou no Frieren" },
                    chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" },
                },
            },
        })

        context.queue:recover()
        context.run_scheduled()

        assert.are.same({}, context.saved_queue())
        assert.are.equal(1, context.download_calls())
        assert.are.equal("/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz.part", removed_paths[1])
    end)

    it("requeues interrupted downloads with preserved recovery progress", function()
        local context = build_queue({
            saved_queue = {
                {
                    key = "m1:398",
                    state = "downloading",
                    download_directory = "/books",
                    started_at = 90,
                    last_progress_at = 98,
                    progress = {
                        state = "downloading",
                        current = "2",
                        total = "5",
                        path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                        updated_at = 98,
                    },
                    manga = { id = "m1", title = "Sousou no Frieren" },
                    chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" },
                },
            },
        })

        context.queue:recover()

        local recovered = context.saved_queue()[1]
        assert.are.equal("queued", recovered.state)
        assert.are.equal(90, recovered.started_at)
        assert.are.equal(98, recovered.last_progress_at)
        assert.are.same({
            reason = "interrupted",
            recovered_at = 100,
            previous_state = "downloading",
            progress = {
                state = "downloading",
                current = 2,
                total = 5,
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                updated_at = 98,
            },
        }, recovered.recovery)
        assert.are.equal("queued", context.queue:getStatus(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1" }
        ).state)
    end)

    it("removes stale partial and progress files while recovering interrupted downloads", function()
        local context = build_queue({
            saved_queue = {
                {
                    key = "m1:398",
                    state = "downloading",
                    download_directory = "/books",
                    manga = { id = "m1", title = "Sousou no Frieren" },
                    chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" },
                },
            },
        })

        context.queue:recover()

        assert.are.same({
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz.part",
            "/books/.suwayomi_dl_progress_m1_398.txt",
        }, removed_paths)
    end)

    it("recovers multiple interrupted downloads in order and schedules one process callback", function()
        local context = build_queue({
            saved_queue = {
                {
                    key = "m1:398",
                    state = "downloading",
                    download_directory = "/books",
                    manga = { id = "m1", title = "Sousou no Frieren" },
                    chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" },
                },
                {
                    key = "m1:399",
                    state = "downloading",
                    download_directory = "/books",
                    manga = { id = "m1", title = "Sousou no Frieren" },
                    chapter = { id = "399", name = "Official_Vol. 1 Ch. 2" },
                },
            },
        })

        context.queue:recover()

        assert.are.equal(1, #context.scheduled)
        assert.are.equal("m1:398", context.saved_queue()[1].key)
        assert.are.equal("m1:399", context.saved_queue()[2].key)
    end)

    it("keeps failed jobs with progress failed during recovery", function()
        local context = build_queue({
            saved_queue = {
                {
                    key = "m1:398",
                    state = "failed",
                    download_directory = "/books",
                    progress = {
                        state = "failed",
                        current = 2,
                        total = 5,
                        error = "network timeout",
                        updated_at = 99,
                    },
                    manga = { id = "m1", title = "Sousou no Frieren" },
                    chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" },
                },
            },
        })

        context.queue:recover()

        assert.are.equal(0, #context.scheduled)
        assert.are.equal("failed", context.saved_queue()[1].state)
        assert.are.equal("network timeout", context.saved_queue()[1].progress.error)
        assert.are.equal("failed", context.queue:getStatus(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1" }
        ).state)
    end)

    it("clears recovered failed jobs when the archive exists locally", function()
        local target_path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"
        local context = build_queue({
            downloader = {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path) return chapter_path .. ".part" end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == target_path
                end,
            },
            saved_queue = {
                {
                    key = "m1:398",
                    state = "failed",
                    download_directory = "/books",
                    progress = {
                        state = "failed",
                        current = 2,
                        total = 2,
                        path = target_path,
                        error = "Could not finalize chapter archive.",
                        updated_at = 99,
                    },
                    manga = { id = "m1", title = "Sousou no Frieren" },
                    chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" },
                },
            },
        })

        context.queue:recover()

        assert.are.same({}, context.saved_queue())
        assert.are.equal(0, #context.scheduled)
        assert.is_nil(context.queue:getStatus(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1" }
        ))
    end)

    it("logs recovered interrupted downloads with progress context", function()
        local context = build_queue({
            saved_queue = {
                {
                    key = "m1:398",
                    state = "downloading",
                    download_directory = "/books",
                    progress = {
                        state = "downloading",
                        current = 2,
                        total = 5,
                    },
                    manga = { id = "m1", title = "Sousou no Frieren" },
                    chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" },
                },
            },
        })

        context.queue:recover()

        assert.are.same({
            {
                operation = "downloadQueue.recover",
                event = "interrupted",
                key = "m1:398",
                chapter_id = "398",
                previous_state = "downloading",
                progress_state = "downloading",
                progress_current = 2,
                progress_total = 5,
                cleanup_attempted = true,
            },
        }, context.debug_events)
    end)

    it("marks the active job failed when the watchdog expires", function()
        local context = build_queue({
            subprocess_done = false,
            skip_subprocess_callback = true,
        })

        context.queue:enqueue({ id = "m1", title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" }, "/books")
        local first = table.remove(context.scheduled, 1)
        first.callback()

        context.advance((30 * 60) + 1)
        local poll = table.remove(context.scheduled, 1)
        poll.callback()

        assert.are.equal("failed", context.saved_queue()[1].state)
        assert.are.same({
            state = "failed",
            current = 0,
            total = 0,
            error = "Could not download \"Sousou no Frieren / Official_Vol. 1 Ch. 1\" (Suwayomi id 398): Chapter download timed out.",
            updated_at = 1901,
        }, context.saved_queue()[1].progress)
        assert.are.equal(
            "Could not download \"Sousou no Frieren / Official_Vol. 1 Ch. 1\" (Suwayomi id 398): Chapter download timed out.",
            context.messages[#context.messages]
        )
    end)

    it("does not time out an active job that is still reporting progress", function()
        local context = build_queue({
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        table.remove(context.scheduled, 1).callback()

        context.advance((30 * 60) - 1)
        context.write_progress(manga, chapter, "downloading", 1, 2, "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz")
        table.remove(context.scheduled, 1).callback()

        context.advance(2)
        context.write_progress(manga, chapter, "downloading", 2, 3, "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz")
        table.remove(context.scheduled, 1).callback()

        assert.are.equal("downloading", context.queue:getStatus(manga, chapter).state)
        assert.are.equal(2, context.queue:getStatus(manga, chapter).current)
        assert.are.equal("downloading", context.saved_queue()[1].state)
        assert.are.same({}, context.messages)
    end)

    it("treats failed progress as downloaded when the archive exists locally", function()
        local target_path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"
        local context = build_queue({
            subprocess_done = true,
            skip_subprocess_callback = true,
            downloader = {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path) return chapter_path .. ".part" end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == target_path
                end,
            },
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        table.remove(context.scheduled, 1).callback()
        context.write_progress(manga, chapter, "failed", 2, 2, target_path, "Could not finalize chapter archive.")
        table.remove(context.scheduled, 1).callback()

        assert.are.same({}, context.saved_queue())
        assert.are.equal("downloaded", context.queue:getStatus(manga, chapter).state)
        assert.are.same({}, context.messages)
    end)
end)
