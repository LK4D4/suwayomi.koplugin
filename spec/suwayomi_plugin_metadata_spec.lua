package.path = "?.lua;" .. package.path

describe("plugin metadata", function()
    before_each(function()
        package.loaded["_meta"] = nil
        package.loaded.gettext = nil
        package.preload.gettext = function()
            return function(text)
                return text
            end
        end
    end)

    after_each(function()
        package.loaded["_meta"] = nil
        package.loaded.gettext = nil
        package.preload.gettext = nil
    end)

    it("keeps package id stable while showing installed version in fullname", function()
        local metadata = require("_meta")

        assert.are.equal("suwayomi", metadata.name)
        assert.are.equal("1.0.2", metadata.version)
        assert.are.equal("Suwayomi Client v1.0.2", metadata.fullname)
    end)

    it("prints versioned release asset name from metadata", function()
        local handle = assert(io.popen("luajit .github/scripts/release-asset-name.lua _meta.lua 2>&1"))
        local output = handle:read("*a")
        local ok = handle:close()

        assert.is_true(ok)
        assert.are.equal("suwayomi.koplugin-v1.0.2.zip\n", output)
    end)
end)
