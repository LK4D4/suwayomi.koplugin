package.path = "?.lua;" .. package.path

describe("suwayomi/settings", function()
    local flushed
    local stored_data

    before_each(function()
        flushed = false
        stored_data = {}

        package.loaded["suwayomi/settings"] = nil
        package.loaded["suwayomi/source_filters"] = nil
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

        local mock_io = {
            open = function(path, _mode)
                return { path = path, buffer = {} }
            end,
            write = function(handle, content)
                table.insert(handle.buffer, content)
                return true
            end,
            flush = function()
                flushed = true
                return true
            end,
            sync_file = function()
                flushed = true
                return true
            end,
            close = function()
                return true
            end,
            rename = function(_old_path, _new_path)
                return true
            end,
            sync_dir = function()
                return true
            end,
            remove = function()
                return true
            end,
            read = function()
                return nil, "not_found"
            end,
            dir_exists = function()
                return true
            end,
        }

        local settings = require("suwayomi/settings")
        settings:setIoAdapter(mock_io)
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
            auth_method = "simple_login",
        }

        local settings = require("suwayomi/settings")
        local credentials = settings:load()

        assert.are.equal("/mock/settings/suwayomi.lua", settings.settings_file)
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
        stored_data.credentials.auth_method = nil
        assert.are.equal("basic_auth", settings:load().auth_method)
    end)

    it("saves Simple Login credentials without session data and flushes the settings file", function()
        local settings = require("suwayomi/settings")
        settings:save({
            server_url = "suwayomi.local:4567",
            username = "alice",
            password = "secret",
            auth_method = "simple_login",
            cookie = "session-cookie",
        })

        assert.is_true(flushed)
        assert.are.same({
            server_url = "http://suwayomi.local:4567",
            username = "alice",
            password = "secret",
            auth_method = "simple_login",
        }, stored_data.credentials)
        assert.are.same(stored_data.credentials, settings:load())
    end)

    it("loads an empty versioned finished cleanup journal by default", function()
        local settings = require("suwayomi/settings")
        assert.are.same({ version = 1, next_sequence = 1, mangas = {} },
            settings:loadFinishedChapterCleanupJournal())
    end)

    it("normalizes and deduplicates finished cleanup records without truncating them", function()
        stored_data.finished_chapter_cleanup = {
            version = 1,
            next_sequence = 1,
            mangas = {
                m1 = { records = {
                    { chapter_id = "c1", path = "/downloads/c1.cbz", sequence = 2, retry_count = 3, retry_after = 10 },
                    { chapter_id = "c1", path = "/downloads/new-c1.cbz", sequence = 4, retry_count = 0, retry_after = 0 },
                    { chapter_id = "c2", path = "/downloads/c2.cbz", sequence = 3, retry_count = 0, retry_after = 0 },
                } },
            },
        }
        local journal = require("suwayomi/settings"):loadFinishedChapterCleanupJournal()
        assert.are.equal(5, journal.next_sequence)
        assert.are.equal(2, #journal.mangas.m1.records)
        assert.are.equal("/downloads/new-c1.cbz", journal.mangas.m1.records[2].path)
    end)

    it("persists pathless completion order and safely deduplicates mixed paths on reload", function()
        local settings = require("suwayomi/settings")
        settings:saveFinishedChapterCleanupJournal({ version = 1, next_sequence = 1, mangas = {
            m = { records = {
                { chapter_id = "A", path = "/A", sequence = 1, retry_count = 0, retry_after = 0 },
                { chapter_id = "B", sequence = 2, retry_count = 0, retry_after = 0 },
                { chapter_id = "B", path = "/B", sequence = 2, retry_count = 0, retry_after = 0 },
                { chapter_id = "bad", path = false, sequence = 3, retry_count = 0, retry_after = 0 },
                { chapter_id = "empty", path = "", sequence = 4, retry_count = 0, retry_after = 0 },
            } },
        } })
        package.loaded["suwayomi/settings"] = nil
        local journal = require("suwayomi/settings"):loadFinishedChapterCleanupJournal()
        assert.equals(3, journal.next_sequence)
        assert.equals(2, #journal.mangas.m.records)
        assert.equals("B", journal.mangas.m.records[2].chapter_id)
        assert.is_nil(journal.mangas.m.records[2].path)
    end)

    it("preserves an unknown finished cleanup journal version", function()
        local raw = { version = 9, opaque = { keep = true } }
        stored_data.finished_chapter_cleanup = raw
        local journal, err = require("suwayomi/settings"):loadFinishedChapterCleanupJournal()
        assert.are.equal(raw, journal)
        assert.are.equal("unsupported_version", err)
        assert.is_false(flushed)
    end)

    it("drops invalid journal records, normalizes keys, and preserves unrelated record fields", function()
        stored_data.finished_chapter_cleanup = {
            version = 1, next_sequence = -2, extra = true, mangas = {
                [7] = { records = {
                    { chapter_id = "", path = "/bad", sequence = 1, retry_count = 0, retry_after = 0 },
                    { chapter_id = "ok", path = "/ok", sequence = 2, retry_count = -1, retry_after = 0 },
                    { chapter_id = "ok", path = "/ok", sequence = 2, retry_count = 1, retry_after = 0, unknown = true },
                    { chapter_id = "later", path = "/later", sequence = 3, retry_count = 0, retry_after = 0 },
                    { chapter_id = "nan", path = "/nan", sequence = 0 / 0, retry_count = 0, retry_after = 0 },
                } },
                empty = { records = "nope" },
                [""] = { records = {} },
            },
        }
        local settings = require("suwayomi/settings")
        local journal = settings:loadFinishedChapterCleanupJournal()
        assert.are.same({ "ok", "later" }, { journal.mangas["7"].records[1].chapter_id,
            journal.mangas["7"].records[2].chapter_id })
        assert.is_true(journal.mangas["7"].records[1].unknown)
        assert.is_true(flushed)
    end)

    it("does not truncate large valid journals and flushes saves and clears", function()
        local records = {}
        for index = 1, 120 do
            records[index] = { chapter_id = "c" .. index, path = "/c" .. index,
                sequence = index, retry_count = 0, retry_after = 0 }
        end
        local settings = require("suwayomi/settings")
        local saved = settings:saveFinishedChapterCleanupJournal({ version = 1,
            next_sequence = 1, mangas = { m = { records = records } } })
        assert.are.equal(120, #saved.mangas.m.records)
        assert.is_true(flushed)
        flushed = false
        local cleared = settings:clearFinishedChapterCleanupJournal()
        assert.are.same({ version = 1, next_sequence = 1, mangas = {} }, cleared)
        assert.is_true(flushed)
    end)

    it("merges manga records when numeric and string keys normalize to the same key", function()
        stored_data.finished_chapter_cleanup = { version = 1, mangas = {
            [7] = { records = {{ chapter_id = "numeric", path = "/numeric", sequence = 1,
                retry_count = 0, retry_after = 0 }} },
            ["7"] = { records = {{ chapter_id = "string", path = "/string", sequence = 2,
                retry_count = 0, retry_after = 0 }} },
        } }
        local journal = require("suwayomi/settings"):loadFinishedChapterCleanupJournal()
        assert.are.equal(2, #journal.mangas["7"].records)
    end)

    it("chooses equal-sequence duplicate chapter state deterministically", function()
        local settings = require("suwayomi/settings")
        local journal = settings:normalizeFinishedChapterCleanupJournal({ version = 1, mangas = {
            m = { records = {
                { chapter_id = "same", path = "/z-path", sequence = 4, retry_count = 0, retry_after = 0 },
                { chapter_id = "same", path = "/a-path", sequence = 4, retry_count = 2, retry_after = 9 },
            } },
        } })
        assert.are.equal("/a-path", journal.mangas.m.records[1].path)
        assert.are.equal(2, journal.mangas.m.records[1].retry_count)
    end)

    it("preserves cleanup blockers through a settings round trip", function()
        stored_data.finished_chapter_cleanup = { version = 1, next_sequence = 4, mangas = { m1 = { records = {
            { chapter_id = "unsafe", path = "/outside/unsafe.cbz", sequence = 1,
                retry_count = 0, retry_after = 0, blocked_reason = "unsafe_path" },
            { chapter_id = "mismatch", path = "/outside/mismatch.cbz", sequence = 2,
                retry_count = 0, retry_after = 0, blocked_reason = "path_mismatch" },
            { chapter_id = "other", path = "/outside/other.cbz", sequence = 3,
                retry_count = 0, retry_after = 0, blocked_reason = true },
        } } } }

        local settings = require("suwayomi/settings")
        local journal = settings:loadFinishedChapterCleanupJournal()

        assert.are.equal("unsafe_path", journal.mangas.m1.records[1].blocked_reason)
        assert.are.equal("path_mismatch", journal.mangas.m1.records[2].blocked_reason)
        assert.is_true(journal.mangas.m1.records[3].blocked_reason)
        local saved = settings:saveFinishedChapterCleanupJournal(journal)
        assert.are.same(journal, saved)
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

    it("loads an empty normalized source filter draft by default", function()
        local settings = require("suwayomi/settings")

        assert.are.same({
            query = "",
            filters = {},
        }, settings:loadSourceFilterDraft("https://suwayomi.example", "source-a"))
    end)

    it("saves normalized source filter drafts by server auth scope and source", function()
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

        local saved = settings:saveSourceFilterDraft(alice, "source-a", {
            query = 123,
            filters = {
                { position = "1", type = "textState", state = 77 },
                "bad",
            },
        })

        assert.is_true(flushed)
        assert.are.same({
            query = "123",
            filters = {
                { position = 1, type = "textState", state = "77" },
            },
        }, saved)
        assert.are.same(saved, settings:loadSourceFilterDraft(alice, "source-a"))
        assert.are.same({
            query = "",
            filters = {},
        }, settings:loadSourceFilterDraft(alice, "source-b"))
        assert.are.same({
            query = "",
            filters = {},
        }, settings:loadSourceFilterDraft(bob, "source-a"))
        assert.matches("^%x+$", stored_data.source_filter_drafts.auth_identity)
        assert.is_nil(stored_data.source_filter_drafts.auth_identity:match("alice"))
        assert.is_nil(stored_data.source_filter_drafts.auth_identity:match("secret"))
    end)

    it("clears one source filter draft without changing other sources", function()
        local settings = require("suwayomi/settings")
        local credentials = {
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }

        settings:saveSourceFilterDraft(credentials, "source-a", { query = "one" })
        settings:saveSourceFilterDraft(credentials, "source-b", { query = "two" })
        flushed = false

        settings:clearSourceFilterDraft(credentials, "source-a")

        assert.is_true(flushed)
        assert.are.same({
            query = "",
            filters = {},
        }, settings:loadSourceFilterDraft(credentials, "source-a"))
        assert.are.equal("two", settings:loadSourceFilterDraft(credentials, "source-b").query)
    end)

    it("loads an empty download directory by default", function()
        local settings = require("suwayomi/settings")

        assert.are.equal("", settings:loadDownloadDirectory())
    end)

    it("treats non-string download directory settings as unset", function()
        local settings = require("suwayomi/settings")

        stored_data.download_directory = true
        assert.are.equal("", settings:loadDownloadDirectory())

        stored_data.download_directory = { path = "/books" }
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

    it("treats scalar download queue settings as empty", function()
        stored_data.download_queue = "legacy-queue"

        local settings = require("suwayomi/settings")

        assert.are.same({}, settings:loadDownloadQueue())
    end)

    it("flushes scalar download queue settings as an empty list", function()
        stored_data.download_queue = "legacy-queue"

        local settings = require("suwayomi/settings")

        assert.are.same({}, settings:loadDownloadQueue())
        assert.is_true(flushed)
        assert.are.same({}, stored_data.download_queue)
    end)

    it("preserves list download queue jobs while dropping malformed entries", function()
        local job = {
            key = "m1:398",
            state = "queued",
            download_directory = "/books",
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" },
        }
        stored_data.download_queue = {
            job,
            "corrupt",
            by_key = "legacy-map-entry",
        }

        local settings = require("suwayomi/settings")

        assert.are.same({ job }, settings:loadDownloadQueue())
    end)

    it("preserves gapped numeric download queue jobs in key order", function()
        local first_job = {
            key = "m1:398",
            state = "queued",
            download_directory = "/books",
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" },
        }
        local second_job = {
            key = "m1:399",
            state = "queued",
            download_directory = "/books",
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapter = { id = "399", name = "Official_Vol. 1 Ch. 2" },
        }
        stored_data.download_queue = {
            [1] = first_job,
            [3] = second_job,
            by_key = { key = "legacy-map-entry" },
        }

        local settings = require("suwayomi/settings")

        assert.are.same({ first_job, second_job }, settings:loadDownloadQueue())
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

    it("loads and saves per-manga scanlator filters", function()
        local settings = require("suwayomi/settings")
        local manga = { id = "m1", title = "Frieren" }

        assert.is_nil(settings:loadMangaScanlatorFilter(manga))

        assert.are.equal("Team A", settings:saveMangaScanlatorFilter(manga, "Team A"))
        assert.is_true(flushed)
        assert.are.equal("Team A", stored_data.manga_scanlator_filters.m1)
        assert.are.equal("Team A", settings:loadMangaScanlatorFilter(manga))

        assert.is_nil(settings:saveMangaScanlatorFilter(manga, ""))
        assert.is_nil(stored_data.manga_scanlator_filters.m1)

        stored_data.manga_scanlator_filters = { m1 = "Team B", m2 = false }
        assert.are.equal("Team B", settings:loadMangaScanlatorFilter(manga))
        assert.is_nil(settings:loadMangaScanlatorFilter({ id = "m2" }))
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

    it("normalizes non-table reader return contexts to an empty table", function()
        stored_data.reader_return_contexts = "not-a-table"

        local settings = require("suwayomi/settings")

        assert.are.same({}, settings:loadReaderReturnContexts())
    end)
end)
