package.path = "?.lua;" .. package.path

describe("suwayomi/network/request_worker", function()
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

    after_each(clear_modules)

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
end)
