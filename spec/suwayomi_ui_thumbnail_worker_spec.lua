describe("suwayomi/ui/thumbnail_worker", function()
    local api
    local cache
    local written_results

    before_each(function()
        package.loaded["suwayomi/ui/thumbnail_worker"] = nil
        package.loaded["suwayomi/api"] = nil
        package.loaded["suwayomi/subprocess/job"] = nil
        package.loaded["suwayomi/ui/thumbnail_cache"] = nil
        package.loaded["ui/renderimage"] = nil

        api = {}
        cache = {}
        written_results = {}

        package.preload["suwayomi/api"] = function()
            return api
        end
        package.preload["suwayomi/subprocess/job"] = function()
            return {
                writeResult = function(path, result)
                    written_results[path] = result
                    return true
                end,
                readResult = function(path, normalize)
                    return normalize(written_results[path])
                end,
            }
        end
        package.preload["suwayomi/ui/thumbnail_cache"] = function()
            return cache
        end
    end)

    after_each(function()
        package.preload["suwayomi/api"] = nil
        package.preload["suwayomi/subprocess/job"] = nil
        package.preload["suwayomi/ui/thumbnail_cache"] = nil
        package.preload["ui/renderimage"] = nil
    end)

    it("downloads JPEG bytes and writes a decoded cached thumbnail path", function()
        local credentials = { server_url = "https://suwayomi.example" }
        local decoded_bitmap = { decoded = true, freed = false }
        api.downloadBinary = function(seen_credentials, thumbnail_url)
            assert.are.same(credentials, seen_credentials)
            assert.are.equal("/thumb.jpg", thumbnail_url)
            return {
                ok = true,
                body = "jpeg bytes",
                content_type = "image/jpeg",
            }
        end
        cache.writeDecoded = function(seen_credentials, thumbnail_url, bitmap)
            assert.are.same(credentials, seen_credentials)
            assert.are.equal("/thumb.jpg", thumbnail_url)
            assert.are.same(decoded_bitmap, bitmap)
            return "/settings/thumb.bb"
        end
        package.preload["ui/renderimage"] = function()
            return {
                renderImageData = function(_, body, size, want_frames, width, height)
                    assert.are.equal("jpeg bytes", body)
                    assert.are.equal(10, size)
                    assert.is_false(want_frames)
                    assert.are.equal(96, width)
                    assert.are.equal(96, height)
                    function decoded_bitmap:free()
                        self.freed = true
                    end
                    return decoded_bitmap
                end,
            }
        end

        local worker = require("suwayomi/ui/thumbnail_worker")
        local result = worker:run(credentials, "/thumb.jpg", "/tmp/result.json")

        assert.is_true(result.ok)
        assert.are.equal("/settings/thumb.bb", result.path)
        assert.is_true(decoded_bitmap.freed)
        assert.are.same(result, written_results["/tmp/result.json"])
    end)

    it("rejects non-image thumbnail responses", function()
        api.downloadBinary = function()
            return {
                ok = true,
                body = "not an image",
                content_type = "text/html",
            }
        end
        cache.writeDecoded = function()
            error("cache.writeDecoded should not be called")
        end

        local worker = require("suwayomi/ui/thumbnail_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, "/thumb", "/tmp/result.json")

        assert.is_false(result.ok)
        assert.are.equal("Downloaded thumbnail was not an image.", result.error)
        assert.are.same(result, written_results["/tmp/result.json"])
    end)

    it("rejects unsupported image content types", function()
        api.downloadBinary = function()
            return {
                ok = true,
                body = "bitmap bytes",
                content_type = "image/bmp",
            }
        end
        cache.writeDecoded = function()
            error("cache.writeDecoded should not be called")
        end

        local worker = require("suwayomi/ui/thumbnail_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, "/thumb.bmp", "/tmp/result.json")

        assert.is_false(result.ok)
        assert.are.equal("Unsupported thumbnail image type.", result.error)
        assert.are.same(result, written_results["/tmp/result.json"])
    end)

    it("decodes WebP thumbnails into a cached bitmap before they reach the UI", function()
        local decoded_bitmap = { decoded = true, freed = false }
        api.downloadBinary = function()
            return {
                ok = true,
                body = "webp bytes",
                content_type = "image/webp",
            }
        end
        cache.writeDecoded = function(_, thumbnail_url, bitmap)
            assert.are.equal("/thumb.webp", thumbnail_url)
            assert.are.same(decoded_bitmap, bitmap)
            return "/settings/thumb.bb"
        end
        package.preload["ui/renderimage"] = function()
            return {
                renderImageData = function(_, body, size, want_frames, width, height)
                    assert.are.equal("webp bytes", body)
                    assert.are.equal(10, size)
                    assert.is_false(want_frames)
                    assert.are.equal(96, width)
                    assert.are.equal(96, height)
                    function decoded_bitmap:free()
                        self.freed = true
                    end
                    return decoded_bitmap
                end,
            }
        end

        local worker = require("suwayomi/ui/thumbnail_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, "/thumb.webp", "/tmp/result.json")

        assert.is_true(result.ok)
        assert.are.equal("/settings/thumb.bb", result.path)
        assert.is_true(decoded_bitmap.freed)
        assert.are.same(result, written_results["/tmp/result.json"])
    end)

    it("uses requested poster size and cache variant when decoding poster images", function()
        local decoded_bitmap = { decoded = true, freed = false }
        local write_options
        api.downloadBinary = function()
            return {
                ok = true,
                body = "poster bytes",
                content_type = "image/jpeg",
            }
        end
        cache.writeDecoded = function(_, thumbnail_url, bitmap, options)
            assert.are.equal("/poster.jpg", thumbnail_url)
            assert.are.same(decoded_bitmap, bitmap)
            write_options = options
            return "/settings/poster.bb"
        end
        package.preload["ui/renderimage"] = function()
            return {
                renderImageData = function(_, body, size, want_frames, width, height)
                    assert.are.equal("poster bytes", body)
                    assert.are.equal(12, size)
                    assert.is_false(want_frames)
                    assert.are.equal(240, width)
                    assert.are.equal(360, height)
                    function decoded_bitmap:free()
                        self.freed = true
                    end
                    return decoded_bitmap
                end,
            }
        end

        local worker = require("suwayomi/ui/thumbnail_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, "/poster.jpg", "/tmp/result.json", {
            variant = "poster",
            width = 240,
            height = 360,
        })

        assert.is_true(result.ok)
        assert.are.equal("/settings/poster.bb", result.path)
        assert.are.same({
            variant = "poster",
            width = 240,
            height = 360,
        }, write_options)
        assert.is_true(decoded_bitmap.freed)
    end)

    it("rejects oversized thumbnail responses", function()
        api.downloadBinary = function()
            return {
                ok = true,
                body = ("x"):rep((2 * 1024 * 1024) + 1),
                content_type = "image/jpeg",
            }
        end
        cache.writeDecoded = function()
            error("cache.writeDecoded should not be called")
        end

        local worker = require("suwayomi/ui/thumbnail_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, "/thumb.jpg", "/tmp/result.json")

        assert.is_false(result.ok)
        assert.are.equal("Thumbnail image is too large.", result.error)
        assert.are.same(result, written_results["/tmp/result.json"])
    end)

    it("normalizes failed worker results when reading result files", function()
        written_results["/tmp/result.json"] = {
            ok = false,
            thumbnail_url = 123,
            path = 456,
        }

        local worker = require("suwayomi/ui/thumbnail_worker")
        local result = worker:readResult("/tmp/result.json")

        assert.is_false(result.ok)
        assert.are.equal("123", result.thumbnail_url)
        assert.are.equal("456", result.path)
        assert.are.equal("Could not load thumbnail.", result.error)
    end)
end)
