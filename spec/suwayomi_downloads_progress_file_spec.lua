package.path = "?.lua;" .. package.path

describe("suwayomi/downloads/progress_file", function()
    local progress_file
    local original_io_open
    local original_os_remove
    local original_os_rename
    local files
    local renames
    local removes

    local function install_file_mock()
        original_io_open = io.open
        original_os_remove = os.remove
        original_os_rename = os.rename
        files = {}
        renames = {}
        removes = {}

        io.open = function(path, mode)
            if mode == "w" then
                local chunks = {}
                return {
                    write = function(_, ...)
                        for _, value in ipairs({...}) do
                            table.insert(chunks, value)
                        end
                    end,
                    close = function()
                        files[path] = table.concat(chunks)
                        return true
                    end,
                }
            end

            local content = files[path]
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

        os.remove = function(path)
            table.insert(removes, path)
            files[path] = nil
            return true
        end

        os.rename = function(from, to)
            table.insert(renames, { from = from, to = to })
            files[to] = files[from]
            files[from] = nil
            return true
        end
    end

    before_each(function()
        package.loaded["suwayomi/downloads/progress_file"] = nil
        progress_file = require("suwayomi/downloads/progress_file")
        install_file_mock()
    end)

    after_each(function()
        io.open = original_io_open
        os.remove = original_os_remove
        os.rename = original_os_rename
        package.loaded["suwayomi/downloads/progress_file"] = nil
    end)

    it("isolates different keys and attempts without shared fallback names", function()
        local first, second = string.rep("1", 32), string.rep("2", 32)
        assert.are_not.equal(
            progress_file.buildPath("m1:398", "/books/", first),
            progress_file.buildPath("m1/398", "/books/", first)
        )
        assert.are_not.equal(
            progress_file.buildPath("m1:398", "/books/", first),
            progress_file.buildPath("m1:398", "/books/", second)
        )
        assert.has_error(function() progress_file.buildPath("m1:398", "/books/") end)
    end)

    it("writes fallback progress through a temporary file before renaming", function()
        progress_file.writeFallback("/books/.suwayomi_progress_m1_398.txt", "failed", 2, 5, "/books/chapter.cbz", "boom", true)

        assert.are.same({
            {
                from = "/books/.suwayomi_progress_m1_398.txt.tmp",
                to = "/books/.suwayomi_progress_m1_398.txt",
            },
        }, renames)
        assert.is_nil(files["/books/.suwayomi_progress_m1_398.txt.tmp"])
        assert.are.same({
            state = "failed",
            current = 2,
            total = 5,
            path = "/books/chapter.cbz",
            error = "boom",
            retryable = true,
        }, progress_file.read("/books/.suwayomi_progress_m1_398.txt"))
    end)

    it("keeps fallback progress values line-safe", function()
        progress_file.writeFallback(
            "/books/.suwayomi_progress_m1_398.txt",
            "downloading",
            2,
            5,
            "/books/Manga\nstate=failed\npath=x/chapter.cbz",
            "first line\nstate=failed\npath=x"
        )

        assert.are.same({
            state = "downloading",
            current = 2,
            total = 5,
            path = "/books/Manga state=failed path=x/chapter.cbz",
            error = "first line state=failed path=x",
        }, progress_file.read("/books/.suwayomi_progress_m1_398.txt"))
    end)

    it("keeps independent workers from replacing each other's progress", function()
        local first = progress_file.buildPath("chapter", "/books", string.rep("1", 32))
        local second = progress_file.buildPath("chapter", "/books", string.rep("2", 32))
        progress_file.writeFallback(first, "downloading", 1, 5, "/books/chapter.cbz")
        progress_file.writeFallback(second, "failed", 2, 5, "/books/chapter.cbz", "damaged", false,
            { archive_state = "damaged", identity = "1:2:3:attempt" })
        assert.are.equal("downloading", progress_file.read(first).state)
        assert.are.equal("damaged", progress_file.read(second).archive_state)
        assert.are.equal("1:2:3:attempt", progress_file.read(second).identity)
    end)

    it("returns nil when no progress file exists", function()
        assert.is_nil(progress_file.read("/books/missing.txt"))
    end)
end)
