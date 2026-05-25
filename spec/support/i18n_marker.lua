local Marker = {}
local preload_stack = {}
local loaded_stack = {}
local loaded_present_stack = {}

local function format(text, ...)
    local result = tostring(text)
    local values = { ... }
    return result:gsub("%%(%d+)", function(index)
        return tostring(values[tonumber(index)] or "")
    end)
end

function Marker.install()
    table.insert(preload_stack, package.preload["suwayomi/i18n"])
    table.insert(loaded_stack, package.loaded["suwayomi/i18n"])
    table.insert(loaded_present_stack, package.loaded["suwayomi/i18n"] ~= nil)
    package.preload["suwayomi/i18n"] = function()
        return {
            t = function(text)
                return "tx:" .. tostring(text)
            end,
            f = function(text, ...)
                return "tx:" .. format(text, ...)
            end,
            c = function(context, text)
                return "ctx:" .. tostring(context) .. ":" .. tostring(text)
            end,
            cf = function(context, text, ...)
                return "ctx:" .. tostring(context) .. ":" .. format(text, ...)
            end,
            n = function(singular, plural, count)
                return "tx:" .. tostring(tonumber(count) == 1 and singular or plural)
            end,
            count = function(count, singular, plural)
                local text = tonumber(count) == 1 and singular or plural
                return "tx:" .. format(text, count)
            end,
            nf = function(count, singular, plural, ...)
                local text = tonumber(count) == 1 and singular or plural
                return "tx:" .. format(text, ...)
            end,
            join = function(parts, separator)
                local rendered = {}
                local source = parts or {}
                for index = 1, table.maxn(source) do
                    local part = source[index]
                    if part ~= nil and part ~= "" then
                        table.insert(rendered, tostring(part))
                    end
                end
                return table.concat(rendered, "tx:" .. tostring(separator or " "))
            end,
        }
    end
    package.loaded["suwayomi/i18n"] = nil
end

function Marker.uninstall()
    local preload = table.remove(preload_stack)
    local loaded = table.remove(loaded_stack)
    local had_loaded = table.remove(loaded_present_stack)

    package.preload["suwayomi/i18n"] = preload
    if had_loaded then
        package.loaded["suwayomi/i18n"] = loaded
    else
        package.loaded["suwayomi/i18n"] = nil
    end
end

return Marker
