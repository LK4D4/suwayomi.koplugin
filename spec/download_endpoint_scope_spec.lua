package.path = "?.lua;" .. package.path

local runtime = require("spec/support/plugin_runtime_spec_helper")

describe("download attempt endpoint authority", function()
    local settings, queue, children, requests, timers, files, root, now, result, saved_modules
    local scope, foreign = "https://a.example", "https://b.example"
    local manga, chapter
    local extra = { "suwayomi/chapters/manual_deletion", "suwayomi/chapters/archive_identity" }

    local function clear()
        runtime.teardown()
        for _, name in ipairs(extra) do package.loaded[name], package.preload[name] = nil, nil end
    end
    local function write(path, content)
        files[path] = true
        local handle = assert(io.open(path, "wb"))
        assert(handle:write(content))
        assert(handle:close())
    end
    local function read(path)
        local handle = assert(io.open(path, "rb"))
        local content = handle:read("*a")
        handle:close()
        return content
    end
    local function newQueue(downloader)
        local service = require("suwayomi/downloads/service"):new{
            settings = settings,
            ui_manager = { scheduleIn = function(_, delay, callback)
                timers[#timers + 1] = { delay = delay, callback = callback }
            end },
            now = function() return now end,
            ffi_util = {
                runInSubProcess = function(callback)
                    children[#children + 1] = { callback = callback }
                    return #children
                end,
                isSubProcessDone = function(pid) return children[pid].done == true end,
                terminateSubProcess = function() end,
            },
            downloader = downloader or {
                getTargetPath = function(_, directory, _, item)
                    return directory, directory .. "/" .. item.id .. ".cbz"
                end,
                chapterExists = function(_, path)
                    local handle = io.open(path, "rb")
                    if handle then handle:close(); return true end
                    return false
                end,
                downloadChapterWithProgress = function(_, credentials, directory, _, item, progress, options)
                    requests[#requests + 1] = { endpoint = credentials.server_url, username = credentials.username,
                        chapter_id = item.id, force = options.force, repair_path = options.repair_path }
                    files[progress] = true
                    local path = options.repair_path or directory .. "/" .. item.id .. ".cbz"
                    if result == "retry" then
                        write(progress, "state=failed\nerror=HTTP 503\nretryable=true\n")
                        return
                    end
                    -- Controlled transfer adapter: colliding IDs return endpoint-specific bytes.
                    write(path, credentials.server_url .. ":" .. item.id)
                    write(progress, "state=downloaded\ncurrent=1\ntotal=1\npath=" .. path .. "\n")
                end,
            },
        }
        return service.queue
    end
    local function finish(pid)
        children[pid].callback()
        children[pid].done = true
        queue:poll()
    end
    local function stored() return assert(queue:findPersistentJob("101:202")) end
    local function change(endpoint, username)
        assert(settings:save{ server_url = endpoint, username = username or "test-user" })
    end

    before_each(function()
        clear()
        runtime.install()
        package.preload["suwayomi/settings"], package.preload["suwayomi/downloads/queue"] = nil, nil
        package.preload.lfs, package.loaded.lfs = nil, nil
        settings = require("suwayomi/settings")
        settings:setStore(require("spec/support/checked_queue_settings")():getStore())
        children, requests, timers, files, now, result = {}, {}, {}, {}, 100, "success"
        saved_modules = {}
        root = os.tmpname()
        os.remove(root)
        assert(require("lfs").mkdir(root))
        manga = { id = 101, title = "Fixture", endpoint_scope = scope, source = { name = "Local" } }
        chapter = { id = 202, name = "Chapter" }
        change(scope)
        queue = newQueue()
    end)
    after_each(function()
        for path in pairs(files) do os.remove(path) end
        assert(require("lfs").rmdir(root))
        for name, saved in pairs(saved_modules) do
            package.loaded[name], package.preload[name] = saved.loaded, saved.preload
        end
        clear()
    end)

    it("fails a queued A job before any B request and allows explicit retry after restoring A", function()
        assert(queue:enqueue(manga, chapter, root))
        change(foreign)
        queue:process()
        assert.equals("failed", stored().state)
        assert.equals(scope, stored().manga.endpoint_scope)
        assert.equals(root, stored().download_directory)
        assert.equals(202, stored().chapter.id)
        assert.same({}, children)
        assert.same({}, requests)
        assert.matches("original server", stored().progress.error)
        assert.is_true(queue:retryFailed("101:202"))
        queue:process()
        assert.equals("failed", stored().state)
        assert.same({}, children)
        change(scope)
        assert.is_true(queue:retryFailed("101:202"))
        queue:process()
        finish(1)
        assert.same({ { endpoint = scope, username = "test-user", chapter_id = 202 } }, requests)
        assert.equals(scope .. ":202", read(root .. "/202.cbz"))
        assert.equals(scope, settings:loadChapterLedger()["101:202"].endpoint_scope)
        assert.equals(scope, settings:loadReaderReturnContexts()[root .. "/202.cbz"].endpoint_scope)
    end)

    it("fails an automatic retry on B without spending another transfer or blocking eligible jobs", function()
        result = "retry"
        assert(queue:enqueue(manga, chapter, root))
        queue:process()
        finish(1)
        assert.equals("queued", stored().state)
        assert.equals(1, stored().retry_count)
        now = stored().retry_at
        change(foreign)
        local other = { id = 303, title = "B fixture", endpoint_scope = foreign }
        assert(queue:enqueue(other, { id = 202, name = "Colliding chapter" }, root))
        queue:process()
        assert.equals("failed", stored().state)
        assert.equals(1, stored().retry_count)
        assert.equals(scope, stored().manga.endpoint_scope)
        assert.equals(2, #children)
        assert.equals("downloading", queue:getStatus(other, chapter).state)
        -- Execute B's eligible worker with a transient response, preserving the shared-ID control.
        finish(2)
        assert.equals(scope, requests[1].endpoint)
        assert.equals(foreign, requests[2].endpoint)
        for _ = 1, 5 do queue:process() end
        assert.equals(2, #children)
    end)

    for _, state in ipairs({ "queued", "downloading" }) do
        it("rejects " .. state .. " A work after restart under B", function()
            assert(queue:enqueue(manga, chapter, root))
            if state == "downloading" then queue:process() end
            local before = stored()
            change(foreign)
            children = {}
            queue = newQueue()
            queue:recover()
            queue:process()
            assert.equals("failed", stored().state)
            assert.same(before.manga, stored().manga)
            assert.same(before.chapter, stored().chapter)
            assert.equals(before.download_directory, stored().download_directory)
            assert.same({}, children)
            assert.same({}, requests)
        end)
    end

    it("refreshes credentials at the same normalized endpoint and keeps a running worker captured", function()
        assert(queue:enqueue(manga, chapter, root))
        change(scope .. "/", "new-user")
        queue:process()
        change(foreign)
        finish(1)
        assert.equals(scope .. "/", requests[1].endpoint)
        assert.equals("new-user", requests[1].username)
        assert.equals(scope, settings:loadChapterLedger()["101:202"].endpoint_scope)
        assert.equals(scope, settings:loadReaderReturnContexts()[root .. "/202.cbz"].endpoint_scope)
    end)

    it("does not infer a missing historical origin from current credentials", function()
        manga.endpoint_scope = nil
        assert(queue:enqueue(manga, chapter, root))
        queue = newQueue()
        queue:recover()
        queue:process()
        assert.equals("failed", stored().state)
        assert.is_nil(stored().manga.endpoint_scope)
        assert.matches("origin is unknown", stored().progress.error)
        assert.same({}, children)
        assert.is_true(queue:retryFailed("101:202"))
        queue:process()
        assert.same({}, children)
    end)

    it("preserves an existing archive and reading metadata when Redownload starts under B", function()
        local path = root .. "/202.cbz"
        write(path, "original A archive")
        write(path .. ".sidecar", "saved page 7")
        local ledger = { ["101:202"] = { manga_id = "101", chapter_id = "202", path = path,
            endpoint_scope = scope, read = true, pending_read_sync = true, pending_read_state = true } }
        assert(settings:saveChapterLedger(ledger))
        assert(queue:redownload(manga, chapter, root))
        change(foreign)
        queue:process()
        assert.equals("failed", stored().state)
        assert.is_true(stored().repair)
        assert.equals(scope, stored().manga.endpoint_scope)
        assert.same({}, children)
        assert.equals("original A archive", read(path))
        assert.equals("saved page 7", read(path .. ".sidecar"))
        assert.same(ledger, settings:loadChapterLedger())
        change(scope)
        assert.is_true(queue:retryFailed("101:202"))
        queue:process()
        finish(1)
        assert.is_true(requests[1].force)
        assert.equals(scope, requests[1].endpoint)
        assert.equals("saved page 7", read(path .. ".sidecar"))
        assert.is_true(settings:loadChapterLedger()["101:202"].read)
        assert.is_true(settings:loadChapterLedger()["101:202"].pending_read_sync)
    end)

    for _, batch in ipairs({ false, true }) do
        it("retains accepted identity when caller metadata changes (batch=" .. tostring(batch) .. ")", function()
            if batch then assert.equals(1, queue:enqueueBatch(manga, { chapter }, root))
            else assert(queue:enqueue(manga, chapter, root)) end
            manga.endpoint_scope, manga.title, chapter.name = foreign, "B title", "B chapter"
            change(foreign)
            queue:process()
            assert.equals("failed", stored().state)
            assert.equals(scope, stored().manga.endpoint_scope)
            assert.equals("Fixture", stored().manga.title)
            assert.equals("Chapter", stored().chapter.name)
            assert.same({}, children)
        end)
    end

    it("keeps a rejected mismatch failure queued without transferring until its save succeeds", function()
        assert(queue:enqueue(manga, chapter, root))
        change(foreign)
        local store = settings:getStore()
        local write_settings = store.io.write
        store.io.write = function() return nil, "injected write rejection" end
        queue:process()
        assert.equals("queued", stored().state)
        assert.same({}, children)
        store.io.write = write_settings
        queue:process()
        assert.equals("failed", stored().state)
        assert.equals(scope, stored().manga.endpoint_scope)
        assert.same({}, children)
    end)

    it("keeps the original failed job when Redownload receives colliding B metadata", function()
        assert(queue:redownload(manga, chapter, root))
        change(foreign)
        queue:process()
        local original = stored()
        local other = { id = 101, title = "B title", endpoint_scope = foreign }
        assert(queue:redownload(other, { id = 202, name = "B chapter" }, root .. "/b"))
        queue:process()
        assert.equals("failed", stored().state)
        assert.same(original.manga, stored().manga)
        assert.same(original.chapter, stored().chapter)
        assert.equals(original.download_directory, stored().download_directory)
        assert.same({}, children)
    end)

    for _, batch in ipairs({ false, true }) do
        it("preserves failed A work through explicit Download with B IDs (batch=" .. tostring(batch) .. ")", function()
            assert(queue:enqueue(manga, chapter, root))
            change(foreign)
            queue:process()
            local original = stored()
            local other = { id = 101, title = "B title", endpoint_scope = foreign }
            local collision = { id = 202, name = "B chapter" }
            if batch then
                assert.equals(1, queue:enqueueBatch(other, { collision }, root .. "/b", { provenance = "explicit" }))
            else
                assert(queue:enqueue(other, collision, root .. "/b", { provenance = "explicit" }))
            end
            queue:process()
            assert.equals("failed", stored().state)
            assert.same(original.manga, stored().manga)
            assert.same(original.chapter, stored().chapter)
            assert.equals(original.download_directory, stored().download_directory)
            assert.same({}, children)
        end)
    end

    it("checks the production downloader HTTP destination after blocking B and restoring A", function()
        for _, name in ipairs({ "suwayomi/api", "suwayomi/api/transport", "suwayomi/api/parsers",
            "suwayomi/api/queries", "suwayomi/downloads/downloader", "suwayomi/fs", "ssl.https" }) do
            saved_modules[name] = { loaded = package.loaded[name], preload = package.preload[name] }
            package.loaded[name], package.preload[name] = nil, nil
        end
        local urls = {}
        package.loaded["ssl.https"] = { request = function(options)
            urls[#urls + 1] = options.url
            return 1, 403, {}
        end }
        local downloader = require("suwayomi/downloads/downloader")
        downloader.getTargetPath = function() return root, root .. "/202.cbz" end
        downloader.getChapterPathCandidates = function() return { root .. "/202.cbz" } end
        queue = newQueue(downloader)
        assert(queue:enqueue(manga, chapter, root))
        change(foreign)
        queue:process()
        assert.equals("failed", stored().state)
        assert.same({}, children)
        assert.same({}, urls)
        change(scope)
        assert(queue:retryFailed("101:202"))
        queue:process()
        files[queue:getActiveJob("101:202").progress_path] = true
        finish(1)
        assert.same({ scope .. "/api/v1/chapter/202/download?markAsRead=false" }, urls)
        assert.equals(scope, stored().manga.endpoint_scope)
        assert.equals("failed", stored().state) -- Controlled HTTP rejection; no archive published.
    end)

    for _, command in ipairs({ "enqueue", "enqueueBatch", "redownload" }) do
        it("preserves incomplete and unsupported failed records during " .. command, function()
            for _, damage in ipairs({ "manga", "chapter", "download_directory", "key", "version" }) do
                local job = queue:buildPersistentJob(manga, chapter, root, "failed")
                if damage == "key" then job.manga.id = 999
                elseif damage == "version" then job.version = 99
                else job[damage] = nil end
                assert(settings:saveDownloadQueue({ job }))
                local other = { id = 101, title = "B fixture", endpoint_scope = foreign }
                change(foreign)
                if command == "enqueueBatch" then
                    assert.equals(0, queue:enqueueBatch(other, { chapter }, root, { provenance = "explicit" }))
                else
                    assert.is_false(queue[command](queue, other, chapter, root, { provenance = "explicit" }))
                end
                assert.same({ job }, settings:loadDownloadQueue())
                assert.same({}, children)
            end
        end)
    end
end)
