package.path = "?.lua;" .. package.path

-- Active job specs exercise subprocess lifecycle and progress polling behind
-- the queue facade. Queue persistence/facade behavior stays in queue specs.
describe("suwayomi/downloads/active_jobs", function()
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
        package.loaded["suwayomi/downloads/active_jobs"] = nil
        package.loaded["suwayomi/downloads/queue"] = nil
        local DownloadQueue = require("suwayomi/downloads/queue")
        local scheduled = {}
        local saved_queue = options.saved_queue or {}
        local save_count = 0
        local now = options.now or 100
        local messages = {}
        local status_changes = 0
        local download_calls = 0
        local archive_ready_calls = {}
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
            onChapterArchiveReady = function(manga, chapter, path)
                table.insert(archive_ready_calls, {
                    manga = manga,
                    chapter = chapter,
                    path = path,
                })
            end,
        }

        local context
        context = {
            queue = queue,
            scheduled = scheduled,
            saved_queue = function() return saved_queue end,
            save_count = function() return save_count end,
            messages = messages,
            archive_ready_calls = archive_ready_calls,
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
                return context.queue:getActiveCount()
            end,
            active_job = function(manga, chapter)
                return context.queue:getActiveJob(context.queue:getKey(manga, chapter))
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
        package.loaded["suwayomi/downloads/active_jobs"] = nil
        package.loaded["suwayomi/downloads/queue"] = nil
        package.loaded.gettext = nil
        package.loaded["ffi/util"] = nil
        package.preload.gettext = nil
        package.preload["ffi/util"] = nil
    end)

    it("loads as the active download lifecycle module", function()
        local ActiveJobs = require("suwayomi/downloads/active_jobs")

        assert.is_table(ActiveJobs)
        assert.is_function(ActiveJobs.new)
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

    it("does not schedule duplicate polls while a poll is already pending", function()
        local context = build_queue({
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        table.remove(context.scheduled, 1).callback()

        assert.are.equal(1, #context.scheduled)

        context.queue:process()

        assert.are.equal(1, #context.scheduled)
    end)

    it("uses atomic progress writes so polling sees complete updates", function()
        local context = build_queue()
        local progress_path = context.queue:buildProgressPath(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1" },
            "/books"
        )

        context.queue.active_job_lifecycle:writeProgressFallback(progress_path, "failed", 0, 1, "", "network timeout")

        assert.are.equal(progress_path .. ".tmp", context.renamed_paths[#context.renamed_paths].from)
        assert.are.equal(progress_path, context.renamed_paths[#context.renamed_paths].to)
        assert.are.equal("state=failed\ncurrent=0\ntotal=1\npath=\nerror=network timeout\n", context.progress_files[progress_path])
        assert.is_nil(context.progress_files[progress_path .. ".tmp"])
    end)

    it("persists initial progress without runtime-only fields when a queued job becomes active", function()
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

    it("records reader return context when a download finishes with a CBZ path", function()
        local context = build_queue()
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        context.run_scheduled()

        assert.are.equal(1, #context.archive_ready_calls)
        assert.are.equal(manga, context.archive_ready_calls[1].manga)
        assert.are.equal(chapter, context.archive_ready_calls[1].chapter)
        assert.are.equal(
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
            context.archive_ready_calls[1].path
        )
    end)

    it("records reader return context when the downloader skips an existing CBZ", function()
        local context = build_queue({
            downloader = {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path) return chapter_path .. ".part" end,
                startChapterDownload = function(_, _, download_directory, manga, chapter)
                    return {
                        ok = true,
                        skipped = true,
                        path = download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz",
                    }
                end,
                chapterExists = function() return true end,
            },
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        context.run_scheduled()

        assert.are.equal(1, #context.archive_ready_calls)
        assert.are.equal(
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
            context.archive_ready_calls[1].path
        )
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

        local message = "Could not download \"Sousou no Frieren / Official_Vol. 1 Ch. 1\" (Suwayomi id 398): network timeout"
        assert.are.equal("failed", context.saved_queue()[1].state)
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

    it("marks the active job failed when the watchdog expires", function()
        local context = build_queue({
            subprocess_done = false,
            skip_subprocess_callback = true,
        })

        context.queue:enqueue({ id = "m1", title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" }, "/books")
        table.remove(context.scheduled, 1).callback()

        context.advance((30 * 60) + 1)
        table.remove(context.scheduled, 1).callback()

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

    it("treats a finished subprocess as downloaded when progress is missing but the archive exists locally", function()
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
        table.remove(context.scheduled, 1).callback()

        assert.are.same({}, context.saved_queue())
        assert.are.equal("downloaded", context.queue:getStatus(manga, chapter).state)
        assert.are.same({}, context.messages)
    end)
end)
