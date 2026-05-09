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

    it("builds the existing sanitized hidden progress filename", function()
        assert.are.equal(
            "/books/.suwayomi_dl_progress_m1_398.txt",
            progress_file.buildPath("m1:398", "/books/")
        )
    end)

    it("writes fallback progress through a temporary file before renaming", function()
        progress_file.writeFallback("/books/.suwayomi_dl_progress_m1_398.txt", "failed", 2, 5, "/books/chapter.cbz", "boom")

        assert.are.same({
            {
                from = "/books/.suwayomi_dl_progress_m1_398.txt.tmp",
                to = "/books/.suwayomi_dl_progress_m1_398.txt",
            },
        }, renames)
        assert.is_nil(files["/books/.suwayomi_dl_progress_m1_398.txt.tmp"])
        assert.are.same({
            state = "failed",
            current = 2,
            total = 5,
            path = "/books/chapter.cbz",
            error = "boom",
        }, progress_file.read("/books/.suwayomi_dl_progress_m1_398.txt"))
    end)

    it("returns nil when no progress file exists", function()
        assert.is_nil(progress_file.read("/books/missing.txt"))
    end)
end)
