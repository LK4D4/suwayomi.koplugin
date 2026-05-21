local metadata_path = arg[1] or "_meta.lua"

local function fail(message)
    io.stderr:write(message .. "\n")
    os.exit(1)
end

local metadata = io.open(metadata_path, "r")
if not metadata then
    fail("Could not open " .. metadata_path)
end

local contents = metadata:read("*a")
metadata:close()

local metadata_version = contents:match('version%s*=%s*"([^"]+)"')
if not metadata_version then
    fail("Could not find version in " .. metadata_path)
end

print("suwayomi.koplugin-v" .. metadata_version .. ".zip")
