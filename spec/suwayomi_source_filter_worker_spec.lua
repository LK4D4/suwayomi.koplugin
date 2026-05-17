package.path = "?.lua;" .. package.path

describe("suwayomi/browse/source_filter_worker", function()
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
            if tostring(path):match("source_filter") then
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
            if tostring(from):match("source_filter") or tostring(to):match("source_filter") then
                files[to] = files[from]
                files[from] = nil
                return true
            end
            return original_os_rename(from, to)
        end

        os.remove = function(path)
            if tostring(path):match("source_filter") then
                files[path] = nil
                return true
            end
            return original_os_remove(path)
        end
    end

    before_each(function()
        install_file_mock()
        package.loaded["suwayomi/browse/source_filter_worker"] = nil
        package.loaded["suwayomi/subprocess/job"] = nil
        package.loaded["suwayomi/api"] = nil
    end)

    after_each(function()
        io.open = original_io_open
        os.rename = original_os_rename
        os.remove = original_os_remove
        package.loaded["suwayomi/browse/source_filter_worker"] = nil
        package.loaded["suwayomi/subprocess/job"] = nil
        package.loaded["suwayomi/api"] = nil
        package.preload["suwayomi/api"] = nil
    end)

    it("fetches source filters and writes a normalized result", function()
        package.preload["suwayomi/api"] = function()
            return {
                fetchSourceFilters = function(credentials, source_id)
                    return {
                        ok = true,
                        server_url = credentials.server_url,
                        source = { id = source_id, name = "MangaDex API" },
                        filters = {
                            { type = "TextFilter", name = "Author", default = "" },
                        },
                    }
                end,
            }
        end

        local worker = require("suwayomi/browse/source_filter_worker")
        local result = worker:run(
            { server_url = "https://suwayomi.example" },
            { id = "s1", name = "MangaDex" },
            "/settings/source_filter.json"
        )

        assert.is_true(result.ok)
        assert.are.equal("s1", result.source.id)
        assert.are.equal("MangaDex API", result.source.name)
        assert.are.equal(1, #result.filters)
        assert.are.same(result, worker:readResult("/settings/source_filter.json"))
    end)

    it("writes source filter errors without crashing", function()
        package.preload["suwayomi/api"] = function()
            return {
                fetchSourceFilters = function()
                    return {
                        ok = false,
                        error = "Unsupported source",
                    }
                end,
            }
        end

        local worker = require("suwayomi/browse/source_filter_worker")
        local result = worker:run(
            { server_url = "https://suwayomi.example" },
            { id = "s2", name = "Comick" },
            "/settings/source_filter_error.json"
        )

        assert.is_false(result.ok)
        assert.are.equal("Unsupported source", result.error)
        assert.are.equal("s2", result.source.id)
        assert.are.same(result, worker:readResult("/settings/source_filter_error.json"))
    end)
end)
