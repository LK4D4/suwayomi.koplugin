package.path = "?.lua;" .. package.path

-- Public downloader behavior with real files; no KOReader or server required.
describe("download archive integrity", function()
    local lfs, root, paths, saved
    local modules = { "suwayomi/downloads/downloader", "suwayomi/downloads/archive", "suwayomi/api",
        "suwayomi/paths", "suwayomi/fs", "ffi/archiver", "ffi/util", "lfs" }

    before_each(function()
        saved = {}
        for _, name in ipairs(modules) do
            saved[name] = { loaded = package.loaded[name], preload = package.preload[name] }
            package.loaded[name], package.preload[name] = nil, nil
        end
        lfs = require("lfs")
        root = os.tmpname()
        os.remove(root)
        assert(lfs.mkdir(root))
        paths = { root }
        package.preload["ffi/util"] = function()
            return { joinPath = function(base, part) return base .. "/" .. part end }
        end
        package.preload["ffi/archiver"] = function() return {} end
        package.preload["suwayomi/api"] = function()
            return { fetchChapterPages = function() error("Existing damage must not trigger an automatic transfer") end }
        end
    end)

    after_each(function()
        for index = #paths, 1, -1 do os.remove(paths[index]) end
        for _, name in ipairs(modules) do
            package.loaded[name], package.preload[name] = saved[name].loaded, saved[name].preload
        end
    end)

    it("rejects a damaged existing archive without removing it or downloading", function()
        local downloader = require("suwayomi/downloads/downloader")
        local manga = { id = 1, title = "Manga", source = { name = "Source" } }
        local chapter = { id = 2, name = "Chapter" }
        local directory, path = downloader:getTargetPath(root, manga, chapter)
        local source_directory = directory:match("^(.*)/[^/]+$")
        assert(lfs.mkdir(source_directory))
        paths[#paths + 1] = source_directory
        assert(lfs.mkdir(directory))
        paths[#paths + 1] = directory
        local handle = assert(io.open(path, "wb"))
        assert(handle:write("PK\003\004broken"))
        assert(handle:close())
        paths[#paths + 1] = path

        local result = downloader:downloadChapter({}, root, manga, chapter)
        assert.is_false(result.ok)
        assert.are.equal("damaged", result.archive_state)
        handle = assert(io.open(path, "rb"))
        local content = handle:read("*a")
        handle:close()
        assert.are.equal("PK\003\004broken", content)
    end)
end)
