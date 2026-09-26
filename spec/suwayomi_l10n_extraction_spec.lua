package.path = "?.lua;" .. package.path

describe("l10n extraction coverage", function()
    local original_popen = io.popen
    local original_open = io.open
    after_each(function()
        io.popen = original_popen
        io.open = original_open
    end)

    local enumeration_complete = "__SUWAYOMI_L10N_ENUMERATION_COMPLETE__"

    local function gitCommand()
        -- Match the localization scripts' Windows-worktree handling under WSL.
        -- Explicit Git environment overrides still take precedence, including broken ones.
        if package.config:sub(1, 1) == "/" and not os.getenv("GIT_DIR") then
            local handle = io.open(".git", "r")
            if handle then
                local line = handle:read("*l")
                handle:close()
                local drive, rest = (line or ""):match("^gitdir: ([A-Za-z]):[/\\](.-)\r?$")
                if drive then
                    local path = "/mnt/" .. drive:lower() .. "/" .. rest:gsub("\\", "/")
                    return "git --git-dir='" .. path:gsub("'", "'\\''") .. "' --work-tree=."
                end
            end
        end
        return "git"
    end

    local function listLuaFiles()
        -- LuaJIT/Lua 5.1 can report true from popen:close() after a failed child.
        -- The shell emits this marker only after successful Git completion.
        local handle = assert(io.popen(gitCommand() .. ' ls-files -- "*.lua" && echo '
            .. enumeration_complete, "r"), "Cannot start runtime file enumeration")
        local files = {}
        local seen = {}
        local completed = false
        local modules = 0
        for path in handle:lines() do
            path = path:gsub("\r$", "")
            if path == enumeration_complete then
                completed = true
            elseif path == "_meta.lua" or path == "main.lua" or path:match("^suwayomi/.*%.lua$") then
                table.insert(files, path)
                seen[path] = true
                if path:match("^suwayomi/") then modules = modules + 1 end
            end
        end
        local closed = handle:close()
        assert(closed and completed, "Runtime Lua file enumeration failed; check Git context and availability")
        assert(seen["_meta.lua"] and seen["main.lua"] and modules > 0,
            "Runtime Lua file enumeration is empty or incomplete (entrypoints and modules required)")
        return files
    end

    local function readFile(path)
        local handle = assert(io.open(path, "r"))
        local content = handle:read("*a")
        handle:close()
        return assert(content, "Cannot read runtime Lua file: " .. path)
    end

    local function lineNumber(content, index)
        local _, count = content:sub(1, index):gsub("\n", "\n")
        return count + 1
    end

    local function scanRuntime()
        local offenders = {}
        local files = listLuaFiles()
        for _, path in ipairs(files) do
            local content = readFile(path)
            local start = 1
            while true do
                local first, last = content:find("self:translate%(%s*['\"]", start)
                if not first then
                    break
                end
                table.insert(offenders, path .. ":" .. lineNumber(content, first))
                start = last + 1
            end
        end

        return offenders, files
    end

    local function enumeration(lines, successful)
        io.popen = function()
            return {
                lines = function()
                    local index = 0
                    return function()
                        index = index + 1
                        return lines[index]
                    end
                end,
                close = function() return successful end,
            }
        end
    end

    local function failsWith(operation, message)
        local ok, err = pcall(operation)
        assert.is_false(ok)
        assert.is_truthy(tostring(type(err) == "table" and err.message or err):find(message, 1, true))
    end

    it("rejects unavailable process execution", function()
        io.popen = function() return nil end
        failsWith(listLuaFiles, "Cannot start runtime file enumeration")
    end)

    it("rejects failed enumeration even when LuaJIT reports successful close", function()
        enumeration({ "_meta.lua", "main.lua", "suwayomi/i18n.lua" }, true)
        failsWith(listLuaFiles,
            "Runtime Lua file enumeration failed; check Git context and availability")
    end)

    it("rejects unsuccessful command close", function()
        enumeration({ "_meta.lua", "main.lua", "suwayomi/i18n.lua", enumeration_complete }, false)
        assert.has_error(listLuaFiles)
    end)

    it("rejects empty or incomplete runtime enumeration", function()
        for _, files in ipairs({
            { enumeration_complete },
            { "_meta.lua", "main.lua", enumeration_complete },
            { "main.lua", "suwayomi/i18n.lua", enumeration_complete },
            { "_meta.lua", "suwayomi/i18n.lua", enumeration_complete },
        }) do
            enumeration(files, true)
            failsWith(listLuaFiles,
                "Runtime Lua file enumeration is empty or incomplete (entrypoints and modules required)")
        end
    end)

    it("rejects unreadable runtime files", function()
        enumeration({ "_meta.lua", "main.lua", "suwayomi/missing.lua", enumeration_complete }, true)
        io.open = function(path, mode)
            if path == "suwayomi/missing.lua" then return nil, "unreadable fixture" end
            return original_open(path, mode)
        end
        failsWith(scanRuntime, "unreadable fixture")
    end)

    it("rejects runtime read failures", function()
        enumeration({ "_meta.lua", "main.lua", "suwayomi/unreadable.lua", enumeration_complete }, true)
        io.open = function(path, mode)
            if path == "suwayomi/unreadable.lua" then
                return { read = function() return nil end, close = function() return true end }
            end
            return original_open(path, mode)
        end
        failsWith(scanRuntime, "Cannot read runtime Lua file: suwayomi/unreadable.lua")
    end)

    it("detects deliberately unextractable UI strings in enumerated runtime files", function()
        enumeration({ "_meta.lua", "main.lua", "suwayomi/fixture.lua", enumeration_complete }, true)
        io.open = function(path, mode)
            if path == "suwayomi/fixture.lua" then
                return {
                    read = function() return "-- fixture\nself:translate(\"Hidden text\")\nself:translate('More text')" end,
                    close = function() return true end,
                }
            end
            return original_open(path, mode)
        end
        assert.are.same({ "suwayomi/fixture.lua:2", "suwayomi/fixture.lua:3" }, scanRuntime())
    end)

    it("keeps plugin chrome out of unextractable client self:translate literals", function()
        local offenders, files = scanRuntime()
        assert.are.same({}, offenders)
        print(string.format("l10n coverage inspected %d tracked runtime Lua files", #files))
    end)
end)
