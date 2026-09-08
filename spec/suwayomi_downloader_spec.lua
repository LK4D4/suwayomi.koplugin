package.path = "?.lua;" .. package.path

local Native = require("spec/support/native_archiver")
local lfs = require("lfs")

-- Exercise the public downloader against real files and real native ZIP IO.
-- HTTP, device/DocSettings paths and explicit filesystem/writer errors are faked.
describe("suwayomi/downloads/downloader", function()
    local downloader, archive, api, root, manga, chapter, target, restore_native
    local saved, original_rename, original_remove, original_open
    local modules = { "suwayomi/downloads/downloader", "suwayomi/downloads/archive",
        "suwayomi/downloads/progress_file", "suwayomi/paths", "suwayomi/api", "suwayomi/fs",
        "ffi/archiver", "ffi/libarchive_h", "ffi/util", "socket", "docsettings",
        "suwayomi/readsync/koreader_metadata", "suwayomi/settings" }
    local first_id, second_id = string.rep("1", 32), string.rep("2", 32)

    local function put(path, content)
        local handle = assert(io.open(path, "wb"))
        assert(handle:write(content))
        assert(handle:close())
    end

    local function bytes(path)
        local handle = assert(io.open(path, "rb"))
        local content = handle:read("*a")
        handle:close()
        return content
    end

    local function removeTree(path)
        if lfs.attributes(path, "mode") == "directory" then
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." then removeTree(path .. "/" .. name) end
            end
            assert(lfs.rmdir(path))
        else
            original_remove(path)
        end
    end

    local function makeArchive(path, entries)
        local writer = Native.Writer:new()
        assert(writer:open(path, "zip"))
        for _, entry in ipairs(entries or { { "0001.jpg", "page-one" } }) do
            assert(writer:addFileFromMemory(entry[1], entry[2]))
        end
        assert(writer:close())
    end

    local function download(options, progress)
        if progress then return downloader:downloadChapterWithProgress({}, root, manga, chapter, progress, options) end
        return downloader:downloadChapter({}, root, manga, chapter, options)
    end

    -- Native DocSettings location boundary: hash storage follows document bytes,
    -- while document and central sidecars remain path keyed across a restart.
    local function docSettings(original_document)
        local settings = {
            isHashLocationEnabled = function() return original_document ~= nil end,
            getSidecarFilename = function() return "metadata.cbz.lua" end,
            getSidecarDir = function(_, path, location)
                if location == "hash" then
                    return root .. "/hash/" .. (bytes(path) == original_document and "old" or "new") .. ".sdr"
                end
                local directory = path:gsub("%.cbz$", ".sdr")
                return location == "dir" and root .. "/central" .. directory or directory
            end,
        }
        function settings:findSidecarFile(path)
            local locations = original_document and { "hash", "doc", "dir" } or { "doc", "dir" }
            for _, location in ipairs(locations) do
                local candidate = self:getSidecarDir(path, location) .. "/" .. self.getSidecarFilename(path)
                if lfs.attributes(candidate, "mode") == "file" then return candidate, location end
            end
        end
        return settings
    end

    local function putSidecar(path, content)
        assert(downloader:ensureDirectory(path:match("^(.*)/[^/]+$")))
        put(path, content)
    end

    local reading_state = 'return { summary = { status = "complete" }, last_page = 7, annotations = { "keep me" } }\n'

    local function hashSidecar()
        local original = "damaged archive with hash metadata"
        put(target, original)
        package.loaded.docsettings = docSettings(original)
        local path = package.loaded.docsettings:getSidecarDir(target, "hash") .. "/metadata.cbz.lua"
        putSidecar(path, reading_state)
        return path, original, target:gsub("%.cbz$", ".sdr") .. "/metadata.cbz.lua"
    end

    before_each(function()
        saved = {}
        for _, name in ipairs(modules) do
            saved[name] = { package.loaded[name], package.preload[name] }
            package.loaded[name], package.preload[name] = nil, nil
        end
        restore_native = Native.install()
        original_rename, original_remove, original_open = os.rename, os.remove, io.open
        root = os.tmpname()
        os.remove(root)
        assert(lfs.mkdir(root))
        api = {
            fetchChapterPages = function() return { ok = true, pages = { "one", "two" } } end,
            downloadBinary = function(_, page) return { ok = true, body = page, content_type = "image/jpeg" } end,
        }
        package.loaded["suwayomi/api"] = api
        package.loaded["suwayomi/fs"] = lfs
        package.loaded["ffi/util"] = { joinPath = function(base, name) return base:gsub("/+$", "") .. "/" .. name end }
        package.loaded.socket = { sleep = function() end }
        package.loaded["suwayomi/settings"] = {}
        package.loaded.docsettings = docSettings()
        downloader = require("suwayomi/downloads/downloader")
        archive = require("suwayomi/downloads/archive")
        manga, chapter = { id = 1, title = "Manga", source = { displayName = "Source" } }, { id = 398, name = "Chapter" }
        local directory
        directory, target = downloader:getTargetPath(root, manga, chapter)
        assert(downloader:ensureDirectory(directory))
    end)

    after_each(function()
        os.rename, os.remove, io.open = original_rename, original_remove, original_open
        restore_native()
        removeTree(root)
        for _, name in ipairs(modules) do
            package.loaded[name], package.preload[name] = saved[name][1], saved[name][2]
        end
    end)

    it("builds a complete ordered CBZ from fetched image pages", function()
        local result = download()
        assert.is_true(result.ok)
        local inspected = archive.validate(target)
        assert.are.equal("valid", inspected.state)
        assert.are.equal(2, inspected.pages)
        assert.are.equal(2, inspected.expected_pages)
        assert.is_truthy(archive.attemptId(target))
    end)

    it("skips only after validating an existing target without contacting the server", function()
        makeArchive(target)
        api.fetchChapterPages = function() error("unexpected transfer") end
        local result = download()
        assert.is_true(result.ok)
        assert.is_true(result.skipped)
        assert.are.equal(archive.identity(target), result.identity)
    end)

    it("validates and adopts a legacy unsuffixed archive", function()
        local legacy = target:gsub(" %[id%-398%]", "")
        makeArchive(legacy)
        api.fetchChapterPages = function() error("unexpected transfer") end
        local result = download()
        assert.is_true(result.skipped)
        assert.are.equal(legacy, result.path)
    end)

    it("keeps a damaged final and reports its evidence through progress", function()
        put(target, "PK\003\004truncated")
        api.fetchChapterPages = function() error("damage must not authorize transfer") end
        local progress_path = root .. "/progress.txt"
        local result = download(nil, progress_path)
        local progress = require("suwayomi/downloads/progress_file").read(progress_path)
        assert.is_false(result.ok)
        assert.are.equal("damaged", result.archive_state)
        assert.are.equal(result.identity, progress.identity)
        assert.are.equal("damaged", progress.archive_state)
        assert.are.equal("PK\003\004truncated", bytes(target))
    end)

    it("does not confuse unavailable native validation with valid or damaged data", function()
        makeArchive(target)
        require("ffi").loadlib = function() error("native validator unavailable") end
        local result = download()
        assert.is_false(result.ok)
        assert.are.equal("unverified", result.archive_state)
    end)

    it("distinguishes missing files from filesystem inspection failure", function()
        local original = lfs.attributes
        lfs.attributes = function() return nil, "permission denied", 13 end
        local ok, result = pcall(download)
        lfs.attributes = original
        assert.is_true(ok)
        assert.is_false(result.ok)
        assert.are.equal("unverified", result.archive_state)
        assert.is_false(downloader:chapterExists(target))
    end)

    it("prefers the direct archive without fetching page metadata", function()
        api.downloadChapterArchive = function(_, _, path)
            makeArchive(path)
            return { ok = true, bytes = #bytes(path), content_type = "application/zip" }
        end
        api.fetchChapterPages = function() error("unexpected page metadata request") end
        assert.is_true(download().ok)
        assert.are.equal(1, archive.validate(target).pages)
    end)

    for _, status in ipairs({ 400, 404 }) do
        it("downloads pages when optional direct export is unavailable with HTTP " .. status, function()
            api.downloadChapterArchive = function() return { ok = false, status_code = status } end
            assert.is_true(download(nil, root .. "/progress.txt").ok)
            assert.are.equal(2, archive.validate(target).expected_pages)
        end)
    end

    it("falls back from invalid export bytes without sharing page scratch files", function()
        local exported_path
        api.downloadChapterArchive = function(_, _, path)
            exported_path = path
            put(path, "PK\003\004broken")
            return { ok = true, bytes = 10, content_type = "application/zip" }
        end
        assert.is_true(download({ attempt_id = first_id }).ok)
        assert.is_nil(lfs.attributes(exported_path))
        assert.are.equal(2, archive.validate(target).pages)
    end)

    it("does not re-adopt another final during export fallback", function()
        api.downloadChapterArchive = function()
            makeArchive(target)
            return { ok = false, status_code = 404 }
        end
        local result = download({ attempt_id = first_id })
        assert.is_true(result.ok)
        assert.is_nil(result.skipped)
        assert.are.equal(first_id, archive.attemptId(target))
        assert.are.equal(2, archive.validate(target).pages)
    end)

    it("retries transient direct errors but does not fall back when they persist", function()
        local calls = 0
        api.downloadChapterArchive = function()
            calls = calls + 1
            return { ok = false, error = "network timeout", retryable = true }
        end
        api.fetchChapterPages = function() error("unexpected fallback") end
        local result = download()
        assert.is_false(result.ok)
        assert.is_true(result.retryable)
        assert.are.equal(3, calls)
    end)

    it("recovers a transient direct export failure", function()
        local calls = 0
        api.downloadChapterArchive = function(_, _, path)
            calls = calls + 1
            if calls == 1 then return { ok = false, error = "timeout" } end
            makeArchive(path)
            return { ok = true, bytes = #bytes(path), content_type = "application/zip" }
        end
        assert.is_true(download().ok)
        assert.are.equal(2, calls)
    end)

    it("does not retry permanent direct errors or silently fetch pages", function()
        local calls = 0
        api.downloadChapterArchive = function()
            calls = calls + 1
            return { ok = false, error = "Unauthorized", retryable = false }
        end
        api.fetchChapterPages = function() error("unexpected fallback") end
        assert.is_false(download().ok)
        assert.are.equal(1, calls)
    end)

    it("retries transient page-list and binary failures", function()
        local lists, pages = 0, 0
        api.fetchChapterPages = function()
            lists = lists + 1
            if lists == 1 then return { ok = false, error = "timeout" } end
            return { ok = true, pages = { "one" } }
        end
        api.downloadBinary = function()
            pages = pages + 1
            if pages == 1 then return { ok = false, error = "timeout" } end
            return { ok = true, body = "image", content_type = "image/png" }
        end
        assert.is_true(download().ok)
        assert.are.equal(2, lists)
        assert.are.equal(2, pages)
    end)

    it("reports page progress before the archive is published", function()
        local started = downloader:startChapterDownload({}, root, manga, chapter, { attempt_id = first_id })
        local first = downloader:downloadNextPage(started.job)
        assert.is_true(first.ok)
        assert.is_false(first.done)
        assert.are.equal(1, first.current)
        assert.is_nil(lfs.attributes(target))
        local last = downloader:downloadNextPage(started.job)
        assert.is_true(last.done)
        assert.are.equal(2, last.current)
        assert.are.equal("valid", archive.validate(target).state)
    end)

    it("isolates interleaved attempts and leaves legacy temporary files alone", function()
        put(target .. ".part", "legacy worker")
        local older = downloader:startChapterDownload({}, root, manga, chapter, { attempt_id = first_id })
        local newer = downloader:startChapterDownload({}, root, manga, chapter, { attempt_id = second_id })
        assert.is_true(downloader:downloadNextPage(older.job).ok)
        assert.is_true(downloader:downloadNextPage(newer.job).ok)
        assert.is_true(downloader:downloadNextPage(newer.job).ok)
        assert.is_true(downloader:downloadNextPage(older.job).ok)
        assert.are.equal(first_id, archive.attemptId(target))
        assert.are.equal("valid", archive.validate(target).state)
        assert.are.equal("legacy worker", bytes(target .. ".part"))
    end)

    it("cleans only a failed attempt and does not retry permanent page errors", function()
        local calls = 0
        local other = downloader:getPartialPath(target, second_id)
        put(other, "other worker")
        api.downloadBinary = function()
            calls = calls + 1
            return { ok = false, error = "Unauthorized", retryable = false }
        end
        local result = download({ attempt_id = first_id })
        assert.is_false(result.ok)
        assert.are.equal(1, calls)
        assert.is_nil(lfs.attributes(downloader:getPartialPath(target, first_id)))
        assert.are.equal("other worker", bytes(other))
    end)

    for _, invalid in ipairs({ { body = "", content_type = "image/jpeg" }, { body = "HTML", content_type = "text/html" } }) do
        it("rejects invalid page content: " .. invalid.content_type .. " / " .. #invalid.body, function()
            api.downloadBinary = function() return { ok = true, body = invalid.body, content_type = invalid.content_type } end
            assert.is_false(download({ attempt_id = first_id }).ok)
            assert.is_nil(lfs.attributes(target))
            assert.is_nil(lfs.attributes(downloader:getPartialPath(target, first_id)))
        end)
    end

    it("preserves an existing final and its evidence when repair transfer fails", function()
        put(target, "damaged archive")
        api.downloadBinary = function() return { ok = false, error = "Unauthorized" } end
        assert.is_false(download({ force = true }).ok)
        assert.are.equal("damaged archive", bytes(target))
    end)

    it("publishes a validated repair over a damaged archive", function()
        put(target, "damaged archive")
        assert.is_true(download({ force = true, attempt_id = first_id }).ok)
        assert.are.equal("valid", archive.validate(target).state)
        assert.are.equal(first_id, archive.attemptId(target))
    end)

    for _, direct in ipairs({ true, false }) do
        it("repairs the legacy pathname and keeps its read state through " .. (direct and "export" or "page fallback"), function()
            local legacy = target:gsub(" %[id%-398%]", "")
            put(legacy, "damaged legacy archive")
            local sidecar = legacy:gsub("%.cbz$", ".sdr") .. "/metadata.cbz.lua"
            putSidecar(sidecar, reading_state)
            api.downloadChapterArchive = function(_, _, path)
                if not direct then return { ok = false, status_code = 404 } end
                makeArchive(path)
                return { ok = true, bytes = #bytes(path), content_type = "application/zip" }
            end
            local result = download({ force = true, attempt_id = first_id })
            assert.is_true(result.ok)
            assert.are.equal(legacy, result.path)
            assert.are.equal("valid", archive.validate(legacy).state)
            assert.is_nil(lfs.attributes(target))
            assert.are.equal(sidecar, package.loaded.docsettings:findSidecarFile(result.path))
            assert.are.equal(reading_state, bytes(sidecar))
            assert.are.equal("complete", dofile(sidecar).summary.status)
        end)
    end

    it("reports the legacy repair path and preserves its archive and sidecar after transfer failure", function()
        local legacy = target:gsub(" %[id%-398%]", "")
        put(legacy, "damaged legacy archive")
        local sidecar = legacy:gsub("%.cbz$", ".sdr") .. "/metadata.cbz.lua"
        putSidecar(sidecar, reading_state)
        api.downloadBinary = function() return { ok = false, error = "Unauthorized" } end
        local result = download({ force = true, attempt_id = first_id })
        assert.is_false(result.ok)
        assert.are.equal(legacy, result.path)
        assert.are.equal("damaged legacy archive", bytes(legacy))
        assert.are.equal(reading_state, bytes(sidecar))
        assert.is_nil(lfs.attributes(target))
        assert.is_nil(lfs.attributes(downloader:getPartialPath(legacy, first_id)))
    end)

    it("retains the authorized legacy target when a canonical archive has appeared", function()
        local legacy = target:gsub(" %[id%-398%]", "")
        put(legacy, "damaged legacy")
        makeArchive(target)
        local canonical = bytes(target)
        local result = download({ force = true, repair_path = legacy, attempt_id = first_id })
        assert.is_true(result.ok)
        assert.are.equal(legacy, result.path)
        assert.are.equal("valid", archive.validate(legacy).state)
        assert.are.equal(canonical, bytes(target))
    end)

    it("rejects a repair target outside supported chapter candidates", function()
        local unrelated = root .. "/other.cbz"
        put(unrelated, "unrelated archive")
        api.fetchChapterPages = function() error("unsupported target must not transfer") end
        assert.is_false(download({ force = true, repair_path = unrelated }).ok)
        assert.are.equal("unrelated archive", bytes(unrelated))
        assert.is_nil(lfs.attributes(target))
    end)

    it("keeps hash-only reading state discoverable after replacement and a fresh location lookup", function()
        local hash_path, original, local_path = hashSidecar()
        local backup = 'return { last_page = 5 }\n'
        put(hash_path .. ".old", backup)
        local result = download({ force = true, attempt_id = first_id })
        assert.is_true(result.ok)
        assert.are.equal("valid", archive.validate(result.path).state)
        assert.are_not.equal(original, bytes(result.path))
        -- A fresh resolver keys hash storage on the replacement bytes, not a
        -- process-local cached hash of the old document.
        package.loaded.docsettings = docSettings(original)
        assert.are_not.equal(hash_path, package.loaded.docsettings:getSidecarDir(result.path, "hash") .. "/metadata.cbz.lua")
        assert.are.equal(local_path, package.loaded.docsettings:findSidecarFile(result.path))
        assert.are.same({ summary = { status = "complete" }, last_page = 7, annotations = { "keep me" } },
            dofile(local_path))
        assert.are.equal(reading_state, bytes(local_path))
        assert.are.equal(backup, bytes(local_path .. ".old"))
        assert.are.equal(reading_state, bytes(hash_path))
        assert.are.equal(backup, bytes(hash_path .. ".old"))
    end)

    for _, failure in ipairs({ "write", "close", "rename" }) do
        it("leaves original archive and hash reading state intact after metadata " .. failure .. " failure", function()
            local hash_path, original, local_path = hashSidecar()
            local temporary = local_path .. "." .. first_id .. ".part"
            if failure == "rename" then
                api.downloadChapterArchive = function(_, _, path)
                    makeArchive(path)
                    return { ok = true, bytes = #bytes(path), content_type = "application/zip" }
                end
                api.fetchChapterPages = function() error("metadata failure must not authorize page fallback") end
                os.rename = function(from, to)
                    if to == local_path then return nil, "metadata rename denied" end
                    return original_rename(from, to)
                end
            else
                io.open = function(path, mode)
                    local handle, open_error = original_open(path, mode)
                    if path ~= temporary or mode ~= "wb" or not handle then return handle, open_error end
                    return {
                        write = function(_, content)
                            if failure == "write" then return nil, "metadata disk full" end
                            return handle:write(content)
                        end,
                        close = function()
                            local result = handle:close()
                            if failure == "close" then return nil, "metadata close failed" end
                            return result
                        end,
                    }
                end
            end
            local result = download({ force = true, attempt_id = first_id })
            assert.is_false(result.ok)
            assert.is_truthy(result.error:find("KOReader", 1, true))
            assert.are.equal(original, bytes(target))
            assert.are.equal(reading_state, bytes(hash_path))
            assert.are.equal(hash_path, package.loaded.docsettings:findSidecarFile(target))
            assert.is_nil(lfs.attributes(local_path))
            assert.is_nil(lfs.attributes(temporary))
            assert.is_nil(lfs.attributes(downloader:getPartialPath(target, first_id)))
        end)
    end

    it("preserves conflicting document and hash metadata without replacing the archive", function()
        local hash_path, original, local_path = hashSidecar()
        local conflict = 'return { last_page = 99 }\n'
        putSidecar(local_path, conflict)
        local result = download({ force = true, attempt_id = first_id })
        assert.is_false(result.ok)
        assert.are.equal(original, bytes(target))
        assert.are.equal(reading_state, bytes(hash_path))
        assert.are.equal(conflict, bytes(local_path))
    end)

    it("leaves a metadata temporary path owned by someone else untouched", function()
        local hash_path, original, local_path = hashSidecar()
        local temporary = local_path .. "." .. first_id .. ".part"
        putSidecar(temporary, "uncertain prior temporary data")
        assert.is_false(download({ force = true, attempt_id = first_id }).ok)
        assert.are.equal(original, bytes(target))
        assert.are.equal(reading_state, bytes(hash_path))
        assert.are.equal("uncertain prior temporary data", bytes(temporary))
    end)

    it("fails a repair rather than replacing bytes without the metadata dependency", function()
        put(target, "original damaged archive")
        package.loaded.docsettings = nil
        package.preload.docsettings = function() error("DocSettings unavailable") end
        local result = download({ force = true, attempt_id = first_id })
        assert.is_false(result.ok)
        assert.are.equal("original damaged archive", bytes(target))
    end)

    it("reports atomic rename failure even when another complete final exists", function()
        makeArchive(target)
        local original = bytes(target)
        os.rename = function(from, to)
            if to == target then return nil, "replacement denied" end
            return original_rename(from, to)
        end
        local result = download({ force = true, attempt_id = first_id })
        assert.is_false(result.ok)
        assert.is_nil(result.skipped)
        assert.are.equal(original, bytes(target))
        assert.is_nil(lfs.attributes(downloader:getPartialPath(target, first_id)))
    end)

    it("reports cleanup failure without deleting a final", function()
        local partial = downloader:getPartialPath(target, first_id)
        os.remove = function(path)
            if path == partial then return nil, "busy" end
            return original_remove(path)
        end
        api.downloadBinary = function() return { ok = false, error = "Unauthorized" } end
        local result = download({ attempt_id = first_id })
        assert.is_false(result.ok)
        assert.is_truthy(result.cleanup_error)
        assert.is_truthy(lfs.attributes(partial))
    end)

    it("does not publish when native writing fails", function()
        package.loaded["ffi/archiver"].Writer = setmetatable({
            addFileFromMemory = function(self) self.err = "disk full"; return false end,
        }, { __index = Native.Writer })
        assert.is_false(download({ attempt_id = first_id }).ok)
        assert.is_nil(lfs.attributes(target))
        assert.is_nil(lfs.attributes(downloader:getPartialPath(target, first_id)))
    end)

    for _, throws in ipairs({ false, true }) do
        it("does not publish when writer close " .. (throws and "throws" or "reports disk failure"), function()
            package.loaded["ffi/archiver"].Writer = setmetatable({
                close = function(self)
                    Native.Writer.close(self)
                    if throws then error("disk full") end
                    return false, "disk full"
                end,
            }, { __index = Native.Writer })
            assert.is_false(download({ attempt_id = first_id }).ok)
            assert.is_nil(lfs.attributes(target))
            assert.is_nil(lfs.attributes(downloader:getPartialPath(target, first_id)))
        end)
    end

    it("checks expected page count captured inside the archive", function()
        makeArchive(target)
        assert(archive.stamp(target, first_id, 2))
        local result = download()
        assert.is_false(result.ok)
        assert.are.equal("damaged", result.archive_state)
        assert.are.equal(2, archive.validate(target).expected_pages)
    end)

    it("preserves a prior export's captured expected count when restamping", function()
        makeArchive(target)
        assert(archive.stamp(target, first_id, 2))
        assert(archive.stamp(target, second_id))
        local result = download()
        assert.is_false(result.ok)
        assert.are.equal("damaged", result.archive_state)
        assert.are.equal(2, archive.validate(target).expected_pages)
    end)

    it("checks the whole central directory beyond the bounded ZIP tail", function()
        local entries = {}
        for index = 1, 1400 do entries[index] = { string.format("%04d.jpg", index), "image" } end
        makeArchive(target, entries)
        assert.is_true(download().skipped)
        assert.are.equal(1400, archive.validate(target).pages)
    end)

    it("does not count ancillary metadata as image pages", function()
        makeArchive(target, { { "0001.jpg", "image" }, { "ComicInfo.xml", "<ComicInfo/>" } })
        assert(archive.stamp(target, first_id, 1))
        assert.is_true(download().skipped)
        assert.are.equal(1, archive.validate(target).pages)
    end)

    it("rejects a local header whose size no longer agrees with the central entry", function()
        makeArchive(target)
        local content = bytes(target)
        -- Changing the local filename length makes its claimed payload overlap.
        put(target, content:sub(1, 26) .. "\255\255" .. content:sub(29))
        assert.are.equal("damaged", download().archive_state)
    end)

    it("rejects a forged data descriptor rather than accepting its byte length", function()
        makeArchive(target)
        local content = bytes(target)
        local descriptor = assert(content:find("PK\007\008", 1, true))
        local crc_byte = content:byte(descriptor + 4)
        put(target, content:sub(1, descriptor + 3) .. string.char((crc_byte + 1) % 256) .. content:sub(descriptor + 5))
        assert.are.equal("damaged", download().archive_state)
    end)

    it("rejects truncated structure even when the validator dependency is absent", function()
        put(target, "PK\003\004truncated")
        require("ffi").loadlib = function() error("native validator unavailable") end
        assert.are.equal("damaged", download().archive_state)
    end)

    it("reports missing pages and directory creation failures without publishing", function()
        api.fetchChapterPages = function() return { ok = true, pages = {} } end
        assert.is_false(download().ok)
        assert.is_nil(lfs.attributes(target))
        api.fetchChapterPages = function() return { ok = true, pages = { "one" } } end
        local original = lfs.mkdir
        lfs.mkdir = function() return nil, "permission denied" end
        local ok, result = pcall(function()
            return downloader:downloadChapter({}, root .. "/missing", manga, chapter)
        end)
        lfs.mkdir = original
        assert.is_true(ok)
        assert.is_false(result.ok)
    end)

    it("builds source-scoped paths and neutralizes traversal-only names", function()
        local directory, path = downloader:getTargetPath("/books", {
            title = "Frieren: Beyond Journey's End", source = { displayName = "MangaDex (EN)" },
        }, { name = "Vol. 1 / Ch. 1" })
        assert.are.equal("/books/MangaDex (EN)/Frieren_ Beyond Journey's End", directory)
        assert.are.equal(directory .. "/Vol. 1 _ Ch. 1.cbz", path)
        directory, path = downloader:getTargetPath("/books", { title = ".." }, { name = ".." })
        assert.are.equal("/books/Unknown source/untitled", directory)
        assert.are.equal(directory .. "/untitled.cbz", path)
    end)
end)
