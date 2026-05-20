package.path = "?.lua;" .. package.path

describe("suwayomi/fs", function()
    after_each(function()
        package.loaded["suwayomi/fs"] = nil
        package.loaded["libs/libkoreader-lfs"] = nil
        package.loaded.lfs = nil
        package.preload["libs/libkoreader-lfs"] = nil
        package.preload.lfs = nil
    end)

    it("prefers KOReader's bundled LuaFileSystem module", function()
        local koreader_lfs = {
            source = "koreader",
        }
        local plain_lfs = {
            source = "plain",
        }

        package.preload["libs/libkoreader-lfs"] = function()
            return koreader_lfs
        end
        package.preload.lfs = function()
            return plain_lfs
        end

        assert.are.same(koreader_lfs, require("suwayomi/fs"))
    end)

    it("falls back to plain lfs for local test and LuaRocks runtimes", function()
        local plain_lfs = {
            source = "plain",
        }

        package.preload.lfs = function()
            return plain_lfs
        end

        assert.are.same(plain_lfs, require("suwayomi/fs"))
    end)
end)
