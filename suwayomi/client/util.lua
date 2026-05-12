-- Boundary: shared helpers for client flow modules.
--
-- Responsibility: keep tiny pure helpers out of the public client facade while
-- avoiding repeated local definitions across flow-specific modules.
-- Owned state: none.
-- Dependencies: none.
-- External data: string inputs are coerced before trimming.

local M = {}

function M.copyOptions(target, source)
    for key, value in pairs(source or {}) do
        target[key] = value
    end
    return target
end

function M.trim(text)
    return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

return M
