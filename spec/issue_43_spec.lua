package.path = "?.lua;" .. package.path

local runtime_helper = require("spec/support/plugin_runtime_spec_helper")

describe("persisted download reconstruction", function()
    local settings, service, timers, workers, clock
    local original_time = os.time
    local extra_modules = {
        "suwayomi/settings/store", "spec/support/checked_queue_settings",
        "suwayomi/chapters/manual_deletion", "suwayomi/chapters/archive_identity",
        "suwayomi/downloads/archive", "suwayomi/paths",
    }
    local function clear()
        runtime_helper.teardown()
        for _, name in ipairs(extra_modules) do package.loaded[name], package.preload[name] = nil, nil end
    end
    local function advance(seconds)
        clock = clock + seconds
        local turns = 0
        while true do
            local next_index
            for index, timer in ipairs(timers) do
                if timer.at <= clock and (not next_index or timer.at < timers[next_index].at) then
                    next_index = index
                end
            end
            if not next_index then return end
            turns = turns + 1
            assert.is_true(turns < 1000, "scheduled callbacks must yield")
            table.remove(timers, next_index).callback()
        end
    end
    local function job(id, state)
        return {
            key = "m1:" .. id, state = state or "queued", download_directory = "/books",
            manga = { id = "m1", title = "Example" }, chapter = { id = id, name = id },
        }
    end
    local function savedJobs()
        local result = {}
        for _, saved in ipairs(settings:loadDownloadQueue()) do result[saved.key] = saved end
        return result
    end

    before_each(function()
        clear()
        runtime_helper.install()
        timers, workers, clock = {}, {}, 100
        os.time = function() return clock end
        package.preload["suwayomi/downloads/queue"] = nil
        package.preload["suwayomi/settings"] = nil
        settings = require("suwayomi/settings")
        settings.store = require("spec/support/checked_queue_settings")():getStore()
        assert(settings:saveMaxParallelChapterDownloads(4))
        local ui = require("ui/uimanager")
        ui.quit = function() end
        ui.scheduleIn = function(_, delay, callback)
            timers[#timers + 1] = { at = clock + delay, callback = callback }
        end
        ui.unschedule = function(_, callback)
            for index = #timers, 1, -1 do
                if timers[index].callback == callback then table.remove(timers, index) end
            end
        end
        ui.nextTick = function(_, callback) ui:scheduleIn(0, callback) end
        local ffi_util = require("ffi/util")
        ffi_util.runInSubProcess = function(callback)
            workers[#workers + 1] = callback
            return #workers
        end
        ffi_util.isSubProcessDone = function() return false end
        ffi_util.terminateSubProcess = function() end
        service = require("suwayomi/downloads/service"):new{
            settings = settings, ui_manager = ui, ffi_util = ffi_util,
            now = function() return clock end,
            downloader = {
                getTargetPath = function(_, directory, _, chapter)
                    return directory, directory .. "/" .. chapter.id .. ".cbz"
                end,
                chapterExists = function() return false end,
            },
        }
    end)
    after_each(function()
        os.time = original_time
        clear()
    end)

    for _, route in ipairs({ "startup", "checked-store reconciliation" }) do
        it("keeps uncertain records inert through " .. route .. " while valid jobs resume", function()
            local inert = { { key = "incomplete", state = "queued" } }
            local missing_manga = job("missing-manga", "downloading")
            missing_manga.manga = nil
            inert[#inert + 1] = missing_manga
            local missing_chapter = job("missing-chapter")
            missing_chapter.chapter = nil
            inert[#inert + 1] = missing_chapter
            local empty_identity = job("empty-identity", "downloading")
            empty_identity.manga.id = ""
            inert[#inert + 1] = empty_identity
            local invalid_identity = job("invalid-identity")
            invalid_identity.chapter.id = false
            inert[#inert + 1] = invalid_identity
            local invalid_metadata = job("invalid-metadata", "downloading")
            invalid_metadata.manga = true
            inert[#inert + 1] = invalid_metadata
            local empty_destination = job("empty-destination", "downloading")
            empty_destination.download_directory = ""
            inert[#inert + 1] = empty_destination
            local invalid_destination = job("invalid-destination")
            invalid_destination.download_directory = {}
            inert[#inert + 1] = invalid_destination
            local unknown = job("unknown", "downloading")
            unknown.version, unknown.future_field = 99, { preserve = true }
            inert[#inert + 1] = unknown
            local failed = job("failed", "failed")
            failed.retry_count, failed.progress = 6, { state = "failed", error = "Permanent failure", retryable = false }
            inert[#inert + 1] = failed
            local queued, interrupted, delayed = job("queued"), job("interrupted", "downloading"), job("delayed")
            interrupted.manga.id, interrupted.chapter.id, interrupted.key = 1, 2, "1:2"
            queued.retry_count, interrupted.retry_count = 2, 3
            delayed.retry_count, delayed.retry_at = 4, 150
            local jobs = {}
            for _, record in ipairs(inert) do jobs[#jobs + 1] = record end
            jobs[#jobs + 1], jobs[#jobs + 2], jobs[#jobs + 3] = delayed, queued, interrupted
            if route == "startup" then
                assert(settings:saveDownloadQueue(jobs))
                service:start()
            else
                service:start()
                advance(0)
                local sync_dir = settings.store.io.sync_dir
                settings.store.io.sync_dir = function() return nil, "injected sync failure" end
                assert.is_false(settings:saveDownloadQueue(jobs))
                assert.is_true(settings:isBlocked())
                settings.store.io.sync_dir = sync_dir
                service:getQueue():process()
            end
            advance(1)
            local saved = savedJobs()
            assert.are.equal(2, #workers)
            assert.are.equal("downloading", saved[queued.key].state)
            assert.are.equal("downloading", saved[interrupted.key].state)
            assert.are.equal(2, saved[queued.key].retry_count)
            assert.are.equal(3, saved[interrupted.key].retry_count)
            assert.are.same(delayed, saved[delayed.key])
            advance(48)
            assert.are.equal(2, #workers)
            advance(1)
            assert.are.equal(3, #workers)
            saved = savedJobs()
            assert.are.equal("downloading", saved[delayed.key].state)
            assert.are.equal(4, saved[delayed.key].retry_count)
            for _, record in ipairs(inert) do
                assert.are.same(record, saved[record.key])
                assert.is_nil(service:getQueue():getActiveJob(record.key))
            end
        end)
    end
end)
