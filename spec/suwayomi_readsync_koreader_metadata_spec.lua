package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/readsync/koreader_metadata", function()
    local original_io_open
    local original_docsettings_preload
    local original_docsettings_loaded
    local original_fs_loaded
    local docsettings
    local files

    local function clearModule()
        package.loaded["suwayomi/readsync/koreader_metadata"] = nil
        package.loaded["suwayomi/settings"] = nil
        package.loaded.docsettings = nil
    end

    before_each(function()
        original_docsettings_preload = package.preload.docsettings
        original_docsettings_loaded = package.loaded.docsettings
        original_fs_loaded = package.loaded["suwayomi/fs"]
        files = {}
        package.loaded["suwayomi/fs"] = {
            attributes = function(path)
                return files[path] and "file" or nil
            end,
        }
        docsettings = {
            findSidecarFile = function() end,
            isHashLocationEnabled = function() return false end,
            getSidecarDir = function(_, path)
                assert.are.equal("/books/Frieren.cbz", path)
                return "/books/Frieren.sdr"
            end,
            getSidecarFilename = function(path)
                assert.are.equal("/books/Frieren.cbz", path)
                return "metadata.cbz.lua"
            end,
        }
        package.preload.docsettings = function()
            return docsettings
        end
        clearModule()
    end)

    after_each(function()
        if original_io_open then
            io.open = original_io_open
            original_io_open = nil
        end
        clearModule()
        package.preload.docsettings = original_docsettings_preload
        package.loaded.docsettings = original_docsettings_loaded
        package.loaded["suwayomi/fs"] = original_fs_loaded
    end)

    local function newSubject()
        helper.stubControllerDependencies()
        local module = require("suwayomi/readsync/koreader_metadata")
        local subject = {}
        for name, method in pairs(module.methods) do
            subject[name] = method
        end
        return subject
    end

    for _, metadata_path in ipairs({
        "/books/Frieren.sdr/metadata.cbz.lua",
        "/settings/docsettings/books/Frieren.sdr/metadata.cbz.lua",
        "/settings/hashdocsettings/ab/abcdef.sdr/metadata.cbz.lua",
    }) do
        it("reads finished state from KOReader's existing sidecar at " .. metadata_path, function()
            docsettings.findSidecarFile = function(_, path)
                assert.are.equal("/books/Frieren.cbz", path)
                return metadata_path
            end
            original_io_open = io.open
            io.open = function(path)
                if path == metadata_path then
                    return {
                        read = function()
                            return 'return { ["summary"] = { ["status"] = "complete" } }'
                        end,
                        close = function() end,
                    }
                end
            end

            assert.is_true(newSubject():isChapterPathFinishedInKoreader("/books/Frieren.cbz"))
        end)
    end

    it("uses KOReader's preferred directory and extension filename for absent metadata", function()
        docsettings.getSidecarDir = function(_, path, force_location)
            assert.are.equal("/books/Frieren.cbz", path)
            if force_location == "doc" then
                return "/books/Frieren.sdr"
            end
            return "/settings/docsettings/books/Frieren.sdr"
        end
        local subject = newSubject()
        local saved_path
        subject.saveKoreaderMetadataTable = function(_, path)
            saved_path = path
            return true
        end
        original_io_open = io.open
        io.open = function() end

        assert.is_true(subject:setKoreaderChapterReadState("/books/Frieren.cbz", true))
        assert.are.equal("/settings/docsettings/books/Frieren.sdr/metadata.cbz.lua", saved_path)
    end)

    it("rejects missing document paths before resolving sidecars", function()
        docsettings.findSidecarFile = function()
            error("must not resolve an invalid document path")
        end
        local subject = newSubject()
        assert.is_nil(subject:getKoreaderMetadataPathForDocument(nil))
        assert.is_nil(subject:getKoreaderMetadataPathForDocument(""))
    end)

    for _, location in ipairs({ "doc", "dir", "hash" }) do
        it("resolves backup-only sidecars in " .. location .. " storage to their primary path", function()
            docsettings.isHashLocationEnabled = function() return true end
            docsettings.getSidecarDir = function(_, _, force_location)
                return "/" .. (force_location or "preferred") .. "/Frieren.sdr"
            end
            files["/" .. location .. "/Frieren.sdr/metadata.cbz.lua.old"] = true

            assert.are.equal("/" .. location .. "/Frieren.sdr/metadata.cbz.lua",
                newSubject():getKoreaderMetadataPathForDocument("/books/Frieren.cbz"))
        end)
    end

    it("propagates KOReader resolver errors instead of guessing a sidecar location", function()
        docsettings.findSidecarFile = function()
            error("sidecar resolution failed", 0)
        end
        local subject = newSubject()
        assert.has_error(function()
            subject:getKoreaderMetadataPathForDocument("/books/Frieren.cbz")
        end, "sidecar resolution failed")
    end)

    for _, suffix in ipairs({ "", ".old" }) do
        it("propagates inspection failures for nonpreferred metadata" .. suffix, function()
            docsettings.getSidecarDir = function(_, _, force_location)
                return "/" .. (force_location or "preferred") .. "/Frieren.sdr"
            end
            package.loaded["suwayomi/fs"].attributes = function(path)
                if path == "/dir/Frieren.sdr/metadata.cbz.lua" .. suffix then
                    return nil, "Permission denied", 13
                end
                return nil, "No such file or directory", 2
            end
            local subject = newSubject()

            assert.has_error(function()
                subject:getKoreaderMetadataPathForDocument("/books/Frieren.cbz")
            end, "cannot inspect KOReader metadata")
        end)
    end

    for _, error_code in ipairs({ 2, 20 }) do
        it("keeps the preferred fallback for missing sidecars with stat code " .. error_code, function()
            package.loaded["suwayomi/fs"].attributes = function()
                return nil, "Missing path component", error_code
            end

            assert.are.equal("/books/Frieren.sdr/metadata.cbz.lua",
                newSubject():getKoreaderMetadataPathForDocument("/books/Frieren.cbz"))
        end)
    end

    for _, preferred_dir in ipairs({ "/doc/Frieren.sdr", "/dir/Frieren.sdr" }) do
        it("refuses unresolved hash storage with preferred directory " .. preferred_dir, function()
            docsettings.isHashLocationEnabled = function() return true end
            docsettings.getSidecarDir = function(_, _, force_location)
                if force_location == nil then
                    return preferred_dir
                end
                if force_location == "hash" then
                    -- KOReader falls back to document storage when partialMD5 fails.
                    return "/doc/Frieren.sdr"
                end
                return "/" .. force_location .. "/Frieren.sdr"
            end
            local subject = newSubject()

            assert.has_error(function()
                subject:getKoreaderMetadataPathForDocument("/books/Frieren.cbz")
            end, "cannot resolve KOReader hash metadata")
        end)
    end

    it("rejects inaccessible alternate storage even when preferred metadata exists", function()
        docsettings.findSidecarFile = function()
            return "/doc/Frieren.sdr/metadata.cbz.lua"
        end
        docsettings.getSidecarDir = function(_, _, force_location)
            return "/" .. (force_location or "doc") .. "/Frieren.sdr"
        end
        package.loaded["suwayomi/fs"].attributes = function(path)
            if path == "/doc/Frieren.sdr/metadata.cbz.lua" then
                return "file"
            end
            if path == "/dir/Frieren.sdr/metadata.cbz.lua" then
                return nil, "Permission denied", 13
            end
        end
        local subject = newSubject()

        assert.has_error(function()
            subject:getKoreaderMetadataPathForDocument("/books/Frieren.cbz")
        end, "cannot inspect KOReader metadata")
    end)

    it("returns all distinct cleanup paths while preserving the selected legacy path", function()
        docsettings.findSidecarFile = function()
            return "/history/Frieren.lua"
        end
        docsettings.isHashLocationEnabled = function() return true end
        docsettings.getSidecarDir = function(_, _, force_location)
            return "/" .. (force_location or "doc") .. "/Frieren.sdr"
        end
        local selected, cleanup_paths = newSubject():getKoreaderMetadataPathForDocument("/books/Frieren.cbz")

        assert.are.equal("/history/Frieren.lua", selected)
        assert.are.same({
            "/doc/Frieren.sdr/metadata.cbz.lua",
            "/dir/Frieren.sdr/metadata.cbz.lua",
            "/hash/Frieren.sdr/metadata.cbz.lua",
            "/history/Frieren.lua",
        }, cleanup_paths)
    end)

    it("resolves backup-only legacy history metadata after its primary was removed", function()
        docsettings.getHistoryPath = function(_, path)
            assert.are.equal("/books/Frieren.cbz", path)
            return "/history/Frieren.lua"
        end
        files["/history/Frieren.lua.old"] = true
        local selected, cleanup_paths = newSubject():getKoreaderMetadataPathForDocument("/books/Frieren.cbz")

        assert.are.equal("/history/Frieren.lua", selected)
        assert.are.same({
            "/books/Frieren.sdr/metadata.cbz.lua",
            "/history/Frieren.lua",
        }, cleanup_paths)
    end)

    it("propagates inaccessible legacy backups when the primary no longer exists", function()
        docsettings.getHistoryPath = function()
            return "/history/Frieren.lua"
        end
        package.loaded["suwayomi/fs"].attributes = function(path)
            if path == "/history/Frieren.lua.old" then
                return nil, "Permission denied", 13
            end
        end
        local subject = newSubject()

        assert.has_error(function()
            subject:getKoreaderMetadataPathForDocument("/books/Frieren.cbz")
        end, "cannot inspect KOReader metadata")
    end)

    it("refuses read-state writes without throwing when metadata resolution fails", function()
        docsettings.findSidecarFile = function()
            error("sidecar resolution failed", 0)
        end
        local writes = 0
        original_io_open = io.open
        io.open = function(_, mode)
            if mode == "w" then
                writes = writes + 1
            end
        end
        local subject = newSubject()
        local ok, result = pcall(subject.setKoreaderChapterReadState, subject, "/books/Frieren.cbz", true)

        assert.is_true(ok)
        assert.is_false(result)
        assert.are.equal(0, writes)
    end)

    it("returns unfinished without throwing when metadata resolution fails", function()
        docsettings.findSidecarFile = function()
            error("sidecar resolution failed", 0)
        end
        local subject = newSubject()
        local ok, result = pcall(subject.isChapterPathFinishedInKoreader, subject, "/books/Frieren.cbz")

        assert.is_true(ok)
        assert.is_false(result)
    end)

    it("rejects inaccessible hash storage despite KOReader caching it as disabled", function()
        docsettings.getSidecarStorage = function(location)
            assert.are.equal("hash", location)
            return "/settings/hashdocsettings"
        end
        package.loaded["suwayomi/fs"].attributes = function(path)
            if path == "/settings/hashdocsettings" then
                return nil, "Permission denied", 13
            end
        end
        local subject = newSubject()

        assert.has_error(function()
            subject:getKoreaderMetadataPathForDocument("/books/Frieren.cbz")
        end, "cannot inspect KOReader metadata")
    end)

    it("includes recovered hash storage despite KOReader caching it as disabled", function()
        docsettings.getSidecarStorage = function()
            return "/settings/hashdocsettings"
        end
        docsettings.getSidecarDir = function(_, _, force_location)
            return "/" .. (force_location or "doc") .. "/Frieren.sdr"
        end
        package.loaded["suwayomi/fs"].attributes = function(path)
            if path == "/settings/hashdocsettings" then
                return "directory"
            end
            if path == "/hash/Frieren.sdr/metadata.cbz.lua" then
                return "file"
            end
        end
        local selected, cleanup_paths = newSubject():getKoreaderMetadataPathForDocument("/books/Frieren.cbz")

        assert.are.equal("/hash/Frieren.sdr/metadata.cbz.lua", selected)
        assert.are.same({
            "/doc/Frieren.sdr/metadata.cbz.lua",
            "/dir/Frieren.sdr/metadata.cbz.lua",
            "/hash/Frieren.sdr/metadata.cbz.lua",
        }, cleanup_paths)
    end)

    it("ignores oversized metadata before running loadstring", function()
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
                    return "return { doc_path = '/bad.cbz' }" .. string.rep(" ", 131072)
                end,
                close = function() end,
            }
        end

        local metadata, metadata_path = subject:loadKoreaderMetadataTable("/books/Frieren.cbz")
        assert.are.equal("/books/Frieren.cbz", metadata.doc_path)
        assert.are.equal("/books/Frieren.sdr/metadata.cbz.lua", metadata_path)
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
