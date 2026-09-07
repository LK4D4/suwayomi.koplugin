package.path = "?.lua;" .. package.path

-- Active job specs exercise subprocess lifecycle and progress polling behind
-- the queue facade. Queue persistence/facade behavior stays in queue specs.
local Marker = require("spec/support/i18n_marker")

describe("suwayomi/downloads/active_jobs", function()
    local original_io_open
    local original_os_remove
    local original_os_rename
    local removed_paths
    local renamed_paths
    local progress_files
    local marker_installed = false

    local function installMarker()
        if not marker_installed then
            Marker.install()
            marker_installed = true
        end
    end

    local function path_was_removed(path)
        for _, removed_path in ipairs(removed_paths or {}) do
            if removed_path == path then
                return true
            end
        end
        return false
    end

    local function install_progress_file_mock()
        original_io_open = io.open
        original_os_remove = os.remove
        original_os_rename = os.rename
        removed_paths = {}
        renamed_paths = {}
        progress_files = {}

        io.open = function(path, mode)
            if tostring(path):match("%.suwayomi_progress_") then
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
        local terminated_pids = {}
        local next_pid = 1233
        local subprocess_done = options.subprocess_done

        local downloader = options.downloader or {
            getTargetPath = function(_, download_directory, manga, chapter)
                return download_directory .. "/" .. manga.title,
                    download_directory .. "/" .. manga.title .. "/" .. chapter.name .. (chapter.id and (" [id-" .. chapter.id .. "]") or "") .. ".cbz"
            end,
            getPartialPath = function(_, chapter_path)
                return chapter_path .. ".part"
            end,
            getDirectPartialPath = function(_, chapter_path)
                return chapter_path .. ".direct.part"
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
                self:writeProgress(progress_path, "downloaded", 1, 1, download_directory .. "/" .. manga.title .. "/" .. chapter.name .. (chapter.id and (" [id-" .. chapter.id .. "]") or "") .. ".cbz")
            end,
            chapterExists = function(_, chapter_path)
                return options.existing_archive_paths and options.existing_archive_paths[chapter_path] == true or false
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
                terminateSubProcess = function(pid)
                    table.insert(terminated_pids, pid)
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
            terminated_pids = terminated_pids,
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
            write_progress = function(manga, chapter, state, current, total, path, error_message, retryable)
                local progress_path = context.queue:buildProgressPath(manga, chapter, "/books")
                local handle = assert(io.open(progress_path, "w"))
                handle:write("state=", tostring(state or ""), "\n")
                handle:write("current=", tostring(current or 0), "\n")
                handle:write("total=", tostring(total or 0), "\n")
                handle:write("path=", tostring(path or ""), "\n")
                if error_message then
                    handle:write("error=", tostring(error_message), "\n")
                end
                if retryable ~= nil then
                    handle:write("retryable=", retryable == true and "true" or "false", "\n")
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
        package.loaded["suwayomi/i18n"] = nil
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
        package.loaded["suwayomi/i18n"] = nil
        package.preload.gettext = nil
        package.preload["ffi/util"] = nil
        if marker_installed then
            Marker.uninstall()
            marker_installed = false
        end
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

    it("skips queued jobs whose key is already active", function()
        local context = build_queue({
            max_active_chapters = 2,
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:setActiveJob({
            key = context.queue:getKey(manga, chapter),
            manga = manga,
            chapter = chapter,
            pid = 999,
        })
        table.insert(context.queue.items, {
            key = context.queue:getKey(manga, chapter),
            download_directory = "/books",
            manga = manga,
            chapter = chapter,
            downloader = context.queue.downloader,
        })

        context.queue:process()

        assert.are.equal(1, context.active_count())
        assert.are.equal(999, context.active_job(manga, chapter).pid)
        assert.are.equal(0, context.download_calls())
        assert.are.equal(0, #context.queue.items)
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
        context.write_progress(manga, chapter, "downloading", 2, 5, "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz")
        table.remove(context.scheduled, 1).callback()

        local persisted = context.saved_queue()[1]
        assert.are.equal("downloading", persisted.state)
        assert.are.equal(100, persisted.started_at)
        assert.are.equal(103, persisted.last_progress_at)
        assert.are.same({
            state = "downloading",
            current = 2,
            total = 5,
            path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz",
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
        context.write_progress(manga, chapter, "downloading", 1, 5, "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz")
        table.remove(context.scheduled, 1).callback()
        local save_count_after_change = context.save_count()
        local status_changes_after_change = context.status_changes()

        context.advance(1)
        table.remove(context.scheduled, 1).callback()

        assert.are.equal(save_count_after_change, context.save_count())
        assert.are.equal(status_changes_after_change, context.status_changes())
        assert.are.equal(101, context.saved_queue()[1].last_progress_at)
        assert.are.equal(101, context.saved_queue()[1].progress.updated_at)
    end)

    it("retries a transient worker failure after a staggered delay", function()
        local context = build_queue({
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        table.remove(context.scheduled, 1).callback()
        context.write_progress(manga, chapter, "failed", 2, 5, "", "network timeout", true)
        table.remove(context.scheduled, 1).callback()

        local persisted = context.saved_queue()[1]
        assert.are.equal("queued", persisted.state)
        assert.are.equal(1, persisted.retry_count)
        assert.is_true(persisted.retry_at >= 105)
        assert.is_true(persisted.retry_at <= 109)
        assert.are.equal(2, persisted.progress.current)
        assert.is_true(persisted.progress.retryable)
        assert.are.equal("queued", context.queue:getStatus(manga, chapter).state)
        assert.is_nil(context.active_job(manga, chapter))
        assert.are.same({}, context.messages)

        context.advance(persisted.retry_at - 100)
        table.remove(context.scheduled, 1).callback()

        assert.is_nil(context.active_job(manga, chapter))
        assert.are.equal(1, context.scheduled[1].delay)

        context.set_subprocess_done(1234, true)
        context.advance(1)
        table.remove(context.scheduled, 1).callback()

        assert.is_not_nil(context.active_job(manga, chapter))
        assert.are.equal(1, context.active_job(manga, chapter).retry_count)
    end)

    it("marks a retryable worker failure terminal after retry exhaustion", function()
        local context = build_queue({
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        table.remove(context.scheduled, 1).callback()
        context.active_job(manga, chapter).retry_count = #context.queue.RETRY_DELAYS_SECONDS
        context.write_progress(manga, chapter, "failed", 2, 5, "", "network timeout", true)
        table.remove(context.scheduled, 1).callback()

        assert.are.equal("failed", context.saved_queue()[1].state)
        assert.are.equal("failed", context.queue:getStatus(manga, chapter).state)
        assert.is_nil(context.active_job(manga, chapter))
        assert.are.same({}, context.messages)
    end)

    it("keeps reaping a terminated worker after canceling its delayed retry", function()
        local context = build_queue({
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        table.remove(context.scheduled, 1).callback()
        context.write_progress(manga, chapter, "failed", 0, 5, "", "network timeout", true)
        table.remove(context.scheduled, 1).callback()
        local retry_at = context.saved_queue()[1].retry_at

        assert.is_true(context.queue:cancelPending(manga, chapter))
        assert.are.same({}, context.saved_queue())
        assert.is_nil(context.queue:getStatus(manga, chapter))
        assert.is_true(context.queue.active_job_lifecycle.terminating_pids[1234])

        context.advance(retry_at - 100)
        table.remove(context.scheduled, 1).callback()
        assert.are.equal(1, context.scheduled[1].delay)

        context.set_subprocess_done(1234, true)
        context.advance(1)
        table.remove(context.scheduled, 1).callback()

        assert.is_nil(context.queue.active_job_lifecycle.terminating_pids[1234])
        assert.are.equal(0, context.download_calls())
    end)

    it("pauses fresh queued work while one transient retry probes the network", function()
        local context = build_queue({
            max_active_chapters = 1,
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapters = {
            { id = "398", name = "Official_Vol. 1 Ch. 1" },
            { id = "399", name = "Official_Vol. 1 Ch. 2" },
        }

        context.queue:enqueueBatch(manga, chapters, "/books")
        table.remove(context.scheduled, 1).callback()
        context.write_progress(manga, chapters[1], "failed", 0, 5, "", "network timeout", true)
        table.remove(context.scheduled, 1).callback()

        assert.is_nil(context.active_job(manga, chapters[1]))
        assert.is_nil(context.active_job(manga, chapters[2]))
        assert.are.equal(chapters[2].id, context.queue.items[1].chapter.id)
        assert.are.equal(chapters[1].id, context.queue.items[2].chapter.id)

        local retry_at = context.saved_queue()[1].retry_at
        context.set_subprocess_done(1234, true)
        context.advance(retry_at - 100)
        table.remove(context.scheduled, 1).callback()

        assert.is_not_nil(context.active_job(manga, chapters[1]))
        assert.is_nil(context.active_job(manga, chapters[2]))
    end)

    it("backfills a completed active slot while another chapter keeps downloading", function()
        local first_path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz"
        local existing_archive_paths = {}
        local context = build_queue({
            max_active_chapters = 2,
            subprocess_done = {},
            skip_subprocess_callback = true,
            existing_archive_paths = existing_archive_paths,
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
        existing_archive_paths[first_path] = true
        context.write_progress(manga, chapters[1], "downloaded", 1, 1, first_path)
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
        local target_path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz"
        local existing_archive_paths = {}
        local context = build_queue({
            existing_archive_paths = existing_archive_paths,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        existing_archive_paths[target_path] = true
        context.run_scheduled()

        assert.are.equal(1, #context.archive_ready_calls)
        assert.are.equal(manga, context.archive_ready_calls[1].manga)
        assert.are.equal(chapter, context.archive_ready_calls[1].chapter)
        assert.are.equal(
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz",
            context.archive_ready_calls[1].path
        )
    end)

    it("records reader return context when the downloader skips an existing CBZ", function()
        local target_path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz"
        local archive_exists = false
        local context = build_queue({
            downloader = {
                getTargetPath = function(_, download_directory, manga)
                    return download_directory .. "/" .. manga.title,
                        target_path
                end,
                getPartialPath = function(_, chapter_path) return chapter_path .. ".part" end,
                startChapterDownload = function()
                    return {
                        ok = true,
                        skipped = true,
                        path = target_path,
                    }
                end,
                chapterExists = function() return archive_exists end,
            },
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        archive_exists = true
        context.run_scheduled()

        assert.are.equal(1, #context.archive_ready_calls)
        assert.are.equal(
            target_path,
            context.archive_ready_calls[1].path
        )
    end)

    it("keeps downloaded progress failed when the reported archive is missing", function()
        local context = build_queue()
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        context.run_scheduled()

        local persisted = context.saved_queue()[1]
        assert.is_not_nil(persisted)
        assert.are.equal("failed", persisted.state)
        assert.are.equal("failed", context.queue:getStatus(manga, chapter).state)
        assert.are.same({}, context.archive_ready_calls)
    end)

    it("keeps skipped progress failed when the reported archive is missing", function()
        local context = build_queue({
            downloader = {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. (chapter.id and (" [id-" .. chapter.id .. "]") or "") .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path) return chapter_path .. ".part" end,
                startChapterDownload = function(_, _, download_directory, manga, chapter)
                    return {
                        ok = true,
                        skipped = true,
                        path = download_directory .. "/" .. manga.title .. "/" .. chapter.name .. (chapter.id and (" [id-" .. chapter.id .. "]") or "") .. ".cbz",
                    }
                end,
                chapterExists = function() return false end,
            },
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        context.run_scheduled()

        local persisted = context.saved_queue()[1]
        assert.is_not_nil(persisted)
        assert.are.equal("failed", persisted.state)
        assert.are.equal("failed", context.queue:getStatus(manga, chapter).state)
        assert.are.same({}, context.archive_ready_calls)
    end)

    it("records translated fallback failures and raw worker errors without interrupting reading", function()
        installMarker()
        local startup = build_queue()
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        startup.queue.ffi_util.runInSubProcess = function()
            return nil
        end
        startup.queue:enqueue(manga, chapter, "/books")
        startup.run_scheduled()

        assert.are.equal(
            "Could not download \"Sousou no Frieren / Official_Vol. 1 Ch. 1\" (Suwayomi id 398): tx:Could not start chapter download: tx:unknown error",
            startup.saved_queue()[1].progress.error
        )
        assert.are.same({}, startup.messages)

        local missing_archive = build_queue()
        missing_archive.queue:enqueue(manga, chapter, "/books")
        missing_archive.run_scheduled()

        assert.are.equal(
            "Could not download \"Sousou no Frieren / Official_Vol. 1 Ch. 1\" (Suwayomi id 398): tx:Chapter download finished but the archive is missing.",
            missing_archive.saved_queue()[1].progress.error
        )
        assert.are.same({}, missing_archive.messages)

        local worker_failure = build_queue({
            downloader = {
                getTargetPath = function(_, download_directory, target_manga, target_chapter)
                    return download_directory .. "/" .. target_manga.title,
                        download_directory .. "/" .. target_manga.title .. "/" .. target_chapter.name .. (target_chapter.id and (" [id-" .. target_chapter.id .. "]") or "") .. ".cbz"
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

        worker_failure.queue:enqueue(manga, chapter, "/books")
        worker_failure.run_scheduled()

        assert.are.equal(
            "Could not download \"Sousou no Frieren / Official_Vol. 1 Ch. 1\" (Suwayomi id 398): network timeout",
            worker_failure.saved_queue()[1].progress.error
        )
        assert.are.same({}, worker_failure.messages)
    end)

    it("persists chapter details when the downloader reports failure", function()
        local context = build_queue({
            downloader = {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. (chapter.id and (" [id-" .. chapter.id .. "]") or "") .. ".cbz"
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
        assert.are.same({}, context.messages)
    end)

    it("removes partial archives when an active job is canceled", function()
        local context = build_queue({
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }
        local chapter_path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz"

        context.queue:enqueue(manga, chapter, "/books")
        table.remove(context.scheduled, 1).callback()
        local progress_path = context.queue:buildProgressPath(manga, chapter, "/books")

        local cancelled = context.queue:cancelPending(manga, chapter)

        assert.is_true(cancelled)
        assert.is_true(path_was_removed(chapter_path .. ".part"))
        assert.is_true(path_was_removed(chapter_path .. ".direct.part"))
        assert.is_true(path_was_removed(progress_path))
    end)

    it("backfills an active slot after the canceled worker exits", function()
        local context = build_queue({
            max_active_chapters = 1,
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapters = {
            { id = "398", name = "Official_Vol. 1 Ch. 1" },
            { id = "399", name = "Official_Vol. 1 Ch. 2" },
        }

        context.queue:enqueueBatch(manga, chapters, "/books")
        table.remove(context.scheduled, 1).callback()

        local cancelled = context.queue:cancelPending(manga, chapters[1])

        assert.is_true(cancelled)
        assert.is_nil(context.queue:getStatus(manga, chapters[1]))
        assert.are.equal("queued", context.queue:getStatus(manga, chapters[2]).state)
        assert.is_nil(context.active_job(manga, chapters[1]))
        assert.is_nil(context.active_job(manga, chapters[2]))
        assert.are.same({ 1234 }, context.terminated_pids)

        context.set_subprocess_done(1234, true)
        context.advance(1)
        while not context.active_job(manga, chapters[2]) do
            table.remove(context.scheduled, 1).callback()
        end

        assert.is_not_nil(context.active_job(manga, chapters[2]))
    end)

    it("requeues an active job with backoff when the watchdog expires", function()
        local context = build_queue({
            subprocess_done = false,
            skip_subprocess_callback = true,
        })
        local chapter_path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz"

        context.queue:enqueue({ id = "m1", title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" }, "/books")
        table.remove(context.scheduled, 1).callback()

        context.advance(context.queue.WATCHDOG_TIMEOUT_SECONDS + 1)
        table.remove(context.scheduled, 1).callback()

        assert.are.same({ 1234 }, context.terminated_pids)
        assert.are.equal("queued", context.saved_queue()[1].state)
        assert.are.equal(1, context.saved_queue()[1].retry_count)
        local watchdog_time = 100 + context.queue.WATCHDOG_TIMEOUT_SECONDS + 1
        assert.is_true(context.saved_queue()[1].retry_at >= watchdog_time + 5)
        assert.is_true(context.saved_queue()[1].retry_at <= watchdog_time + 9)
        assert.are.same({
            state = "queued",
            current = 0,
            total = 0,
            error = "Chapter download timed out.",
            retryable = true,
            updated_at = watchdog_time,
        }, context.saved_queue()[1].progress)
        assert.are.same({}, context.messages)
        assert.is_true(path_was_removed(chapter_path .. ".part"))
        assert.is_true(path_was_removed(chapter_path .. ".direct.part"))
    end)

    it("translates the queued watchdog retry detail", function()
        installMarker()
        local context = build_queue({
            subprocess_done = false,
            skip_subprocess_callback = true,
        })

        context.queue:enqueue({ id = "m1", title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" }, "/books")
        table.remove(context.scheduled, 1).callback()

        context.advance(context.queue.WATCHDOG_TIMEOUT_SECONDS + 1)
        table.remove(context.scheduled, 1).callback()

        assert.are.equal(
            "tx:Chapter download timed out.",
            context.saved_queue()[1].progress.error
        )
        assert.are.same({}, context.messages)
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

        context.advance(context.queue.WATCHDOG_TIMEOUT_SECONDS - 1)
        context.write_progress(manga, chapter, "downloading", 1, 2, "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz")
        table.remove(context.scheduled, 1).callback()

        context.advance(2)
        context.write_progress(manga, chapter, "downloading", 2, 3, "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz")
        table.remove(context.scheduled, 1).callback()

        assert.are.equal("downloading", context.queue:getStatus(manga, chapter).state)
        assert.are.equal(2, context.queue:getStatus(manga, chapter).current)
        assert.are.equal("downloading", context.saved_queue()[1].state)
        assert.are.same({}, context.messages)
    end)

    it("treats failed progress as downloaded when the archive exists locally", function()
        local target_path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz"
        local archive_exists = false
        local context = build_queue({
            subprocess_done = true,
            skip_subprocess_callback = true,
            downloader = {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. (chapter.id and (" [id-" .. chapter.id .. "]") or "") .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path) return chapter_path .. ".part" end,
                chapterExists = function(_, chapter_path)
                    return archive_exists and chapter_path == target_path
                end,
            },
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        table.remove(context.scheduled, 1).callback()
        archive_exists = true
        context.write_progress(manga, chapter, "failed", 2, 2, target_path, "Could not finalize chapter archive.")
        table.remove(context.scheduled, 1).callback()

        assert.are.same({}, context.saved_queue())
        assert.are.equal("downloaded", context.queue:getStatus(manga, chapter).state)
        assert.are.same({}, context.messages)
    end)

    it("treats a finished subprocess as downloaded when progress is missing but the archive exists locally", function()
        local target_path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz"
        local archive_exists = false
        local context = build_queue({
            subprocess_done = true,
            skip_subprocess_callback = true,
            downloader = {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. (chapter.id and (" [id-" .. chapter.id .. "]") or "") .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path) return chapter_path .. ".part" end,
                chapterExists = function(_, chapter_path)
                    return archive_exists and chapter_path == target_path
                end,
            },
        })
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" }

        context.queue:enqueue(manga, chapter, "/books")
        table.remove(context.scheduled, 1).callback()
        archive_exists = true
        table.remove(context.scheduled, 1).callback()

        assert.are.same({}, context.saved_queue())
        assert.are.equal("downloaded", context.queue:getStatus(manga, chapter).state)
        assert.are.same({}, context.messages)
    end)
end)
