-- Boundary: read-sync worker process.
--
-- Responsibility: mark read batches through the API facade and write a compact
-- JSON result file for the read-sync controller.
-- Owned state: none.
-- Dependencies: dkjson, Suwayomi API facade, and Lua file IO.
-- External data: credentials, chapter IDs, result paths, and API responses are
-- normalized into explicit success/failure records.

local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")

local ReadSyncWorker = {}

function ReadSyncWorker:writeResult(result_path, result)
    return SubprocessJob.writeResult(result_path, result)
end

function ReadSyncWorker:readResult(result_path)
    return SubprocessJob.readResult(result_path, function(parsed)
        parsed.successes = type(parsed.successes) == "table" and parsed.successes or {}
        parsed.failures = type(parsed.failures) == "table" and parsed.failures or {}
        parsed.attempted = tonumber(parsed.attempted) or (#parsed.successes + #parsed.failures)
        return parsed
    end)
end

function ReadSyncWorker:validateItem(credentials, item)
    if type(item) ~= "table" then
        return false, "Malformed read sync item."
    end
    if not credentials or credentials.server_url == "" then
        return false, "Missing Suwayomi server URL."
    end
    if not item or not item.chapter_id or item.chapter_id == "" then
        return false, "Missing chapter id."
    end
    return true
end

function ReadSyncWorker:resultEntry(item)
    item = type(item) == "table" and item or {}
    return {
        key = item.key,
        chapter_id = item.chapter_id,
        desired_read_state = item.desired_read_state == true,
    }
end

function ReadSyncWorker:appendGroupResult(credentials, items, desired_read_state, result)
    local chapter_ids = {}
    for _, item in ipairs(items or {}) do
        table.insert(chapter_ids, item.chapter_id)
    end

    local api_result = SuwayomiAPI.markChaptersReadState(credentials, chapter_ids, desired_read_state)
    if not api_result or not api_result.ok then
        local error_message = api_result and api_result.error or "Read sync failed."
        for _, item in ipairs(items or {}) do
            local entry = self:resultEntry(item)
            entry.error = error_message
            table.insert(result.failures, entry)
        end
        return
    end

    local confirmed = {}
    for _, chapter in ipairs(api_result.chapters or {}) do
        if chapter.is_read == desired_read_state then
            confirmed[tostring(chapter.id)] = true
        end
    end

    for _, item in ipairs(items or {}) do
        local entry = self:resultEntry(item)
        if confirmed[tostring(item.chapter_id)] then
            table.insert(result.successes, entry)
        else
            entry.error = "Suwayomi server did not confirm chapter read state."
            table.insert(result.failures, entry)
        end
    end
end

function ReadSyncWorker:run(credentials, batch, result_path)
    local result = {
        attempted = 0,
        successes = {},
        failures = {},
    }
    local groups = {}
    local group_order = {}

    for _, item in ipairs(batch or {}) do
        result.attempted = result.attempted + 1
        local ok, error_message = self:validateItem(credentials, item)
        if ok then
            local desired_read_state = item.desired_read_state == true
            if not groups[desired_read_state] then
                groups[desired_read_state] = {}
                table.insert(group_order, desired_read_state)
            end
            table.insert(groups[desired_read_state], item)
        else
            local entry = self:resultEntry(item)
            entry.error = error_message
            table.insert(result.failures, entry)
        end
    end

    for _, desired_read_state in ipairs(group_order) do
        self:appendGroupResult(credentials, groups[desired_read_state], desired_read_state, result)
    end

    self:writeResult(result_path, result)
    return result
end

return ReadSyncWorker
