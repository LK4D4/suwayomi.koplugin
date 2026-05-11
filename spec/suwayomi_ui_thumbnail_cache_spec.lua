describe("suwayomi/ui/thumbnail_cache", function()
    local written_files
    local removed_files
    local directories
    local original_io_open
    local original_os_remove

    before_each(function()
        package.loaded["suwayomi/ui/thumbnail_cache"] = nil
        package.loaded.datastorage = nil
        package.loaded.lfs = nil
        package.loaded["ffi/util"] = nil
        package.loaded.bit = nil

        written_files = {}
        removed_files = {}
        directories = {}

        package.preload.datastorage = function()
            return {
                getSettingsDir = function()
                    return "/settings"
                end,
            }
        end

        package.preload.lfs = function()
            return {
                attributes = function(path, attr)
                    if attr == "mode" and directories[path] then
                        return "directory"
                    end
                    if attr == "mode" and written_files[path] then
                        return "file"
                    end
                    return nil
                end,
                mkdir = function(path)
                    directories[path] = true
                    return true
                end,
            }
        end

        package.preload["ffi/util"] = function()
            return {
                joinPath = function(left, right)
                    return tostring(left):gsub("/+$", "") .. "/" .. tostring(right):gsub("^/+", "")
                end,
            }
        end

        package.preload.bit = function()
            return {
                bxor = function(left, right)
                    return (left + right) % 4294967296
                end,
                band = function(left)
                    return left % 4294967296
                end,
            }
        end

        _G.io = _G.io or io
        original_io_open = io.open
        original_os_remove = os.remove
        io.open = function(path, mode)
            local chunks = {}
            return {
                write = function(_, chunk)
                    table.insert(chunks, chunk)
                    return true
                end,
                close = function()
                    written_files[path] = {
                        mode = mode,
                        body = table.concat(chunks),
                    }
                    return true
                end,
            }
        end
        os.remove = function(path)
            table.insert(removed_files, path)
            written_files[path] = nil
            return true
        end
    end)

    after_each(function()
        io.open = original_io_open
        os.remove = original_os_remove
        package.preload.datastorage = nil
        package.preload.lfs = nil
        package.preload["ffi/util"] = nil
        package.preload.bit = nil
        package.loaded["suwayomi/ui/thumbnail_cache"] = nil
    end)

    it("builds thumbnail cache paths without leaking server or manga data", function()
        local cache = require("suwayomi/ui/thumbnail_cache")

        local path = cache.getPath({
            server_url = "https://suwayomi.example",
        }, "/api/v1/manga/123/thumbnail", "image/webp")

        assert.matches("^/settings/suwayomi_dl_thumbnails/%x+%.webp$", path)
        assert.are.equal(16, cache.getKey({
            server_url = "https://suwayomi.example",
        }, "/api/v1/manga/123/thumbnail"):len())
        assert.is_nil(path:match("suwayomi%.example"))
        assert.is_nil(path:match("manga/123"))
    end)

    it("writes thumbnails and finds existing cached files by known image extension", function()
        local cache = require("suwayomi/ui/thumbnail_cache")
        local credentials = { server_url = "https://suwayomi.example" }

        local path = cache.write(credentials, "/cover.png", "PNGDATA", "image/png")
        local found = cache.find(credentials, "/cover.png")

        assert.are.equal(path, found)
        assert.are.equal("PNGDATA", written_files[path].body)
        assert.is_true(directories["/settings/suwayomi_dl_thumbnails"])
        assert.are.same({}, removed_files)
    end)
end)
