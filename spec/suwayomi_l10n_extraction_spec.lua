package.path = "?.lua;" .. package.path

describe("l10n extraction coverage", function()
    local function listLuaFiles()
        local handle = assert(io.popen('git ls-files "*.lua"', "r"))
        local files = {}
        for path in handle:lines() do
            if path == "_meta.lua" or path == "main.lua" or path:match("^suwayomi/") then
                table.insert(files, path)
            end
        end
        handle:close()
        return files
    end

    local function readFile(path)
        local handle = assert(io.open(path, "r"))
        local content = handle:read("*a")
        handle:close()
        return content
    end

    local function lineNumber(content, index)
        local _, count = content:sub(1, index):gsub("\n", "\n")
        return count + 1
    end

    it("keeps plugin chrome out of unextractable client self:translate literals", function()
        local offenders = {}
        for _, path in ipairs(listLuaFiles()) do
            local content = readFile(path)
            local start = 1
            while true do
                local first, last = content:find('self:translate%(%s*"', start)
                if not first then
                    break
                end
                table.insert(offenders, path .. ":" .. lineNumber(content, first))
                start = last + 1
            end
        end

        assert.are.same({}, offenders)
    end)
end)
