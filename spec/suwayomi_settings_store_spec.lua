package.path = "?.lua;" .. package.path

describe("suwayomi/settings/store", function()
    local SettingsStore
    local mock_io
    local store

    before_each(function()
        package.loaded["suwayomi/settings/store"] = nil
        SettingsStore = require("suwayomi/settings/store")

        mock_io = {
            files = {},
            written = {},
            opened_modes = {},
            flushed = {},
            synced_files = {},
            closed = {},
            renamed = {},
            synced_dirs = {},
            removed = {},

            open = function(path, mode)
                mock_io.opened_modes[path] = mode
                if mock_io.fail_open then
                    return nil, "injected_open_failure"
                end
                local handle = { path = path, content = "" }
                return handle
            end,

            write = function(handle, content)
                table.insert(mock_io.written, { path = handle.path, content = content })
                if mock_io.fail_write then
                    return nil, "injected_write_failure"
                end
                handle.content = (handle.content or "") .. content
                return true
            end,

            flush = function(handle)
                table.insert(mock_io.flushed, handle.path)
                if mock_io.fail_flush then
                    return nil, "injected_flush_failure"
                end
                return true
            end,

            sync_file = function(handle)
                table.insert(mock_io.synced_files, handle.path)
                if mock_io.fail_sync_file then
                    return nil, "injected_sync_file_failure"
                end
                return true
            end,

            close = function(handle)
                table.insert(mock_io.closed, handle.path)
                if mock_io.fail_close then
                    return nil, "injected_close_failure"
                end
                mock_io.files[handle.path] = handle.content
                return true
            end,

            rename = function(old_path, new_path)
                table.insert(mock_io.renamed, { old_path = old_path, new_path = new_path })
                if mock_io.fail_rename then
                    return nil, "injected_rename_failure"
                end
                mock_io.files[new_path] = mock_io.files[old_path]
                mock_io.files[old_path] = nil
                return true
            end,

            sync_dir = function(dir_path)
                table.insert(mock_io.synced_dirs, dir_path)
                if mock_io.fail_sync_dir then
                    return nil, "injected_sync_dir_failure"
                end
                return true
            end,

            remove = function(path)
                table.insert(mock_io.removed, path)
                mock_io.files[path] = nil
                return true
            end,

            read = function(path)
                if mock_io.files[path] then
                    return mock_io.files[path]
                end
                return nil, "no_such_file"
            end,

            dir_exists = function()
                return true
            end,
        }

        store = SettingsStore:new({
            path = "/test/suwayomi.lua",
            io_adapter = mock_io,
        })
    end)

    it("stages changes separately and assigns unique transaction identity on success", function()
        store:load({ existing = "original", count = 1 })

        local ok, saved_doc = store:saveKey("count", 2)
        assert.is_true(ok)
        assert.are.equal(2, saved_doc.count)
        assert.are.equal("original", saved_doc.existing)
        assert.is_table(saved_doc.store_transaction)
        assert.are.equal(1, saved_doc.store_transaction.version)
        assert.is_string(saved_doc.store_transaction.id)
        assert.are.equal(saved_doc.store_transaction.id, store:getTransactionId())

        assert.are.equal(2, store:readKey("count"))
        assert.are.equal("original", store:readKey("existing"))

        assert.are.equal(1, #mock_io.written)
        assert.are.equal(1, #mock_io.flushed)
        assert.are.equal(1, #mock_io.synced_files)
        assert.are.equal(1, #mock_io.closed)
        assert.are.equal(1, #mock_io.renamed)
        assert.are.equal(1, #mock_io.synced_dirs)

        assert.is_string(mock_io.files["/test/suwayomi.lua"])
        local loader = loadstring(mock_io.files["/test/suwayomi.lua"])
        assert.is_function(loader)
        local loaded_table = loader()
        assert.are.equal(2, loaded_table.count)
        assert.are.equal("original", loaded_table.existing)
        assert.are.equal(saved_doc.store_transaction.id, loaded_table.store_transaction.id)
    end)

    it("leaves committed cache unchanged and cleans temp file on pre-replacement write failure", function()
        store:load({ setting = "old_value" })
        mock_io.fail_write = true

        local ok, err = store:saveKey("setting", "new_value")
        assert.is_nil(ok)
        assert.matches("write_failed", err)

        assert.are.equal("old_value", store:readKey("setting"))
        assert.are.equal(1, #mock_io.removed)
        assert.is_nil(mock_io.files["/test/suwayomi.lua"])
        assert.is_false(store:isBlocked())
    end)

    it("leaves committed cache unchanged on flush failure", function()
        store:load({ setting = "old_value" })
        mock_io.fail_flush = true

        local ok, err = store:saveKey("setting", "new_value")
        assert.is_nil(ok)
        assert.matches("flush_failed", err)
        assert.are.equal("old_value", store:readKey("setting"))
        assert.are.equal(1, #mock_io.removed)
        assert.is_false(store:isBlocked())
    end)

    it("leaves committed cache unchanged on sync file failure", function()
        store:load({ setting = "old_value" })
        mock_io.fail_sync_file = true

        local ok, err = store:saveKey("setting", "new_value")
        assert.is_nil(ok)
        assert.matches("sync_failed", err)
        assert.are.equal("old_value", store:readKey("setting"))
        assert.are.equal(1, #mock_io.removed)
        assert.is_false(store:isBlocked())
    end)

    it("leaves committed cache unchanged on close failure", function()
        store:load({ setting = "old_value" })
        mock_io.fail_close = true

        local ok, err = store:saveKey("setting", "new_value")
        assert.is_nil(ok)
        assert.matches("close_failed", err)
        assert.are.equal("old_value", store:readKey("setting"))
        assert.are.equal(1, #mock_io.removed)
        assert.is_false(store:isBlocked())
    end)

    it("leaves committed cache unchanged on rename failure", function()
        store:load({ setting = "old_value" })
        mock_io.fail_rename = true

        local ok, err = store:saveKey("setting", "new_value")
        assert.is_nil(ok)
        assert.matches("replacement_failed", err)
        assert.are.equal("old_value", store:readKey("setting"))
        assert.are.equal(1, #mock_io.removed)
        assert.is_false(store:isBlocked())
    end)

    it("blocks further writes on post-replacement sync_dir ambiguity until reconciled", function()
        store:load({ setting = "old_value" })
        mock_io.fail_sync_dir = true

        local ok, err = store:saveKey("setting", "new_value")
        assert.is_nil(ok)
        assert.matches("ambiguous_post_replacement", err)

        assert.is_true(store:isBlocked())

        local ok2, err2 = store:saveKey("setting", "another_value")
        assert.is_nil(ok2)
        assert.matches("store_blocked", err2)

        mock_io.fail_sync_dir = false
        local rec_ok, rec_status = store:reconcile()
        assert.is_true(rec_ok)
        assert.are.equal("committed", rec_status)
        assert.is_false(store:isBlocked())
        assert.are.equal("new_value", store:readKey("setting"))

        local ok3 = store:saveKey("setting", "another_value")
        assert.is_true(ok3)
        assert.are.equal("another_value", store:readKey("setting"))
    end)

    it("reconciles rolled back state when destination file still has previous tx", function()
        store:load({ setting = "old_value" })
        store:saveKey("setting", "v1")
        local v1_tx = store:getTransactionId()

        mock_io.fail_sync_dir = true
        store:saveKey("setting", "v2")
        assert.is_true(store:isBlocked())

        mock_io.files["/test/suwayomi.lua"] = "return { [\"setting\"] = \"v1\", [\"store_transaction\"] = { [\"version\"] = 1, [\"id\"] = \"" .. v1_tx .. "\" } }"

        mock_io.fail_sync_dir = false
        local rec_ok, rec_status = store:reconcile()
        assert.is_true(rec_ok)
        assert.are.equal("rolled_back", rec_status)
        assert.is_false(store:isBlocked())
        assert.are.equal("v1", store:readKey("setting"))
    end)

    it("preserves unfamiliar persisted versions and unknown fields", function()
        local raw_table = {
            store_transaction = { version = 99, id = "future_tx" },
            future_feature = { enabled = true, count = 42 },
            download_queue = { { key = "m:c", state = "queued" } },
            chapter_ledger = { ["1"] = { read = true } },
            reader_return_contexts = { ["ctx"] = true },
        }
        mock_io.files["/test/suwayomi.lua"] = store:serializeDocument(raw_table)
        store = SettingsStore:new({
            path = "/test/suwayomi.lua",
            io_adapter = mock_io,
        })

        assert.are.equal("future_tx", store:getTransactionId())
        assert.are.same({ enabled = true, count = 42 }, store:readKey("future_feature"))

        local ok, saved = store:saveKey("new_field", "hello")
        assert.is_true(ok)

        assert.are.equal(99, saved.store_transaction.version)
        assert.are.same({ enabled = true, count = 42 }, saved.future_feature)
        assert.are.equal("hello", saved.new_field)
        assert.are.same({ { key = "m:c", state = "queued" } }, saved.download_queue)
    end)

    it("rejects serialization of invalid data like nan or cyclic tables", function()
        store:load({})
        local cyclic = {}
        cyclic.self = cyclic

        local ok, err = store:saveKey("bad", cyclic)
        assert.is_nil(ok)
        assert.matches("serialization_failed", err)
        assert.is_nil(store:readKey("bad"))
        assert.is_false(store:isBlocked())
        assert.are.equal(0, #mock_io.written)
    end)
end)

describe("suwayomi/settings/store real filesystem", function()
    local SettingsStore = require("suwayomi/settings/store")
    local test_dir
    local test_file

    before_each(function()
        local ok_lfs, lfs = pcall(require, "lfs")
        local base = (ok_lfs and lfs and lfs.currentdir()) or "."
        test_dir = base:gsub("\\", "/") .. "/.codex-tmp-settings-test-" .. os.time() .. "-" .. math.random(1000, 9999)
        if ok_lfs and lfs then
            lfs.mkdir(test_dir)
        end
        test_file = test_dir .. "/suwayomi.lua"
    end)

    after_each(function()
        local ok_lfs, lfs = pcall(require, "lfs")
        if ok_lfs and lfs and test_dir then
            for file in lfs.dir(test_dir) do
                if file ~= "." and file ~= ".." then
                    os.remove(test_dir .. "/" .. file)
                end
            end
            lfs.rmdir(test_dir)
        end
    end)

    it("performs atomic replacement on real filesystem and cleans up temp files", function()
        local store = SettingsStore:new({
            path = test_file,
        })

        local ok, saved = store:saveKey("real_test", "works")
        assert.is_true(ok)
        assert.are.equal("works", saved.real_test)

        local handle = io.open(test_file, "r")
        assert.is_not_nil(handle)
        local content = handle:read("*a")
        handle:close()

        local loader = loadstring(content)
        assert.is_function(loader)
        local data = loader()
        assert.are.equal("works", data.real_test)
        assert.is_table(data.store_transaction)

        local ok_lfs, lfs = pcall(require, "lfs")
        if ok_lfs and lfs then
            for file in lfs.dir(test_dir) do
                assert.is_nil(file:match("%.tmp"))
            end
        end
    end)
end)
