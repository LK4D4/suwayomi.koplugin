-- Boundary: filesystem dependency loader.
--
-- Responsibility: resolve LuaFileSystem in KOReader and local test runtimes.
-- Owned state: none.
-- Dependencies: KOReader's bundled LuaFileSystem module or plain LuaRocks lfs.
-- External data: none.

local ok, lfs = pcall(require, "libs/libkoreader-lfs")
if ok and lfs then
    return lfs
end

return require("lfs")
