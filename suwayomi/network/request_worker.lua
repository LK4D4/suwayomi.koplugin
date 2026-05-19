-- Boundary: generic Suwayomi network request worker process.
--
-- Responsibility: run selected API facade calls in a subprocess and persist a
-- compact result file for the UI process.
-- Owned state: none.
-- Dependencies: dkjson, Suwayomi API facade, and shared subprocess result IO.
-- External data: request tables and API results are normalized before writing.

local json = require("dkjson")
local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")

local RequestWorker = {}
local LIBRARY_TOO_LARGE_ERROR = "Suwayomi library is too large to load at once."

local function libraryResultExceedsLimit(manga, total_count)
    local limit = tonumber(SubprocessJob.max_result_bytes)
    if not limit or limit <= 0 then
        return false
    end
    local encoded = json.encode({
        ok = true,
        manga = manga,
        total_count = total_count,
    })
    return type(encoded) == "string" and #encoded > limit
end

local function fetchLibraryMangaPages(credentials)
    local page_size = 100
    local offset = 0
    local all_manga = {}
    local total_count

    while true do
        local result = SuwayomiAPI.fetchLibraryManga(credentials, {
            first = page_size,
            offset = offset,
        })
        if not result.ok then
            return result
        end

        local page_manga = result.manga or {}
        for _, manga in ipairs(page_manga) do
            table.insert(all_manga, manga)
        end
        total_count = tonumber(result.total_count) or #all_manga

        if libraryResultExceedsLimit(all_manga, total_count) then
            return {
                ok = false,
                error = LIBRARY_TOO_LARGE_ERROR,
            }
        end

        if #page_manga == 0 or #page_manga < page_size or #all_manga >= total_count then
            break
        end
        offset = offset + page_size
    end

    return {
        ok = true,
        manga = all_manga,
        total_count = total_count,
    }
end

local function fetchReaderReturnChapters(credentials, manga_id)
    local result = SuwayomiAPI.fetchChaptersForManga(credentials, manga_id)
    if not result.ok then
        return result
    end

    if SuwayomiAPI.fetchMangaById then
        local manga_result = SuwayomiAPI.fetchMangaById(credentials, manga_id)
        if manga_result and manga_result.ok and type(manga_result.manga) == "table" then
            result.manga = manga_result.manga
        end
    end
    return result
end

local function normalizeResult(result)
    if type(result) ~= "table" then
        return {
            ok = false,
            error = "Could not complete network request.",
        }
    end
    result.ok = result.ok == true
    if not result.ok then
        result.error = result.error or "Could not complete network request."
    end
    return result
end

function RequestWorker:writeResult(result_path, result)
    return SubprocessJob.writeResult(result_path, normalizeResult(result))
end

function RequestWorker:readResult(result_path)
    return normalizeResult(SubprocessJob.readResult(result_path, normalizeResult))
end

function RequestWorker:run(credentials, request, result_path)
    request = request or {}
    local ok, result = pcall(function()
        if request.action == "fetch_chapters_for_manga" then
            return SuwayomiAPI.fetchChaptersForManga(credentials, request.manga_id)
        end
        if request.action == "fetch_reader_return_chapters_for_manga" then
            return fetchReaderReturnChapters(credentials, request.manga_id)
        end
        if request.action == "refresh_manga" then
            return SuwayomiAPI.refreshManga(credentials, request.manga_id)
        end
        if request.action == "update_manga_library_state" then
            return SuwayomiAPI.updateMangaLibraryState(credentials, request.manga_id, request.in_library == true)
        end
        if request.action == "fetch_library_categories" then
            return SuwayomiAPI.fetchCategories(credentials)
        end
        if request.action == "fetch_library_manga_pages" then
            return fetchLibraryMangaPages(credentials)
        end
        return {
            ok = false,
            error = "Unsupported network request.",
        }
    end)

    if not ok then
        result = {
            ok = false,
            error = tostring(result),
        }
    end
    self:writeResult(result_path, result)
    return result
end

return RequestWorker
