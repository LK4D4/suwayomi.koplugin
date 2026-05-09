package.path = "?.lua;" .. package.path

describe("suwayomi/downloads/status_formatter", function()
    local formatter

    before_each(function()
        package.loaded["suwayomi/downloads/status_formatter"] = nil
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
        package.loaded["suwayomi/downloads/status_formatter"] = nil
        package.preload.gettext = nil
        package.preload["ffi/util"] = nil
    end)

    it("keeps read and download status symbols compact", function()
        assert.are.same({ "✓", "↓" }, formatter.buildChapterStatusSymbols(
            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true },
            { state = "downloaded" }
        ))
        assert.are.equal("✓↓", formatter.formatChapterMenuStatus(
            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true },
            { state = "downloaded" }
        ))
    end)

    it("formats downloading progress and shortens long titles without changing text", function()
        assert.are.equal(
            "Official_Vol. 25 Ch. 126 A Very Long Chapter Ti…  ✓ ↓ 3/12",
            formatter.formatChapterMenuText(
                { id = "398", name = "Official_Vol. 25 Ch. 126 A Very Long Chapter Title", is_read = true },
                { state = "downloading", current = 3, total = 12 }
            )
        )
    end)

    it("shortens unicode chapter names without splitting multibyte characters", function()
        assert.are.equal(
            "Очень длинное название главы с кириллицей для провер…  ✓ ↓",
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
