package.path = "?.lua;" .. package.path

local checkedQueueSettings = require("spec/support/checked_queue_settings")

describe("suwayomi/downloads/job_store", function()
    local JobStore

    local function build_store(saved_jobs)
        package.loaded["suwayomi/downloads/job_store"] = nil
        JobStore = require("suwayomi/downloads/job_store")
        local settings, save_count = checkedQueueSettings(saved_jobs)
        local store = JobStore:new{
            settings = settings,
            getKey = function(manga, chapter)
                return tostring(manga.id or manga.title or "") .. ":" .. tostring(chapter.id or chapter.name or "")
            end,
        }
        return store, function()
            return settings:loadDownloadQueue()
        end, save_count
    end

    after_each(function()
        package.loaded["suwayomi/downloads/job_store"] = nil
    end)

    it("builds persisted jobs with the existing schema", function()
        local store = build_store()
        local job = store:buildJob(
            {
                id = "m1",
                title = "Sousou no Frieren",
                source = { id = "mangadex", displayName = "MangaDex (EN)", raw_secret = "ignored" },
            },
            { id = "398", name = "Official_Vol. 1 Ch. 1", chapter_number = 1, source_order = 7 },
            "/books",
            "queued",
            {
                retry_count = "2",
                retry_at = "120",
                progress = { state = "queued", current = "2", total = "5", retryable = "true" },
            }
        )

        assert.are.same({
            key = "m1:398",
            state = "queued",
            download_directory = "/books",
            manga = {
                id = "m1",
                title = "Sousou no Frieren",
                source = { id = "mangadex", displayName = "MangaDex (EN)" },
            },
            chapter = {
                id = "398",
                name = "Official_Vol. 1 Ch. 1",
                chapter_number = 1,
                source_order = 7,
            },
            retry_count = 2,
            retry_at = 120,
            progress = {
                state = "queued",
                current = 2,
                total = 5,
                retryable = true,
            },
        }, job)
    end)

    it("does not persist runtime-only fields from queued work", function()
        local store = build_store()
        local job = store:buildJob(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1" },
            "/books",
            "downloading",
            {
                credentials = { token = "secret" },
                downloader = {},
                pid = 1234,
                onDone = function() end,
                progress = { state = "downloading", current = 1, total = 2 },
            }
        )

        assert.is_nil(job.credentials)
        assert.is_nil(job.downloader)
        assert.is_nil(job.pid)
        assert.is_nil(job.onDone)
        assert.are.same({ state = "downloading", current = 1, total = 2 }, job.progress)
    end)

    it("normalizes progress and recovery tables loaded from settings", function()
        local store = build_store()

        assert.are.same({
            state = "failed",
            current = 3,
            total = 8,
            path = "/books/chapter.cbz",
            error = "boom",
            updated_at = 100,
        }, store:normalizeProgress({
            state = "failed",
            current = "3",
            total = "8",
            path = "/books/chapter.cbz",
            error = "boom",
            updated_at = "100",
            ignored = "nope",
        }))

        assert.are.same({
            reason = "active-at-startup",
            recovered_at = 200,
            previous_state = "downloading",
            progress = { state = "downloading", current = 1, total = 4 },
        }, store:normalizeRecovery({
            reason = "active-at-startup",
            recovered_at = "200",
            previous_state = "downloading",
            progress = { state = "downloading", current = "1", total = "4" },
            ignored = "nope",
        }))
    end)

    it("loads non-list persisted queue data as empty", function()
        local store = build_store("legacy-queue")

        assert.are.same({}, store:load())
    end)

    it("loads valid list jobs while dropping malformed persisted entries", function()
        local valid_job = {
            key = "m1:398",
            state = "queued",
            download_directory = "/books",
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" },
        }
        local store = build_store({
            valid_job,
            true,
            by_key = { key = "legacy-map" },
        })

        assert.are.same({ valid_job }, store:load())
    end)

    it("upserts, finds, and removes jobs through the download_queue settings key", function()
        local store, saved, save_count = build_store()
        local job = store:buildJob({ id = "m1", title = "Manga" }, { id = "c1", name = "Chapter" }, "/books")

        store:upsert(job)
        assert.are.equal(1, save_count())
        assert.are.same(job, store:find("m1:c1"))

        store:remove("m1:c1")
        assert.are.same({}, saved())
    end)

    it("skips malformed existing jobs while batch upserting", function()
        local existing_job = {
            key = "m1:c1",
            state = "queued",
            download_directory = "/books",
            manga = { id = "m1", title = "Manga" },
            chapter = { id = "c1", name = "Chapter" },
        }
        local replacement = {
            key = "m1:c1",
            state = "queued",
            download_directory = "/books-new",
            manga = { id = "m1", title = "Manga" },
            chapter = { id = "c1", name = "Chapter" },
        }
        local added = {
            key = "m1:c2",
            state = "queued",
            download_directory = "/books",
            manga = { id = "m1", title = "Manga" },
            chapter = { id = "c2", name = "Chapter 2" },
        }
        local store, saved = build_store({
            { state = "queued", manga = { id = "legacy" }, chapter = { id = "broken" } },
            existing_job,
        })

        store:upsertMany({ replacement, added })

        assert.are.same({ replacement, added }, saved())
    end)
end)
