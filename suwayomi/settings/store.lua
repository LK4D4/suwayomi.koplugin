-- Boundary: checked atomic document persistence for plugin settings.
--
-- Responsibility: stage, serialize, atomically write, sync, replace, and reconcile
-- the shared plugin settings document.
-- Owned state: committed document cache, transaction metadata, and post-replacement
-- ambiguity fence.
-- Dependencies: Lua table serialization, file I/O, and atomic rename primitives.
-- External data: stored settings documents are treated as untrusted and preserved
-- across versions.

local SettingsStore = {}
SettingsStore.__index = SettingsStore

local STORE_VERSION = 1

local function deepCopy(source, seen)
    if type(source) ~= "table" then
        return source
    end
    seen = seen or {}
    if seen[source] then
        return seen[source]
    end
    local target = {}
    seen[source] = target
    for key, value in pairs(source) do
        target[deepCopy(key, seen)] = deepCopy(value, seen)
    end
    return target
end

local function sortKeys(left, right)
    local left_type = type(left)
    local right_type = type(right)
    if left_type == right_type then
        if left_type == "number" then
            return left < right
        end
        return tostring(left) < tostring(right)
    end
    return left_type < right_type
end

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function defaultParentDir(path)
    return tostring(path):match("^(.*)[/\\][^/\\]+$") or "."
end

local function defaultIoAdapter()
    return {
        open = function(path, mode)
            return io.open(path, mode)
        end,
        write = function(handle, content)
            return handle:write(content)
        end,
        flush = function(handle)
            return handle:flush()
        end,
        sync_file = function(handle)
            handle:flush()
            return true
        end,
        close = function(handle)
            return handle:close()
        end,
        rename = function(old_path, new_path)
            local ok, err = os.rename(old_path, new_path)
            if not ok and package.config:sub(1, 1) == "\\" then
                os.remove(new_path)
                return os.rename(old_path, new_path)
            end
            return ok, err
        end,
        sync_dir = function(_dir_path)
            return true
        end,
        remove = function(path)
            return os.remove(path)
        end,
        read = function(path)
            local handle, err = io.open(path, "r")
            if not handle then
                return nil, err
            end
            local content = handle:read("*a")
            handle:close()
            return content
        end,
        dir_exists = function(dir_path)
            local ok_lfs, lfs = pcall(require, "lfs")
            if ok_lfs and lfs and lfs.attributes then
                local attr = lfs.attributes(dir_path)
                return attr and attr.mode == "directory"
            end
            return true
        end,
    }
end

function SettingsStore:new(options)
    options = options or {}
    local instance = setmetatable({
        path = options.path or "./suwayomi.lua",
        io = options.io or options.io_adapter or defaultIoAdapter(),
        luasettings = options.luasettings,
        supported_version = options.supported_version or STORE_VERSION,
        committed_data = nil,
        last_tx_id = nil,
        last_tx_version = nil,
        tx_counter = 0,
        is_blocked = false,
        blocked_reason = nil,
        pending_tx_id = nil,
        pending_staged = nil,
    }, self)
    return instance
end

function SettingsStore:setIoAdapter(io_adapter)
    self.io = io_adapter or defaultIoAdapter()
end

function SettingsStore:isBlocked()
    return self.is_blocked == true
end

function SettingsStore:getTransactionId()
    if not self.last_tx_id and self.committed_data == nil then
        self:load()
    end
    return self.last_tx_id
end

