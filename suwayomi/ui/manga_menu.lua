-- Boundary: compatibility alias for the shared file-manager-like list menu.
--
-- Responsibility: preserve the existing manga-menu module path while the
-- renderer itself lives in suwayomi/ui/list_menu.lua.
-- Owned state: none.
-- Dependencies: shared list menu.
-- External data: forwarded unchanged to suwayomi/ui/list_menu.lua.

return require("suwayomi/ui/list_menu")
