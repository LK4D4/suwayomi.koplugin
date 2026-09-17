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
                fetchCategories = function()
                    return { ok = true, categories = { { id = "reading", name = "Reading" } } }
                end,
                fetchLibraryManga = function(_, options)
                    table.insert(library_offsets, options.offset)
                    if options.offset == 0 then
                        local manga = {}
                        for index = 1, 100 do
                            manga[#manga + 1] = { id = "m" .. tostring(index) }
                        end
                        return { ok = true, manga = manga, total_count = 101, has_next_page = true }
                    end
                    return { ok = true, manga = { { id = "m101" } }, total_count = 101, has_next_page = false }
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
            action = "fetch_library_snapshot",
        }, "/settings/library.json")

        assert.are.same({ 0, 100 }, library_offsets)
        assert.is_true(written["/settings/library.json"].ok)
        assert.are.equal(101, #written["/settings/library.json"].manga)
    end)

    it("publishes categories and the complete Library together", function()
        local Worker = require("suwayomi/network/request_worker")
        local result = Worker:run({}, { action = "fetch_library_snapshot" }, "/settings/snapshot.json")

        assert.is_true(result.ok)
        assert.are.same({ { id = "reading", name = "Reading" } }, result.categories)
        assert.are.equal(101, result.total_count)
        assert.are.equal(101, #result.manga)
        assert.are.equal("m1", result.manga[1].id)
        assert.are.equal("m101", result.manga[101].id)
        assert.are.same(result, written["/settings/snapshot.json"])
    end)

    local function snapshotWithPages(pages, categories)
        local api = require("suwayomi/api")
        local index = 0
        api.fetchCategories = function()
            return categories or { ok = true, categories = {} }
        end
        api.fetchLibraryManga = function()
            index = index + 1
            return pages[index]
        end
        return require("suwayomi/network/request_worker"):run(
            {}, { action = "fetch_library_snapshot" }, "/settings/snapshot.json")
    end

    local function libraryPage(first, last, total, has_next)
        local manga = {}
        for id = first, last do manga[#manga + 1] = { id = tostring(id) } end
        return { ok = true, manga = manga, total_count = total, has_next_page = has_next }
    end

    it("publishes an authoritative empty Library snapshot", function()
        assert.are.same({ ok = true, categories = {}, manga = {}, total_count = 0 },
            snapshotWithPages({ libraryPage(1, 0, 0, false) }))
    end)

    for name, later_page in pairs({
        ["a failed later page"] = { ok = false, error = "Unavailable" },
        ["a missing later page"] = {},
        ["an early end"] = libraryPage(101, 101, 102, false),
        ["an empty continuation"] = libraryPage(101, 100, 102, true),
        ["a short continuing page"] = libraryPage(101, 101, 102, true),
        ["a changed total"] = libraryPage(101, 101, 101, false),
        ["duplicate identities"] = libraryPage(100, 101, 102, false),
        ["a contradictory continuation"] = libraryPage(101, 102, 102, true),
        ["too many records"] = libraryPage(101, 103, 102, false),
        ["missing completion metadata"] = { ok = true, manga = { { id = "101" }, { id = "102" } } },
    }) do
        it("does not publish a partial snapshot after " .. name, function()
            local result = snapshotWithPages({ libraryPage(1, 100, 102, true), later_page })
            assert.is_false(result.ok)
            assert.is_nil(result.manga)
            assert.is_nil(result.categories)
            assert.is_nil(written["/settings/snapshot.json"].manga)
        end)
    end

    it("does not publish a snapshot when categories fail", function()
        local result = snapshotWithPages({ libraryPage(1, 0, 0, false) },
            { ok = false, error = "Unavailable", categories = { { id = "partial" } } })
        assert.is_false(result.ok)
        assert.is_nil(result.categories)
        assert.is_nil(result.manga)
    end)

    it("bounds the full snapshot envelope including categories", function()
        require("suwayomi/subprocess/job").max_result_bytes = 256
        local result = snapshotWithPages({ libraryPage(1, 1, 1, false) },
            { ok = true, categories = { { id = "1", name = string.rep("x", 256) } } })
        assert.is_false(result.ok)
        assert.is_nil(result.categories)
        assert.is_nil(result.manga)
    end)

    it("fails clearly before library worker results exceed the subprocess cap", function()
        package.loaded["suwayomi/network/request_worker"] = nil
        package.loaded["suwayomi/subprocess/job"] = nil
        package.loaded["suwayomi/api"] = nil
        package.preload["suwayomi/subprocess/job"] = function()
            return {
                max_result_bytes = 512,
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
                fetchCategories = function() return { ok = true, categories = {} } end,
                fetchLibraryManga = function(_, options)
                    table.insert(library_offsets, options.offset)
                    local manga = {}
                    for index = 1, 100 do
                        manga[#manga + 1] = {
                            id = tostring(options.offset + index),
                            title = string.rep("x", 32),
                        }
                    end
                    return { ok = true, manga = manga, total_count = 300, has_next_page = true }
                end,
            }
        end

        local Worker = require("suwayomi/network/request_worker")

        Worker:run({ server_url = "https://suwayomi.example" }, {
            action = "fetch_library_snapshot",
        }, "/settings/large_library.json")

        local result = written["/settings/large_library.json"]
        assert.is_false(result.ok)
        assert.are.equal("too_large", result.error_kind)
        assert.is_nil(result.manga)
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

    it("fetches reader return chapters with fresh manga metadata", function()
        package.preload["suwayomi/api"] = function()
            return {
                fetchChaptersForManga = function()
                    return {
                        ok = true,
                        chapters = { { id = "c1", name = "Chapter 1" } },
                    }
                end,
                fetchMangaById = function(_, manga_id)
                    return {
                        ok = true,
                        manga = { id = manga_id, title = "Paper Comet", in_library = true },
                    }
                end,
            }
        end
        package.loaded["suwayomi/api"] = nil
        local Worker = require("suwayomi/network/request_worker")

        Worker:run({ server_url = "https://suwayomi.example" }, {
            action = "fetch_reader_return_chapters_for_manga",
            manga_id = "m1",
        }, "/settings/reader-return.json")

        assert.are.same({
            ok = true,
            chapters = { { id = "c1", name = "Chapter 1" } },
            manga = { id = "m1", title = "Paper Comet", in_library = true },
        }, written["/settings/reader-return.json"])
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
