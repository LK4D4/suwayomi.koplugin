std = "luajit"

-- Match KOReader's method-table style: many callbacks are declared with
-- colon syntax even when a particular implementation does not read self.
self = false

-- The codebase has long GraphQL strings and fixture-heavy specs. KOReader's
-- own luacheck config also leaves line-length enforcement off.
ignore = {
    "631",
    "211/_.*",
    "212/_.*",
    "213/_.*",
}

exclude_files = {
    ".codex-tmp/**",
    ".worktrees/**",
}

-- Specs run under Busted and commonly replace io/os functions while stubbing
-- KOReader filesystem behavior.
files["spec/*.lua"].std = "+busted"
files["spec/*.lua"].ignore = {
    "122",
}

files["spec/support/*.lua"].std = "+busted"
files["spec/support/*.lua"].ignore = {
    "122",
}
