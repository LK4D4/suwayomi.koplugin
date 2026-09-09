package.path = "?.lua;" .. package.path

-- Real files and the public metadata writer; DocSettings only supplies locations.
describe("issue #39 native metadata preservation", function()
    local root, chapter, directories, subject, docsettings, lfs
    local original_open, saved_loaded, saved_preload
    local modules = {
        "docsettings", "suwayomi/fs", "suwayomi/readsync/koreader_metadata", "lfs",
        "suwayomi/settings", "suwayomi/chapters/local_downloads",
    }

    local function writeFile(path, content)
        local handle = assert(original_open(path, "wb"))
        assert(handle:write(content))
        assert(handle:close())
    end

    local function readFile(path)
        local handle = assert(original_open(path, "rb"))
        local content = assert(handle:read("*a"))
        assert(handle:close())
        return content
    end

    local function removeTree(path)
        if lfs.attributes(path, "mode") == "directory" then
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." then removeTree(path .. "/" .. name) end
            end
            assert(lfs.rmdir(path))
        else
            assert(os.remove(path))
        end
    end

    local function primary(location)
        return directories[location] .. "/metadata.cbz.lua"
    end

    local function metadata(position)
        return {
            doc_path = chapter,
            last_page = position or 17,
            bookmarks = { { page = 9, notes = "Saved bookmark" } },
            annotations = { { page = 12, text = "Saved annotation" } },
            zoom_mode = "contentwidth",
            gamma = 1.25,
            summary = { status = "reading", note = "Keep summary note" },
            percent_finished = 0.4,
        }
    end

    local function seed(path, data)
        local content = "return " .. subject:serializeLuaValue(data) .. "\n"
        writeFile(path, content)
        return content
    end

    -- KOReader v2026.07.1 buildCandidates: MRU, native insertion-order ties,
    -- and a primary always precedes its paired backup, even a newer backup.
    local function nativeCandidate()
        local candidates = {}
        for _, location in ipairs({ "doc", "dir", "hash" }) do
            local main = primary(location)
            local main_time = lfs.attributes(main, "modification")
            local backup_time = lfs.attributes(main .. ".old", "modification")
            if main_time then
                candidates[#candidates + 1] = {
                    path = main, time = math.max(main_time, backup_time or main_time), priority = #candidates + 1,
                }
            end
            if backup_time then
                candidates[#candidates + 1] = {
                    path = main .. ".old", time = backup_time, priority = #candidates + 1,
                }
            end
        end
        table.sort(candidates, function(left, right)
            if left.time == right.time then return left.priority < right.priority end
            return left.time > right.time
        end)
        local selected = assert(candidates[1]).path
        return assert(loadfile(selected))(), selected
    end

    before_each(function()
        saved_loaded, saved_preload = {}, {}
        for _, name in ipairs(modules) do
            saved_loaded[name], saved_preload[name] = package.loaded[name], package.preload[name]
            package.loaded[name], package.preload[name] = nil, nil
        end
        lfs = require("lfs")
        original_open = io.open
        root = os.tmpname():gsub("\\", "/")
        os.remove(root)
        assert(lfs.mkdir(root))
        chapter = root .. "/Chapter.cbz"
        writeFile(chapter, "archive remains unchanged")
        directories = { doc = root .. "/Chapter.sdr", dir = root .. "/docsettings", hash = root .. "/hashdocsettings" }
        for _, directory in pairs(directories) do assert(lfs.mkdir(directory)) end
        docsettings = {
            preferred = "doc",
            isHashLocationEnabled = function() return true end,
            getSidecarFilename = function() return "metadata.cbz.lua" end,
            getSidecarDir = function(self, _, location) return directories[location or self.preferred] end,
            findSidecarFile = function(self)
                for _, location in ipairs({ self.preferred, "doc", "dir", "hash" }) do
                    if lfs.attributes(primary(location), "mode") == "file" then return primary(location) end
                end
            end,
            open = function() error("Native open may purge uncertain metadata") end,
        }
        package.loaded.docsettings = docsettings
        package.loaded["suwayomi/fs"] = lfs
        subject = require("suwayomi/readsync/koreader_metadata").methods
    end)

    after_each(function()
        io.open = original_open
        if root then removeTree(root) end
        for _, name in ipairs(modules) do
            package.loaded[name], package.preload[name] = saved_loaded[name], saved_preload[name]
        end
    end)

    for _, is_read in ipairs({ true, false }) do
        for _, location in ipairs({ "doc", "dir", "hash" }) do
            for _, backup_only in ipairs({ true, false }) do
                it("preserves " .. location .. " metadata on " .. (is_read and "read" or "unread")
                    .. (backup_only and " with backup only" or " with primary and newer backup"), function()
                    docsettings.preferred = location
                    local target = primary(location)
                    local expected = metadata()
                    local backup = seed(target .. ".old", backup_only and expected or metadata(99))
                    if not backup_only then seed(target, expected) end
                    assert(lfs.touch(target .. ".old", os.time() + 60, os.time() + 60))

                    assert.is_true(subject:setKoreaderChapterReadState(chapter, is_read))

                    expected.percent_finished = is_read and 1 or 0
                    expected.summary.status = is_read and "complete" or nil
                    local reopened, selected = nativeCandidate()
                    assert.are.equal(target, selected)
                    assert.are.same(expected, reopened)
                    assert.are.equal(backup, readFile(target .. ".old"))
                    assert.are.equal("archive remains unchanged", readFile(chapter))
                end)
            end
        end
    end

    it("uses native MRU metadata instead of the preferred-location finder", function()
        seed(primary("doc"), metadata(2))
        seed(primary("dir") .. ".old", metadata(17))
        assert(lfs.touch(primary("doc"), 100, 100))
        assert(lfs.touch(primary("dir") .. ".old", 200, 200))
        assert.is_true(subject:setKoreaderChapterReadState(chapter, true))
        local reopened, selected = nativeCandidate()
        assert.are.equal(primary("dir"), selected)
        assert.are.equal(17, reopened.last_page)
        assert.are.equal("complete", reopened.summary.status)
    end)

    for _, is_read in ipairs({ true, false }) do
        for _, failure in ipairs({ "inspection", "open", "read", "invalid", "oversized" }) do
            it("preserves uncertain metadata on " .. (is_read and "read" or "unread") .. " after " .. failure .. " failure", function()
                local target = primary("dir")
                local content = seed(target .. ".old", metadata())
                if failure == "invalid" then
                    content = "return { broken syntax"
                    writeFile(target .. ".old", content)
                elseif failure == "oversized" then
                    content = content .. string.rep(" ", 65536)
                    writeFile(target .. ".old", content)
                elseif failure == "inspection" then
                    package.loaded["suwayomi/fs"] = setmetatable({
                        attributes = function(path, attribute)
                            if path == target .. ".old" then return nil, "Permission denied", 13 end
                            return lfs.attributes(path, attribute)
                        end,
                    }, { __index = lfs })
                else
                    io.open = function(path, mode)
                        if path == target .. ".old" and (mode == "r" or mode == "rb") then
                            if failure == "open" then return nil, "Permission denied" end
                            return { read = function() return nil, "Input/output error" end, close = function() return true end }
                        end
                        return original_open(path, mode)
                    end
                end

                assert.is_false(subject:setKoreaderChapterReadState(chapter, is_read))
                assert.is_nil(lfs.attributes(target))
                assert.are.equal(content, readFile(target .. ".old"))
                assert.are.equal("archive remains unchanged", readFile(chapter))
            end)
        end
    end

    it("preserves an unreadable primary rather than replacing it from its backup", function()
        local target = primary("doc")
        local main = seed(target, metadata(8))
        local backup = seed(target .. ".old", metadata(17))
        io.open = function(path, mode)
            if path == target and mode == "r" then return nil, "Permission denied" end
            return original_open(path, mode)
        end
        assert.is_false(subject:setKoreaderChapterReadState(chapter, true))
        assert.are.equal(main, readFile(target))
        assert.are.equal(backup, readFile(target .. ".old"))
    end)

    it("discovers primary and backup cleanup targets without reading metadata", function()
        local backup = seed(primary("hash") .. ".old", metadata())
        io.open = function() error("Cleanup must not read metadata") end
        local _, paths = subject:getKoreaderMetadataPathForDocument(chapter)
        local found = false
        for _, path in ipairs(paths) do if path == primary("hash") then found = true end end
        assert.is_true(found)
        assert.is_nil(lfs.attributes(primary("hash")))
        assert.are.equal(backup, readFile(primary("hash") .. ".old"))
    end)

    it("removes primary and backup files through ordinary archive cleanup without reading them", function()
        for _, location in ipairs({ "doc", "dir", "hash" }) do
            seed(primary(location), metadata())
            seed(primary(location) .. ".old", metadata(9))
        end
        package.loaded["suwayomi/settings"] = {}
        local cleanup = require("suwayomi/chapters/local_downloads").methods
        io.open = function() error("Cleanup must not read metadata") end
        local _, paths = subject:getKoreaderMetadataPathForDocument(chapter)
        assert.is_true(cleanup:removeChapterArchiveAndSidecars(chapter, paths))
        assert.is_nil(lfs.attributes(chapter))
        for _, location in ipairs({ "doc", "dir", "hash" }) do
            assert.is_nil(lfs.attributes(primary(location)))
            assert.is_nil(lfs.attributes(primary(location) .. ".old"))
        end
    end)
end)
