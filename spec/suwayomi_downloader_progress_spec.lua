package.path = "?.lua;" .. package.path

describe("suwayomi/downloads/downloader progress writing", function()
    local original_io_open
    local original_os_remove
    local original_os_rename
    local files

    local function install_file_mock()
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
            files[path] = nil
            return true
        end
        os.rename = function(from, to)
            files[to] = files[from]
            files[from] = nil
            return true
        end
    end

    before_each(function()
        package.loaded["suwayomi/downloads/downloader"] = nil
        package.loaded["suwayomi/downloads/progress_file"] = nil
        package.loaded["suwayomi/downloads/archive"] = nil
        package.loaded["suwayomi/paths"] = nil
        package.loaded["suwayomi/api"] = nil
        package.loaded["suwayomi/fs"] = nil
        package.loaded.lfs = nil
        package.loaded["ffi/archiver"] = nil
        package.loaded["ffi/util"] = nil

        package.preload["suwayomi/api"] = function()
            return {}
        end
        package.preload.lfs = function()
            return {}
        end
        package.preload["ffi/archiver"] = function()
            return {}
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    return tostring(base or "") .. "/" .. tostring(segment or "")
                end,
            }
        end

        original_io_open = io.open
        original_os_remove = os.remove
        original_os_rename = os.rename
        files = {}
    end)

    after_each(function()
        io.open = original_io_open
        os.remove = original_os_remove
        os.rename = original_os_rename

        package.loaded["suwayomi/downloads/downloader"] = nil
        package.loaded["suwayomi/downloads/progress_file"] = nil
        package.loaded["suwayomi/downloads/archive"] = nil
        package.loaded["suwayomi/paths"] = nil
        package.loaded["suwayomi/api"] = nil
        package.loaded["suwayomi/fs"] = nil
        package.loaded.lfs = nil
        package.loaded["ffi/archiver"] = nil
        package.loaded["ffi/util"] = nil
        package.preload["suwayomi/api"] = nil
        package.preload["suwayomi/fs"] = nil
        package.preload.lfs = nil
        package.preload["ffi/archiver"] = nil
        package.preload["ffi/util"] = nil
    end)

    it("keeps downloader progress values line-safe", function()
        local downloader = require("suwayomi/downloads/downloader")
        local progress_file = require("suwayomi/downloads/progress_file")
        install_file_mock()

        downloader:writeProgress(
            "/books/.suwayomi_progress_m1_398.txt",
            "downloading",
            1,
            3,
            "/books/Chapter\nstate=failed\npath=x.cbz",
            "temporary\nstate=failed"
        )

        local progress = progress_file.read("/books/.suwayomi_progress_m1_398.txt")

        assert.are.equal("downloading", progress.state)
        assert.are.equal("/books/Chapter state=failed path=x.cbz", progress.path)
        assert.are.equal("temporary state=failed", progress.error)
    end)
end)
