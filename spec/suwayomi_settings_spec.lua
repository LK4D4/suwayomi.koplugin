package.path = "?.lua;" .. package.path

describe("suwayomi/settings", function()
    local flushed
    local stored_data

    before_each(function()
        flushed = false
        stored_data = {}

        package.loaded["suwayomi/settings"] = nil
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

        local settings = require("suwayomi/settings")
        local credentials = settings:load()

        assert.are.equal("/mock/settings/suwayomi_dl.lua", settings.settings_file)
        assert.are.same(stored_data.credentials, credentials)
    end)

    it("normalizes corrupt scalar credentials before callers use them", function()
        stored_data.credentials = "not-a-table"

        local settings = require("suwayomi/settings")
        local credentials = settings:load()

        assert.are.same({
            server_url = "",
            username = "",
            password = "",
            auth_method = "basic_auth",
        }, credentials)
    end)

    it("normalizes persisted credential fields", function()
        stored_data.credentials = {
            server_url = "suwayomi.local:4567",
            username = false,
            password = 456,
            auth_method = "bad",
        }

        local settings = require("suwayomi/settings")
        local credentials = settings:load()

        assert.are.equal("http://suwayomi.local:4567", credentials.server_url)
        assert.are.equal("false", credentials.username)
        assert.are.equal("456", credentials.password)
        assert.are.equal("basic_auth", credentials.auth_method)
    end)

    it("saves credentials and flushes the settings file", function()
        local settings = require("suwayomi/settings")
        settings:save({
            server_url = "suwayomi.local:4567",
            username = "alice",
            password = "secret",
            auth_method = "bad",
        })

        assert.is_true(flushed)
        assert.are.equal("http://suwayomi.local:4567", stored_data.credentials.server_url)
        assert.are.equal("alice", stored_data.credentials.username)
        assert.are.equal("secret", stored_data.credentials.password)
        assert.are.equal("basic_auth", stored_data.credentials.auth_method)
    end)

    it("loads source languages with english enabled by default", function()
        local settings = require("suwayomi/settings")
        local source_languages = settings:loadSourceLanguages()

        assert.are.same({ "en" }, source_languages)
    end)

    it("saves source languages and flushes the settings file", function()
        local settings = require("suwayomi/settings")
        settings:saveSourceLanguages({ "en", "ru", "de" })

        assert.is_true(flushed)
        assert.are.same({ "en", "ru", "de" }, stored_data.source_languages)
    end)

    it("loads conservative browse settings by default", function()
        local settings = require("suwayomi/settings")

        assert.are.same({
            show_nsfw_sources = false,
            hide_in_library_results = false,
        }, settings:loadBrowseSettings())
    end)

    it("saves normalized browse settings and flushes the settings file", function()
        local settings = require("suwayomi/settings")

        local saved = settings:saveBrowseSettings({
            show_nsfw_sources = true,
            hide_in_library_results = "yes",
        })

        assert.is_true(flushed)
        assert.are.same({
            show_nsfw_sources = true,
            hide_in_library_results = false,
        }, saved)
        assert.are.same(saved, stored_data.browse_settings)
    end)

    it("normalizes persisted browse settings", function()
        local settings = require("suwayomi/settings")
        stored_data.browse_settings = {
            show_nsfw_sources = 1,
            hide_in_library_results = true,
        }

        assert.are.same({
            show_nsfw_sources = false,
            hide_in_library_results = true,
        }, settings:loadBrowseSettings())
    end)

    it("loads automatic library category picker behavior by default", function()
        local settings = require("suwayomi/settings")

        assert.are.equal("automatic", settings:loadLibraryCategoryPickerBehavior())
    end)

    it("saves supported library category picker behavior", function()
        local settings = require("suwayomi/settings")

        local saved = settings:saveLibraryCategoryPickerBehavior("always")

        assert.is_true(flushed)
        assert.are.equal("always", saved)
        assert.are.equal("always", stored_data.library_category_picker_behavior)
    end)

    it("normalizes unsupported library category picker behavior to automatic", function()
        local settings = require("suwayomi/settings")

        stored_data.library_category_picker_behavior = "mystery"

        assert.are.equal("automatic", settings:loadLibraryCategoryPickerBehavior())
        assert.are.equal("automatic", settings:saveLibraryCategoryPickerBehavior("mystery"))
    end)

    it("loads and saves source cache for the current server", function()
        local settings = require("suwayomi/settings")
        local cache = settings:saveSourceCache("https://suwayomi.example", {
            { id = "1", name = "Local source", lang = "localsourcelang" },
        }, 1777777777)

        assert.is_true(flushed)
        assert.are.same(cache, settings:loadSourceCache("https://suwayomi.example"))
        assert.is_nil(settings:loadSourceCache("https://other.example"))
    end)

    it("partitions source cache by auth identity", function()
        local settings = require("suwayomi/settings")
        local alice = {
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }
        local bob = {
            server_url = "https://suwayomi.example",
            username = "bob",
            password = "secret",
            auth_method = "basic_auth",
        }
        local cache = settings:saveSourceCache(alice, {
            { id = "source-mangadex" },
        }, 1777777777)

        assert.are.same(cache, settings:loadSourceCache(alice))
        assert.is_nil(settings:loadSourceCache(bob))
        assert.matches("^%x+$", stored_data.source_cache.auth_identity)
        assert.is_nil(stored_data.source_cache.auth_identity:match("alice"))
        assert.is_nil(stored_data.source_cache.auth_identity:match("secret"))
    end)

    it("loads an empty download directory by default", function()
        local settings = require("suwayomi/settings")

        assert.are.equal("", settings:loadDownloadDirectory())
    end)

    it("saves the download directory and flushes the settings file", function()
        local settings = require("suwayomi/settings")
        settings:saveDownloadDirectory("/storage/emulated/0/Books/Manga")

        assert.is_true(flushed)
        assert.are.equal("/storage/emulated/0/Books/Manga", stored_data.download_directory)
    end)

    it("loads an empty download queue by default", function()
        local settings = require("suwayomi/settings")

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

        local settings = require("suwayomi/settings")
        settings:saveDownloadQueue(jobs)

        assert.is_true(flushed)
        assert.are.same(jobs, stored_data.download_queue)
    end)

    it("loads two parallel chapter downloads by default", function()
        local settings = require("suwayomi/settings")

        assert.are.equal(2, settings:loadMaxParallelChapterDownloads())
    end)

    it("clamps persisted parallel chapter downloads to the supported range", function()
        local settings = require("suwayomi/settings")

        stored_data.max_parallel_chapter_downloads = 0
        assert.are.equal(1, settings:loadMaxParallelChapterDownloads())

        stored_data.max_parallel_chapter_downloads = 9
        assert.are.equal(4, settings:loadMaxParallelChapterDownloads())

        stored_data.max_parallel_chapter_downloads = "3"
        assert.are.equal(3, settings:loadMaxParallelChapterDownloads())
    end)

    it("saves clamped parallel chapter download settings", function()
        local settings = require("suwayomi/settings")

        local saved = settings:saveMaxParallelChapterDownloads(9)

        assert.is_true(flushed)
        assert.are.equal(4, saved)
        assert.are.equal(4, stored_data.max_parallel_chapter_downloads)
    end)

    it("loads and saves automatic delete-after-read settings", function()
        local settings = require("suwayomi/settings")

        assert.are.same({
            delete_after_mark_read = false,
            delete_finished_while_reading = 0,
        }, settings:loadDeleteChaptersSettings())

        local saved = settings:saveDeleteChaptersSettings({
            delete_after_mark_read = true,
            delete_finished_while_reading = 3,
        })

        assert.is_true(flushed)
        assert.are.same({
            delete_after_mark_read = true,
            delete_finished_while_reading = 3,
        }, saved)
        assert.are.same(saved, stored_data.delete_chapters_settings)

        stored_data.delete_chapters_settings = {
            delete_after_mark_read = "yes",
            delete_finished_while_reading = "8",
        }
        assert.are.same({
            delete_after_mark_read = false,
            delete_finished_while_reading = 0,
        }, settings:loadDeleteChaptersSettings())
    end)

    it("loads and saves per-manga keep-next unread download limits", function()
        local settings = require("suwayomi/settings")
        local manga = { id = "m1", title = "Frieren" }

        assert.are.equal(0, settings:loadMangaKeepNextUnreadDownloads(manga))

        assert.are.equal(5, settings:saveMangaKeepNextUnreadDownloads(manga, 5))
        assert.is_true(flushed)
        assert.are.equal(5, stored_data.manga_keep_next_unread_downloads.m1)
        assert.are.equal(5, settings:loadMangaKeepNextUnreadDownloads(manga))

        assert.are.equal(0, settings:saveMangaKeepNextUnreadDownloads(manga, "7"))
        assert.is_nil(stored_data.manga_keep_next_unread_downloads.m1)

        stored_data.manga_keep_next_unread_downloads = { m1 = "10", m2 = 9 }
        assert.are.equal(10, settings:loadMangaKeepNextUnreadDownloads(manga))
        assert.are.equal(0, settings:loadMangaKeepNextUnreadDownloads({ id = "m2" }))
    end)

    it("loads an empty chapter ledger by default", function()
        local settings = require("suwayomi/settings")

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

        local settings = require("suwayomi/settings")
        settings:saveChapterLedger(ledger)

        assert.is_true(flushed)
        assert.are.same(ledger, stored_data.chapter_ledger)
    end)

    it("drops corrupt chapter ledger values before read-sync uses them", function()
        stored_data.chapter_ledger = {
            ["m1:c1"] = {
                manga_id = 1,
                manga_title = 2,
                chapter_id = 3,
                chapter_name = 4,
                path = 5,
                read = 1,
                pending_read_sync = true,
                pending_read_state = 1,
            },
            bad = "scalar",
        }

        local settings = require("suwayomi/settings")
        local ledger = settings:loadChapterLedger()

        assert.is_nil(ledger.bad)
        assert.are.same({
            manga_id = "1",
            manga_title = "2",
            chapter_id = "3",
            chapter_name = "4",
            path = "5",
            read = false,
            pending_read_sync = true,
            pending_read_state = true,
        }, ledger["m1:c1"])
    end)

    it("normalizes non-table chapter ledgers to an empty table", function()
        stored_data.chapter_ledger = "not-a-table"

        local settings = require("suwayomi/settings")

        assert.are.same({}, settings:loadChapterLedger())
    end)

    it("loads and saves reader return contexts by chapter path", function()
        local settings = require("suwayomi/settings")
        local contexts = {
            ["/downloads/Local/Manga/Chapter 1.cbz"] = {
                path = "/downloads/Local/Manga/Chapter 1.cbz",
                manga_id = "m1",
                manga_title = "Manga",
                chapter_id = "c1",
                chapter_name = "Chapter 1",
                source = { id = "local", name = "Local source" },
            },
        }

        settings:saveReaderReturnContexts(contexts)

        assert.is_true(flushed)
        assert.are.same(contexts, stored_data.reader_return_contexts)
        assert.are.same(contexts, settings:loadReaderReturnContexts())
    end)
end)
