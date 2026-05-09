package.path = "?.lua;" .. package.path

describe("suwayomi/browse/source_fetch_worker", function()
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
            if tostring(path):match("source_fetch") then
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
            if tostring(from):match("source_fetch") or tostring(to):match("source_fetch") then
                files[to] = files[from]
                files[from] = nil
                return true
            end
            return original_os_rename(from, to)
        end

        os.remove = function(path)
            if tostring(path):match("source_fetch") then
                files[path] = nil
                return true
            end
            return original_os_remove(path)
        end
    end

    before_each(function()
        install_file_mock()
        package.loaded["suwayomi/browse/source_fetch_worker"] = nil
        package.loaded["suwayomi/api"] = nil
    end)

    after_each(function()
        io.open = original_io_open
        os.rename = original_os_rename
        os.remove = original_os_remove
        package.loaded["suwayomi/browse/source_fetch_worker"] = nil
        package.loaded["suwayomi/api"] = nil
        package.preload["suwayomi/api"] = nil
    end)

    it("fetches sources and writes the result atomically", function()
        package.preload["suwayomi/api"] = function()
            return {
                fetchSources = function(credentials)
                    return {
                        ok = true,
                        sources = {
                            { id = "1", name = "Local source", lang = "localsourcelang" },
                            { id = "2", name = "MangaDex", lang = "en" },
                        },
                        server_url = credentials.server_url,
                    }
                end,
            }
        end

        local worker = require("suwayomi/browse/source_fetch_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, "/settings/source_fetch.json")

        assert.is_true(result.ok)
        assert.are.equal(2, #result.sources)
        assert.are.same(result, worker:readResult("/settings/source_fetch.json"))
    end)
end)
