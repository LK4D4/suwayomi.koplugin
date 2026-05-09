-- Boundary: KOReader plugin metadata.
--
-- Responsibility: expose the plugin name, description, and entrypoint metadata
-- consumed by KOReader's plugin loader.
-- Owned state: none.
-- Dependencies: gettext only.
-- External data: none.

local _ = require("gettext")

return {
    name = "suwayomi_dl",
    fullname = _("Suwayomi Downloader"),
    description = _([[Experimental plugin in active development. Browse and asynchronously download manga chapters from a Suwayomi server.]]),
    version = "1.0.0",
}
