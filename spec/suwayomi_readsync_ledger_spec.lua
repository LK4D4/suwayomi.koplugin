package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

local modules_to_clear = {
    "suwayomi/settings",
    "suwayomi/readsync/ledger",
    "suwayomi/downloads/service",
    "suwayomi/downloads/refill",
    "suwayomi/downloads/queue",
    "suwayomi/downloads/cleanup_adapter",
    "suwayomi/chapters/manual_deletion",
}

local function clearModules()
    for _, name in ipairs(modules_to_clear) do
        package.loaded[name] = nil
        package.preload[name] = nil
    end
end

local function installLedger(options)
    options = options or {}
    clearModules()
    helper.stubControllerDependencies()
    local settings = dofile("suwayomi/settings.lua")
    settings:setStore(require("spec/support/checked_queue_settings")():getStore())
    assert(settings:saveChapterLedger(options.ledger or {}))
    package.preload["suwayomi/settings"] = function() return settings end
    local service = require("suwayomi/downloads/service"):new{
        settings = settings,
        ui_manager = { scheduleIn = function() end, unschedule = function() end },
    }

    local ledger_module = require("suwayomi/readsync/ledger")
    local plugin = {}
    for name, method in pairs(ledger_module.methods) do
        plugin[name] = method
    end
    function plugin:getDownloadQueue() return service.queue end
    function plugin:getChapterDownloadKey(manga, chapter)
        return tostring(manga.id or "") .. ":" .. tostring(chapter.id or "")
    end

    return plugin, {
        loadLedger = function()
            return settings:loadChapterLedger()
        end,
    }
end

describe("suwayomi/readsync/ledger", function()
    after_each(clearModules)

    it("clears pending sync when remote read state already matches", function()
        local plugin, state = installLedger({
            ledger = {
                ["m1:c1"] = {
                    manga_id = "m1",
                    manga_title = "Frieren",
                    chapter_id = "c1",
                    chapter_name = "Chapter 1",
                    read = true,
                    path = "/books/Frieren/Chapter 1.cbz",
                    pending_read_sync = true,
                    pending_read_state = true,
                },
                ["m1:c2"] = {
                    manga_id = "m1",
                    manga_title = "Frieren",
                    chapter_id = "c2",
                    chapter_name = "Chapter 2",
                    read = false,
                    path = "/books/Frieren/Chapter 2.cbz",
                    pending_read_sync = true,
                    pending_read_state = false,
                },
            },
        })

        local chapters = plugin:mergeChaptersWithReadLedger({ id = "m1", title = "Frieren" }, {
            { id = "c1", name = "Chapter 1", is_read = true },
            { id = "c2", name = "Chapter 2", is_read = false },
        })

        local entry = state.loadLedger()["m1:c1"]
        local unread_entry = state.loadLedger()["m1:c2"]
        assert.is_true(chapters[1].is_read)
        assert.is_true(chapters[1]._suwayomi_is_read)
        assert.is_false(chapters[2].is_read)
        assert.is_false(chapters[2]._suwayomi_is_read)
        assert.is_true(entry.read)
        assert.are.equal("/books/Frieren/Chapter 1.cbz", entry.path)
        assert.is_nil(entry.pending_read_sync)
        assert.is_nil(entry.pending_read_state)
        assert.is_false(unread_entry.read)
        assert.are.equal("/books/Frieren/Chapter 2.cbz", unread_entry.path)
        assert.is_nil(unread_entry.pending_read_sync)
        assert.is_nil(unread_entry.pending_read_state)
    end)
end)
