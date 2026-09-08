-- Boundary: proved filesystem identity for one explicitly authorized CBZ.
-- Paths are re-resolved on every check; unsupported identity never grants removal.

local lfs = require("suwayomi/fs")
local FFIUtil = require("ffi/util")
local Identity = {}

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function clean(path)
    if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then return nil end
    path = path:gsub("\\", "/")
    if #path > 1 then path = path:gsub("/+$", "") end
    return path
end

function Identity.resolve(path)
    if not clean(path) or type(FFIUtil.realpath) ~= "function" then return nil end
    local ok, resolved = pcall(FFIUtil.realpath, path)
    return ok and clean(resolved) or nil
end

local function descendant(root, path)
    return root and path and path ~= root
        and path:sub(1, #(root == "/" and root or root .. "/")) == (root == "/" and root or root .. "/")
end

local function attributes(path, symbolic)
    local fn = symbolic and lfs.symlinkattributes or lfs.attributes
    if type(fn) ~= "function" then return nil, "unsupported_identity" end
    local ok, attr, _, code = pcall(fn, path)
    if not ok then return nil, "stat_failed" end
    if attr then return attr end
    -- Error text is platform/localization dependent; only ENOENT proves absence.
    return nil, code == 2 and "missing" or "stat_failed"
end

local function evidence(attr, resolved, root)
    if attr.mode ~= "file" then return nil, "unsafe_path" end
    if not finite(attr.dev) or not finite(attr.ino) or attr.ino <= 0
        or not finite(attr.size) or not finite(attr.change) or not finite(attr.modification) then
        return nil, "unsupported_identity"
    end
    return {
        version = 1, dev = attr.dev, ino = attr.ino, size = attr.size,
        ctime = attr.change, mtime = attr.modification, resolved_path = resolved, resolved_root = root,
    }
end

function Identity.supported(value)
    return type(value) == "table" and value.version == 1
        and finite(value.dev) and finite(value.ino) and value.ino > 0
        and finite(value.size) and finite(value.ctime) and finite(value.mtime)
        and clean(value.resolved_path) ~= nil and clean(value.resolved_root) ~= nil
end

function Identity.same(left, right)
    return Identity.supported(left) and Identity.supported(right)
        and left.dev == right.dev and left.ino == right.ino and left.size == right.size
        and left.ctime == right.ctime and left.mtime == right.mtime
        and left.resolved_path == right.resolved_path and left.resolved_root == right.resolved_root
end

function Identity.inspect(path, root, original)
    local cleaned = clean(path)
    if not cleaned or cleaned:sub(-4):lower() ~= ".cbz" or not clean(root) then
        return nil, "unsafe_path"
    end
    local resolved_root = Identity.resolve(root)
    if not resolved_root then return nil, "realpath_failed" end
    if original and (not Identity.supported(original) or original.resolved_root ~= resolved_root) then
        return nil, "identity_changed"
    end
    local root_attr, root_error = attributes(root)
    if not root_attr then return nil, root_error == "missing" and "realpath_failed" or root_error end
    if root_attr.mode ~= "directory" then return nil, "unsafe_path" end
    local link_attr, link_error = attributes(path, true)
    if not link_attr then
        if link_error ~= "missing" then return nil, link_error end
        -- A changed directory alias must not turn absence elsewhere into recovery.
        local parent, name = cleaned:match("^(.*)/([^/]+)$")
        local resolved_parent = parent and Identity.resolve(parent)
        local missing_path = resolved_parent and (resolved_parent:gsub("/+$", "") .. "/" .. name)
        if not missing_path then return nil, "realpath_failed" end
        if not descendant(resolved_root, missing_path) then return nil, "unsafe_path" end
        if original and missing_path ~= original.resolved_path then return nil, "identity_changed" end
        return nil, "missing"
    end
    -- Removing a leaf symlink would remove the link, not its captured archive.
    if link_attr.mode == "link" then return nil, "unsafe_path" end
    local resolved = Identity.resolve(path)
    if not resolved then return nil, "realpath_failed" end
    if not descendant(resolved_root, resolved) then return nil, "unsafe_path" end
    local attr, attr_error = attributes(path)
    if not attr then return nil, attr_error end
    local current, err = evidence(attr, resolved, resolved_root)
    if not current then return nil, err end
    if original and not Identity.same(original, current) then return nil, "identity_changed" end
    return current
end

function Identity.readerOwns(target)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or type(ReaderUI) ~= "table" then return true, "reader_unavailable" end
    local reader = ReaderUI.instance
    if not reader then return false end
    local doc = reader.document
    local path = reader.document_path or reader.document_pathname
        or (doc and (doc.file or doc.filename or doc.path))
    if not path then return false end
    if path == target.path then return true, "current_document" end
    local resolved = Identity.resolve(path)
    if not resolved then return true, "realpath_failed" end
    if resolved == target.evidence.resolved_path then return true, "current_document" end
    local attr, err = attributes(path)
    if not attr then return true, err == "missing" and "reader_unavailable" or err end
    if not finite(attr.dev) or not finite(attr.ino) or attr.ino <= 0 then
        return true, "reader_unavailable"
    end
    if attr.dev == target.evidence.dev and attr.ino == target.evidence.ino then
        return true, "current_document"
    end
    return false
end

return Identity
