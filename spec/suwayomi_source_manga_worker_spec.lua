package.path = "?.lua;" .. package.path

describe("suwayomi/browse/source_manga_worker", function()
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
            if tostring(path):match("source_manga") then
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
            if tostring(from):match("source_manga") or tostring(to):match("source_manga") then
                files[to] = files[from]
                files[from] = nil
                return true
            end
            return original_os_rename(from, to)
        end

        os.remove = function(path)
            if tostring(path):match("source_manga") then
                files[path] = nil
                return true
            end
            return original_os_remove(path)
        end
    end

    before_each(function()
        install_file_mock()
        package.loaded["suwayomi/browse/source_manga_worker"] = nil
        package.loaded["suwayomi/subprocess/job"] = nil
        package.loaded["suwayomi/api"] = nil
    end)

    after_each(function()
        io.open = original_io_open
        os.rename = original_os_rename
        os.remove = original_os_remove
        package.loaded["suwayomi/browse/source_manga_worker"] = nil
        package.loaded["suwayomi/subprocess/job"] = nil
        package.loaded["suwayomi/api"] = nil
        package.preload["suwayomi/api"] = nil
    end)

    it("fetches one source manga page and writes a normalized result", function()
        package.preload["suwayomi/api"] = function()
            return {
                fetchMangaForSource = function(credentials, options)
                    return {
                        ok = true,
                        server_url = credentials.server_url,
                        options = options,
                        manga = {
                            { id = "m1", title = "Frieren" },
                        },
                        has_next_page = true,
                    }
                end,
            }
        end

        local worker = require("suwayomi/browse/source_manga_worker")
        local result = worker:run(
            { server_url = "https://suwayomi.example" },
            { id = "s1", name = "MangaDex", lang = "en" },
            { type = "SEARCH", query = "frieren", page = 2 },
            "/settings/source_manga.json"
        )

        assert.is_true(result.ok)
        assert.are.equal("s1", result.source.id)
        assert.are.equal("SEARCH", result.browse_options.type)
        assert.are.equal("frieren", result.browse_options.query)
        assert.are.equal(2, result.browse_options.page)
        assert.are.equal(1, #result.manga)
        assert.is_true(result.has_next_page)
        assert.are.same(result, worker:readResult("/settings/source_manga.json"))
    end)

    it("writes source manga errors without crashing", function()
        package.preload["suwayomi/api"] = function()
            return {
                fetchMangaForSource = function()
                    return {
                        ok = false,
                        error = "Timed out",
                    }
                end,
            }
        end

        local worker = require("suwayomi/browse/source_manga_worker")
        local result = worker:run(
            { server_url = "https://suwayomi.example" },
            { id = "s2", name = "Comick" },
            { type = "POPULAR", page = 1 },
            "/settings/source_manga_error.json"
        )

        assert.is_false(result.ok)
        assert.are.equal("Timed out", result.error)
        assert.are.equal("s2", result.source.id)
        assert.are.same(result, worker:readResult("/settings/source_manga_error.json"))
    end)
end)
