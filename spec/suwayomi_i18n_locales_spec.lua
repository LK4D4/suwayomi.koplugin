package.path = "?.lua;" .. package.path

describe("suwayomi/i18n/locales", function()
    before_each(function()
        package.loaded["suwayomi/i18n/locales"] = nil
    end)

    it("keeps the WebUI target locale set visible", function()
        local Locales = require("suwayomi/i18n/locales")

        assert.are.same({
            "ar",
            "de",
            "es",
            "fa",
            "fr",
            "hu",
            "id",
            "it",
            "ja",
            "ko",
            "pl",
            "pt",
            "ru",
            "vi",
            "zh_CN",
            "zh_TW",
        }, Locales.supported())
    end)

    it("normalizes WebUI and KOReader Chinese aliases", function()
        local Locales = require("suwayomi/i18n/locales")

        assert.are.equal("zh_CN", Locales.normalize("zh-Hans"))
        assert.are.equal("zh_CN", Locales.normalize("zh_Hans"))
        assert.are.equal("zh_CN", Locales.normalize("zh_CN"))
        assert.are.equal("zh_TW", Locales.normalize("zh-Hant"))
        assert.are.equal("zh_TW", Locales.normalize("zh_Hant"))
        assert.are.equal("zh_TW", Locales.normalize("zh_TW"))
    end)

    it("falls Portuguese regions back to the shared pt catalog first", function()
        local Locales = require("suwayomi/i18n/locales")

        assert.are.same({ "pt", "pt_BR" }, Locales.candidates("pt_BR"))
        assert.are.same({ "pt", "pt_PT" }, Locales.candidates("pt_PT"))
    end)

    it("falls other regions back from full locale to base language", function()
        local Locales = require("suwayomi/i18n/locales")

        assert.are.same({ "de_DE", "de" }, Locales.candidates("de_DE"))
        assert.are.same({ "fr_CA", "fr" }, Locales.candidates("fr-CA"))
    end)

    it("does not load a plugin catalog for English or empty locales", function()
        local Locales = require("suwayomi/i18n/locales")

        assert.are.same({}, Locales.candidates(nil))
        assert.are.same({}, Locales.candidates(""))
        assert.are.same({}, Locales.candidates("C"))
        assert.are.same({}, Locales.candidates("en"))
        assert.are.same({}, Locales.candidates("en_US"))
    end)
end)
