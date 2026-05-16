package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/chapters/context", function()
    before_each(function()
        package.loaded["suwayomi/chapters/context"] = nil
        package.loaded.gettext = nil
        package.loaded["ffi/util"] = nil
        package.loaded["suwayomi/readsync/ledger"] = nil
        package.preload.gettext = function()
            return function(text) return text end
        end
        package.preload["ffi/util"] = function()
            return {
                template = function(template_string, ...)
                    local result = template_string
                    local values = {...}
                    for index, value in ipairs(values) do
                        result = result:gsub("%%" .. index, tostring(value))
                    end
                    return result
                end,
            }
        end
        package.preload["suwayomi/readsync/ledger"] = function()
            return { methods = { mergeChaptersWithReadLedger = function() end } }
        end
    end)

    after_each(function()
        package.loaded["suwayomi/chapters/context"] = nil
        package.loaded.gettext = nil
        package.loaded["ffi/util"] = nil
        package.loaded["suwayomi/readsync/ledger"] = nil
        package.preload.gettext = nil
        package.preload["ffi/util"] = nil
        package.preload["suwayomi/readsync/ledger"] = nil
    end)

    it("exports chapter context and selection methods", function()
        helper.assertControllerModule("suwayomi/chapters/context", {
            "getChapterSelectionKey",
            "getVisibleChapters",
            "mergeChaptersWithReadLedger",
            "toggleChapterSelection",
        })
    end)

    it("builds previous/through ranges from visible scanlator-filtered chapters", function()
        local controller = require("suwayomi/chapters/context")
        local plugin = {
            current_scanlator_filter = "Team A",
            current_chapter_context = {
                chapters = {
                    { id = "1", name = "One", scanlator = "Team A" },
                    { id = "2", name = "Two", scanlator = "Team B" },
                    { id = "3", name = "Three", scanlator = "Team A" },
                },
            },
        }
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        assert.are.same({
            { id = "1", name = "One", scanlator = "Team A" },
        }, plugin:getChaptersBefore({ id = "3" }))
        assert.are.same({
            { id = "1", name = "One", scanlator = "Team A" },
            { id = "3", name = "Three", scanlator = "Team A" },
        }, plugin:getChaptersThrough({ id = "3" }))
    end)

    it("does not scope manga-level next unread downloads to the current scanlator filter", function()
        local controller = require("suwayomi/chapters/context")
        local manga = { id = "m1", title = "Manga" }
        local plugin = {
            current_scanlator_filter = "Team A",
            current_chapter_context = {
                manga = manga,
                chapters = {
                    { id = "1", name = "One", scanlator = "Team A", is_read = false },
                    { id = "2", name = "Two", scanlator = "Team B", is_read = false },
                    { id = "3", name = "Three", scanlator = "Team A", is_read = true },
                },
            },
            getDownloadQueue = function()
                return {
                    getStatus = function()
                        return nil
                    end,
                }
            end,
            isChapterDownloaded = function()
                return false
            end,
        }
        for name, method in pairs(controller.methods) do
            plugin[name] = method
        end

        assert.are.same({
            { id = "1", name = "One", scanlator = "Team A", is_read = false },
            { id = "2", name = "Two", scanlator = "Team B", is_read = false },
        }, plugin:getNextUnreadChaptersForDownload(manga, 2))
    end)
end)
