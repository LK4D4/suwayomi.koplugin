package.path = "?.lua;" .. package.path

describe("suwayomi_read_sync_worker", function()
    local original_io_open
    local original_os_rename
    local original_os_remove
    local files
    local renamed_paths
    local removed_paths

    local function install_file_mock()
        original_io_open = io.open
        original_os_rename = os.rename
        original_os_remove = os.remove
        files = {}
        renamed_paths = {}
        removed_paths = {}

        io.open = function(path, mode)
            if tostring(path):match("read_sync") then
                if mode == "w" then
                    local chunks = {}
                    return {
                        write = function(_, ...)
                            for _, chunk in ipairs({...}) do
                                table.insert(chunks, chunk)
                            end
                        end,
                        close = function()
                            files[path] = table.concat(chunks)
                        end,
                    }
                end

                local content = files[path]
                if not content then
                    return nil
                end
                return {
                    read = function(_, what)
                        if what == "*a" then
                            return content
                        end
                    end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end

        os.rename = function(from, to)
            if tostring(from):match("read_sync") or tostring(to):match("read_sync") then
                table.insert(renamed_paths, { from = from, to = to })
                files[to] = files[from]
                files[from] = nil
                return true
            end
            return original_os_rename(from, to)
        end

        os.remove = function(path)
            if tostring(path):match("read_sync") then
                table.insert(removed_paths, path)
                files[path] = nil
                return true
            end
            return original_os_remove(path)
        end
    end

    before_each(function()
        install_file_mock()
        package.loaded.suwayomi_read_sync_worker = nil
        package.loaded.suwayomi_api = nil
    end)

    after_each(function()
        io.open = original_io_open
        os.rename = original_os_rename
        os.remove = original_os_remove
        package.loaded.suwayomi_read_sync_worker = nil
        package.loaded.suwayomi_api = nil
        package.preload.suwayomi_api = nil
    end)

    it("dispatches read and unread mutations and writes mixed results atomically", function()
        local calls = {}
        package.preload.suwayomi_api = function()
            return {
                markChapterRead = function(credentials, chapter_id)
                    table.insert(calls, { state = true, chapter_id = chapter_id, server_url = credentials.server_url })
                    return { ok = true, chapter = { id = chapter_id, is_read = true } }
                end,
                markChapterUnread = function(credentials, chapter_id)
                    table.insert(calls, { state = false, chapter_id = chapter_id, server_url = credentials.server_url })
                    return { ok = false, error = "offline" }
                end,
            }
        end

        local worker = require("suwayomi_read_sync_worker")
        worker:run(
            { server_url = "https://suwayomi.example" },
            {
                { key = "m1:398", chapter_id = "398", desired_read_state = true },
                { key = "m1:399", chapter_id = "399", desired_read_state = false },
            },
            "/settings/suwayomi_read_sync_result.json"
        )

        assert.are.same({
            { state = true, chapter_id = "398", server_url = "https://suwayomi.example" },
            { state = false, chapter_id = "399", server_url = "https://suwayomi.example" },
        }, calls)
        assert.are.same({
            { from = "/settings/suwayomi_read_sync_result.json.tmp", to = "/settings/suwayomi_read_sync_result.json" },
        }, renamed_paths)

        local result = worker:readResult("/settings/suwayomi_read_sync_result.json")
        assert.are.equal(2, result.attempted)
        assert.are.same({
            { key = "m1:398", chapter_id = "398", desired_read_state = true },
        }, result.successes)
        assert.are.same({
            { key = "m1:399", chapter_id = "399", desired_read_state = false, error = "offline" },
        }, result.failures)
    end)

    it("writes failures for invalid requests without calling the API", function()
        local calls = 0
        package.preload.suwayomi_api = function()
            return {
                markChapterRead = function()
                    calls = calls + 1
                    return { ok = true }
                end,
            }
        end

        local worker = require("suwayomi_read_sync_worker")
        worker:run(
            { server_url = "https://suwayomi.example" },
            {
                { key = "missing-id", desired_read_state = true },
            },
            "/settings/suwayomi_read_sync_result.json"
        )

        local result = worker:readResult("/settings/suwayomi_read_sync_result.json")
        assert.are.equal(1, result.attempted)
        assert.are.equal(0, #result.successes)
        assert.are.equal("Missing chapter id.", result.failures[1].error)
        assert.are.equal(0, calls)
    end)

    it("writes failures for malformed batch items without crashing", function()
        local calls = 0
        package.preload.suwayomi_api = function()
            return {
                markChapterRead = function()
                    calls = calls + 1
                    return { ok = true }
                end,
            }
        end

        local worker = require("suwayomi_read_sync_worker")
        worker:run(
            { server_url = "https://suwayomi.example" },
            { 42 },
            "/settings/suwayomi_read_sync_result.json"
        )

        local result = worker:readResult("/settings/suwayomi_read_sync_result.json")
        assert.are.equal(1, result.attempted)
        assert.are.equal(0, #result.successes)
        assert.are.equal("Malformed read sync item.", result.failures[1].error)
        assert.are.equal(0, calls)
    end)

    it("writes failures when credentials are missing", function()
        local calls = 0
        package.preload.suwayomi_api = function()
            return {
                markChapterRead = function()
                    calls = calls + 1
                    return { ok = true }
                end,
            }
        end

        local worker = require("suwayomi_read_sync_worker")
        worker:run(
            { server_url = "" },
            {
                { key = "m1:398", chapter_id = "398", desired_read_state = true },
            },
            "/settings/suwayomi_read_sync_result.json"
        )

        local result = worker:readResult("/settings/suwayomi_read_sync_result.json")
        assert.are.equal(1, result.attempted)
        assert.are.equal(0, #result.successes)
        assert.are.equal("Missing Suwayomi server URL.", result.failures[1].error)
        assert.are.equal(0, calls)
    end)
end)
