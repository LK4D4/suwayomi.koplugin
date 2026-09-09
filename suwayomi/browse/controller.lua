-- Boundary: BrowseController.
--
-- Responsibility: Composes source catalog methods and owns source request/UI identity; the shared job helper owns cancellation, polling, and cleanup.
-- Owned state: Accepts source data from Suwayomi API and worker result files, so boundary code validates table shapes before rendering.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and the plugin i18n facade are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local UIManager = require("ui/uimanager")
local SuwayomiSourceCatalog = require("suwayomi/browse/source_catalog")
local SuwayomiBrowseExtensions = require("suwayomi/browse/extensions")
local SuwayomiSourceFetchWorker = require("suwayomi/browse/source_fetch_worker")
local SubprocessJob = require("suwayomi/subprocess/job")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiDebug = require("suwayomi/debug")
local I18n = require("suwayomi/i18n")
local FFIUtil = require("ffi/util")

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

local function credentialField(credentials, field)
    return tostring(type(credentials) == "table" and credentials[field] or "")
end

local function trim(value)
    value = value == nil and "" or tostring(value)
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value
end

local function credentialsMatch(left, right)
    return credentialField(left, "server_url") == credentialField(right, "server_url")
        and credentialField(left, "auth_method") == credentialField(right, "auth_method")
        and credentialField(left, "username") == credentialField(right, "username")
        and credentialField(left, "password") == credentialField(right, "password")
end

local function closeSourceFetchLoading(owner, active)
    local loading_message = active and active.loading_message
    if not loading_message then return end
    active.loading_message = nil
    loading_message.dismiss_callback = nil
    owner:closeLoadingMessage(loading_message)
end

function Methods:getSourceFetchResultPath()
    return SubprocessJob.buildResultPath("source_fetch")
end


function Methods:scheduleSourceCacheRefresh(credentials)
    if self.suwayomi_host_retired or self.source_cache_refresh_scheduled or self.source_fetch_active then
        return
    end

    self.source_cache_refresh_scheduled = true
    UIManager:scheduleIn(self.source_cache_refresh_delay_seconds, function()
        self.source_cache_refresh_scheduled = false
        if not credentialsMatch(credentials, SuwayomiSettings:load()) then
            return
        end
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
    if self.suwayomi_host_retired or self.source_fetch_active then
        return false
    end

    local result_path = self:getSourceFetchResultPath()
    local active = {
        credentials = credentials,
        options = options,
        result_path = result_path,
    }
    if not options.silent then
        active.loading_message = self:showLoadingMessage(
            options.loading_message or I18n.t("Loading sources..."),
            function()
                if self.source_fetch_active == active then self:cancelSourceFetchWorker() end
            end)
    end

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
        on_timeout = function(timed_out_active)
            if self.source_fetch_active ~= timed_out_active then return end
            self.source_fetch_active = nil
            closeSourceFetchLoading(self, timed_out_active)
            if not self.suwayomi_host_retired and not options.silent then
                self:showMessage(I18n.t("Source loading timed out."))
            end
        end,
        on_cancel = function(canceled_active)
            if self.source_fetch_active == canceled_active then
                self.source_fetch_active = nil
            end
            closeSourceFetchLoading(self, canceled_active)
        end,
        on_cleanup = function(cleaned_active)
            if self.source_fetch_active == cleaned_active then
                self.source_fetch_active = nil
            end
        end,
        on_error = function(err)
            self.source_fetch_active = nil
            closeSourceFetchLoading(self, active)
            if not self.suwayomi_host_retired and not options.silent then
                local message = trim(err)
                if message ~= "" then
                    self:showMessage(I18n.f("Could not start source loading: %1", message))
                else
                    self:showMessage(I18n.t("Could not start source loading: unknown error"))
                end
            end
        end,
    })
    self.source_fetch_active = active and not active.cleaned and active or nil
    return active ~= nil
end

function Methods:cancelSourceFetchWorker()
    local active = self.source_fetch_active
    if not active then
        return false
    end
    SubprocessJob.cancel(active)
    return true
end


function Methods:finishSourceFetch(active, result)
    if not active or active.canceled or self.source_fetch_active ~= active then
        return false
    end
    self.source_fetch_active = nil
    closeSourceFetchLoading(self, active)
    if self.suwayomi_host_retired or not credentialsMatch(active.credentials, SuwayomiSettings:load()) then
        return false
    end
    self:showFetchedSources(result, active and active.options or {})
    return true
end


function Methods:pollSourceFetch()
    SubprocessJob.poll(self.source_fetch_active)
end


function Methods:browseSuwayomi()
    return SuwayomiDebug.time("browseSuwayomi", function()
        local credentials = SuwayomiSettings:load()
        if credentials.server_url == "" then
            self:showMessage(I18n.t("Set up your Suwayomi server login first."))
            if self.showOnboardingSetup then
                self:showOnboardingSetup({ first_run = true })
            end
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
