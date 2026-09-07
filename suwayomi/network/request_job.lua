-- Boundary: UI-process launcher for cancellable Suwayomi network workers.
--
-- Responsibility: start a subprocess request, show/close loading feedback, and
-- dispatch normalized completion or timeout results.
-- Owned state: caller-owned active job references only.
-- Dependencies: KOReader subprocess utilities, UIManager, and request worker.
-- External data: worker result files are normalized by the worker before use.

local FFIUtil = require("ffi/util")
local UIManager = require("ui/uimanager")
local SubprocessJob = require("suwayomi/subprocess/job")
local RequestWorker = require("suwayomi/network/request_worker")

local RequestJob = {}

local function closeLoading(owner, loading_message)
    if loading_message then loading_message.dismiss_callback = nil end
    if owner and owner.closeLoadingMessage then
        owner:closeLoadingMessage(loading_message)
    elseif loading_message and UIManager.close then
        UIManager:close(loading_message)
    end
end

local function showLoading(owner, message, cancel)
    if owner and owner.showLoadingMessage then
        return owner:showLoadingMessage(message, cancel)
    end
    return nil
end

function RequestJob.start(options)
    options = options or {}
    local owner = options.owner
    local active, loading_message, dismissed
    loading_message = showLoading(owner, options.loading_message, function()
        if dismissed then return end
        dismissed = true
        if loading_message then loading_message.dismiss_callback = nil end
        if active then RequestJob.cancel(active) end
    end)
    local function close()
        if dismissed then return end
        dismissed = true
        closeLoading(owner, loading_message)
    end
    active = SubprocessJob.start({
        active = {
            request = options.request,
            result_path = SubprocessJob.buildResultPath(options.result_prefix or "network_request"),
        },
        ffi_util = options.ffi_util or FFIUtil,
        ui_manager = options.ui_manager or UIManager,
        poll_interval_seconds = options.poll_interval_seconds or 0.5,
        timeout_seconds = options.timeout_seconds or 30,
        run = function(path)
            RequestWorker:run(options.credentials, options.request, path)
        end,
        read_result = function(path)
            return RequestWorker:readResult(path)
        end,
        on_finish = function(_, result)
            close()
            if options.on_finish then
                options.on_finish(result)
            end
        end,
        on_timeout = function()
            close()
            if options.on_finish then
                options.on_finish({
                    ok = false,
                    error = options.timeout_message or "Network request timed out.",
                })
            end
        end,
        on_error = function(err)
            close()
            if options.on_finish then
                options.on_finish({
                    ok = false,
                    error = err or "Could not start network request.",
                })
            end
        end,
        on_cancel = function()
            close()
            if options.on_cancel then
                options.on_cancel()
            end
        end,
    })
    return active
end

function RequestJob.cancel(active)
    return SubprocessJob.cancel(active)
end

return RequestJob
