local function stubControllerDependencies()
    package.preload.datastorage = package.preload.datastorage or function()
        return {
            getSettingsDir = function()
                return "/mock/settings"
            end,
        }
    end

    package.preload.luasettings = package.preload.luasettings or function()
        return {
            open = function()
                return {
                    readSetting = function(_, _, default)
                        return default
                    end,
                    saveSetting = function(self)
                        return self
                    end,
                    flush = function() end,
                }
            end,
        }
    end

    package.preload.gettext = package.preload.gettext or function()
        return function(text)
            return text
        end
    end

    package.preload["ffi/util"] = package.preload["ffi/util"] or function()
        return {
            template = function(template_string, ...)
                local result = template_string
                local values = {...}
                for index, value in ipairs(values) do
                    result = result:gsub("%%" .. index, tostring(value))
                end
                return result
            end,
        }
    end

    package.preload["ui/uimanager"] = package.preload["ui/uimanager"] or function()
        return {
            show = function() end,
            close = function() end,
            scheduleIn = function() end,
            nextTick = function(callback)
                if callback then
                    callback()
                end
            end,
        }
    end

    package.preload["ui/widget/infomessage"] = package.preload["ui/widget/infomessage"] or function()
        return {
            new = function(_, options)
                return options or {}
            end,
        }
    end

    package.preload["ui/widget/menu"] = package.preload["ui/widget/menu"] or function()
        return {
            new = function(_, options)
                return options or {}
            end,
        }
    end

    package.preload["ui/widget/buttondialog"] = package.preload["ui/widget/buttondialog"] or function()
        return {
            new = function(_, options)
                return options or {}
            end,
        }
    end

    package.preload["ui/widget/confirmbox"] = package.preload["ui/widget/confirmbox"] or function()
        return {
            new = function(_, options)
                return options or {}
            end,
        }
    end

    package.preload["ui/widget/multiinputdialog"] = package.preload["ui/widget/multiinputdialog"] or function()
        return {
            new = function(_, options)
                return options or {}
            end,
        }
    end
end

local function assertControllerModule(module_name, expected_methods)
    stubControllerDependencies()
    package.loaded[module_name] = nil
    package.loaded["suwayomi/i18n"] = nil

    local module = require(module_name)
    assert(type(module) == "table")
    assert(type(module.new) == "function")
    assert(type(module.methods) == "table")

    local instance = module:new({ plugin = {} })
    assert(type(instance) == "table")

    for _, method_name in ipairs(expected_methods) do
        assert(type(module.methods[method_name]) == "function")
    end
end

return {
    assertControllerModule = assertControllerModule,
    stubControllerDependencies = stubControllerDependencies,
}
