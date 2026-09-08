-- Boundary: private ZIP integrity inspection and embedded publication metadata.
-- Reads bounded headers and streams every entry; never extracts archive contents.
local lfs = require("suwayomi/fs")
local Archive = {}
local MARKER = "\nSuwayomi-Archive-v1:"
local BUFFER_SIZE = 65536

local function validId(value)
    return type(value) == "string" and #value == 32 and value:match("^[0-9a-f]+$") ~= nil
end

function Archive.newAttemptId()
    -- OS entropy is independent across forked workers and process restarts.
    local handle, err = io.open("/dev/urandom", "rb")
    if not handle then return nil, err or "Could not obtain download attempt entropy." end
    local bytes = handle:read(16)
    local closed, close_error = handle:close()
    if not bytes or #bytes ~= 16 or not closed then
        return nil, close_error or "Could not read download attempt entropy."
    end
    return (bytes:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end

local function u16(bytes, index)
    return bytes:byte(index) + bytes:byte(index + 1) * 256
end

local function u32(bytes, index)
    return u16(bytes, index) + u16(bytes, index + 2) * 65536
end

local function flag(value, mask)
    return value % (mask * 2) >= mask
end

local function fail(state, message)
    error({ state = state, error = message }, 0)
end

local function readAt(handle, offset, length)
    local position, err = handle:seek("set", offset)
    if not position then fail("unverified", err or "Could not seek chapter archive.") end
    if length == 0 then return "" end
    local bytes, read_error = handle:read(length)
    if not bytes or #bytes ~= length then
        -- A read failure is not evidence of damage, even when it looks like EOF.
        fail("unverified", read_error or "Could not read chapter archive.")
    end
    return bytes
end

local function endRecord(handle)
    local size, err = handle:seek("end")
    if not size then fail("unverified", err or "Could not inspect chapter archive size.") end
    if size < 22 then fail("damaged", "Chapter archive is truncated.") end
    local tail_size = math.min(size, 65557)
    local tail = readAt(handle, size - tail_size, tail_size)
    for index = #tail - 21, 1, -1 do
        if tail:sub(index, index + 3) == "PK\005\006"
            and index + 21 + u16(tail, index + 20) == #tail then
            return {
                size = size,
                offset = size - tail_size + index - 1,
                disk = u16(tail, index + 4),
                central_disk = u16(tail, index + 6),
                disk_entries = u16(tail, index + 8),
                entries = u16(tail, index + 10),
                central_size = u32(tail, index + 12),
                central_offset = u32(tail, index + 16),
                comment = tail:sub(index + 22),
            }
        end
    end
    fail("damaged", "Chapter archive has no complete ZIP end record.")
end

local function metadata(comment)
    local id, count = comment:match("\nSuwayomi%-Archive%-v1:([0-9a-f]+):([0-9]+)\n$")
    if not validId(id) or not tonumber(count) or tonumber(count) > 4294967294 then
        return nil, nil, comment:find(MARKER, 1, true) and "Invalid chapter archive validation metadata." or nil
    end
    count = tonumber(count)
    return id, count > 0 and count or nil
end

local function withFile(path, mode, callback)
    local handle, err = io.open(path, mode)
    if not handle then return nil, { state = "unverified", error = err or "Could not open chapter archive." } end
    local ok, result = pcall(callback, handle)
    local closed, close_error = handle:close()
    if not ok then
        return nil, type(result) == "table" and result or { state = "unverified", error = tostring(result) }
    end
    if not closed then return nil, { state = "unverified", error = close_error or "Could not close chapter archive." } end
    return result
end

function Archive.attemptId(path)
    local record, err = withFile(path, "rb", endRecord)
    if not record then return nil, err.error end
    local attempt_id = metadata(record.comment)
    return attempt_id
end

function Archive.identity(path)
    local attributes, err = lfs.attributes(path)
    if type(attributes) ~= "table" or attributes.mode ~= "file" then
        return nil, err or "Could not inspect chapter archive identity."
    end
    local record, record_error = withFile(path, "rb", endRecord)
    -- Broken ZIPs still have an observational stat identity.
    if not record and record_error.state ~= "damaged" then return nil, record_error.error end
    local id = record and metadata(record.comment) or ""
    return table.concat({
        tostring(attributes.dev or ""), tostring(attributes.ino or ""),
        tostring(attributes.size or ""), tostring(attributes.modification or ""),
        tostring(attributes.change or ""), id or "",
    }, ":")
end

function Archive.stamp(path, attempt_id, expected_pages)
    if not validId(attempt_id) then return nil, "Invalid download attempt ID." end
    if expected_pages ~= nil and (type(expected_pages) ~= "number" or expected_pages < 1
        or expected_pages > 4294967294 or expected_pages % 1 ~= 0) then
        return nil, "Invalid expected chapter page count."
    end
    local result, err = withFile(path, "r+b", function(handle)
        local record = endRecord(handle)
        if expected_pages == nil then
            local _, captured_pages, metadata_error = metadata(record.comment)
            if metadata_error then fail("damaged", metadata_error) end
            expected_pages = captured_pages
        end
        -- Append rather than truncate an export's existing user comment/metadata.
        local comment = record.comment .. MARKER .. attempt_id .. ":" .. string.format("%.0f", expected_pages or 0) .. "\n"
        if #comment > 65535 then fail("unverified", "Chapter archive comment has no room for validation metadata.") end
        if not handle:seek("set", record.offset + 20) then fail("unverified", "Could not seek chapter archive metadata.") end
        local written, write_error = handle:write(string.char(#comment % 256, math.floor(#comment / 256)), comment)
        if not written then fail("unverified", write_error or "Could not write chapter archive metadata.") end
        return true
    end)
    if not result then return nil, err.error end
    return true
end

local function inspectStructure(handle)
    local record = endRecord(handle)
    if record.disk ~= 0 or record.central_disk ~= 0 or record.disk_entries ~= record.entries then
        fail("unverified", "Multi-volume ZIP archives are not supported for verification.")
    end
    if record.entries == 65535 or record.central_size == 4294967295 or record.central_offset == 4294967295 then
        fail("unverified", "ZIP64 archive verification is not supported.")
    end
    if record.central_offset + record.central_size ~= record.offset then
        -- ZIP64 may include its own end records even when the ordinary fields fit.
        if record.offset >= 20 and readAt(handle, record.offset - 20, 4) == "PK\006\007" then
            fail("unverified", "ZIP64 archive verification is not supported.")
        end
        fail("damaged", "Chapter archive central directory has invalid bounds.")
    end
    if record.entries == 0 or record.central_size < 46 or record.central_offset < 30 then
        fail("damaged", "Chapter archive contains no pages.")
    end
    -- Ported from the downloader's ZIP structure checks. Read one bounded header
    -- at a time, not the whole central directory or any uncompressed entry.
    -- ZIP32 limits this offset index to fewer than 65535 compact records.
    local offsets = {}
    local position = record.central_offset
    for _ = 1, record.entries do
        if position + 46 > record.offset then fail("damaged", "Chapter archive central directory is truncated.") end
        local entry = readAt(handle, position, 46)
        if entry:sub(1, 4) ~= "PK\001\002" then fail("damaged", "Invalid chapter archive central entry.") end
        local flags, method = u16(entry, 9), u16(entry, 11)
        local crc, compressed, uncompressed = u32(entry, 17), u32(entry, 21), u32(entry, 25)
        local name_length, extra_length, comment_length = u16(entry, 29), u16(entry, 31), u16(entry, 33)
        local offset = u32(entry, 43)
        if compressed == 4294967295 or uncompressed == 4294967295 or offset == 4294967295 then
            fail("unverified", "ZIP64 archive verification is not supported.")
        end
        if flag(flags, 1) or flag(flags, 64) or flag(flags, 8192) then
            fail("unverified", "Encrypted chapter archives cannot be verified.")
        end
        if u16(entry, 35) ~= 0 then fail("unverified", "Multi-volume ZIP archives cannot be verified.") end
        if name_length == 0 or position + 46 + name_length + extra_length + comment_length > record.offset
            or offset + 30 > record.central_offset then
            fail("damaged", "Invalid chapter archive entry bounds.")
        end
        local local_header = readAt(handle, offset, 30)
        local local_flags = u16(local_header, 7)
        local local_name_length, local_extra_length = u16(local_header, 27), u16(local_header, 29)
        local payload_end = offset + 30 + local_name_length + local_extra_length + compressed
        if local_header:sub(1, 4) ~= "PK\003\004" or flags ~= local_flags
            or method ~= u16(local_header, 9) or name_length ~= local_name_length
            or payload_end > record.central_offset then
            fail("damaged", "Chapter archive local header disagrees with its central entry.")
        end
        if readAt(handle, position + 46, name_length) ~= readAt(handle, offset + 30, name_length) then
            fail("damaged", "Chapter archive entry names disagree.")
        end
        local descriptor = flag(flags, 8)
        if not descriptor and (compressed ~= u32(local_header, 19)
            or uncompressed ~= u32(local_header, 23) or crc ~= u32(local_header, 15)) then
            fail("damaged", "Chapter archive entry sizes or checksums disagree.")
        end
        offsets[#offsets + 1] = { offset, payload_end, descriptor, crc, compressed, uncompressed }
        position = position + 46 + name_length + extra_length + comment_length
    end
    if position ~= record.offset then fail("damaged", "Chapter archive entry count disagrees with its directory.") end
    table.sort(offsets, function(left, right) return left[1] < right[1] end)
    if offsets[1][1] ~= 0 then fail("unverified", "Prefixed ZIP archives cannot be verified.") end
    for index, entry in ipairs(offsets) do
        local next_offset = offsets[index + 1] and offsets[index + 1][1] or record.central_offset
        local gap = next_offset - entry[2]
        if entry[3] then
            if gap ~= 12 and gap ~= 16 then fail("damaged", "Chapter archive data descriptor is incomplete.") end
            local descriptor = readAt(handle, entry[2], gap)
            local start = gap == 16 and 5 or 1
            if (gap == 16 and descriptor:sub(1, 4) ~= "PK\007\008") or u32(descriptor, start) ~= entry[4]
                or u32(descriptor, start + 4) ~= entry[5] or u32(descriptor, start + 8) ~= entry[6] then
                fail("damaged", "Chapter archive data descriptor disagrees with its entry.")
            end
        elseif gap ~= 0 then
            fail("damaged", "Chapter archive entries overlap or have missing data.")
        end
    end
    local metadata_error
    record.attempt_id, record.expected_pages, metadata_error = metadata(record.comment)
    if metadata_error then fail("damaged", metadata_error) end
    return record
end

local function nativeError(ffi, native, reader)
    local message = native.archive_error_string(reader)
    message = message ~= nil and ffi.string(message) or "Native chapter archive verification failed."
    local lower = message:lower()
    -- Only explicit integrity diagnostics establish damage. Codec, encryption,
    -- allocation, permissions and unknown native errors remain inconclusive.
    local damaged = lower:find("crc", 1, true) or lower:find("checksum", 1, true)
        or lower:find("truncated zip", 1, true) or lower:find("corrupt", 1, true)
        or lower:find("inconsistent", 1, true) or lower:find("invalid compressed data", 1, true)
        or lower:find("zip compressed data is wrong size", 1, true)
        or lower:find("zip uncompressed data is ", 1, true)
        or lower:find("zip decompression failed (-3)", 1, true)
    fail(damaged and "damaged" or "unverified", message)
end

local function inspectContents(path, expected_entries)
    local ffi = require("ffi")
    require("ffi/libarchive_h")
    local native = ffi.loadlib("archive", "13")
    local reader = native.archive_read_new()
    if reader == nil then fail("unverified", "Could not allocate chapter archive reader.") end
    reader = ffi.gc(reader, native.archive_free)
    local entry = native.archive_entry_new()
    if entry == nil then
        ffi.gc(reader, nil)
        native.archive_free(reader)
        fail("unverified", "Could not allocate chapter archive entry.")
    end
    entry = ffi.gc(entry, native.archive_entry_free)
    local ok, result = pcall(function()
        if native.archive_read_support_format_all(reader) ~= 0 or native.archive_read_support_filter_all(reader) ~= 0 then
            nativeError(ffi, native, reader)
        end
        if native.archive_read_open_filename(reader, path, BUFFER_SIZE) ~= 0 then nativeError(ffi, native, reader) end
        local buffer = ffi.new("uint8_t[?]", BUFFER_SIZE)
        local pages, entries = 0, 0
        while true do
            local status = native.archive_read_next_header2(reader, entry)
            if status == 1 then break end
            if status ~= 0 then nativeError(ffi, native, reader) end
            entries = entries + 1
            local pathname = native.archive_entry_pathname(entry)
            local name = pathname ~= nil and ffi.string(pathname):lower() or ""
            local is_page = native.archive_entry_filetype(entry) == 32768
                and (name:match("%.jpe?g$") or name:match("%.png$")
                or name:match("%.webp$") or name:match("%.gif$") or name:match("%.bmp$")
                or name:match("%.tiff?$") or name:match("%.avif$") or name:match("%.jxl$"))
            local count = 0
            while true do
                -- Drain to EOF, including a final read after the advertised size:
                -- libarchive reports ZIP CRC failures at the end of entry data.
                local bytes = tonumber(native.archive_read_data(reader, buffer, BUFFER_SIZE))
                if bytes < 0 then nativeError(ffi, native, reader) end
                if bytes == 0 then break end
                count = count + bytes
            end
            if count ~= tonumber(native.archive_entry_size(entry)) then fail("damaged", "Chapter archive entry size does not match its contents.") end
            if is_page then
                if count == 0 then fail("damaged", "Chapter archive contains an empty page.") end
                pages = pages + 1
            end
        end
        if entries ~= expected_entries then fail("unverified", "Native archive reader did not inspect every ZIP entry.") end
        if pages == 0 then fail("damaged", "Chapter archive contains no image pages.") end
        if native.archive_read_close(reader) ~= 0 then nativeError(ffi, native, reader) end
        return pages
    end)
    ffi.gc(entry, nil)
    native.archive_entry_free(entry)
    ffi.gc(reader, nil)
    native.archive_free(reader)
    if not ok then error(result, 0) end
    return result
end

function Archive.validate(path)
    local identity, identity_error = Archive.identity(path)
    local record, err = withFile(path, "rb", inspectStructure)
    local result = { identity = identity }
    if not record then
        result.state, result.error = err.state, err.error
    elseif not identity then
        result.state, result.error = "unverified", identity_error
    else
        result.expected_pages = record.expected_pages
        local ok, pages = pcall(inspectContents, path, record.entries)
        if ok then
            result.pages = pages
            if record.expected_pages and pages ~= record.expected_pages then
                result.state, result.error = "damaged", "Chapter archive page count does not match its captured expected count."
            else
                result.state = "valid"
            end
        else
            result.state = type(pages) == "table" and pages.state or "unverified"
            result.error = type(pages) == "table" and pages.error or tostring(pages)
        end
    end
    local current_identity = Archive.identity(path)
    if identity and current_identity ~= identity then
        result.state, result.error, result.identity = "unverified", "Chapter archive changed during verification.", nil
    end
    return result
end

return Archive
