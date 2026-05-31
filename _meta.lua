-- Boundary: KOReader plugin metadata.
--
-- Responsibility: expose the plugin name, description, and entrypoint metadata
-- consumed by KOReader's plugin loader.
-- Owned state: none.
-- Dependencies: plugin i18n facade only.
-- External data: none.

local I18n = require("suwayomi/i18n")

return {
    name = "suwayomi",
    fullname = I18n.t("Suwayomi Client v1.0.6"),
    description = I18n.t([[Suwayomi client for KOReader. Browse your Suwayomi server, manage source extensions, sync read state, and download chapters as local CBZ files.]]),
    version = "1.0.6",
}
