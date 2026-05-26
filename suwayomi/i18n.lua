-- Boundary: plugin-owned i18n facade.
--
-- Responsibility: wrap KOReader gettext/template helpers behind a stable plugin
-- API for runtime UI strings.
-- Owned state: cached helper functions and plugin catalog tables only.
-- Dependencies: KOReader gettext and ffi/util when present.
-- External data: callers decide which values are user/server data and must not
-- translate them.

local Locales = require("suwayomi/i18n/locales")

local I18n = {}

local cached_gettext
local cached_ngettext
local cached_pgettext
local cached_template
local cached_catalogs = {}
local test_locale

local EMPTY_CATALOG = {
    translation = {},
    context = {},
    getPlural = function(count)
        return tonumber(count) == 1 and 0 or 1
    end,
}

local function identity(text)
    return tostring(text or "")
end

local function fallbackTemplate(text, ...)
    local values = { ... }
    return tostring(text or ""):gsub("%%(%d+)", function(index)
        return tostring(values[tonumber(index)] or "")
    end)
end

local function isCallable(value)
    if type(value) == "function" then
        return true
    end
    local metatable = debug.getmetatable(value)
    return type(metatable) == "table" and type(metatable.__call) == "function"
end

local function extractMethod(gettext, method_name)
    local ok, method = pcall(function()
        return gettext[method_name]
    end)
    return ok and type(method) == "function" and method or nil
end

local function callGettext(gettext, msgid)
    if isCallable(gettext) then
        return gettext(msgid)
    end
    return identity(msgid)
end

local function splitLines(text)
    local lines = {}
    for line in tostring(text):gmatch("([^\n]+)") do
        table.insert(lines, line)
    end
    return lines
end

local function isStandardMissingDiagnostic(module_name, line)
    return line == "\tno field package.preload['" .. module_name .. "']"
        or line:match("^\tno file .+$") ~= nil
end

