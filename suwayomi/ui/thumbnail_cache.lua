-- Boundary: manga thumbnail cache paths and file writes.
--
-- Responsibility: map remote thumbnail URLs to private cache file paths and
-- write validated image bytes for the manga row UI.
-- Owned state: cache directory on disk.
-- Dependencies: datastorage, lfs, ffi/util, and Lua file IO.
-- External data: server URLs and thumbnail URLs are hashed before becoming
-- filenames so library metadata does not leak through cache paths.

local DataStorage = require("datastorage")
local FFIUtil = require("ffi/util")
local lfs = require("lfs")

local ThumbnailCache = {}

local CACHE_DIR_NAME = "suwayomi_dl_thumbnails"
local KNOWN_EXTENSIONS = { "jpg", "jpeg", "png", "webp", "gif", "svg" }

local function hashText(text)
    local hash = 2166136261
    for index = 1, #text do
        hash = (hash * 131 + text:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
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
        return "webp"
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
    if suffix == "jpeg" or suffix == "jpg" or suffix == "png" or suffix == "webp" or suffix == "gif" or suffix == "svg" then
        return suffix == "jpeg" and "jpg" or suffix
    end
    return "jpg"
end

function ThumbnailCache.getKey(credentials, thumbnail_url)
    local server_url = credentials and credentials.server_url or ""
    return hashText(tostring(server_url) .. "\n" .. tostring(thumbnail_url or ""))
end

function ThumbnailCache.getPath(credentials, thumbnail_url, content_type)
    return FFIUtil.joinPath(
        getCacheDir(),
        ThumbnailCache.getKey(credentials, thumbnail_url) .. "." .. ThumbnailCache.getExtension(content_type, thumbnail_url)
    )
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

function ThumbnailCache.find(credentials, thumbnail_url)
    if not thumbnail_url or thumbnail_url == "" then
        return nil
    end
    local key = ThumbnailCache.getKey(credentials, thumbnail_url)
    local cache_dir = getCacheDir()
    for _, extension in ipairs(KNOWN_EXTENSIONS) do
        local path = FFIUtil.joinPath(cache_dir, key .. "." .. extension)
        if lfs.attributes(path, "mode") == "file" then
            return path
        end
    end
    return nil
end

function ThumbnailCache.write(credentials, thumbnail_url, body, content_type)
    if not thumbnail_url or thumbnail_url == "" or not body or body == "" then
        return nil, "Missing thumbnail data."
    end
    local ok = ThumbnailCache.ensureCacheDir()
    if not ok then
        return nil, "Could not create thumbnail cache."
    end

    local path = ThumbnailCache.getPath(credentials, thumbnail_url, content_type)
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

return ThumbnailCache
