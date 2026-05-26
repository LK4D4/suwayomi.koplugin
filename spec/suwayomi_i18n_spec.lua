package.path = "?.lua;" .. package.path

describe("suwayomi/i18n", function()
    local loader_list_name = rawget(package, "searchers") and "searchers" or "loaders"
    local injected_loader_count = 0
    local function_metatable
    local function_metatable_saved = false

    before_each(function()
        package.loaded["suwayomi/i18n"] = nil
        package.loaded.gettext = nil
        package.loaded["ffi/util"] = nil
    end)

    after_each(function()
        package.loaded["suwayomi/i18n"] = nil
        package.loaded["suwayomi/i18n/locales"] = nil
        package.preload.gettext = nil
        package.preload["ffi/util"] = nil
        _G.G_reader_settings = nil
        if function_metatable_saved then
            debug.setmetatable(function() end, function_metatable)
            function_metatable = nil
            function_metatable_saved = false
        end
        local loaders = package[loader_list_name]
        for _ = 1, injected_loader_count do
            table.remove(loaders, 1)
        end
        injected_loader_count = 0
    end)

    local function installGettext(prefix)
        package.preload.gettext = function()
            return function(text)
                return prefix .. tostring(text)
            end
        end
    end

    local function installPluralGettext(prefix, plural_prefix)
        local native_plural_prefix = plural_prefix or "np:"
        package.preload.gettext = function()
            local gettext = function(text)
                return prefix .. tostring(text)
            end
            if not function_metatable_saved then
                function_metatable = debug.getmetatable(gettext)
                function_metatable_saved = true
            end
            debug.setmetatable(gettext, {
                __index = {
                    ngettext = function(singular, plural, count)
                        local chosen = tonumber(count) == 1 and singular or plural
                        return native_plural_prefix .. tostring(chosen)
                    end,
                },
            })
            return gettext
        end
    end

    local function installContextGettext(prefix)
        package.preload.gettext = function()
            local gettext = function(text)
                return prefix .. tostring(text)
            end
            if not function_metatable_saved then
                function_metatable = debug.getmetatable(gettext)
                function_metatable_saved = true
            end
            debug.setmetatable(gettext, {
                __index = {
                    pgettext = function(context, text)
                        return "ctx:" .. tostring(context) .. ":" .. tostring(text)
                    end,
                },
            })
            return gettext
        end
    end

    local function installTemplate()
        package.preload["ffi/util"] = function()
            return {
                template = function(text, ...)
                    local values = { ... }
                    return (text:gsub("%%(%d+)", function(index)
                        return tostring(values[tonumber(index)] or "")
                    end))
                end,
            }
        end
    end

    local function installLoaderError(module_name, message)
        local loaders = package[loader_list_name]
        table.insert(loaders, 1, function(name)
            if name ~= module_name then
                return "\n\tno injected loader for " .. name
            end
            return function()
                error(message)
            end
        end)
        injected_loader_count = injected_loader_count + 1
    end

    local function installSearcherDiagnostic(module_name, message)
        local loaders = package[loader_list_name]
        table.insert(loaders, 1, function(name)
            if name ~= module_name then
                return "\n\tno injected loader for " .. name
            end
            return "\n\t" .. message
        end)
        injected_loader_count = injected_loader_count + 1
    end

    it("translates message ids through KOReader gettext", function()
        installGettext("tx:")

        local i18n = require("suwayomi/i18n")

        assert.are.equal("tx:Library", i18n.t("Library"))
    end)

    it("formats translated templates with KOReader template placeholders", function()
        installGettext("tx:")
        installTemplate()

        local i18n = require("suwayomi/i18n")

        assert.are.equal("tx:Downloading 3/12", i18n.f("Downloading %1/%2", 3, 12))
    end)

    it("chooses singular and plural message ids before translation", function()
        installGettext("tx:")
        installTemplate()

        local i18n = require("suwayomi/i18n")

        assert.are.equal("tx:%1 chapter", i18n.n("%1 chapter", "%1 chapters", 1))
        assert.are.equal("tx:12 chapters", i18n.count(12, "%1 chapter", "%1 chapters"))
    end)

    it("uses native gettext plural helper when available", function()
        installPluralGettext("tx:")
        installTemplate()

        local i18n = require("suwayomi/i18n")

        assert.are.equal("np:%1 chapters", i18n.n("%1 chapter", "%1 chapters", 2))
        assert.are.equal("np:2 chapters", i18n.count(2, "%1 chapter", "%1 chapters"))
    end)

    it("formats plural translations with multiple placeholders", function()
        installPluralGettext("tx:", "tx:")
        installTemplate()

        local i18n = require("suwayomi/i18n")

        assert.are.equal(
            "tx:Queue 1 missing download to keep the next 5 unread chapters available?",
            i18n.nf(
                1,
                "Queue %1 missing download to keep the next %2 unread chapters available?",
                "Queue %1 missing downloads to keep the next %2 unread chapters available?",
                1,
                5
            )
        )
        assert.are.equal(
            "tx:Queue 3 missing downloads to keep the next 5 unread chapters available?",
            i18n.nf(
                3,
                "Queue %1 missing download to keep the next %2 unread chapters available?",
                "Queue %1 missing downloads to keep the next %2 unread chapters available?",
                3,
                5
            )
        )
    end)

    it("does not leak native plural helper into later gettext stubs", function()
        installGettext("tx:")
        installTemplate()

        local i18n = require("suwayomi/i18n")

        assert.are.equal("tx:3 chapters", i18n.count(3, "%1 chapter", "%1 chapters"))
    end)

    it("uses native gettext context helper when available", function()
        installContextGettext("tx:")

        local i18n = require("suwayomi/i18n")

        assert.are.equal("ctx:browse action:Search", i18n.c("browse action", "Search"))
    end)

    it("falls back to normal gettext when native context helper is missing", function()
        installGettext("tx:")

        local i18n = require("suwayomi/i18n")

        assert.are.equal("tx:Search", i18n.c("browse action", "Search"))
    end)

    it("formats contextual translated templates", function()
        installContextGettext("tx:")
        installTemplate()

        local i18n = require("suwayomi/i18n")

        assert.are.equal(
            "ctx:browse action:Search extensions: komga",
            i18n.cf("browse action", "Search extensions: %1", "komga")
        )
    end)

    it("joins non-empty labels with a translated separator", function()
        installGettext("tx:")

        local i18n = require("suwayomi/i18n")

        assert.are.equal("Readtx: | Queued", i18n.join({ "Read", nil, "", "Queued" }, " | "))
    end)

    it("falls back to identity gettext and internal template when KOReader modules are missing", function()
        local i18n = require("suwayomi/i18n")

        assert.are.equal("Queued", i18n.t("Queued"))
        assert.are.equal("Downloading 1/8", i18n.f("Downloading %1/%2", 1, 8))
    end)

    it("propagates gettext loader errors when a loader exists but fails", function()
        package.preload.gettext = function()
            error("boom")
        end

        local ok, err = pcall(function()
            require("suwayomi/i18n").t("Queued")
        end)

        assert.is_false(ok)
        assert.matches("boom", err)
    end)

    it("propagates template loader errors when a loader exists but fails", function()
        installGettext("tx:")
        package.preload["ffi/util"] = function()
            error("boom")
        end

        local ok, err = pcall(function()
            require("suwayomi/i18n").f("Downloading %1/%2", 1, 8)
        end)

        assert.is_false(ok)
        assert.matches("boom", err)
    end)

    it("propagates gettext searcher loader errors outside package.preload", function()
        installLoaderError("gettext", "boom gettext loader")

        local ok, err = pcall(function()
            require("suwayomi/i18n").t("Queued")
        end)

        assert.is_false(ok)
        assert.matches("boom gettext loader", err)
    end)

    it("propagates ffi util searcher loader errors outside package.preload", function()
        installGettext("tx:")
        installLoaderError("ffi/util", "boom ffi loader")

        local ok, err = pcall(function()
            require("suwayomi/i18n").f("Downloading %1/%2", 1, 8)
        end)

        assert.is_false(ok)
        assert.matches("boom ffi loader", err)
    end)

    it("propagates gettext searcher diagnostic strings outside package.preload", function()
        installSearcherDiagnostic("gettext", "boom gettext searcher")

        local ok, err = pcall(function()
            require("suwayomi/i18n").t("Queued")
        end)

        assert.is_false(ok)
        assert.matches("boom gettext searcher", err)
    end)

    it("propagates ffi util searcher diagnostic strings outside package.preload", function()
        installGettext("tx:")
        installSearcherDiagnostic("ffi/util", "boom ffi searcher")

        local ok, err = pcall(function()
            require("suwayomi/i18n").f("Downloading %1/%2", 1, 8)
        end)

        assert.is_false(ok)
        assert.matches("boom ffi searcher", err)
    end)

    local function installCatalogGettext(options)
        local state = {
            dirname = "l10n",
            textdomain = "koreader",
            translation = options.native_translation or {},
            context = options.native_context or {},
            current_lang = options.native_lang or "de",
            wrapUntranslated = function(text)
                return "native:" .. tostring(text)
            end,
            getPlural = function(count)
                return tonumber(count) == 1 and 0 or 1
            end,
            loaded_paths = {},
        }
        function state:changeLang(locale)
            table.insert(self.loaded_paths, self.dirname .. "/" .. tostring(locale) .. "/" .. self.textdomain .. ".mo")
            if options.fail_locale == locale then
                error("catalog boom")
            end
            local catalog = options.catalogs and options.catalogs[locale]
            if not catalog then
                return false
            end
            self.translation = catalog.translation or {}
            self.context = catalog.context or {}
            self.current_lang = locale
            self.getPlural = catalog.getPlural or self.getPlural
            return true
        end
        setmetatable(state, {
            __call = function(_, text)
                return "native:" .. tostring(text)
            end,
        })
        package.preload.gettext = function()
            return state
        end
        return state
    end

    it("loads plugin catalog for the KOReader language and returns translated strings", function()
        _G.G_reader_settings = {
            readSetting = function(_, key)
                return key == "language" and "de_DE" or nil
            end,
        }
        local gettext = installCatalogGettext({
            catalogs = {
                de = {
                    translation = {
                        Library = "Bibliothek",
                        ["%1 chapter"] = { [0] = "%1 Kapitel", [1] = "%1 Kapitel" },
                    },
                    context = {
                        ["browse action"] = {
                            Search = "Suche",
                        },
                    },
                    getPlural = function(count)
                        return tonumber(count) == 1 and 0 or 1
                    end,
                },
            },
        })
        installTemplate()

        local i18n = require("suwayomi/i18n")

        assert.are.equal("Bibliothek", i18n.t("Library"))
        assert.are.equal("3 Kapitel", i18n.count(3, "%1 chapter", "%1 chapters"))
        assert.are.equal("Suche", i18n.c("browse action", "Search"))
        assert.are.equal("l10n/de_DE/suwayomi.mo", gettext.loaded_paths[1])
        assert.are.equal("l10n/de/suwayomi.mo", gettext.loaded_paths[2])
    end)

    it("returns English msgids when plugin catalog or string is missing", function()
        _G.G_reader_settings = {
            readSetting = function(_, key)
                return key == "language" and "fr" or nil
            end,
        }
        installCatalogGettext({ catalogs = {} })
        installTemplate()

        local i18n = require("suwayomi/i18n")

        assert.are.equal("Library", i18n.t("Library"))
        assert.are.equal("Downloading 1/8", i18n.f("Downloading %1/%2", 1, 8))
        assert.are.equal("Search", i18n.c("browse action", "Search"))
        assert.are.equal("3 chapters", i18n.count(3, "%1 chapter", "%1 chapters"))
    end)

    it("restores native KOReader gettext state after catalog loading", function()
        _G.G_reader_settings = {
            readSetting = function(_, key)
                return key == "language" and "de" or nil
            end,
        }
        local original_translation = { Native = "Nativ" }
        local original_context = { Native = { Search = "Native Search" } }
        local gettext = installCatalogGettext({
            native_translation = original_translation,
            native_context = original_context,
            native_lang = "ru",
            catalogs = {
                de = {
                    translation = { Library = "Bibliothek" },
                    context = {},
                },
            },
        })

        local i18n = require("suwayomi/i18n")

        assert.are.equal("Bibliothek", i18n.t("Library"))
        assert.are.equal("l10n", gettext.dirname)
        assert.are.equal("koreader", gettext.textdomain)
        assert.are.same(original_translation, gettext.translation)
        assert.are.same(original_context, gettext.context)
        assert.are.equal("ru", gettext.current_lang)
    end)

    it("restores native KOReader gettext state after failed catalog loading", function()
        _G.G_reader_settings = {
            readSetting = function(_, key)
                return key == "language" and "de" or nil
            end,
        }
        local gettext = installCatalogGettext({
            native_translation = { Native = "Nativ" },
            native_context = {},
            native_lang = "ru",
            fail_locale = "de",
        })

        local i18n = require("suwayomi/i18n")

        assert.are.equal("Library", i18n.t("Library"))
        assert.are.equal("l10n", gettext.dirname)
        assert.are.equal("koreader", gettext.textdomain)
        assert.are.equal("ru", gettext.current_lang)
    end)

    it("supports test locale override and reset", function()
        installCatalogGettext({
            catalogs = {
                de = { translation = { Library = "Bibliothek" }, context = {} },
                es = { translation = { Library = "Biblioteca" }, context = {} },
            },
        })

        local i18n = require("suwayomi/i18n")
        i18n.setLocaleForTests("de")
        assert.are.equal("Bibliothek", i18n.t("Library"))

        i18n.setLocaleForTests("es")
        assert.are.equal("Biblioteca", i18n.t("Library"))

        i18n.reset()
        assert.are.equal("Library", i18n.t("Library"))
    end)
end)
