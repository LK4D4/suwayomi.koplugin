-- Boundary: client runtime dependencies and timing knobs.
--
-- Responsibility: resolve lazy runtime dependencies and expose worker timeout/concurrency settings.
-- Owned state: installed methods only; runtime state remains on SuwayomiClient instances.
-- Dependencies: SuwayomiClient core helpers and injected runtime services.
-- External data: validated by the moved methods before UI rendering or worker use.

local M = {}

function M.install(SuwayomiClient)
function SuwayomiClient:isLocalSource(source)
    return source and source.lang == "localsourcelang"
end

function SuwayomiClient:getSubprocessJob()
    if not self.subprocess_job then
        self.subprocess_job = require("suwayomi/subprocess/job")
    end
    return self.subprocess_job
end

function SuwayomiClient:getGlobalSearchWorker()
    if not self.global_search_worker then
        self.global_search_worker = require("suwayomi/browse/global_search_worker")
    end
    return self.global_search_worker
end

function SuwayomiClient:getSourceFilterWorker()
    if not self.source_filter_worker then
        self.source_filter_worker = require("suwayomi/browse/source_filter_worker")
    end
    return self.source_filter_worker
end

function SuwayomiClient:getSourceMangaWorker()
    if not self.source_manga_worker then
        self.source_manga_worker = require("suwayomi/browse/source_manga_worker")
    end
    return self.source_manga_worker
end

function SuwayomiClient:getChapterCountWorker()
    if not self.chapter_count_worker then
        self.chapter_count_worker = require("suwayomi/browse/chapter_count_worker")
    end
    return self.chapter_count_worker
end

function SuwayomiClient:getNetworkRequestJob()
    if not self.network_request_job then
        self.network_request_job = require("suwayomi/network/request_job")
    end
    return self.network_request_job
end

function SuwayomiClient:getFFIUtil()
    if not self.ffi_util then
        self.ffi_util = require("ffi/util")
    end
    return self.ffi_util
end

function SuwayomiClient:getUIManager()
    if not self.ui_manager then
        self.ui_manager = require("ui/uimanager")
    end
    return self.ui_manager
end

function SuwayomiClient:getGlobalSearchMaxActiveSources()
    local configured = self.plugin and tonumber(self.plugin.global_search_max_active_sources)
    if configured and configured > 0 then
        return configured
    end
    return 3
end

function SuwayomiClient:getGlobalSearchPollIntervalSeconds()
    return (self.plugin and self.plugin.global_search_poll_interval_seconds) or 0.5
end

function SuwayomiClient:getGlobalSearchSourceTimeoutSeconds()
    return (self.plugin and self.plugin.global_search_source_timeout_seconds) or 15
end

function SuwayomiClient:getSourceMangaPollIntervalSeconds()
    return (self.plugin and self.plugin.source_manga_poll_interval_seconds)
        or self:getGlobalSearchPollIntervalSeconds()
end

function SuwayomiClient:getSourceMangaTimeoutSeconds()
    return (self.plugin and self.plugin.source_manga_timeout_seconds)
        or self:getGlobalSearchSourceTimeoutSeconds()
end

function SuwayomiClient:getChapterCountMaxActive()
    local configured = self.plugin and tonumber(self.plugin.chapter_count_max_active)
    if configured and configured > 0 then
        return configured
    end
    return 4
end

function SuwayomiClient:getChapterCountPollIntervalSeconds()
    return (self.plugin and self.plugin.chapter_count_poll_interval_seconds) or 0.5
end

function SuwayomiClient:getChapterCountTimeoutSeconds()
    return (self.plugin and self.plugin.chapter_count_timeout_seconds) or 15
end

function SuwayomiClient:getNetworkRequestTimeoutSeconds()
    return (self.plugin and self.plugin.network_request_timeout_seconds) or 30
end
end

return M
