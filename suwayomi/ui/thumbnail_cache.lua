-- Boundary: manga thumbnail cache paths and file writes.
--
-- Responsibility: map remote thumbnail URLs to private cache file paths and
-- write validated image bytes or decoded bitmap thumbnails for the manga row UI.
-- Owned state: cache directory on disk.
-- Dependencies: datastorage, filesystem loader, ffi/util, and Lua file IO.
-- External data: server URLs and thumbnail URLs are hashed before becoming
-- filenames so library metadata does not leak through cache paths.

local DataStorage = require("datastorage")
local FFIUtil = require("ffi/util")
local lfs = require("suwayomi/fs")

local ThumbnailCache = {}
ThumbnailCache.MAX_THUMBNAIL_BYTES = 2 * 1024 * 1024

local CACHE_DIR_NAME = "suwayomi_thumbnails"
local DECODED_EXTENSION = "bb"
local DECODED_MAGIC = "SWTHUMB1"
local RAW_IMAGE_EXTENSIONS = { "webp", "jpg", "jpeg", "png", "gif", "svg" }
local DEFAULT_VARIANT = "thumbnail"

local function normalizeVariant(options)
    if type(options) ~= "table" then
        return DEFAULT_VARIANT
    end
    local variant = tostring(options.variant or DEFAULT_VARIANT)
        :lower()
        :gsub("[^%w_-]", "_")
        :gsub("_+", "_")
        :gsub("^_+", "")
        :gsub("_+$", "")
    if variant == "" then
        variant = DEFAULT_VARIANT
    end
    if variant == DEFAULT_VARIANT then
        return DEFAULT_VARIANT
    end

    local width = math.floor(tonumber(options.width) or 0)
    local height = math.floor(tonumber(options.height) or 0)
    if width > 0 and height > 0 then
        return table.concat({ variant, tostring(width), tostring(height) }, ":")
    end
    return variant
end

local function rollingHash(text, seed, multiplier)
    local hash = seed
    multiplier = multiplier or 131
    for index = 1, #text do
        hash = (hash * multiplier + text:byte(index)) % 4294967296
    end
    return hash
end

local function hashText(text)
    local hash = 2166136261
    local alternate_hash = 16777619
    return string.format(
        "%08x%08x",
        rollingHash(text, hash, 131),
        rollingHash(text, alternate_hash, 65599)
    )
end

local function getCacheDir()
    return FFIUtil.joinPath(DataStorage:getSettingsDir(), CACHE_DIR_NAME)
end

local function normalizeContentType(content_type)
    return tostring(content_type or ""):lower():match("^%s*([^;%s]+)")
end

function ThumbnailCache.getExtension(content_type, thumbnail_url)
    content_type = normalizeContentType(content_type)
    if content_type == "image/png" then
        return "png"
    end
    if content_type == "image/webp" then
        return DECODED_EXTENSION
    end
    if content_type == "image/gif" then
        return "gif"
    end
    if content_type == "image/svg+xml" then
        return "svg"
    end
    if content_type == "image/jpeg" or content_type == "image/jpg" then
        return "jpg"
    end

    local suffix = tostring(thumbnail_url or ""):lower():match("%.([%w]+)%??[^/]*$")
    if suffix == "webp" then
        return DECODED_EXTENSION
    end
    if suffix == "jpeg" or suffix == "jpg" or suffix == "png" or suffix == "gif" or suffix == "svg" then
        return suffix == "jpeg" and "jpg" or suffix
    end
    return "jpg"
end

function ThumbnailCache.getKey(credentials, thumbnail_url, options)
    local server_url = credentials and credentials.server_url or ""
    local auth_identity = ""
    if type(credentials) == "table" then
        auth_identity = hashText(table.concat({
            tostring(credentials.auth_method or ""),
            tostring(credentials.username or ""),
        }, "\n"))
    end
    local cache_identity = tostring(server_url) .. "\n" .. auth_identity .. "\n" .. tostring(thumbnail_url or "")
    local variant = normalizeVariant(options)
    if variant ~= DEFAULT_VARIANT then
        cache_identity = cache_identity .. "\n" .. variant
    end
    return hashText(cache_identity)
end

function ThumbnailCache.getPath(credentials, thumbnail_url, content_type, options)
    return FFIUtil.joinPath(
        getCacheDir(),
        ThumbnailCache.getKey(credentials, thumbnail_url, options) .. "." .. ThumbnailCache.getExtension(content_type, thumbnail_url)
    )
end

function ThumbnailCache.isDecodedPath(path)
    return path ~= nil and tostring(path):match("%." .. DECODED_EXTENSION .. "$") ~= nil
end

