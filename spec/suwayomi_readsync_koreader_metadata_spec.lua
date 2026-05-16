package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/readsync/koreader_metadata", function()
    local original_io_open

    local function clearModule()
        package.loaded["suwayomi/readsync/koreader_metadata"] = nil
        package.loaded["suwayomi/settings"] = nil
    end

    after_each(function()
        if original_io_open then
            io.open = original_io_open
            original_io_open = nil
        end
        clearModule()
    end)

    it("exports KOReader sidecar and history helpers", function()
        helper.assertControllerModule("suwayomi/readsync/koreader_metadata", {
            "getKoreaderMetadataPathForDocument",
            "loadKoreaderMetadataTable",
            "setKoreaderChapterReadState",
            "loadKoreaderHistoryPaths",
        })
    end)

    it("ignores oversized metadata and history files before running loadstring", function()
        helper.stubControllerDependencies()
        clearModule()
        local module = require("suwayomi/readsync/koreader_metadata")
        local subject = {}
        for name, method in pairs(module.methods) do
            subject[name] = method
        end
        subject.getKoreaderHistoryPath = function()
            return "/settings/history.lua"
        end

        original_io_open = io.open
        io.open = function(path)
            return {
                read = function()
                    if path == "/settings/history.lua" then
                        return "return { { file = '/bad.cbz' } }" .. string.rep(" ", 131072)
                    end
                    return "return { doc_path = '/bad.cbz' }" .. string.rep(" ", 131072)
                end,
                close = function() end,
            }
        end

        local metadata, metadata_path = subject:loadKoreaderMetadataTable("/books/Frieren.cbz")
        assert.are.equal("/books/Frieren.cbz", metadata.doc_path)
        assert.are.equal("/books/Frieren.sdr/metadata.lua", metadata_path)

        assert.are.same({}, subject:loadKoreaderHistoryPaths())
    end)

    it("ignores oversized metadata when checking finished state", function()
        helper.stubControllerDependencies()
        clearModule()
        local module = require("suwayomi/readsync/koreader_metadata")
        local subject = {}
        for name, method in pairs(module.methods) do
            subject[name] = method
        end

        original_io_open = io.open
        io.open = function()
            return {
                read = function()
                    return 'return { ["summary"] = { ["status"] = "complete" }, ["percent_finished"] = 1 }'
                        .. string.rep(" ", 131072)
                end,
                close = function() end,
            }
        end

        assert.is_false(subject:isChapterPathFinishedInKoreader("/books/Frieren.cbz"))
    end)
end)
