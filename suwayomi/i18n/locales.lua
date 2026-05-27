-- Boundary: plugin i18n locale registry.
--
-- Responsibility: map Suwayomi/WebUI locale names to plugin catalog locales.
-- Owned state: immutable supported-locale and alias tables.
-- Dependencies: none.
-- External data: caller-provided locale names are normalized defensively.

local Locales = {}

local SUPPORTED = {
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
    "uk",
    "vi",
    "zh_CN",
    "zh_TW",
}

local ALIASES = {
    ["zh-Hans"] = "zh_CN",
    ["zh_Hans"] = "zh_CN",
    ["zh-CN"] = "zh_CN",
    ["zh_CN"] = "zh_CN",
    ["zh-Hant"] = "zh_TW",
    ["zh_Hant"] = "zh_TW",
    ["zh-TW"] = "zh_TW",
    ["zh_TW"] = "zh_TW",
}

local function normalizeSeparators(locale)
    return tostring(locale or ""):gsub("-", "_"):gsub("%.utf8$", ""):gsub("%.UTF%-8$", "")
end

local function baseLanguage(locale)
    return normalizeSeparators(locale):match("^([a-z][a-z])_")
end

function Locales.supported()
    local copy = {}
    for index = 1, #SUPPORTED do
        copy[index] = SUPPORTED[index]
    end
    return copy
end

function Locales.normalize(locale)
    if locale == nil then
        return nil
    end
    local raw = tostring(locale)
    if raw == "" or raw == "C" then
        return nil
    end
    if raw == "en" or raw:match("^en[_-]") then
        return nil
    end
    return ALIASES[raw] or normalizeSeparators(raw)
end

function Locales.candidates(locale)
    local normalized = Locales.normalize(locale)
    if not normalized then
        return {}
    end
    if normalized == "pt" then
        return { "pt" }
    end
    if normalized:match("^pt_") then
        return { "pt", normalized }
    end
    local base = baseLanguage(normalized)
    if base and base ~= normalized then
        return { normalized, base }
    end
    return { normalized }
end

return Locales