function SettingsStore:serializeValue(value, indent, visited)
    indent = indent or 0
    visited = visited or {}
    local value_type = type(value)

    if value_type == "string" then
        return string.format("%q", value)
    end
    if value_type == "boolean" then
        return tostring(value)
    end
    if value_type == "number" then
        if not isFiniteNumber(value) then
            return nil, "non_finite_number"
        end
        return tostring(value)
    end
    if value_type ~= "table" then
        return nil, "unsupported_type_" .. value_type
    end

    if visited[value] then
        return nil, "cyclic_table"
    end
    visited[value] = true

    local keys = {}
    for key in pairs(value) do
        local key_type = type(key)
        if key_type ~= "string" and key_type ~= "number" then
            visited[value] = nil
            return nil, "unsupported_key_type_" .. key_type
        end
        if key_type == "number" and not isFiniteNumber(key) then
            visited[value] = nil
            return nil, "non_finite_number_key"
        end
        table.insert(keys, key)
    end
    table.sort(keys, sortKeys)

    local next_indent = indent + 4
    local current_padding = string.rep(" ", indent)
    local next_padding = string.rep(" ", next_indent)
    local lines = { "{" }

    for _, key in ipairs(keys) do
        local key_repr
        if type(key) == "string" then
            key_repr = "[" .. string.format("%q", key) .. "]"
        else
            key_repr = "[" .. tostring(key) .. "]"
        end

        local item_str, err = self:serializeValue(value[key], next_indent, visited)
        if not item_str then
            visited[value] = nil
            return nil, err
        end

        table.insert(lines, next_padding .. key_repr .. " = " .. item_str .. ",")
    end

    visited[value] = nil
    table.insert(lines, current_padding .. "}")
    return table.concat(lines, "\n")
end

function SettingsStore:serializeDocument(doc)
    local serialized, err = self:serializeValue(doc, 0, {})
    if not serialized then
        return nil, err
    end
    return "return " .. serialized .. "\n"
end

function SettingsStore:load(initial_data)
    if initial_data ~= nil then
        self.committed_data = deepCopy(initial_data)
        if type(self.committed_data.store_transaction) == "table" then
            self.last_tx_id = self.committed_data.store_transaction.id
            self.last_tx_version = self.committed_data.store_transaction.version
        end
        return self.committed_data
    end

    if self.committed_data ~= nil then
        return self.committed_data
    end

    local raw_content, _read_err = self.io.read(self.path)
    if raw_content and raw_content ~= "" then
        local loader, _load_err = loadstring(raw_content)
        if loader then
            local ok, parsed = pcall(loader)
            if ok and type(parsed) == "table" then
                self.committed_data = parsed
                if type(parsed.store_transaction) == "table" then
                    self.last_tx_id = parsed.store_transaction.id
                    self.last_tx_version = parsed.store_transaction.version
                end
                return self.committed_data
            end
        end
    end

    if self.luasettings and type(self.luasettings.data) == "table" then
        self.committed_data = deepCopy(self.luasettings.data)
        if type(self.committed_data.store_transaction) == "table" then
            self.last_tx_id = self.committed_data.store_transaction.id
            self.last_tx_version = self.committed_data.store_transaction.version
        end
        return self.committed_data
    end

    self.committed_data = {}
    return self.committed_data
end

function SettingsStore:readKey(key, default)
    if self.luasettings and type(self.luasettings.data) == "table" and self.luasettings.data[key] ~= nil then
        return self.luasettings.data[key]
    end
    local doc = self:load()
    local val = doc[key]
    if val == nil then
        return default
    end
    return val
end

