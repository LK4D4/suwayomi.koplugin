package.path = "?.lua;" .. package.path

describe("suwayomi/downloads/status_formatter", function()
    local formatter

    before_each(function()
        package.loaded["gettext"] = nil
        package.loaded["ffi/util"] = nil
        package.loaded["suwayomi/downloads/status_formatter"] = nil
        package.loaded["suwayomi/i18n"] = nil
        package.preload.gettext = function()
            return function(text)
                return text
            end
        end
        package.preload["ffi/util"] = function()
            return {
                template = function(text, ...)
                    local values = {...}
                    return (text:gsub("%%(%d+)", function(index)
                        return tostring(values[tonumber(index)] or "")
                    end))
                end,
            }
        end
        formatter = require("suwayomi/downloads/status_formatter")
    end)

    after_each(function()
        package.loaded["gettext"] = nil
        package.loaded["ffi/util"] = nil
        package.loaded["suwayomi/downloads/status_formatter"] = nil
        package.loaded["suwayomi/i18n"] = nil
        package.preload.gettext = nil
        package.preload["ffi/util"] = nil
    end)

    it("labels read and downloaded chapter rows clearly", function()
        assert.are.same({ "Read", "Downloaded" }, formatter.buildChapterStatusSymbols(
            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true },
            { state = "downloaded" }
        ))
        assert.are.equal("Read · Downloaded", formatter.formatChapterMenuStatus(
            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true },
            { state = "downloaded" }
        ))
    end)

    it("labels queued and downloading chapter rows clearly", function()
        assert.are.equal("Queued", formatter.formatChapterMenuStatus(
            { id = "399", name = "Official_Vol. 1 Ch. 2" },
            { state = "queued" }
        ))
        assert.are.equal("Retry scheduled", formatter.formatChapterMenuStatus(
            { id = "399", name = "Official_Vol. 1 Ch. 2" },
            { state = "queued", retry_at = 130 }
        ))
        assert.are.equal("Downloading 2/26", formatter.formatChapterMenuStatus(
            { id = "400", name = "Official_Vol. 1 Ch. 3" },
            { state = "downloading", current = 2, total = 26 }
        ))
    end)

    it("preserves damage evidence while repair is active and never calls inconclusive inspection damage", function()
        local damaged = formatter.formatArchiveStatus({ archive_state = "damaged" })
        local unverified = formatter.formatArchiveStatus({ archive_state = "unverified" })
        assert.are_not.equal(damaged, unverified)
        assert.are.same({ "Read", damaged, "Downloading 2/5" }, formatter.buildChapterStatusSymbols(
            { is_read = true }, { state = "downloading", archive_state = "damaged", current = 2, total = 5 }))
        assert.are.same({ unverified }, formatter.buildChapterStatusSymbols(
            {}, { state = "failed", archive_state = "unverified" }))
        assert.are.same({ "Verifying download" }, formatter.buildChapterStatusSymbols(
            {}, { state = "downloaded", verifying = true }))
    end)

    it("uses a fixed local retry timestamp and handles missing or invalid timestamps", function()
        local timestamp = os.time({ year = 2026, month = 9, day = 6, hour = 14, min = 30, sec = 15 })
        assert.are.equal("Next retry: 2026-09-06 14:30:15", formatter.formatRetryTime(timestamp))
        assert.are.equal("Retry time unavailable.", formatter.formatRetryTime(nil))
        assert.are.equal("Retry time unavailable.", formatter.formatRetryTime("unknown"))
    end)

    it("routes status labels and templates through i18n", function()
        package.preload.gettext = function()
            return function(text)
                return "tx:" .. text
            end
        end
        package.loaded["gettext"] = nil
        package.loaded["ffi/util"] = nil
        package.loaded["suwayomi/downloads/status_formatter"] = nil
        package.loaded["suwayomi/i18n"] = nil

        formatter = require("suwayomi/downloads/status_formatter")

        assert.are.equal("tx:Retry scheduled", formatter.formatChapterMenuStatus(
            { name = "Chapter" }, { state = "queued", retry_at = 130 }
        ))
        assert.are.equal("tx:Retry time unavailable.", formatter.formatRetryTime(nil))
        assert.are.equal("tx:Download damaged; redownload", formatter.formatArchiveStatus({ archive_state = "damaged" }))
        assert.are.equal("tx:Could not verify download", formatter.formatArchiveStatus({ archive_state = "unverified" }))
        local timestamp = os.time({ year = 2026, month = 9, day = 6, hour = 14, min = 30, sec = 15 })
        assert.are.equal("tx:Next retry: 2026-09-06 14:30:15", formatter.formatRetryTime(timestamp))

        assert.are.equal("tx:Downloading 2/26", formatter.formatChapterMenuStatus(
            { id = "400", name = "Official_Vol. 1 Ch. 3" },
            { state = "downloading", current = 2, total = 26 }
        ))
        assert.are.equal(
            "tx:Could not download \"Sousou no Frieren / Official_Vol. 1 Ch. 1\"tx: (Ch. 1.5): network timeout",
            formatter.formatFailureMessage(
                { id = "m1", title = "Sousou no Frieren" },
                { id = "398", name = "Official_Vol. 1 Ch. 1", chapter_number = 1.5 },
                "network timeout",
                "m1:398"
            )
        )
    end)

    it("formats downloading progress and shortens long titles without changing text", function()
        assert.are.equal(
            "Official_Vol. 25 Ch. 126 A Very Lo…  Read Downloading 3/12",
            formatter.formatChapterMenuText(
                { id = "398", name = "Official_Vol. 25 Ch. 126 A Very Long Chapter Title", is_read = true },
                { state = "downloading", current = 3, total = 12 }
            )
        )
    end)

    it("shortens unicode chapter names without splitting multibyte characters", function()
        assert.are.equal(
            "Очень длинное название главы с кириллице…  Read Downloaded",
            formatter.formatChapterMenuText(
                { id = "401", name = "Очень длинное название главы с кириллицей для проверки", is_read = true },
                { state = "downloaded" }
            )
        )
    end)

    it("formats useful failure messages from manga and chapter metadata", function()
        assert.are.equal(
            "Could not download \"Sousou no Frieren / Official_Vol. 1 Ch. 1\" (Ch. 1.5): network timeout",
            formatter.formatFailureMessage(
                { id = "m1", title = "Sousou no Frieren" },
                { id = "398", name = "Official_Vol. 1 Ch. 1", chapter_number = 1.5 },
                "network timeout",
                "m1:398"
            )
        )
    end)
end)
