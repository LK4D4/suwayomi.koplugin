-- Boundary: Shared subprocess job helper.
--
-- Responsibility: launch one-shot subprocess workers, poll for completion, and
-- move bounded JSON result files across the process boundary.
-- Owned state: a module-local result path counter and caller-owned active jobs.
-- Dependencies: dkjson, settings path lookup, KOReader ui_manager/ffi_util collaborators.
-- External data: result files and subprocess state are normalized before callbacks run.

local json = require("dkjson")
local SubprocessJob = {
    result_counter = 0,
    max_result_bytes = 4 * 1024 * 1024,
}

local function defaultNow()
    return os.time()
end

function SubprocessJob.buildResultPath(prefix)
    local SuwayomiSettings = require("suwayomi/settings")
    local settings_dir = SuwayomiSettings.getSettingsDir and SuwayomiSettings:getSettingsDir() or "."
    SubprocessJob.result_counter = SubprocessJob.result_counter + 1
    return tostring(settings_dir or "."):gsub("/+$", "")
        .. "/suwayomi_"
        .. tostring(prefix or "subprocess")
        .. "_"
        .. tostring(SubprocessJob.result_counter)
        .. ".json"
end

function SubprocessJob.writeResult(result_path, result)
    if not result_path or result_path == "" then
        return false
    end

    local tmp_path = tostring(result_path) .. ".tmp"
    local handle = io.open(tmp_path, "w")
    if not handle then
        return false
    end

    local ok, err = handle:write(json.encode(result or {}))
    if ok == false or (ok == nil and err ~= nil) then
        handle:close()
        os.remove(tmp_path)
        return false
    end

    ok, err = handle:close()
    if ok == false or (ok == nil and err ~= nil) then
        os.remove(tmp_path)
        return false
    end

    if not os.rename(tmp_path, result_path) then
        os.remove(tmp_path)
        return false
    end
    return true
end

function SubprocessJob.readResult(result_path, normalize, max_result_bytes)
    local handle = result_path and io.open(result_path, "r")
    if not handle then
        return nil
    end

    local limit = tonumber(max_result_bytes) or SubprocessJob.max_result_bytes
    local content = handle:read(limit + 1)
    if content == nil then
        content = handle:read("*a") or ""
    end
    handle:close()
    if #content > limit then
        return nil
    end

    local parsed = json.decode(content)
    if type(parsed) ~= "table" then
        return nil
    end
    if normalize then
        return normalize(parsed)
    end
    return parsed
end

function SubprocessJob.cleanup(active)
    if not active or active.cleaned then
        return
    end
    active.cleaned = true
    if active.result_path then
        os.remove(active.result_path)
        os.remove(active.result_path .. ".tmp")
    end
    if active.on_cleanup then
        active.on_cleanup(active)
    end
end

function SubprocessJob.schedulePoll(active)
    if not active or active.poll_scheduled then
        return false
    end
    if active.canceled and not active.terminating then
        return false
    end
    if not active.ui_manager or not active.ui_manager.scheduleIn then
        return false
    end

    active.poll_scheduled = true
    active.ui_manager:scheduleIn(active.poll_interval_seconds or 1, function()
        SubprocessJob.poll(active)
    end)
    return true
end

function SubprocessJob.terminate(active)
    if not active or active.terminating then
        return
    end
    active.terminating = true
    if active.ffi_util and active.ffi_util.terminateSubProcess and active.pid then
        pcall(active.ffi_util.terminateSubProcess, active.pid)
    end
end

function SubprocessJob.finish(active)
    if active.terminating or active.canceled then
        SubprocessJob.cleanup(active)
        return
    end
    local result
    if active.read_result then
        result = active.read_result(active.result_path, active)
    else
        result = SubprocessJob.readResult(active.result_path)
    end
    if active.on_finish then
        active.on_finish(active, result)
    end
    SubprocessJob.cleanup(active)
end

function SubprocessJob.poll(active)
    if not active then
        return
    end
    if active.canceled and not active.terminating then
        return
    end
    active.poll_scheduled = false

    local done = active.ffi_util and active.ffi_util.isSubProcessDone and active.ffi_util.isSubProcessDone(active.pid)
    if not done then
        local now = active.now or defaultNow
        if active.timeout_seconds
            and not active.terminating
            and now() - (active.started_at or now()) > active.timeout_seconds
        then
            SubprocessJob.terminate(active)
            if active.on_timeout then
                active.on_timeout(active)
            end
        end
        SubprocessJob.schedulePoll(active)
        return
    end

    SubprocessJob.finish(active)
end

function SubprocessJob.start(options)
    options = options or {}
    local active = options.active or {}
    active.result_path = options.result_path or active.result_path or SubprocessJob.buildResultPath(options.prefix)
    active.ffi_util = options.ffi_util or active.ffi_util
    active.ui_manager = options.ui_manager or active.ui_manager
    active.poll_interval_seconds = options.poll_interval_seconds or active.poll_interval_seconds
    active.timeout_seconds = options.timeout_seconds or active.timeout_seconds
    active.now = options.now or active.now or defaultNow
    active.read_result = options.read_result or active.read_result
    active.on_finish = options.on_finish or active.on_finish
    active.on_timeout = options.on_timeout or active.on_timeout
    active.on_cancel = options.on_cancel or active.on_cancel
    active.on_cleanup = options.on_cleanup or active.on_cleanup
    active.started_at = options.started_at or active.started_at or active.now()

    os.remove(active.result_path)
    os.remove(active.result_path .. ".tmp")

    local pid, err = active.ffi_util.runInSubProcess(function()
        if options.run then
            options.run(active.result_path, active)
        end
    end)

    if not pid then
        if options.on_error then
            options.on_error(err, active)
        end
        SubprocessJob.cleanup(active)
        return nil, err
    end

    active.pid = pid
    SubprocessJob.schedulePoll(active)
    return active
end

function SubprocessJob.cancel(active)
    if not active or active.canceled then
        return
    end
    active.canceled = true
    SubprocessJob.terminate(active)
    if active.on_cancel then
        active.on_cancel(active)
    end
    if not active.pid or (not active.poll_scheduled and not SubprocessJob.schedulePoll(active)) then
        SubprocessJob.cleanup(active)
    end
end

return SubprocessJob
