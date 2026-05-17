local metadata_path = arg[1] or "_meta.lua"
local tag_name = arg[2] or os.getenv("GITHUB_REF_NAME") or ""

local function fail(message)
    io.stderr:write(message .. "\n")
    os.exit(1)
end

if tag_name == "" then
    fail("Release tag name is required")
end

local metadata = assert(io.open(metadata_path, "r"))
local contents = metadata:read("*a")
metadata:close()

local metadata_version = contents:match('version%s*=%s*"([^"]+)"')
if not metadata_version then
    fail("Could not find version in " .. metadata_path)
end

local tag_version = tag_name:match("^v(.+)$")
if not tag_version then
    fail("Release tag must start with v: " .. tag_name)
end

if tag_version ~= metadata_version then
    fail("Release tag " .. tag_name .. " does not match " .. metadata_path .. " version " .. metadata_version)
end

print("Release tag " .. tag_name .. " matches " .. metadata_path .. " version " .. metadata_version)
