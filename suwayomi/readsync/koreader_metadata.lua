-- Boundary: KoreaderMetadata.
--
-- Responsibility: Separates readable KOReader candidates from cleanup paths, preserves metadata during read updates/replacement, and owns bounded metadata helpers.
-- Owned state: Accepts filesystem paths from downloaded chapters/current documents and validates table/file state before trusting it.
-- Dependencies: KOReader DocSettings location APIs and the filesystem adapter.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

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

    local content = handle:read(MAX_KOREADER_LUA_BYTES + 1)
    local closed, close_error = handle:close()
    if not content or (not closed and close_error) or #content > MAX_KOREADER_LUA_BYTES then
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
    -- Cleanup needs primary paths even for backup-only metadata. These paths
    -- are not the ordered candidates that native DocSettings will read.
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
    local hash_path
    for _, location in ipairs(locations) do
        local directory = DocSettings:getSidecarDir(document_path, location)
        -- Hashing failure silently falls back to document storage in KOReader.
        -- Preserve the archive until its actual hash sidecar can be resolved.
        if location == "hash" and directory == DocSettings:getSidecarDir(document_path, "doc") then
            error("cannot resolve KOReader hash metadata", 0)
        end
        paths[#paths + 1] = directory .. "/" .. filename
        if location == "hash" then hash_path = directory .. "/" .. filename end
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
    return metadata_path or existing_path or preferred_path, cleanup_paths, hash_path
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

-- Repairs keep the document path but change its content hash. Copy raw hash
-- sidecars to document storage before replacing bytes; never open/flush native
-- DocSettings, whose candidate validation and purge can delete the originals.
function KoreaderMetadata.preserveForReplacement(document_path, attempt_id)
    local temporary_path, temporary_owned
    local input, output
    local ok, failure = pcall(function()
        assert(type(attempt_id) == "string" and #attempt_id == 32
            and attempt_id:match("^[0-9a-f]+$"), "Invalid download attempt ID.")
        local DocSettings = require("docsettings")
        local fs = require("suwayomi/fs")
        local _, paths, hash_path = Methods.getKoreaderMetadataPathForDocument(Methods, document_path)
        if not hash_path then return end

        local function mode(path)
            local value, message, code = fs.symlinkattributes(path, "mode")
            if not value and (message or code) and code ~= 2 and code ~= 20 then
                error("Could not inspect metadata: " .. path .. ": " .. tostring(message), 0)
            end
            return value
        end
        local function readRaw(path)
            local kind = mode(path)
            if not kind then return nil end
            assert(kind == "file", "Unsupported metadata file: " .. path)
            input = assert(io.open(path, "rb"))
            local content = assert(input:read("*a"))
            local closed, close_error = input:close()
            input = nil
            assert(closed, close_error)
            return content
        end

        local source = { readRaw(hash_path), readRaw(hash_path .. ".old") }
        if source[1] == nil and source[2] == nil then return end
        local directory = DocSettings:getSidecarDir(document_path, "doc")
        local destination = directory .. "/" .. DocSettings.getSidecarFilename(document_path)
        -- These legacy candidates are read by open(), but not findSidecarFile().
        paths[#paths + 1] = directory .. "/" .. document_path:match("[^/]+$") .. ".lua"
        paths[#paths + 1] = document_path .. ".kpdfview.lua"
        for _, path in ipairs(paths) do
            if path ~= hash_path then
                for index, suffix in ipairs({ "", ".old" }) do
                    local existing = readRaw(path .. suffix)
                    assert(existing == nil or existing == source[index],
                        "Conflicting KOReader metadata: " .. path .. suffix)
                end
            end
        end
        assert(Methods.ensureDirectory(Methods, directory), "Could not create document metadata folder.")
        for index, suffix in ipairs({ "", ".old" }) do
            local content = source[index]
            local final_path = destination .. suffix
            if content ~= nil and readRaw(final_path) == nil then
                temporary_path = final_path .. "." .. attempt_id .. ".part"
                assert(mode(temporary_path) == nil, "Metadata temporary path already exists: " .. temporary_path)
                output = assert(io.open(temporary_path, "wb"))
                temporary_owned = true
                assert(output:write(content))
                local closed, close_error = output:close()
                output = nil
                assert(closed, close_error)
                -- A competing sidecar is not ours to replace.
                assert(mode(final_path) == nil, "Metadata destination appeared during repair: " .. final_path)
                assert(os.rename(temporary_path, final_path))
                temporary_owned = false
            end
        end
    end)
    if input then pcall(input.close, input) end
    if output then pcall(output.close, output) end
    if not ok then
        if temporary_owned then
            local removed, remove_error = os.remove(temporary_path)
            if not removed then failure = tostring(failure) .. " Could not remove metadata temporary file: " .. tostring(remove_error) end
        end
        return false, tostring(failure)
    end
    return true
end


-- DocSettings:open sorts native candidates by mtime, not findSidecarFile's
-- preferred location. Do not call open(): it removes invalid candidates.
local function getReadableCandidate(chapter_path, hash_path)
    local DocSettings = require("docsettings")
    local fs = require("suwayomi/fs")
    local candidates, seen = {}, {}
    local function add(path, primary)
        if not path or seen[path] then return end
        seen[path] = true
        local mode, message, code = fs.attributes(path, "mode")
        if not mode then
            if (message or code) and code ~= 2 and code ~= 20 then
                error("cannot inspect KOReader metadata", 0)
            end
            return
        end
        assert(mode == "file", "unsupported KOReader metadata file")
        local mtime = fs.attributes(path, "modification")
        assert(type(mtime) == "number", "cannot inspect KOReader metadata timestamp")
        local candidate = { path = path, primary = primary or path, mtime = mtime, priority = #candidates + 1 }
        local previous = candidates[#candidates]
        if primary and previous and previous.path == primary then
            previous.mtime = math.max(previous.mtime, mtime)
        end
        candidates[#candidates + 1] = candidate
    end
    local function addPair(path)
        if not path then return end
        add(path)
        add(path .. ".old", path)
    end
    local filename = DocSettings.getSidecarFilename(chapter_path)
    local doc_directory = DocSettings:getSidecarDir(chapter_path, "doc")
    addPair(doc_directory .. "/" .. filename)
    add(doc_directory .. "/" .. chapter_path:match("[^/]+$") .. ".lua")
    addPair(DocSettings:getSidecarDir(chapter_path, "dir") .. "/" .. filename)
    addPair(hash_path)
    if DocSettings.getHistoryPath then addPair(DocSettings:getHistoryPath(chapter_path)) end
    add(chapter_path .. ".kpdfview.lua")
    table.sort(candidates, function(left, right)
        if left.mtime == right.mtime then return left.priority < right.priority end
        return left.mtime > right.mtime
    end)
    return candidates[1]
end

function Methods:loadKoreaderMetadataTable(chapter_path)
    local metadata = {
        doc_path = chapter_path,
    }
    local ok, parsed, metadata_path = pcall(function()
        local preferred_path, _, hash_path = self:getKoreaderMetadataPathForDocument(chapter_path)
        local candidate = getReadableCandidate(chapter_path, hash_path)
        if not candidate then return metadata, preferred_path end

        -- An existing but unreadable/invalid candidate is not absent metadata.
        -- Refuse the update without opening, purging, or overwriting its files.
        local content = assert(readBoundedLuaFile(candidate.path), "cannot read KOReader metadata")
        local loader = assert(loadstring(content))
        setfenv(loader, {})
        local stored = loader()
        assert(type(stored) == "table" and next(stored) ~= nil, "invalid KOReader metadata")
        stored.doc_path = stored.doc_path or chapter_path
        return stored, candidate.primary
    end)
    if ok then return parsed, metadata_path end
    return metadata, nil
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

    return false
end


function Methods:isChapterPathFinishedInKoreader(chapter_path)
    local resolved, metadata_path = pcall(self.getKoreaderMetadataPathForDocument, self, chapter_path)
    return resolved and self:isKoreaderMetadataFinished(metadata_path) or false
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
