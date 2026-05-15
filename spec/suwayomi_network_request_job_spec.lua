package.path = "?.lua;" .. package.path

describe("suwayomi/network/request_job", function()
    local started
    local canceled
    local closed

    local function clear_modules()
        for _, name in ipairs({
            "suwayomi/network/request_job",
            "suwayomi/network/request_worker",
            "suwayomi/subprocess/job",
            "ffi/util",
            "ui/uimanager",
        }) do
            package.loaded[name] = nil
            package.preload[name] = nil
        end
    end

    before_each(function()
        clear_modules()
        started = {}
        canceled = {}
        closed = {}

        package.preload["ffi/util"] = function()
            return {}
        end
        package.preload["ui/uimanager"] = function()
            return {}
        end
        package.preload["suwayomi/network/request_worker"] = function()
            return {
                run = function() end,
                readResult = function()
                    return { ok = true }
                end,
            }
        end
        package.preload["suwayomi/subprocess/job"] = function()
            return {
                buildResultPath = function(prefix)
                    return "/settings/" .. tostring(prefix) .. ".json"
                end,
                start = function(options)
                    local active = options.active or {}
                    active.on_finish = options.on_finish
                    active.on_cancel = options.on_cancel
                    table.insert(started, active)
                    return active
                end,
                cancel = function(active)
                    table.insert(canceled, active)
                    if active and active.on_cancel then
                        active.on_cancel(active)
                    end
                end,
            }
        end
    end)

    after_each(clear_modules)

    it("returns the active job and closes loading feedback when canceled", function()
        local RequestJob = require("suwayomi/network/request_job")
        local owner = {
            showLoadingMessage = function(_, message)
                return { message = message }
            end,
            closeLoadingMessage = function(_, loading_message)
                table.insert(closed, loading_message.message)
            end,
        }

        local active = RequestJob.start({
            owner = owner,
            credentials = { server_url = "https://suwayomi.example" },
            request = { action = "fetch_chapters_for_manga", manga_id = "m1" },
            loading_message = "Loading chapters...",
        })

        assert.are.equal(started[1], active)

        RequestJob.cancel(active)

        assert.are.same({ active }, canceled)
        assert.are.same({ "Loading chapters..." }, closed)
    end)
end)
