package.path = "?.lua;" .. package.path

describe("suwayomi/i18n", function()
    local loader_list_name = rawget(package, "searchers") and "searchers" or "loaders"
    local injected_loader_count = 0

    before_each(function()
        package.loaded["suwayomi/i18n"] = nil
        package.loaded.gettext = nil
        package.loaded["ffi/util"] = nil
    end)

    after_each(function()
        package.loaded["suwayomi/i18n"] = nil
        package.preload.gettext = nil
        package.preload["ffi/util"] = nil
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

    local function installPluralGettext(prefix)
        package.preload.gettext = function()
            local gettext = function(text)
                return prefix .. tostring(text)
            end
            debug.setmetatable(gettext, {
                __index = {
                    ngettext = function(singular, plural, count)
                        local chosen = tonumber(count) == 1 and singular or plural
                        return "np:" .. tostring(chosen)
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
end)
