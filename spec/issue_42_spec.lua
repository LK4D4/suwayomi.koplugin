package.path = "?.lua;" .. package.path

-- Real checked writes and fresh loads with controlled identity evidence, not
-- a claim that the host filesystem allocates these inode values.
describe("issue #42 lossless settings persistence", function()
    local SettingsStore, Identity, lfs, directory, path
    local previous
    local modules = {
        "lfs", "suwayomi/fs", "libs/libkoreader-lfs", "ffi/util",
        "suwayomi/settings/store", "suwayomi/chapters/archive_identity",
    }

    before_each(function()
        previous = {}
        for _, name in ipairs(modules) do
            previous[name] = { loaded = package.loaded[name], preload = package.preload[name] }
            package.loaded[name], package.preload[name] = nil, nil
        end
        -- Identity.same does not resolve paths; only the KOReader import is absent.
        package.preload["ffi/util"] = function() return {} end
        lfs = require("lfs")
        SettingsStore = require("suwayomi/settings/store")
        Identity = require("suwayomi/chapters/archive_identity")
        directory = os.tmpname():gsub("\\", "/")
        os.remove(directory)
        assert(lfs.mkdir(directory))
        path = directory .. "/suwayomi.lua"
    end)

    after_each(function()
        if directory then
            for name in lfs.dir(directory) do
                if name ~= "." and name ~= ".." then
                    assert(os.remove(directory .. "/" .. name))
                end
            end
            assert(lfs.rmdir(directory))
            directory = nil
        end
        for _, name in ipairs(modules) do
            package.loaded[name] = previous[name].loaded
            package.preload[name] = previous[name].preload
        end
    end)

    local function evidence(inode)
        return {
            version = 1, dev = 1, ino = inode, size = 4096,
            ctime = 1700000000.125, mtime = 1700000000.25,
            resolved_path = directory .. "/chapter.cbz", resolved_root = directory,
        }
    end

    it("recognizes unchanged wide identities after restart without trusting changed or rounded identities", function()
        local original = evidence(281474976710657)
        local historical = evidence(281474976710660)
        local store = SettingsStore:new({ path = path })
        assert.is_true(store:saveDocument(function(doc)
            doc.archive = original
            doc.historical_archive = historical
        end))

        local reopened = SettingsStore:new({ path = path })
        local restored = reopened:readKey("archive")
        assert.is_true(Identity.same(original, restored))
        assert.are.same(original, restored)
        assert.is_false(Identity.same(evidence(281474976710658), restored))
        assert.are.same(historical, reopened:readKey("historical_archive"))
        assert.is_false(Identity.same(original, reopened:readKey("historical_archive")))
    end)

    it("preserves fractional values and distinct wide numeric keys through replacement and reload", function()
        local numbers = {
            [0.1] = 1 / 3,
            [1.0000000000000002] = 1.0000000000000002,
            [281474976710657] = 281474976710657,
            [281474976710658] = 9007199254740991,
            [-281474976710657] = -281474976710657,
            [1e-200] = 1e200,
        }
        local store = SettingsStore:new({ path = path })
        assert.is_true(store:saveKey("numbers", numbers))
        local reopened = SettingsStore:new({ path = path })
        assert.are.same(numbers, reopened:readKey("numbers"))
        assert.is_true(reopened:saveKey("unrelated", true))
        local replaced = SettingsStore:new({ path = path })
        assert.are.same(numbers, replaced:readKey("numbers"))
        for key, value in pairs(numbers) do
            assert.are.equal(value, replaced:readKey("numbers")[key])
        end
    end)

    it("rejects unsupported and non-finite data without replacing committed settings", function()
        local store = SettingsStore:new({ path = path })
        local original = evidence(281474976710657)
        assert.is_true(store:saveKey("archive", original))
        local transaction = store:getTransactionId()
        local cyclic = {}
        cyclic.self = cyclic
        local rejected = {
            { value = 0 / 0, reason = "non_finite_number" },
            { value = math.huge, reason = "non_finite_number" },
            { value = -math.huge, reason = "non_finite_number" },
            { value = { [math.huge] = true }, reason = "non_finite_number_key" },
            { value = function() end, reason = "unsupported_type_function" },
            { value = { [true] = 1 }, reason = "unsupported_key_type_boolean" },
            { value = cyclic, reason = "cyclic_table" },
        }
        for _, case in ipairs(rejected) do
            local saved, err = store:saveKey("invalid", case.value)
            assert.is_nil(saved)
            assert.are.equal("serialization_failed: " .. case.reason, err)
            assert.is_false(store:isBlocked())
            assert.is_nil(store:readKey("invalid"))
            local reopened = SettingsStore:new({ path = path })
            assert.are.equal(transaction, reopened:getTransactionId())
            assert.is_nil(reopened:readKey("invalid"))
            assert.is_true(Identity.same(original, reopened:readKey("archive")))
        end
    end)
end)
