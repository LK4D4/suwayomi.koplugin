-- Boundary: KOReader plugin metadata.
--
-- Responsibility: expose the plugin name, description, and entrypoint metadata
-- consumed by KOReader's plugin loader.
-- Owned state: none.
-- Dependencies: gettext only.
-- External data: none.

local _ = require("gettext")

return {
    name = "suwayomi",
    fullname = _("Suwayomi Client v1.0.3"),
    description = _([[Suwayomi client for KOReader. Browse your Suwayomi server, manage source extensions, sync read state, and download chapters as local CBZ files.]]),
    version = "1.0.3",
}
