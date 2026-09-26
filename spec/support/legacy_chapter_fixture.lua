local runtime = require("spec/support/plugin_runtime_spec_helper")
local Fixture = {}
function Fixture.clear()
    runtime.teardown()
    for _, name in ipairs({ "suwayomi/settings/store", "suwayomi/chapters/manual_deletion",
        "suwayomi/chapters/archive_identity", "suwayomi/manga/action_menu" }) do
        package.loaded[name], package.preload[name] = nil, nil
    end
end
function Fixture.new()
    Fixture.clear()
    runtime.install()
    package.preload["suwayomi/settings"] = nil
    package.preload["suwayomi/downloads/queue"] = nil
    local settings = require("suwayomi/settings")
    settings:setStore(require("spec/support/checked_queue_settings")():getStore())
    local scope = "https://suwayomi.example"
    assert(settings:save{ server_url = scope })
    assert(settings:saveDownloadDirectory("/downloads"))
    local existing, finished, writes, menus, messages = {}, {}, {}, {}, {}
    local downloader = require("suwayomi/downloads/downloader")
    function downloader:getTargetPath(_, _, chapter) return "/downloads", "/downloads/" .. chapter.id .. ".cbz" end
    function downloader:chapterExists(path) return existing[path] == true end
    downloader.findExistingChapterPath = nil
    local service = require("suwayomi/downloads/service"):new{ settings = settings, ui_manager = require("ui/uimanager") }
    -- Keep asynchronous workers outside this deterministic admission/render test.
    service.queue.process = function() end
    service.queue.refill.wake = function() end
    require("suwayomi/debug").elapsedMs = function() return 0 end
    require("suwayomi/ui").formatRefillStatus = function() return "Pending" end
    require("suwayomi/ui").showChapterActionsMenu = function(options, callback)
        menus[#menus + 1] = { options = options, callback = callback }
    end
    local plugin = { max_batch_queue_chapters = 50 }
    for _, name in ipairs({ "suwayomi/chapters/context", "suwayomi/chapters/menu", "suwayomi/chapters/actions",
        "suwayomi/readsync/ledger", "suwayomi/downloads/controller", "suwayomi/manga/controller" }) do
        for key, method in pairs(require(name).methods) do plugin[key] = method end
    end
    plugin.getDownloadQueue = function() return service.queue end
    plugin.getChapterDownloadKey = function(_, manga, chapter) return service.queue:getKey(manga, chapter) end
    plugin.getChapterDownloadStatus = function(_, manga, chapter) return service.queue:getStatus(manga, chapter) end
    plugin.getDownloadDirectoryOrChoose = function() return "/downloads" end
    plugin.withChapterMenuRefreshSuppressed = function(_, callback) return callback() end
    plugin.refreshChapterMenu = function() end
    plugin.showMessage = function(_, message) messages[#messages + 1] = message end
    plugin.isChapterPathFinishedInKoreader = function(_, path) return finished[path] == true end
    plugin.setKoreaderChapterReadState = function(_, path, read) writes[#writes + 1] = { path, read }; return true end
    plugin.schedulePendingReadSync = function() error("unexpected sync") end
    local manga = { id = "1", title = "Fixture", endpoint_scope = scope }
    local chapters = {}
    for id = 1, 4 do chapters[id] = { id = tostring(id), name = "Chapter " .. id, source_order = id, scanlator = id == 4 and "B" or "A", is_read = false } end
    plugin:setCurrentMangaChapterContext(manga, chapters)
    local fixture = { settings = settings, plugin = plugin, queue = service.queue, manga = manga, chapters = chapters,
        scope = scope, existing = existing, finished = finished, writes = writes, menus = menus, messages = messages }
    function fixture:legacy(path, origin)
        assert(settings:saveChapterLedger({ ["1:1"] = { manga_id = "1", chapter_id = "1", manga_title = "Fixture", chapter_name = "Chapter 1", path = path,
            endpoint_scope = origin, read = false, pending_read_sync = true, pending_read_state = false } }))
        if path then existing[path] = true end
    end
    function fixture:choose(id)
        local menu = assert(menus[#menus])
        for _, action in ipairs(menu.options.actions) do
            if action.id == id then return menu.callback(action) end
        end
        error("missing action " .. id)
    end
    function fixture:action(id)
        for _, action in ipairs(assert(menus[#menus]).options.actions) do if action.id == id then return action end end
    end
    return fixture
end
return Fixture
