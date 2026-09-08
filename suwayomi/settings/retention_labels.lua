-- Boundary: shared user-facing labels for persisted finish-retention values.
-- Values 1–5 keep zero through four completions; value 0 disables retention.
local I18n = require("suwayomi/i18n")

local RetentionLabels = {}

function RetentionLabels.format(value)
    value = tonumber(value) or 0
    if value < 1 or value > 5 or value % 1 ~= 0 then
        return I18n.t("Off")
    end
    return I18n.count(value - 1, "Keep %1 newest completion", "Keep %1 newest completions")
end

return RetentionLabels
