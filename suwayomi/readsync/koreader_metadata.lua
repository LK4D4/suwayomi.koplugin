-- Boundary: KoreaderMetadata.
--
-- Responsibility: Owns KOReader sidecar metadata and history helpers.
-- Owned state: Accepts filesystem paths from downloaded chapters/current documents and validates table/file state before trusting it.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and gettext are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local SuwayomiSettings = require("suwayomi/settings")

local KoreaderMetadata = {}
KoreaderMetadata.__index = KoreaderMetadata

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function KoreaderMetadata:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

function Methods:getKoreaderMetadataPathForDocument(document_path)
    if not document_path or document_path == "" then
        return nil
    end

    local base_path, extension = document_path:match("^(.*)%.([^%.%/]+)$")
    if not base_path or not extension then
        return nil
    end

    return base_path .. ".sdr/metadata." .. extension .. ".lua"
end


function Methods:ensureDirectory(path)
    if not path or path == "" then
        return false
    end

    local ok, lfs = pcall(require, "lfs")
    if not ok or not lfs then
        return false
    end

    if lfs.attributes(path, "mode") == "directory" then
        return true
    end

    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path and lfs.attributes(parent, "mode") ~= "directory" then
        self:ensureDirectory(parent)
    end

    return lfs.mkdir(path) or lfs.attributes(path, "mode") == "directory"
end


function Methods:loadKoreaderMetadataTable(chapter_path)
    local metadata_path = self:getKoreaderMetadataPathForDocument(chapter_path)
    local metadata = {
        doc_path = chapter_path,
    }
    local handle = metadata_path and io.open(metadata_path, "r")
    if not handle then
        return metadata, metadata_path
    end

    local content = handle:read("*a") or ""
    handle:close()

    local loader = loadstring(content)
    if not loader then
        return metadata, metadata_path
    end

    setfenv(loader, {})
    local ok, parsed = pcall(loader)
    if ok and type(parsed) == "table" then
        parsed.doc_path = parsed.doc_path or chapter_path
        return parsed, metadata_path
    end

    return metadata, metadata_path
end

local function sortLuaKeys(left, right)
    local left_type = type(left)
    local right_type = type(right)
    if left_type == right_type then
        return tostring(left) < tostring(right)
    end
    return left_type < right_type
end


function Methods:serializeLuaValue(value, indent)
    indent = indent or 0
    local value_type = type(value)
    if value_type == "string" then
        return string.format("%q", value)
    end
    if value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end
    if value_type ~= "table" then
        return "nil"
    end

    local next_indent = indent + 4
    local current_padding = string.rep(" ", indent)
    local next_padding = string.rep(" ", next_indent)
    local keys = {}
    for key in pairs(value) do
        table.insert(keys, key)
    end
    table.sort(keys, sortLuaKeys)

    local lines = { "{" }
    for _, key in ipairs(keys) do
        local item = value[key]
        if item ~= nil then
            table.insert(lines, next_padding
                .. "["
                .. self:serializeLuaValue(key, 0)
                .. "] = "
                .. self:serializeLuaValue(item, next_indent)
                .. ",")
        end
    end
    table.insert(lines, current_padding .. "}")
    return table.concat(lines, "\n")
end


function Methods:saveKoreaderMetadataTable(metadata_path, metadata)
    if not metadata_path then
        return false
    end

    local metadata_dir = metadata_path:match("^(.*)/[^/]+$")
    if metadata_dir and not self:ensureDirectory(metadata_dir) then
        return false
    end

    local handle = io.open(metadata_path, "w")
    if not handle then
        return false
    end

    handle:write("return ", self:serializeLuaValue(metadata, 0), "\n")
    handle:close()
    return true
end


function Methods:setKoreaderChapterReadState(chapter_path, is_read)
    if not chapter_path or chapter_path == "" then
        return false
    end

    local metadata, metadata_path = self:loadKoreaderMetadataTable(chapter_path)
    metadata.doc_path = metadata.doc_path or chapter_path
    metadata.summary = type(metadata.summary) == "table" and metadata.summary or {}

    if is_read then
        metadata.percent_finished = 1
        metadata.summary.status = "complete"
    else
        metadata.percent_finished = 0
        metadata.summary.status = nil
    end

    return self:saveKoreaderMetadataTable(metadata_path, metadata)
end


function Methods:isKoreaderMetadataFinished(metadata_path)
    local handle = metadata_path and io.open(metadata_path, "r")
    if not handle then
        return false
    end

    local content = handle:read("*a") or ""
    handle:close()

    local status = content:match('%["status"%]%s*=%s*"([^"]+)"')
    if status == "complete" or status == "completed" or status == "finished" then
        return true
    end

    local percent_finished = tonumber(content:match('%["percent_finished"%]%s*=%s*([%d%.]+)'))
    return percent_finished ~= nil and percent_finished >= 1
end


function Methods:isChapterPathFinishedInKoreader(chapter_path)
    return self:isKoreaderMetadataFinished(self:getKoreaderMetadataPathForDocument(chapter_path))
end


function Methods:getKoreaderHistoryPath()
    if not SuwayomiSettings.getSettingsDir then
        return nil
    end

    local settings_dir = SuwayomiSettings:getSettingsDir()
    if not settings_dir or settings_dir == "" then
        return nil
    end

    return settings_dir .. "/history.lua"
end


function Methods:loadKoreaderHistoryPaths()
    local history_path = self:getKoreaderHistoryPath()
    local handle = history_path and io.open(history_path, "r")
    if not handle then
        return {}
    end

    local content = handle:read("*a") or ""
    handle:close()

    local loader = loadstring(content)
    if not loader then
        return {}
    end

    setfenv(loader, {})
    local ok, history = pcall(loader)
    if not ok or type(history) ~= "table" then
        return {}
    end

    local paths = {}
    for _, entry in pairs(history) do
        if type(entry) == "table" and type(entry.file) == "string" and entry.file ~= "" then
            paths[entry.file] = true
        end
    end
    return paths
end


function Methods:getCurrentDocumentPath()
    if not self.ui then
        return nil
    end

    local document = self.ui.document
    return self.ui.document_path
        or self.ui.document_pathname
        or (document and (document.file or document.filename or document.path))
end


function Methods:isCurrentDocumentFinished()
    local doc_settings = self.ui and self.ui.doc_settings
    if not doc_settings or not doc_settings.readSetting then
        return false
    end

    local summary = doc_settings:readSetting("summary")
    local status = summary and summary.status
    return status == "finished" or status == "complete" or status == "completed"
end


KoreaderMetadata.methods = Methods

return KoreaderMetadata
