package.path = "?.lua;" .. package.path

describe("suwayomi/browse/chapter_count_worker", function()
    local original_io_open
    local original_os_rename
    local original_os_remove
    local files

    local function install_file_mock()
        original_io_open = io.open
        original_os_rename = os.rename
        original_os_remove = os.remove
        files = {}

        io.open = function(path, mode)
            if tostring(path):match("chapter_count") then
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
            if tostring(from):match("chapter_count") or tostring(to):match("chapter_count") then
                files[to] = files[from]
                files[from] = nil
                return true
            end
            return original_os_rename(from, to)
        end

        os.remove = function(path)
            if tostring(path):match("chapter_count") then
                files[path] = nil
                return true
            end
            return original_os_remove(path)
        end
    end

    before_each(function()
        install_file_mock()
        package.loaded["suwayomi/browse/chapter_count_worker"] = nil
        package.loaded["suwayomi/subprocess/job"] = nil
        package.loaded["suwayomi/api"] = nil
    end)

    after_each(function()
        io.open = original_io_open
        os.rename = original_os_rename
        os.remove = original_os_remove
        package.loaded["suwayomi/browse/chapter_count_worker"] = nil
        package.loaded["suwayomi/subprocess/job"] = nil
        package.loaded["suwayomi/api"] = nil
        package.preload["suwayomi/api"] = nil
    end)

    it("fetches chapters and writes a normalized count result", function()
        package.preload["suwayomi/api"] = function()
            return {
                fetchChaptersForManga = function(credentials, manga_id)
                    return {
                        ok = true,
                        server_url = credentials.server_url,
                        manga_id = manga_id,
                        chapters = {
                            { id = "c1" },
                            { id = "c2" },
                        },
                    }
                end,
            }
        end

        local worker = require("suwayomi/browse/chapter_count_worker")
        local result = worker:run(
            { server_url = "https://suwayomi.example" },
            "m1",
            "/settings/chapter_count.json"
        )

        assert.is_true(result.ok)
        assert.are.equal("m1", result.manga_id)
        assert.are.equal(2, result.chapter_count)
        assert.are.same(result, worker:readResult("/settings/chapter_count.json"))
    end)

    it("writes manga-scoped errors without crashing", function()
        package.preload["suwayomi/api"] = function()
            return {
                fetchChaptersForManga = function()
                    return {
                        ok = false,
                        error = "No chapters found",
                    }
                end,
            }
        end

        local worker = require("suwayomi/browse/chapter_count_worker")
        local result = worker:run(
            { server_url = "https://suwayomi.example" },
            "m2",
            "/settings/chapter_count_error.json"
        )

        assert.is_false(result.ok)
        assert.are.equal("m2", result.manga_id)
        assert.are.equal("No chapters found", result.error)
        assert.are.equal(0, result.chapter_count)
        assert.are.same(result, worker:readResult("/settings/chapter_count_error.json"))
    end)
end)
