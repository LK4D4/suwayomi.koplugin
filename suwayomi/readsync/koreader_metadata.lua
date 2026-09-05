-- Boundary: KoreaderMetadata.
--
-- Responsibility: Resolves KOReader sidecar locations and owns bounded metadata/history helpers.
-- Owned state: Accepts filesystem paths from downloaded chapters/current documents and validates table/file state before trusting it.
-- Dependencies: Suwayomi settings, KOReader DocSettings location APIs, and the filesystem adapter.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local SuwayomiSettings = require("suwayomi/settings")

local KoreaderMetadata = {}
KoreaderMetadata.__index = KoreaderMetadata
local MAX_KOREADER_LUA_BYTES = 64 * 1024

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function KoreaderMetadata:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function readBoundedLuaFile(path)
    local handle = path and io.open(path, "r")
    if not handle then
        return nil
    end

    local content = handle:read(MAX_KOREADER_LUA_BYTES + 1) or ""
    handle:close()
    if #content > MAX_KOREADER_LUA_BYTES then
        return nil
    end
    return content
end

function Methods:getKoreaderMetadataPathForDocument(document_path)
    if not document_path or document_path == "" then
        return nil
    end

    local DocSettings = require("docsettings")
    local metadata_path = DocSettings:findSidecarFile(document_path)

    local filename = DocSettings.getSidecarFilename(document_path)
    local preferred_path = DocSettings:getSidecarDir(document_path) .. "/" .. filename
    local fs = require("suwayomi/fs")
    local function inspectMode(path)
        local mode, message, code = fs.attributes(path, "mode")
        -- KOReader's finder discards stat errors. Only missing paths are safe
        -- to treat as absent; keep other failures visible to cleanup retries.
        if not mode and (message or code) and code ~= 2 and code ~= 20 then
            error("cannot inspect KOReader metadata", 0)
        end
        return mode
    end
    -- findSidecarFile ignores backups. Return their primary path so cleanup can
    -- remove both files without opening DocSettings (which can delete bad data).
    local paths = { preferred_path }
    local locations = { "doc", "dir" }
    local hash_enabled = DocSettings.isHashLocationEnabled()
    if DocSettings.getSidecarStorage then
        local hash_root = DocSettings.getSidecarStorage("hash")
        if hash_root then
            -- KOReader caches failed root inspections as disabled.
            local hash_mode = inspectMode(hash_root)
            hash_enabled = hash_enabled or hash_mode == "directory"
        end
    end
    if hash_enabled then
        locations[#locations + 1] = "hash"
    end
    for _, location in ipairs(locations) do
        local directory = DocSettings:getSidecarDir(document_path, location)
        -- Hashing failure silently falls back to document storage in KOReader.
        -- Preserve the archive until its actual hash sidecar can be resolved.
        if location == "hash" and directory == DocSettings:getSidecarDir(document_path, "doc") then
            error("cannot resolve KOReader hash metadata", 0)
        end
        paths[#paths + 1] = directory .. "/" .. filename
    end
    if DocSettings.getHistoryPath then
        paths[#paths + 1] = DocSettings:getHistoryPath(document_path)
    end
    if metadata_path then
        paths[#paths + 1] = metadata_path
    end
    local existing_path
    local cleanup_paths, seen = {}, {}
    for _, path in ipairs(paths) do
        if not seen[path] then
            seen[path] = true
            cleanup_paths[#cleanup_paths + 1] = path
            local primary_exists = inspectMode(path) == "file"
            local backup_exists = inspectMode(path .. ".old") == "file"
            if primary_exists or backup_exists then
                existing_path = existing_path or path
            end
        end
    end
    return metadata_path or existing_path or preferred_path, cleanup_paths
end


function Methods:ensureDirectory(path)
    if not path or path == "" then
        return false
    end

    local ok, lfs = pcall(require, "suwayomi/fs")
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
    local metadata = {
        doc_path = chapter_path,
    }
    local resolved, metadata_path = pcall(self.getKoreaderMetadataPathForDocument, self, chapter_path)
    if not resolved then
        return metadata, nil
    end

    local content = readBoundedLuaFile(metadata_path)
    if not content then
        return metadata, metadata_path
    end
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
    local content = readBoundedLuaFile(metadata_path)
    if not content then
        return false
    end
    local status = content:match('%["status"%]%s*=%s*"([^"]+)"')
    if status == "complete" or status == "completed" or status == "finished" then
        return true
    end

    local percent_finished = tonumber(content:match('%["percent_finished"%]%s*=%s*([%d%.]+)'))
    return percent_finished ~= nil and percent_finished >= 1
end


function Methods:isChapterPathFinishedInKoreader(chapter_path)
    local resolved, metadata_path = pcall(self.getKoreaderMetadataPathForDocument, self, chapter_path)
    return resolved and self:isKoreaderMetadataFinished(metadata_path) or false
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
    local content = readBoundedLuaFile(history_path)
    if not content then
        return {}
    end
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