local function isMissingModuleError(module_name, err)
    if type(err) ~= "string" then
        return false
    end

    local lines = splitLines(err)
    local prefix = "module '" .. module_name .. "' not found:"
    if lines[1]:sub(1, #prefix) ~= prefix then
        return false
    end

    local first_line_suffix = lines[1]:sub(#prefix + 1)
    if first_line_suffix ~= "" and first_line_suffix ~= "No LuaRocks module found for " .. module_name then
        return false
    end

    for index = 2, #lines do
        if not isStandardMissingDiagnostic(module_name, lines[index]) then
            return false
        end
    end

    return #lines > 1
end

local function loadGettext()
    if cached_gettext then
        return cached_gettext, cached_ngettext, cached_pgettext
    end
    local ok, gettext = pcall(require, "gettext")
    if ok then
        cached_gettext = gettext or identity
        cached_ngettext = extractMethod(cached_gettext, "ngettext")
        cached_pgettext = extractMethod(cached_gettext, "pgettext")
        return cached_gettext, cached_ngettext, cached_pgettext
    end
    if not isMissingModuleError("gettext", gettext) then
        error(gettext, 0)
    end
    cached_gettext = identity
    cached_ngettext = nil
    cached_pgettext = nil
    return cached_gettext, cached_ngettext, cached_pgettext
end

local function loadTemplate()
    if cached_template then
        return cached_template
    end
    local ok, ffi_util = pcall(require, "ffi/util")
    if ok then
        cached_template = type(ffi_util) == "table"
            and type(ffi_util.template) == "function"
            and ffi_util.template
            or fallbackTemplate
        return cached_template
    end
    if not isMissingModuleError("ffi/util", ffi_util) then
        error(ffi_util, 0)
    end
    cached_template = fallbackTemplate
    return cached_template
end

local function pluginRoot()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    local root = source:match("^(.*)[/\\]suwayomi[/\\]i18n%.lua$")
    return root or "."
end

local function catalogRoot()
    local root = pluginRoot()
    return root == "." and "l10n" or root .. "/l10n"
end

local function readKoreaderLanguage()
    if test_locale ~= nil then
        return test_locale
    end
    local reader_settings = _G.G_reader_settings
    if reader_settings and type(reader_settings.readSetting) == "function" then
        local ok, language = pcall(function()
            return reader_settings:readSetting("language")
        end)
        if ok then
            return language
        end
    end
    return nil
end

local SNAPSHOT_FIELDS = {
    "dirname",
    "textdomain",
    "translation",
    "context",
    "current_lang",
    "wrapUntranslated",
    "getPlural",
}

local function snapshotNativeGettext(gettext)
    local snapshot = {}
    for index = 1, #SNAPSHOT_FIELDS do
        local field = SNAPSHOT_FIELDS[index]
        local ok, value = pcall(function()
            return gettext[field]
        end)
        if ok then
            snapshot[field] = value
        end
    end
    return snapshot
end

local function restoreNativeGettext(gettext, snapshot)
    for index = 1, #SNAPSHOT_FIELDS do
        local field = SNAPSHOT_FIELDS[index]
        pcall(function()
            gettext[field] = snapshot[field]
        end)
    end
end

local function copyTable(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = type(value) == "table" and copyTable(value) or value
    end
    return copy
end

local function tryChangeLang(gettext, change_lang, candidate)
    local ok, loaded = pcall(function()
        return change_lang(candidate)
    end)
    if ok then
        return loaded
    end
    ok, loaded = pcall(function()
        return change_lang(gettext, candidate)
    end)
    return ok and loaded or false
end

local function loadCatalogForLocale(locale)
    local cache_key = tostring(locale or "")
    if cached_catalogs[cache_key] then
        return cached_catalogs[cache_key]
    end

    local gettext = loadGettext()
    local change_lang = extractMethod(gettext, "changeLang")
    if not change_lang then
        cached_catalogs[cache_key] = EMPTY_CATALOG
        return EMPTY_CATALOG
    end

    for _, candidate in ipairs(Locales.candidates(locale)) do
        local snapshot = snapshotNativeGettext(gettext)
        local loaded = false
        pcall(function()
            gettext.dirname = catalogRoot()
            gettext.textdomain = "suwayomi"
            loaded = tryChangeLang(gettext, change_lang, candidate)
        end)
        local catalog
        if loaded then
            catalog = {
                translation = copyTable(gettext.translation),
                context = copyTable(gettext.context),
                getPlural = gettext.getPlural or EMPTY_CATALOG.getPlural,
            }
        end
        restoreNativeGettext(gettext, snapshot)
        if catalog then
            cached_catalogs[cache_key] = catalog
            return catalog
        end
    end

    cached_catalogs[cache_key] = EMPTY_CATALOG
    return EMPTY_CATALOG
end

local function activeCatalog()
    local locale = readKoreaderLanguage()
    if not Locales.normalize(locale) then
        return nil
    end
    return loadCatalogForLocale(locale)
end

local function catalogText(msgid)
    local catalog = activeCatalog()
    if not catalog then
        return callGettext(loadGettext(), msgid)
    end
    local value = catalog.translation[msgid]
    if type(value) == "table" then
        return value[0] or msgid
    end
    return value or msgid
end

local function catalogContextText(context, msgid)
    local catalog = activeCatalog()
    if not catalog then
        local gettext, _, pgettext = loadGettext()
        if pgettext then
            return pgettext(context, msgid)
        end
        return callGettext(gettext, msgid)
    end
    local contexts = catalog.context
    return contexts[context] and contexts[context][msgid] or msgid
end

function I18n.t(msgid)
    return catalogText(msgid)
end

function I18n.f(msgid, ...)
    return loadTemplate()(I18n.t(msgid), ...)
end

function I18n.c(context, msgid)
    return catalogContextText(context, msgid)
end

function I18n.cf(context, msgid, ...)
    return loadTemplate()(I18n.c(context, msgid), ...)
end

function I18n.n(singular_msgid, plural_msgid, count)
    local catalog = activeCatalog()
    if catalog then
        local plural = catalog.getPlural(count)
        local translated = catalog.translation[singular_msgid]
        if type(translated) == "table" then
            return translated[plural] or (plural == 0 and singular_msgid or plural_msgid)
        end
        return tonumber(count) == 1 and catalogText(singular_msgid) or catalogText(plural_msgid)
    end

    local gettext, ngettext = loadGettext()
    if ngettext then
        return ngettext(singular_msgid, plural_msgid, count)
    end
    return callGettext(gettext, tonumber(count) == 1 and singular_msgid or plural_msgid)
end

function I18n.count(count, singular_msgid, plural_msgid)
    return loadTemplate()(I18n.n(singular_msgid, plural_msgid, count), count)
end

function I18n.nf(count, singular_msgid, plural_msgid, ...)
    return loadTemplate()(I18n.n(singular_msgid, plural_msgid, count), ...)
end

function I18n.join(parts, separator_msgid)
    local rendered = {}
    local source = parts or {}
    for index = 1, table.maxn(source) do
        local part = source[index]
        if part ~= nil and part ~= "" then
            table.insert(rendered, tostring(part))
        end
    end
    return table.concat(rendered, I18n.t(separator_msgid or " "))
end

function I18n.reset()
    cached_gettext = nil
    cached_ngettext = nil
    cached_pgettext = nil
    cached_template = nil
    cached_catalogs = {}
    test_locale = nil
end

function I18n.setLocaleForTests(locale)
    test_locale = locale
    cached_catalogs = {}
end

return I18n
