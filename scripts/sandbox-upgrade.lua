-- Private, disposable-profile fault controls. Never part of the release payload.
local DataStorage = require("datastorage")
local PluginLoader = require("pluginloader")
local userpatch = require("userpatch")
local json = require("json")
local root = DataStorage:getDataDir()
local function mode()
    local file = io.open(root .. "/acceptance-fault", "r")
    if not file then return "none" end
    local value = file:read("*l")
    file:close()
    return value
end
local function record(event, data)
    data = data or {}
    data.event = event
    data.time = os.time()
    local file = assert(io.open(root .. "/acceptance-events.jsonl", "a"))
    file:write(json.encode(data), "\n")
    file:close()
end
userpatch.registerPatchPluginFunc("suwayomi", function(Plugin)
    local plugin = assert(PluginLoader.loaded_plugins.suwayomi)
    local Archive = require("suwayomi/downloads/archive")
    local validate = Archive.validate
    Archive.validate = function(...)
        if mode() == "delay" then
            record("verification-delay", {})
            require("socket").sleep(5)
        end
        return validate(...)
    end
    local queue = plugin:getDownloadQueue()
    if not queue.acceptance_observed then
        queue.acceptance_observed = true
        local original = queue.commitChapterArchive
        local store = queue.settings:getStore()
        local read = store.io.read
        store.io.read = function(...)
            if store.is_blocked and mode():find("uncertain", 1, true) then
                record("reconciliation-held", { blocked = true })
                return nil, "controlled unreadable destination"
            end
            return read(...)
        end
        queue.commitChapterArchive = function(active, path)
            local fault = mode()
            if not queue:isVerification(active) or (fault ~= "reject" and fault ~= "uncertain") then
                return original(active, path)
            end
            local seam = fault == "reject" and "rename" or "sync_dir"
            local before = store.io[seam]
            store.io[seam] = function() return nil, "controlled acceptance fault" end
            local called, ok, err, generation, pending = pcall(original, active, path)
            store.io[seam] = before
            record("verification-save", { mode = fault, success = ok == true,
                blocked = store.is_blocked == true, worker_done = active.worker_done == true })
            if not called then error(ok) end
            return ok, err, generation, pending
        end
        local poll = queue.pollVerification
        queue.pollVerification = function(self)
            local active = self.verification
            if active then
                record("verification-poll", { result = active.result and active.result.state,
                    worker_done = active.worker_done == true, canceled = active.canceled == true,
                    delivered = active.delivered == true, blocked = store.is_blocked == true })
            end
            local result = poll(self)
            if active and not self.verification then record("verification-released", { blocked = store.is_blocked == true }) end
            return result
        end
    end
    if not Plugin.acceptance_context_observed then
        Plugin.acceptance_context_observed = true
        local capture = Plugin.captureChapterActionGuard
        Plugin.captureChapterActionGuard = function(self)
            local guard = capture(self)
            local context, revision = self.current_chapter_context, self.chapter_request_revision
            return function(...)
                local current = guard(...)
                if not current then
                    record("stale-guard", { context_changed = self.current_chapter_context ~= context,
                        revision_changed = self.chapter_request_revision ~= revision,
                        host_retired = self.suwayomi_host_retired == true })
                end
                return current
            end
        end
        local set_context = Plugin.setCurrentMangaChapterContext
        Plugin.setCurrentMangaChapterContext = function(self, manga, chapters)
            local context = set_context(self, manga, chapters)
            local reads = {}
            for index, chapter in ipairs(context.chapters or {}) do
                reads[index] = { id = tostring(chapter.id), read = chapter.is_read == true }
            end
            record("context-publication", { reads = reads, revision = self.chapter_request_revision })
            return context
        end
    end
end)
-- Additional labeled response and checked-store controls, scoped to this profile.
userpatch.registerPatchPluginFunc("suwayomi", function(Plugin)
    if Plugin.upgrade_stages_observed then return end
    Plugin.upgrade_stages_observed = true
    -- Isolate publication acknowledgments from the independently scheduled sync worker.
    local start_sync = assert(Plugin.startPendingReadSyncWorker)
    Plugin.startPendingReadSyncWorker = function(self, ...)
        if mode():match("^cache%-") or mode():match("^merge%-") or mode():match("^visible%-") then
            record("background-read-sync-held")
            return false, 0
        end
        return start_sync(self, ...)
    end
    local Settings = require("suwayomi/settings")
    local store = Settings:getStore()
    local function wrap(receiver, method, stage)
        local original = assert(receiver[method], "Missing upgrade collaborator: " .. method)
        receiver[method] = function(...)
            if stage == "visible" then record("menu-preparation") end
            local fault = mode()
            if fault ~= stage .. "-reject" and fault ~= stage .. "-uncertain" then return original(...) end
            local seam = fault:find("uncertain", 1, true) and "sync_dir" or "rename"
            local before = store.io[seam]
            store.io[seam] = function()
                record("stage-fault", { stage = stage, outcome = fault })
                return nil, "controlled acceptance failure"
            end
            local result = { pcall(original, ...) }
            store.io[seam] = before
            if not result[1] then error(result[2]) end
            return unpack(result, 2)
        end
    end
    wrap(Settings, "saveChapterCache", "cache")
    wrap(Plugin, "mergeChaptersWithReadLedger", "merge")
    -- Current and historical payloads have different preparation names.
    wrap(Plugin, Plugin.prepareChapterMenuItems and "prepareChapterMenuItems" or "buildChapterMenuItems", "visible")
    local show = Plugin.showChapterResultForManga
    Plugin.showChapterResultForManga = function(self, manga, result, options)
        if not (options and options.saved) and
            (mode():match("^cache%-") or mode():match("^merge%-") or mode():match("^visible%-")) then
            assert(result and result.ok and #result.chapters == 3, "Unexpected stage response fixture")
            table.remove(result.chapters, 3)
            record("membership-subset-injected", { count = 2 })
        end
        if mode() == "empty" then
            result = { ok = true, chapters = {} }
            record("empty-response-injected")
        end
        return show(self, manga, result, options)
    end
    local preload = Plugin.handleChapterContextResult
    Plugin.handleChapterContextResult = function(...)
        local out = { preload(...) }
        record("action-preload")
        return unpack(out)
    end
    local Request = require("suwayomi/network/request_job")
    local start_request = Request.start
    Request.start = function(options)
        if options.result_prefix == "manga_request" then
            local observed_finish = options.on_finish
            options.on_finish = function(result)
                local out = { observed_finish(result) }
                if result and type(result.chapters) == "table" then record("chapter-response", { ok = result.ok == true }) end
                return unpack(out)
            end
        end
        if mode() == "stale-response" and options.result_prefix == "manga_request" then
            local finish = options.on_finish
            options.on_finish = function(result)
                options.owner.current_chapter_context = {}
                record("stale-response-injected")
                return finish(result)
            end
        end
        return start_request(options)
    end
end)
