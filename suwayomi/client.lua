-- Boundary: library and browse orchestration client.
--
-- Responsibility: coordinate API calls, loading messages, browse/library menus,
-- and controller callbacks that are not KOReader plugin lifecycle glue.
-- Owned state: injected API/UI/settings/debug/plugin dependencies.
-- Dependencies: supplied through new() so specs can stub runtime services.
-- External data: API results and settings values are checked before rendering.

local SuwayomiClient = {}
SuwayomiClient.__index = SuwayomiClient

function SuwayomiClient:new(options)
    options = options or {}
    return setmetatable({
        api = options.api,
        ui = options.ui,
        subprocess_job = options.subprocess_job,
        global_search_worker = options.global_search_worker,
        source_filter_worker = options.source_filter_worker,
        source_manga_worker = options.source_manga_worker,
        chapter_count_worker = options.chapter_count_worker,
        network_request_job = options.network_request_job,
        ffi_util = options.ffi_util,
        ui_manager = options.ui_manager,
        settings = options.settings,
        debug = options.debug,
        plugin = options.plugin,
        gettext = options.gettext or function(text) return text end,
    }, self)
end

function SuwayomiClient:translate(text)
    return self.gettext(text)
end

function SuwayomiClient:time(operation, context, callback)
    if self.debug and self.debug.time then
        return self.debug.time(operation, context, callback)
    end
    return callback()
end

function SuwayomiClient:log(event)
    if self.debug and self.debug.log then
        self.debug.log(event)
    end
end

function SuwayomiClient:getTitleBarMenuOptions(options)
    if self.plugin and self.plugin.getTitleBarMenuOptions then
        return self.plugin:getTitleBarMenuOptions(options)
    end
    return nil
end

function SuwayomiClient:trackScreen(route_id, widget)
    if widget and self.plugin and self.plugin.trackSuwayomiScreen then
        self.plugin:trackSuwayomiScreen(route_id, widget)
    end
    return widget
end

require("suwayomi/client/runtime").install(SuwayomiClient)
require("suwayomi/client/browse_chapter_counts").install(SuwayomiClient)
require("suwayomi/client/source_manga").install(SuwayomiClient)
require("suwayomi/client/global_search").install(SuwayomiClient)
require("suwayomi/client/library").install(SuwayomiClient)

return SuwayomiClient
