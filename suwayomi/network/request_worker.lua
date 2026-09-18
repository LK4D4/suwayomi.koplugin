-- Boundary: generic Suwayomi network request worker process.
--
-- Responsibility: run selected API facade calls in a subprocess and persist a
-- compact result file for the UI process.
-- Owned state: none.
-- Dependencies: dkjson, Suwayomi API facade, and shared subprocess result IO.
-- External data: request tables and API results are normalized before writing;
-- complete Library snapshots and chapter results must fit the result-file budget.

local json = require("dkjson")
local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")

local RequestWorker = {}
local LIBRARY_TOO_LARGE_ERROR = "Suwayomi library is too large to load at once."

local function incompleteLibraryLoad(reason)
    return {
        ok = false,
        error_kind = "incomplete",
        error = reason or "Suwayomi server returned an incomplete library.",
    }
end

local function fetchLibraryMangaPages(credentials, categories)
    local page_size = 100
    local all_manga, seen = {}, {}
    local snapshot = { ok = true, categories = categories, manga = all_manga }
    local total_count
    local result_bytes
    local limit = tonumber(SubprocessJob.max_result_bytes) or 4 * 1024 * 1024

    while true do
        local result = SuwayomiAPI.fetchLibraryManga(credentials, {
            first = page_size,
            offset = #all_manga,
            require_complete = true,
        })
        if type(result) ~= "table" or result.ok ~= true then
            return incompleteLibraryLoad(type(result) == "table" and result.error or nil)
        end
        local page_manga = result.manga
        local total = result.total_count
        if type(page_manga) ~= "table" or type(total) ~= "number"
            or total < 0 or total > 9007199254740991 or total ~= math.floor(total)
            or type(result.has_next_page) ~= "boolean"
            or (total_count ~= nil and total_count ~= total) then
            return incompleteLibraryLoad()
        end
        total_count = total
        snapshot.total_count = total_count
        if not result_bytes then result_bytes = #json.encode(snapshot) end
        if #page_manga > page_size or #all_manga + #page_manga > total_count then
            return incompleteLibraryLoad()
        end
        for _, manga in ipairs(page_manga) do
            if type(manga) ~= "table" or manga.id == nil or seen[tostring(manga.id)] then
                return incompleteLibraryLoad()
            end
            seen[tostring(manga.id)] = true
            result_bytes = result_bytes + #json.encode(manga) + (#all_manga > 0 and 1 or 0)
            if result_bytes > limit then
                return { ok = false, error_kind = "too_large", error = LIBRARY_TOO_LARGE_ERROR }
            end
            all_manga[#all_manga + 1] = manga
        end
        if result_bytes > limit then
            return { ok = false, error_kind = "too_large", error = LIBRARY_TOO_LARGE_ERROR }
        end
        if #all_manga == total_count and result.has_next_page == false then
            return snapshot
        end
        if #page_manga < page_size or #all_manga == total_count or result.has_next_page == false then
            return incompleteLibraryLoad()
        end
    end
end

local function fetchLibrarySnapshot(credentials)
    local result = SuwayomiAPI.fetchCategories(credentials, { require_complete = true })
    if type(result) ~= "table" or result.ok ~= true or type(result.categories) ~= "table" then
        return incompleteLibraryLoad(type(result) == "table" and result.error or nil)
    end
    return fetchLibraryMangaPages(credentials, result.categories)
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
            return SuwayomiAPI.fetchChaptersForManga(credentials, request.manga_id, {
                max_result_bytes = SubprocessJob.max_result_bytes,
            })
        end
        if request.action == "fetch_refill_context" then
            local chapters = SuwayomiAPI.fetchChaptersForManga(credentials, request.manga_id, {
                max_result_bytes = SubprocessJob.max_result_bytes,
            })
            if not chapters.ok then return chapters end
            local manga = request.manga
            if type(manga) ~= "table" or not manga.title or manga.title == "" or type(manga.source) ~= "table"
                or not (manga.source.name or manga.source.displayName or manga.source.display_name) then
                local metadata = SuwayomiAPI.fetchMangaById(credentials, request.manga_id)
                if not metadata.ok then return metadata end
                manga = metadata.manga
            end
            chapters.manga = manga
            return chapters
        end
        if request.action == "refresh_manga" then
            return SuwayomiAPI.refreshManga(credentials, request.manga_id)
        end
        if request.action == "update_manga_library_state" then
            return SuwayomiAPI.updateMangaLibraryState(credentials, request.manga_id, request.in_library == true)
        end
        if request.action == "fetch_library_snapshot" then
            return fetchLibrarySnapshot(credentials)
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
    if type(result) == "table" and result.ok and type(result.chapters) == "table"
        and #json.encode(result) > (tonumber(SubprocessJob.max_result_bytes) or 4 * 1024 * 1024)
    then
        result = { ok = false, error_kind = "too_large", error = "Chapter list is too large to load completely." }
    end
    self:writeResult(result_path, result)
    return result
end

return RequestWorker
