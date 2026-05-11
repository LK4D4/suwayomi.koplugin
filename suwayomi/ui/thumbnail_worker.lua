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

local function isImageContentType(content_type)
    return tostring(content_type or ""):lower():match("^image/") ~= nil
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
    elseif not binary.body or binary.body == "" or not isImageContentType(binary.content_type) then
        result = {
            ok = false,
            thumbnail_url = thumbnail_url,
            error = "Downloaded thumbnail was not an image.",
        }
    else
        local path, write_error = ThumbnailCache.write(credentials, thumbnail_url, binary.body, binary.content_type)
        result = {
            ok = path ~= nil,
            thumbnail_url = thumbnail_url,
            path = path,
            error = write_error,
        }
    end

    self:writeResult(result_path, result)
    return result
end

return ThumbnailWorker
