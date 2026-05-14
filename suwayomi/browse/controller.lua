-- Boundary: BrowseController.
--
-- Responsibility: Composes source catalog methods, owns source fetch worker polling, and coordinates Browse entry flow.
-- Owned state: Accepts source data from Suwayomi API and worker result files, so boundary code validates table shapes before rendering.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and gettext are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local UIManager = require("ui/uimanager")
local SuwayomiSourceCatalog = require("suwayomi/browse/source_catalog")
local SuwayomiBrowseExtensions = require("suwayomi/browse/extensions")
local SuwayomiSourceFetchWorker = require("suwayomi/browse/source_fetch_worker")
local SubprocessJob = require("suwayomi/subprocess/job")
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

for name, method in pairs(SuwayomiBrowseExtensions.methods) do
    Methods[name] = method
end

function Methods:getSourceFetchResultPath()
    return SubprocessJob.buildResultPath("source_fetch")
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
    SubprocessJob.schedulePoll(self.source_fetch_active)
end


function Methods:startSourceFetchWorker(credentials, options)
    options = options or {}
    options.credentials = options.credentials or credentials
    if self.source_fetch_active then
        return false
    end

    local result_path = self:getSourceFetchResultPath()
    local active = {
        credentials = credentials,
        options = options,
        result_path = result_path,
        loading_message = not options.silent
            and self:showLoadingMessage(options.loading_message or _("Loading sources..."))
            or nil,
    }

    active = SubprocessJob.start({
        active = active,
        ffi_util = FFIUtil,
        ui_manager = UIManager,
        poll_interval_seconds = self.source_fetch_poll_interval_seconds,
        timeout_seconds = self.source_fetch_watchdog_timeout_seconds,
        run = function(path)
            SuwayomiSourceFetchWorker:run(credentials, path)
        end,
        read_result = function(path)
            return SuwayomiSourceFetchWorker:readResult(path)
        end,
        on_finish = function(finished_active, result)
            self:finishSourceFetch(finished_active, result)
        end,
        on_error = function(err)
            self.source_fetch_active = nil
            self:closeLoadingMessage(active.loading_message)
            if not options.silent then
                self:showMessage(T(_("Could not start source loading: %1"), err or _("unknown error")))
            end
        end,
    })
    self.source_fetch_active = active and not active.cleaned and active or nil
    return active ~= nil
end


function Methods:finishSourceFetch(active, result)
    self.source_fetch_active = nil
    self:closeLoadingMessage(active and active.loading_message)
    self:showFetchedSources(result, active and active.options or {})
end


function Methods:pollSourceFetch()
    SubprocessJob.poll(self.source_fetch_active)
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
        if cache and #(cache.sources or {}) > 0 and self:showCachedSources(cache, { credentials = credentials }) then
            self:scheduleSourceCacheRefresh(credentials)
            return
        end

        self:startSourceFetchWorker(credentials, { credentials = credentials })
    end)
end


BrowseController.methods = Methods

return BrowseController
