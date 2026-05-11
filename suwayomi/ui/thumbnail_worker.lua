-- Boundary: manga thumbnail download worker.
--
-- Responsibility: fetch one manga thumbnail and persist it into the local
-- thumbnail cache from a subprocess-friendly entry point.
-- Owned state: none.
-- Dependencies: Suwayomi API facade, thumbnail cache, and subprocess result IO.
-- External data: thumbnail URLs and downloaded bytes are validated before the UI
-- process receives a cache path.

local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")
local ThumbnailCache = require("suwayomi/ui/thumbnail_cache")

local ThumbnailWorker = {}
ThumbnailWorker.MAX_THUMBNAIL_BYTES = 2 * 1024 * 1024
ThumbnailWorker.DECODED_THUMBNAIL_SIZE = 96

local SUPPORTED_IMAGE_TYPES = {
    ["image/gif"] = true,
    ["image/jpeg"] = true,
    ["image/jpg"] = true,
    ["image/png"] = true,
    ["image/svg+xml"] = true,
    ["image/webp"] = true,
}

local EXTENSION_IMAGE_TYPES = {
    gif = "image/gif",
    jpeg = "image/jpeg",
    jpg = "image/jpeg",
    png = "image/png",
    svg = "image/svg+xml",
    webp = "image/webp",
}

local function normalizeContentType(content_type)
    return tostring(content_type or ""):lower():match("^%s*([^;%s]+)") or ""
end

local function getUrlImageType(thumbnail_url)
    local suffix = tostring(thumbnail_url or ""):lower():match("%.([%w]+)%??[^/]*$")
    return EXTENSION_IMAGE_TYPES[suffix or ""]
end

local function getImageType(content_type, thumbnail_url)
    content_type = normalizeContentType(content_type)
    if content_type ~= "" then
        return content_type
    end
    return getUrlImageType(thumbnail_url) or ""
end

local function isImageContentType(content_type)
    return tostring(content_type or ""):match("^image/") ~= nil
end

function ThumbnailWorker:writeResult(result_path, result)
    return SubprocessJob.writeResult(result_path, result)
end

function ThumbnailWorker:readResult(result_path)
    return SubprocessJob.readResult(result_path, function(parsed)
        parsed.ok = parsed.ok == true
        parsed.thumbnail_url = parsed.thumbnail_url ~= nil and tostring(parsed.thumbnail_url) or nil
        parsed.path = parsed.path ~= nil and tostring(parsed.path) or nil
        if not parsed.ok then
            parsed.error = parsed.error or "Could not load thumbnail."
        end
        return parsed
    end)
end

local function freeBitmap(bitmap)
    if bitmap and bitmap.free then
        pcall(function()
            bitmap:free()
        end)
    end
end

function ThumbnailWorker:writeDecodedWebp(credentials, thumbnail_url, body)
    local ok, RenderImage = pcall(require, "ui/renderimage")
    if not ok or not RenderImage then
        return nil, "Could not decode WebP thumbnail."
    end

    local size = self.DECODED_THUMBNAIL_SIZE
    local rendered_ok, bitmap = pcall(function()
        return RenderImage:renderImageData(body, #body, false, size, size)
    end)
    if not rendered_ok or not bitmap then
        freeBitmap(bitmap)
        return nil, "Could not decode WebP thumbnail."
    end

    local write_ok, path, write_error = pcall(function()
        return ThumbnailCache.writeDecoded(credentials, thumbnail_url, bitmap)
    end)
    freeBitmap(bitmap)
    if not write_ok then
        return nil, tostring(path)
    end
    return path, write_error
end

function ThumbnailWorker:writeThumbnail(credentials, thumbnail_url, body, image_type)
    if image_type == "image/webp" then
        return self:writeDecodedWebp(credentials, thumbnail_url, body)
    end
    return ThumbnailCache.write(credentials, thumbnail_url, body, image_type)
end

function ThumbnailWorker:run(credentials, thumbnail_url, result_path)
    local result
    local ok, binary = pcall(function()
        return SuwayomiAPI.downloadBinary(credentials, thumbnail_url)
    end)

    if not ok then
        result = {
            ok = false,
            thumbnail_url = thumbnail_url,
            error = tostring(binary),
        }
    elseif not binary or not binary.ok then
        result = {
            ok = false,
            thumbnail_url = thumbnail_url,
            error = binary and binary.error or "Could not load thumbnail.",
        }
    else
        local image_type = getImageType(binary.content_type, thumbnail_url)
        if not binary.body or binary.body == "" or not isImageContentType(image_type) then
            result = {
                ok = false,
                thumbnail_url = thumbnail_url,
                error = "Downloaded thumbnail was not an image.",
            }
        elseif not SUPPORTED_IMAGE_TYPES[image_type] then
            result = {
                ok = false,
                thumbnail_url = thumbnail_url,
                error = "Unsupported thumbnail image type.",
            }
        elseif #binary.body > ThumbnailWorker.MAX_THUMBNAIL_BYTES then
            result = {
                ok = false,
                thumbnail_url = thumbnail_url,
                error = "Thumbnail image is too large.",
            }
        else
            local path, write_error = self:writeThumbnail(credentials, thumbnail_url, binary.body, image_type)
            result = {
                ok = path ~= nil,
                thumbnail_url = thumbnail_url,
                path = path,
                error = write_error,
            }
        end
    end

    self:writeResult(result_path, result)
    return result
end

return ThumbnailWorker
