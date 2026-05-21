describe("suwayomi/ui/thumbnail_cache", function()
    local written_files
    local removed_files
    local directories
    local original_io_open
    local original_os_remove

    before_each(function()
        package.loaded["suwayomi/ui/thumbnail_cache"] = nil
        package.loaded["suwayomi/fs"] = nil
        package.loaded.datastorage = nil
        package.loaded.lfs = nil
        package.loaded["ffi/util"] = nil
        package.loaded["ffi/blitbuffer"] = nil
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
                    if written_files[path] then
                        if attr == "mode" then
                            return "file"
                        end
                        if attr == "size" then
                            return written_files[path].size or #(written_files[path].body or "")
                        end
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
            if mode == nil then
                return original_io_open(path, mode)
            end
            if mode == "rb" then
                local file = written_files[path]
                if not file then
                    return nil
                end
                return {
                    read = function(_, pattern)
                        assert.are.equal("*a", pattern)
                        return file.body
                    end,
                    close = function()
                        return true
                    end,
                }
            end
            if mode == "wb" then
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
            error("unexpected io.open mode: " .. tostring(mode))
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
        package.preload["suwayomi/fs"] = nil
        package.preload.lfs = nil
        package.preload["ffi/util"] = nil
        package.preload["ffi/blitbuffer"] = nil
        package.preload.bit = nil
        package.loaded["suwayomi/ui/thumbnail_cache"] = nil
        package.loaded["suwayomi/fs"] = nil
    end)

    it("builds thumbnail cache paths without leaking server or manga data", function()
        local cache = require("suwayomi/ui/thumbnail_cache")

        local path = cache.getPath({
            server_url = "https://suwayomi.example",
        }, "/api/v1/manga/123/thumbnail", "image/png")

        assert.matches("^/settings/suwayomi_thumbnails/%x+%.png$", path)
        assert.are.equal(16, cache.getKey({
            server_url = "https://suwayomi.example",
        }, "/api/v1/manga/123/thumbnail"):len())
        assert.is_nil(path:match("suwayomi%.example"))
        assert.is_nil(path:match("manga/123"))
    end)

    it("partitions thumbnail cache keys by auth identity without leaking it", function()
        local cache = require("suwayomi/ui/thumbnail_cache")
        local alice_path = cache.getPath({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }, "/cover.png", "image/png")
        local bob_path = cache.getPath({
            server_url = "https://suwayomi.example",
            username = "bob",
            password = "secret",
            auth_method = "basic_auth",
        }, "/cover.png", "image/png")
        local alice_new_password_path = cache.getPath({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "changed",
            auth_method = "basic_auth",
        }, "/cover.png", "image/png")
        local alice_no_auth_path = cache.getPath({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "none",
        }, "/cover.png", "image/png")

        assert.are_not.equal(alice_path, bob_path)
        assert.are.equal(alice_path, alice_new_password_path)
        assert.are_not.equal(alice_path, alice_no_auth_path)
        assert.matches("^/settings/suwayomi_thumbnails/%x+%.png$", alice_path)
        assert.is_nil(alice_path:match("alice"))
        assert.is_nil(alice_path:match("secret"))
    end)

    it("writes thumbnails without leaking server or manga data", function()
        local cache = require("suwayomi/ui/thumbnail_cache")
        local credentials = { server_url = "https://suwayomi.example" }

        local path = cache.write(credentials, "/cover.png", "PNGDATA", "image/png")

        assert.matches("^/settings/suwayomi_thumbnails/%x+%.png$", path)
        assert.are.equal("PNGDATA", written_files[path].body)
        assert.is_true(directories["/settings/suwayomi_thumbnails"])
    end)

    it("removes stale raw image thumbnails instead of returning them to the UI", function()
        local cache = require("suwayomi/ui/thumbnail_cache")
        local credentials = { server_url = "https://suwayomi.example" }
        local raw_path = "/settings/suwayomi_thumbnails/" .. cache.getKey(credentials, "/cover.jpg") .. ".jpg"
        written_files[raw_path] = {
            mode = "wb",
            body = "JPGDATA",
        }

        assert.is_nil(cache.find(credentials, "/cover.jpg"))
        assert.are.same({ raw_path }, removed_files)
    end)

    it("removes oversized decoded thumbnails instead of returning them to the UI", function()
        local cache = require("suwayomi/ui/thumbnail_cache")
        local credentials = { server_url = "https://suwayomi.example" }
        local path = cache.getPath(credentials, "/cover.webp", "image/webp")
        written_files[path] = {
            mode = "wb",
            body = "BBDATA",
            size = cache.MAX_THUMBNAIL_BYTES + 1,
        }

        assert.is_nil(cache.find(credentials, "/cover.webp"))
        assert.are.same({ path }, removed_files)
    end)

    it("writes and loads decoded WebP bitmap thumbnails", function()
        local fromstring_args
        package.preload["ffi/blitbuffer"] = function()
            return {
                tostring = function(bitmap)
                    assert.are.equal("bitmap", bitmap.kind)
                    return "RAWDATA"
                end,
                fromstring = function(width, height, fmt, data, stride, rotation, inverse)
                    fromstring_args = {
                        width = width,
                        height = height,
                        fmt = fmt,
                        data = data,
                        stride = stride,
                        rotation = rotation,
                        inverse = inverse,
                    }
                    return { kind = "loaded_bitmap" }
                end,
            }
        end

        local cache = require("suwayomi/ui/thumbnail_cache")
        local credentials = { server_url = "https://suwayomi.example" }
        local path = cache.writeDecoded(credentials, "/cover.webp", {
            kind = "bitmap",
            w = 12,
            h = 34,
            stride = 48,
            getType = function() return 6 end,
            getRotation = function() return 0 end,
            getInverse = function() return 0 end,
        })
        local found = cache.find(credentials, "/cover.webp")
        local loaded = cache.loadDecoded(path)

        assert.matches("^/settings/suwayomi_thumbnails/%x+%.bb$", path)
        assert.are.equal(path, found)
        assert.are.equal("loaded_bitmap", loaded.kind)
        assert.are.same({
            width = 12,
            height = 34,
            fmt = 6,
            data = "RAWDATA",
            stride = 48,
            rotation = 0,
            inverse = 0,
        }, fromstring_args)
    end)

    it("keeps decoded poster cache paths separate from row thumbnails without leaking data", function()
        package.preload["ffi/blitbuffer"] = function()
            return {
                tostring = function()
                    return "RAWDATA"
                end,
            }
        end

        local cache = require("suwayomi/ui/thumbnail_cache")
        local credentials = {
            server_url = "https://suwayomi.example",
            username = "alice",
            auth_method = "basic_auth",
        }
        local bitmap = {
            w = 240,
            h = 360,
            stride = 960,
            getType = function() return 6 end,
            getRotation = function() return 0 end,
            getInverse = function() return 0 end,
        }

        local thumbnail_path = cache.writeDecoded(credentials, "/api/v1/manga/123/thumbnail", bitmap)
        local poster_path = cache.writeDecoded(credentials, "/api/v1/manga/123/thumbnail", bitmap, {
            variant = "poster",
            width = 240,
            height = 360,
        })

        assert.are_not.equal(thumbnail_path, poster_path)
        assert.are.equal(thumbnail_path, cache.find(credentials, "/api/v1/manga/123/thumbnail"))
        assert.are.equal(poster_path, cache.find(credentials, "/api/v1/manga/123/thumbnail", {
            variant = "poster",
            width = 240,
            height = 360,
        }))
        assert.matches("^/settings/suwayomi_thumbnails/%x+%.bb$", poster_path)
        assert.is_nil(poster_path:match("suwayomi%.example"))
        assert.is_nil(poster_path:match("manga/123"))
        assert.is_nil(poster_path:match("alice"))
    end)
end)
