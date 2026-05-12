package.path = "?.lua;" .. package.path

describe("suwayomi/source_languages", function()
    before_each(function()
        package.loaded["suwayomi/source_languages"] = nil
    end)

    it("uses Suwayomi WebUI native language names", function()
        local source_languages = require("suwayomi/source_languages")

        assert.are.equal("English", source_languages.formatLabel("en"))
        assert.are.equal("Español", source_languages.formatLabel("es"))
        assert.are.equal("日本語", source_languages.formatLabel("ja"))
        assert.are.equal("Português (Brasil)", source_languages.formatLabel("pt_BR"))
        assert.are.equal("српски језик", source_languages.formatLabel("sr"))
    end)

    it("uses readable fallbacks for scripts missing from KOReader UI fonts", function()
        local source_languages = require("suwayomi/source_languages")

        assert.are.equal("Telugu", source_languages.formatLabel("te"))
        assert.are.equal("Tigrinya", source_languages.formatLabel("ti"))
        assert.are.equal("Burmese", source_languages.formatLabel("my"))
    end)

    it("falls back to the source language code for unknown values", function()
        local source_languages = require("suwayomi/source_languages")

        assert.are.equal("custom-source-lang", source_languages.formatLabel("custom-source-lang"))
    end)
end)
