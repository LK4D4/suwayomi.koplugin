package.path = "?.lua;" .. package.path

describe("suwayomi_settings", function()
    local flushed
    local stored_data

    before_each(function()
        flushed = false
        stored_data = {}

        package.loaded.suwayomi_settings = nil
        package.loaded.datastorage = nil
        package.loaded.luasettings = nil

        package.preload.datastorage = function()
            return {
                getSettingsDir = function()
                    return "/mock/settings"
                end,
            }
        end

        package.preload.luasettings = function()
            return {
                open = function(_, path)
                    return {
                        file = path,
                        data = stored_data,
                        readSetting = function(self, key, default)
                            if self.data[key] == nil and default ~= nil then
                                self.data[key] = default
                            end
                            return self.data[key]
                        end,
                        saveSetting = function(self, key, value)
                            self.data[key] = value
                            return self
                        end,
                        flush = function()
                            flushed = true
                        end,
                    }
                end,
            }
        end
    end)

    after_each(function()
        package.preload.datastorage = nil
        package.preload.luasettings = nil
    end)

    it("loads persisted credentials from the KOReader settings directory", function()
        stored_data.credentials = {
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }

        local settings = require("suwayomi_settings")
        local credentials = settings:load()

        assert.are.equal("/mock/settings/suwayomi_dl.lua", settings.settings_file)
        assert.are.same(stored_data.credentials, credentials)
    end)

    it("saves credentials and flushes the settings file", function()
        local settings = require("suwayomi_settings")
        settings:save({
            server_url = "suwayomi.local:4567",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.is_true(flushed)
        assert.are.equal("http://suwayomi.local:4567", stored_data.credentials.server_url)
        assert.are.equal("alice", stored_data.credentials.username)
        assert.are.equal("secret", stored_data.credentials.password)
        assert.are.equal("basic_auth", stored_data.credentials.auth_method)
    end)

    it("loads source languages with english enabled by default", function()
        local settings = require("suwayomi_settings")
        local source_languages = settings:loadSourceLanguages()

        assert.are.same({ "en" }, source_languages)
    end)

    it("saves source languages and flushes the settings file", function()
        local settings = require("suwayomi_settings")
        settings:saveSourceLanguages({ "en", "ru", "de" })

        assert.is_true(flushed)
        assert.are.same({ "en", "ru", "de" }, stored_data.source_languages)
    end)

    it("loads an empty download directory by default", function()
        local settings = require("suwayomi_settings")

        assert.are.equal("", settings:loadDownloadDirectory())
    end)

    it("saves the download directory and flushes the settings file", function()
        local settings = require("suwayomi_settings")
        settings:saveDownloadDirectory("/storage/emulated/0/Books/Manga")

        assert.is_true(flushed)
        assert.are.equal("/storage/emulated/0/Books/Manga", stored_data.download_directory)
    end)

    it("loads an empty download queue by default", function()
        local settings = require("suwayomi_settings")

        assert.are.same({}, settings:loadDownloadQueue())
    end)

    it("saves download queue jobs and flushes the settings file", function()
        local jobs = {
            {
                key = "m1:398",
                state = "queued",
                download_directory = "/books",
                manga = { id = "m1", title = "Sousou no Frieren" },
                chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" },
            },
        }

        local settings = require("suwayomi_settings")
        settings:saveDownloadQueue(jobs)

        assert.is_true(flushed)
        assert.are.same(jobs, stored_data.download_queue)
    end)

    it("loads two parallel chapter downloads by default", function()
        local settings = require("suwayomi_settings")

        assert.are.equal(2, settings:loadMaxParallelChapterDownloads())
    end)

    it("clamps persisted parallel chapter downloads to the supported range", function()
        local settings = require("suwayomi_settings")

        stored_data.max_parallel_chapter_downloads = 0
        assert.are.equal(1, settings:loadMaxParallelChapterDownloads())

        stored_data.max_parallel_chapter_downloads = 9
        assert.are.equal(4, settings:loadMaxParallelChapterDownloads())

        stored_data.max_parallel_chapter_downloads = "3"
        assert.are.equal(3, settings:loadMaxParallelChapterDownloads())
    end)

    it("saves clamped parallel chapter download settings", function()
        local settings = require("suwayomi_settings")

        local saved = settings:saveMaxParallelChapterDownloads(9)

        assert.is_true(flushed)
        assert.are.equal(4, saved)
        assert.are.equal(4, stored_data.max_parallel_chapter_downloads)
    end)

    it("loads an empty chapter ledger by default", function()
        local settings = require("suwayomi_settings")

        assert.are.same({}, settings:loadChapterLedger())
    end)

    it("saves the chapter ledger and flushes the settings file", function()
        local ledger = {
            ["m1:398"] = {
                manga_id = "m1",
                chapter_id = "398",
                read = true,
            },
        }

        local settings = require("suwayomi_settings")
        settings:saveChapterLedger(ledger)

        assert.is_true(flushed)
        assert.are.same(ledger, stored_data.chapter_ledger)
    end)
end)
