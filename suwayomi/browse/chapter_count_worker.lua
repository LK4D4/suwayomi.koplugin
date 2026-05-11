-- Boundary: Browse manga chapter-count worker process.
--
-- Responsibility: fetch one manga chapter list in a subprocess-friendly module
-- and write a compact count result for the client to poll.
-- Owned state: none.
-- Dependencies: Suwayomi API facade and shared subprocess result-file helper.
-- External data: credentials, manga IDs, and API responses are normalized into
-- explicit per-manga count result records.

local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")

local ChapterCountWorker = {}

function ChapterCountWorker:writeResult(result_path, result)
    return SubprocessJob.writeResult(result_path, result)
end

function ChapterCountWorker:readResult(result_path)
    return SubprocessJob.readResult(result_path, function(parsed)
        parsed.ok = parsed.ok == true
        parsed.manga_id = parsed.manga_id ~= nil and tostring(parsed.manga_id) or nil
        parsed.chapter_count = tonumber(parsed.chapter_count) or 0
        if not parsed.ok then
            parsed.error = parsed.error or "Could not load chapters."
        end
        return parsed
    end)
end

function ChapterCountWorker:run(credentials, manga_id, result_path)
    manga_id = tostring(manga_id or "")
    local ok, api_result = pcall(function()
        return SuwayomiAPI.fetchChaptersForManga(credentials, manga_id)
    end)

    local result
    if not ok then
        result = {
            ok = false,
            manga_id = manga_id,
            chapter_count = 0,
            error = tostring(api_result),
        }
    elseif not api_result or not api_result.ok then
        result = {
            ok = false,
            manga_id = manga_id,
            chapter_count = 0,
            error = api_result and api_result.error or "Could not load chapters.",
        }
    else
        result = {
            ok = true,
            manga_id = manga_id,
            chapter_count = #(api_result.chapters or {}),
        }
    end

    self:writeResult(result_path, result)
    return result
end

return ChapterCountWorker
