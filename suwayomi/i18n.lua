-- Boundary: plugin-owned i18n facade.
--
-- Responsibility: wrap KOReader gettext/template helpers behind a stable plugin
-- API for runtime UI strings.
-- Owned state: cached helper functions only.
-- Dependencies: KOReader gettext and ffi/util when present.
-- External data: callers decide which values are user/server data and must not
-- translate them.

local I18n = {}

local cached_gettext
local cached_ngettext
local cached_template

local function identity(text)
    return tostring(text or "")
end

local function fallbackTemplate(text, ...)
    local values = { ... }
    return tostring(text or ""):gsub("%%(%d+)", function(index)
        return tostring(values[tonumber(index)] or "")
    end)
end

local function extractNGettext(gettext)
    local ok, ngettext = pcall(function()
        return gettext.ngettext
    end)
    return ok and type(ngettext) == "function" and ngettext or nil
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
        return cached_gettext, cached_ngettext
    end
    local ok, gettext = pcall(require, "gettext")
    if ok then
        cached_gettext = type(gettext) == "function" and gettext or identity
        cached_ngettext = extractNGettext(cached_gettext)
        return cached_gettext, cached_ngettext
    end
    if not isMissingModuleError("gettext", gettext) then
        error(gettext, 0)
    end
    cached_gettext = identity
    cached_ngettext = nil
    return cached_gettext, cached_ngettext
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

function I18n.t(msgid)
    local gettext = loadGettext()
    return gettext(msgid)
end

function I18n.f(msgid, ...)
    return loadTemplate()(I18n.t(msgid), ...)
end

function I18n.n(singular_msgid, plural_msgid, count)
    local gettext, ngettext = loadGettext()
    if ngettext then
        return ngettext(singular_msgid, plural_msgid, count)
    end
    return gettext(tonumber(count) == 1 and singular_msgid or plural_msgid)
end

function I18n.count(count, singular_msgid, plural_msgid)
    return loadTemplate()(I18n.n(singular_msgid, plural_msgid, count), count)
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

return I18n
