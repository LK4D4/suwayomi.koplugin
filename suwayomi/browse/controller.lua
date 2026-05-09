-- Boundary: BrowseController.
--
-- Responsibility: Composes source catalog methods, owns source fetch worker polling, and coordinates Browse entry flow.
-- Owned state: Accepts source data from Suwayomi API and worker result files, so boundary code validates table shapes before rendering.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and gettext are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local UIManager = require("ui/uimanager")
local SuwayomiSourceCatalog = require("suwayomi/browse/source_catalog")
local SuwayomiSourceFetchWorker = require("suwayomi/browse/source_fetch_worker")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiDebug = require("suwayomi/debug")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local BrowseController = {}
BrowseController.__index = BrowseController

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function BrowseController:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

for name, method in pairs(SuwayomiSourceCatalog.methods) do
    Methods[name] = method
end

function Methods:getSourceFetchResultPath()
    local settings_dir = SuwayomiSettings.getSettingsDir and SuwayomiSettings:getSettingsDir() or "."
    self.source_fetch_result_counter = (self.source_fetch_result_counter or 0) + 1
    return tostring(settings_dir or "."):gsub("/+$", "")
        .. "/suwayomi_dl_source_fetch_"
        .. tostring(os.time())
        .. "_"
        .. tostring(self.source_fetch_result_counter)
        .. ".json"
end


function Methods:scheduleSourceCacheRefresh(credentials)
    if self.source_cache_refresh_scheduled or self.source_fetch_active then
        return
    end

    self.source_cache_refresh_scheduled = true
    UIManager:scheduleIn(self.source_cache_refresh_delay_seconds, function()
        self.source_cache_refresh_scheduled = false
        self:startSourceFetchWorker(credentials, {
            refresh = true,
            silent = true,
        })
    end)
end


function Methods:scheduleSourceFetchPoll()
    if self.source_fetch_poll_scheduled or not self.source_fetch_active then
        return
    end

    self.source_fetch_poll_scheduled = true
    UIManager:scheduleIn(self.source_fetch_poll_interval_seconds, function()
        self:pollSourceFetch()
    end)
end


function Methods:startSourceFetchWorker(credentials, options)
    options = options or {}
    options.credentials = options.credentials or credentials
    if self.source_fetch_active then
        return false
    end

    local result_path = self:getSourceFetchResultPath()
    os.remove(result_path)
    os.remove(result_path .. ".tmp")

    local active = {
        credentials = credentials,
        options = options,
        result_path = result_path,
        started_at = os.time(),
        loading_message = not options.silent
            and self:showLoadingMessage(options.loading_message or _("Loading sources..."))
            or nil,
    }
    self.source_fetch_active = active

    local pid, err = FFIUtil.runInSubProcess(function()
        SuwayomiSourceFetchWorker:run(credentials, result_path)
    end)

    if not pid then
        self.source_fetch_active = nil
        self:closeLoadingMessage(active.loading_message)
        os.remove(result_path)
        os.remove(result_path .. ".tmp")
        if not options.silent then
            self:showMessage(T(_("Could not start source loading: %1"), err or _("unknown error")))
        end
        return false
    end

    active.pid = pid
    if FFIUtil.isSubProcessDone(pid) then
        self:pollSourceFetch()
    else
        self:scheduleSourceFetchPoll()
    end
    return true
end


function Methods:finishSourceFetch(active, result)
    self.source_fetch_active = nil
    self:closeLoadingMessage(active and active.loading_message)
    if active and active.result_path then
        os.remove(active.result_path)
        os.remove(active.result_path .. ".tmp")
    end
    self:showFetchedSources(result, active and active.options or {})
end


function Methods:pollSourceFetch()
    self.source_fetch_poll_scheduled = false
    local active = self.source_fetch_active
    if not active then
        return
    end

    local done = FFIUtil.isSubProcessDone(active.pid)
    if not done then
        if not active.terminating
            and os.time() - (active.started_at or os.time()) > self.source_fetch_watchdog_timeout_seconds
        then
            if FFIUtil.terminateSubProcess then
                pcall(FFIUtil.terminateSubProcess, active.pid)
            end
            active.terminating = true
        end
        self:scheduleSourceFetchPoll()
        return
    end

    local result = SuwayomiSourceFetchWorker:readResult(active.result_path)
    self:finishSourceFetch(active, result)
end


function Methods:browseSuwayomi()
    return SuwayomiDebug.time("browseSuwayomi", function()
        local credentials = SuwayomiSettings:load()
        if credentials.server_url == "" then
            self:showMessage(_("Set up your Suwayomi server login first."))
            return
        end

        self:schedulePendingReadSync(credentials)

        local cache = self:loadSourceCache(credentials)
        if cache and #(cache.sources or {}) > 0 and self:showCachedSources(cache) then
            self:scheduleSourceCacheRefresh(credentials)
            return
        end

        self:startSourceFetchWorker(credentials, { credentials = credentials })
    end)
end


BrowseController.methods = Methods

return BrowseController
