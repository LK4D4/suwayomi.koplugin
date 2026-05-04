local json = require("dkjson")
local SuwayomiAPI = require("suwayomi_api")

local ReadSyncWorker = {}

function ReadSyncWorker:writeResult(result_path, result)
    if not result_path or result_path == "" then
        return false
    end

    local tmp_path = tostring(result_path) .. ".tmp"
    local handle = io.open(tmp_path, "w")
    if not handle then
        return false
    end

    handle:write(json.encode(result or {}))
    handle:close()
    if not os.rename(tmp_path, result_path) then
        os.remove(tmp_path)
        return false
    end
    return true
end

function ReadSyncWorker:readResult(result_path)
    local handle = result_path and io.open(result_path, "r")
    if not handle then
        return nil
    end

    local content = handle:read("*a") or ""
    handle:close()

    local parsed = json.decode(content)
    if type(parsed) ~= "table" then
        return nil
    end
    parsed.successes = type(parsed.successes) == "table" and parsed.successes or {}
    parsed.failures = type(parsed.failures) == "table" and parsed.failures or {}
    parsed.attempted = tonumber(parsed.attempted) or (#parsed.successes + #parsed.failures)
    return parsed
end

function ReadSyncWorker:syncItem(credentials, item)
    if type(item) ~= "table" then
        return false, "Malformed read sync item."
    end
    if not credentials or credentials.server_url == "" then
        return false, "Missing Suwayomi server URL."
    end
    if not item or not item.chapter_id or item.chapter_id == "" then
        return false, "Missing chapter id."
    end

    local result
    if item.desired_read_state == true and SuwayomiAPI.markChapterRead then
        result = SuwayomiAPI.markChapterRead(credentials, item.chapter_id)
    elseif SuwayomiAPI.markChapterUnread then
        result = SuwayomiAPI.markChapterUnread(credentials, item.chapter_id)
    else
        result = { ok = false, error = "Read sync mutation is unavailable." }
    end

    if result and result.ok then
        return true
    end
    return false, result and result.error or "Read sync failed."
end

function ReadSyncWorker:run(credentials, batch, result_path)
    local result = {
        attempted = 0,
        successes = {},
        failures = {},
    }

    for _, item in ipairs(batch or {}) do
        result.attempted = result.attempted + 1
        local ok, error_message = self:syncItem(credentials, item)
        item = type(item) == "table" and item or {}
        local entry = {
            key = item.key,
            chapter_id = item.chapter_id,
            desired_read_state = item.desired_read_state == true,
        }
        if ok then
            table.insert(result.successes, entry)
        else
            entry.error = error_message
            table.insert(result.failures, entry)
        end
    end

    self:writeResult(result_path, result)
    return result
end

return ReadSyncWorker