function ThumbnailCache.ensureCacheDir()
    local cache_dir = getCacheDir()
    if lfs.attributes(cache_dir, "mode") == "directory" then
        return true, cache_dir
    end
    if lfs.mkdir(cache_dir) then
        return true, cache_dir
    end
    return false, cache_dir
end

function ThumbnailCache.find(credentials, thumbnail_url, options)
    if not thumbnail_url or thumbnail_url == "" then
        return nil
    end
    local key = ThumbnailCache.getKey(credentials, thumbnail_url, options)
    local cache_dir = getCacheDir()
    local decoded_path = FFIUtil.joinPath(cache_dir, key .. "." .. DECODED_EXTENSION)
    if lfs.attributes(decoded_path, "mode") == "file" then
        local size = tonumber(lfs.attributes(decoded_path, "size"))
        if size and size > ThumbnailCache.MAX_THUMBNAIL_BYTES then
            os.remove(decoded_path)
            return nil
        end
        return decoded_path
    end
    for _, extension in ipairs(RAW_IMAGE_EXTENSIONS) do
        local path = FFIUtil.joinPath(cache_dir, key .. "." .. extension)
        if lfs.attributes(path, "mode") == "file" then
            os.remove(path)
        end
    end
    return nil
end

function ThumbnailCache.write(credentials, thumbnail_url, body, content_type, options)
    if not thumbnail_url or thumbnail_url == "" or not body or body == "" then
        return nil, "Missing thumbnail data."
    end
    local ok = ThumbnailCache.ensureCacheDir()
    if not ok then
        return nil, "Could not create thumbnail cache."
    end

    local path = ThumbnailCache.getPath(credentials, thumbnail_url, content_type, options)
    local handle = io.open(path, "wb")
    if not handle then
        return nil, "Could not write thumbnail cache."
    end
    local written, write_error = handle:write(body)
    handle:close()
    if not written then
        os.remove(path)
        return nil, write_error or "Could not write thumbnail cache."
    end
    return path
end

local function getBitmapField(bitmap, field, method)
    if bitmap[field] ~= nil then
        return bitmap[field]
    end
    if bitmap[method] then
        return bitmap[method](bitmap)
    end
end

function ThumbnailCache.writeDecoded(credentials, thumbnail_url, bitmap, options)
    if not thumbnail_url or thumbnail_url == "" or not bitmap then
        return nil, "Missing thumbnail data."
    end
    local ok = ThumbnailCache.ensureCacheDir()
    if not ok then
        return nil, "Could not create thumbnail cache."
    end

    local Blitbuffer = require("ffi/blitbuffer")
    local width = tonumber(getBitmapField(bitmap, "w", "getWidth"))
    local height = tonumber(getBitmapField(bitmap, "h", "getHeight"))
    local stride = tonumber(bitmap.stride)
    local bitmap_type = tonumber(bitmap:getType())
    if not width or not height or not stride or not bitmap_type then
        return nil, "Could not encode thumbnail bitmap."
    end

    local rotation = tonumber(bitmap:getRotation()) or 0
    local inverse = tonumber(bitmap:getInverse()) or 0
    local data = Blitbuffer.tostring(bitmap)
    local path = ThumbnailCache.getPath(credentials, thumbnail_url, "image/webp", options)
    local handle = io.open(path, "wb")
    if not handle then
        return nil, "Could not write thumbnail cache."
    end
    local header = table.concat({
        DECODED_MAGIC,
        tostring(width),
        tostring(height),
        tostring(bitmap_type),
        tostring(stride),
        tostring(rotation),
        tostring(inverse),
        "",
    }, "\n")
    local written, write_error = handle:write(header .. data)
    handle:close()
    if not written then
        os.remove(path)
        return nil, write_error or "Could not write thumbnail cache."
    end
    return path
end

function ThumbnailCache.loadDecoded(path)
    if not ThumbnailCache.isDecodedPath(path) then
        return nil
    end
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end
    local body = handle:read("*a")
    handle:close()
    if not body or body == "" then
        return nil
    end

    local magic, width, height, bitmap_type, stride, rotation, inverse, data_start = body:match(
        "^([^\n]*)\n(%d+)\n(%d+)\n(%d+)\n(%d+)\n(-?%d+)\n(-?%d+)\n()"
    )
    if magic ~= DECODED_MAGIC or not data_start then
        return nil
    end

    local data = body:sub(data_start)
    if data == "" then
        return nil
    end
    local ok, Blitbuffer = pcall(require, "ffi/blitbuffer")
    if not ok or not Blitbuffer then
        return nil
    end
    local loaded_ok, bitmap = pcall(Blitbuffer.fromstring,
        tonumber(width),
        tonumber(height),
        tonumber(bitmap_type),
        data,
        tonumber(stride),
        tonumber(rotation),
        tonumber(inverse)
    )
    return loaded_ok and bitmap or nil
end

return ThumbnailCache
