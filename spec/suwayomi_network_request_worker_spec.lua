package.path = "?.lua;" .. package.path

describe("suwayomi/network/request_worker", function()
    local original_io_open
    local written
    local library_offsets

    local function clear_modules()
        for _, name in ipairs({
            "suwayomi/network/request_worker",
            "suwayomi/api",
            "suwayomi/subprocess/job",
        }) do
            package.loaded[name] = nil
            package.preload[name] = nil
        end
    end

    before_each(function()
        clear_modules()
        original_io_open = io.open
        written = {}
        library_offsets = {}

        package.preload["suwayomi/subprocess/job"] = function()
            return {
                writeResult = function(result_path, result)
                    written[result_path] = result
                    return true
                end,
                readResult = function(result_path, normalize)
                    local result = written[result_path]
                    if normalize then
                        return normalize(result)
                    end
                    return result
                end,
            }
        end
        package.preload["suwayomi/api"] = function()
            return {
                fetchLibraryManga = function(_, options)
                    table.insert(library_offsets, options.offset)
                    if options.offset == 0 then
                        local manga = {}
                        for index = 1, 100 do
                            manga[#manga + 1] = { id = "m" .. tostring(index) }
                        end
                        return { ok = true, manga = manga, total_count = 101 }
                    end
                    return { ok = true, manga = { { id = "m101" } }, total_count = 101 }
                end,
                updateMangaLibraryState = function(_, manga_id, in_library)
                    return {
                        ok = true,
                        manga = { id = manga_id, in_library = in_library },
                    }
                end,
            }
        end
    end)

    after_each(function()
        io.open = original_io_open
        clear_modules()
    end)

    it("paginates library manga inside the worker process", function()
        local Worker = require("suwayomi/network/request_worker")

        Worker:run({ server_url = "https://suwayomi.example" }, {
            action = "fetch_library_manga_pages",
        }, "/settings/library.json")

        assert.are.same({ 0, 100 }, library_offsets)
        assert.is_true(written["/settings/library.json"].ok)
        assert.are.equal(101, #written["/settings/library.json"].manga)
    end)

    it("updates manga library state inside the worker process", function()
        local Worker = require("suwayomi/network/request_worker")

        Worker:run({ server_url = "https://suwayomi.example" }, {
            action = "update_manga_library_state",
            manga_id = "m1",
            in_library = true,
        }, "/settings/update.json")

        assert.are.same({
            ok = true,
            manga = { id = "m1", in_library = true },
        }, written["/settings/update.json"])
    end)

    it("normalizes missing and malformed result files to network request errors", function()
        local Worker = require("suwayomi/network/request_worker")

        assert.are.same({
            ok = false,
            error = "Could not complete network request.",
        }, Worker:readResult("/settings/missing.json"))

        written["/settings/malformed.json"] = "not a result table"

        assert.are.same({
            ok = false,
            error = "Could not complete network request.",
        }, Worker:readResult("/settings/malformed.json"))
    end)

    it("normalizes oversized result files to network request errors", function()
        package.loaded["suwayomi/network/request_worker"] = nil
        package.loaded["suwayomi/subprocess/job"] = nil
        package.preload["suwayomi/subprocess/job"] = nil

        local oversized_content = '{"ok":true,"manga":[{"id":"' .. string.rep("x", 4 * 1024 * 1024 + 1) .. '"}]}'
        io.open = function(path, mode)
            if path == "/settings/oversized.json" and mode == "r" then
                local read_offset = 1
                return {
                    read = function(_, what)
                        if what == "*a" then
                            local chunk = oversized_content:sub(read_offset)
                            read_offset = #oversized_content + 1
                            return chunk
                        end
                        if type(what) == "number" then
                            local chunk = oversized_content:sub(read_offset, read_offset + what - 1)
                            read_offset = read_offset + #chunk
                            return chunk
                        end
                    end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end

        local Worker = require("suwayomi/network/request_worker")

        assert.are.same({
            ok = false,
            error = "Could not complete network request.",
        }, Worker:readResult("/settings/oversized.json"))
    end)
end)
