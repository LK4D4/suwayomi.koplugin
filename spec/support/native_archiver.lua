-- Linux spec boundary for KOReader's ffi/archiver API; real libarchive throughout.
local ffi = require("ffi")
ffi.cdef[[
struct archive; struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_format_all(struct archive *);
int archive_read_support_filter_all(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header2(struct archive *, struct archive_entry *);
long archive_read_data(struct archive *, void *, size_t);
int archive_read_close(struct archive *);
int archive_free(struct archive *);
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
int archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
const char *archive_error_string(struct archive *);
struct archive *archive_write_new(void);
int archive_write_set_format_by_name(struct archive *, const char *);
int archive_write_open_filename(struct archive *, const char *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
void archive_entry_set_size(struct archive_entry *, int64_t);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
void archive_entry_set_perm(struct archive_entry *, int);
int archive_write_header(struct archive *, struct archive_entry *);
long archive_write_data(struct archive *, const void *, size_t);
int archive_write_close(struct archive *);
]]
local native = ffi.load("libarchive.so.13")
local Native = {}
local Writer = {}

local function message(archive)
    local value = native.archive_error_string(archive)
    return value ~= nil and ffi.string(value) or "Native archive failure"
end

function Writer:new()
    return setmetatable({}, { __index = self })
end

function Writer:open(path, format)
    self.archive = ffi.gc(native.archive_write_new(), native.archive_free)
    if native.archive_write_set_format_by_name(self.archive, format) ~= 0
        or native.archive_write_open_filename(self.archive, path) ~= 0 then
        self.err = message(self.archive)
        return false
    end
    return true
end

function Writer:addFileFromMemory(name, content)
    local entry = ffi.gc(native.archive_entry_new(), native.archive_entry_free)
    native.archive_entry_set_pathname(entry, name)
    native.archive_entry_set_size(entry, #content)
    native.archive_entry_set_filetype(entry, 32768)
    native.archive_entry_set_perm(entry, 420)
    local ok = native.archive_write_header(self.archive, entry) == 0
        and tonumber(native.archive_write_data(self.archive, content, #content)) == #content
    if not ok then self.err = message(self.archive) end
    ffi.gc(entry, nil)
    native.archive_entry_free(entry)
    return ok
end

function Writer:close()
    if not self.archive then return true end
    local ok = native.archive_write_close(self.archive) == 0
    if not ok then self.err = message(self.archive) end
    ffi.gc(self.archive, nil)
    native.archive_free(self.archive)
    self.archive = nil
    return ok
end

Native.Writer = Writer

function Native.install()
    local previous = ffi.loadlib
    ffi.loadlib = function(name, version)
        if name == "archive" and version == "13" then return native end
        return previous(name, version)
    end
    package.loaded["ffi/archiver"] = { Writer = Writer }
    package.loaded["ffi/libarchive_h"] = true
    return function() ffi.loadlib = previous end
end

return Native