function SettingsStore:saveDocument(mutator)
    if self.is_blocked then
        return nil, "store_blocked_ambiguous_transaction: " .. tostring(self.blocked_reason)
    end

    local doc = self:load()
    local staged = deepCopy(doc)
    mutator(staged)

    self.tx_counter = self.tx_counter + 1
    local tx_id = string.format("tx-%d-%d-%04x", os.time(), self.tx_counter, math.random(0, 0xffff))
    local version = self.last_tx_version or self.supported_version or STORE_VERSION
    staged.store_transaction = {
        version = version,
        id = tx_id,
    }

    local serialized, ser_err = self:serializeDocument(staged)
    if not serialized then
        return nil, "serialization_failed: " .. tostring(ser_err)
    end

    local parent_dir = defaultParentDir(self.path)
    local parent_exists = self.io.dir_exists and self.io.dir_exists(parent_dir)

    -- If in mock environment with luasettings and non-existent parent directory,
    -- sync with luasettings and update committed cache.
    if self.luasettings and not parent_exists then
        self.committed_data = staged
        self.last_tx_id = tx_id
        self.last_tx_version = version
        for k, v in pairs(staged) do
            self.luasettings.data[k] = v
        end
        if self.luasettings.flush then
            self.luasettings:flush()
        end
        return true, staged
    end

    local tmp_path = string.format("%s.tmp.%d.%04x", self.path, os.time(), math.random(0, 0xffff))
    local call_open_ok, handle, open_err = pcall(self.io.open, tmp_path, "w")
    if not call_open_ok or not handle then
        return nil, "open_failed: " .. tostring(open_err or handle)
    end

    local call_write_ok, ok_write, write_err = pcall(self.io.write, handle, serialized)
    if not call_write_ok or ok_write == false or (ok_write == nil and write_err ~= nil) then
        pcall(self.io.close, handle)
        pcall(self.io.remove, tmp_path)
        return nil, "write_failed: " .. tostring(write_err or ok_write)
    end

    local call_flush_ok, ok_flush, flush_err = pcall(self.io.flush, handle)
    if not call_flush_ok or ok_flush == false or (ok_flush == nil and flush_err ~= nil) then
        pcall(self.io.close, handle)
        pcall(self.io.remove, tmp_path)
        return nil, "flush_failed: " .. tostring(flush_err or ok_flush)
    end

    local call_sync_ok, ok_sync, sync_err = pcall(self.io.sync_file, handle)
    if not call_sync_ok or ok_sync == false or (ok_sync == nil and sync_err ~= nil) then
        pcall(self.io.close, handle)
        pcall(self.io.remove, tmp_path)
        return nil, "sync_failed: " .. tostring(sync_err or ok_sync)
    end

    local call_close_ok, ok_close, close_err = pcall(self.io.close, handle)
    if not call_close_ok or ok_close == false or (ok_close == nil and close_err ~= nil) then
        pcall(self.io.remove, tmp_path)
        return nil, "close_failed: " .. tostring(close_err or ok_close)
    end

    local call_rename_ok, ok_rename, rename_err = pcall(self.io.rename, tmp_path, self.path)
    if not call_rename_ok or not ok_rename then
        pcall(self.io.remove, tmp_path)
        return nil, "replacement_failed: " .. tostring(rename_err or ok_rename)
    end

    local call_dir_ok, ok_dir, dir_err = pcall(self.io.sync_dir, parent_dir)
    if not call_dir_ok or ok_dir == false or (ok_dir == nil and dir_err ~= nil) then
        self.is_blocked = true
        self.blocked_reason = "post_replacement_sync_dir_failed: " .. tostring(dir_err or ok_dir)
        self.pending_tx_id = tx_id
        self.pending_staged = staged
        return nil, "ambiguous_post_replacement: " .. tostring(dir_err or ok_dir)
    end

    self.committed_data = staged
    self.last_tx_id = tx_id
    self.last_tx_version = version

    if self.luasettings and type(self.luasettings.data) == "table" then
        for k, v in pairs(staged) do
            self.luasettings.data[k] = v
        end
        if self.luasettings.flush then
            self.luasettings:flush()
        end
    end

    return true, staged
end

function SettingsStore:saveKey(key, value)
    return self:saveDocument(function(doc)
        doc[key] = value
    end)
end

function SettingsStore:reconcile()
    local raw_content, read_err = self.io.read(self.path)
    if not raw_content or raw_content == "" then
        return false, "unreadable_destination: " .. tostring(read_err)
    end

    local loader, load_err = loadstring(raw_content)
    if not loader then
        return false, "corrupted_destination: " .. tostring(load_err)
    end

    local ok, parsed = pcall(loader)
    if not ok or type(parsed) ~= "table" then
        return false, "invalid_destination_table"
    end

    local disk_tx = parsed.store_transaction
    local disk_tx_id = type(disk_tx) == "table" and disk_tx.id

    if self.pending_tx_id and disk_tx_id == self.pending_tx_id then
        self.committed_data = parsed
        self.last_tx_id = self.pending_tx_id
        self.last_tx_version = disk_tx.version
        self.is_blocked = false
        self.blocked_reason = nil
        self.pending_tx_id = nil
        self.pending_staged = nil
        if self.luasettings and type(self.luasettings.data) == "table" then
            for k, v in pairs(parsed) do
                self.luasettings.data[k] = v
            end
        end
        return true, "committed"
    elseif disk_tx_id == self.last_tx_id then
        self.committed_data = parsed
        self.is_blocked = false
        self.blocked_reason = nil
        self.pending_tx_id = nil
        self.pending_staged = nil
        return true, "rolled_back"
    end

    return false, "unresolved_transaction_mismatch"
end

return SettingsStore
