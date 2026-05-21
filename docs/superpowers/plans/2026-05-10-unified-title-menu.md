# Unified Title Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every full-screen Suwayomi plugin menu use a consistent KOReader-native burger/title/close title bar with `Suwayomi home` in every burger menu.

**Architecture:** Add a plugin-bound `suwayomi/plugin/title_menu.lua` controller for shared title-menu behavior. Keep UI modules responsible for native KOReader widgets, while controllers continue to own screen-specific action lists and callbacks.

**Tech Stack:** LuaJIT/Lua 5.1, KOReader `Menu` and `ButtonDialog`, Busted specs, luacheck.

---

## File Structure

- Create `suwayomi/plugin/title_menu.lua`: shared title-menu controller mixin.
- Modify `main.lua`: require and install the new controller.
- Modify `suwayomi/ui.lua`: add generic `showActionMenu`; keep chapter/manga wrappers.
- Modify `suwayomi/ui/menu_utils.lua`: ensure title-bar callbacks receive the native menu.
- Modify `suwayomi/client.lua`: replace direct home title options with title-menu options.
- Modify `suwayomi/browse/source_catalog.lua`: use title-menu options for source list with `Global search`.
- Modify `suwayomi/chapters/menu.lua`: use title-menu options for chapter list burger actions.
- Modify `suwayomi/downloads/controller.lua`: use title-menu options for downloads burger actions.
- Add/update focused specs for the new controller and migrated callers.

## Task 1: Shared Title Menu Controller

**Files:**
- Create: `suwayomi/plugin/title_menu.lua`
- Modify: `main.lua`
- Test: `spec/suwayomi_plugin_title_menu_spec.lua`
- Test: `spec/main_spec.lua`

- [ ] **Step 1: Write the failing title-menu controller spec**

Create `spec/suwayomi_plugin_title_menu_spec.lua` with tests asserting:

```lua
package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/plugin/title_menu", function()
    local shown_action_menu
    local action_callback

    before_each(function()
        shown_action_menu = nil
        action_callback = nil
        package.loaded["suwayomi/plugin/title_menu"] = nil
        package.loaded["suwayomi/ui"] = nil
        package.loaded.gettext = nil
        package.preload.gettext = function()
            return function(text)
                return text
            end
        end
        package.preload["suwayomi/ui"] = function()
            return {
                showActionMenu = function(options, onSelect)
                    shown_action_menu = options
                    action_callback = onSelect
                    return { name = "title-action-menu" }
                end,
            }
        end
    end)

    after_each(function()
        package.preload.gettext = nil
        package.preload["suwayomi/ui"] = nil
    end)

    it("exports title menu methods", function()
        helper.assertControllerModule("suwayomi/plugin/title_menu", {
            "getTitleBarMenuOptions",
            "buildTitleBarActions",
            "showTitleBarActionMenu",
            "performTitleBarAction",
        })
    end)

    it("prepends Suwayomi home to screen actions", function()
        local TitleMenu = require("suwayomi/plugin/title_menu")
        local plugin = {}
        for name, method in pairs(TitleMenu.methods) do
            plugin[name] = method
        end

        local actions = plugin:buildTitleBarActions({
            { id = "refresh", text = "Refresh" },
        })

        assert.are.equal("home", actions[1].id)
        assert.are.equal("Suwayomi home", actions[1].text)
        assert.are.equal("refresh", actions[2].id)
    end)

    it("opens title actions from a native burger callback and delegates screen actions", function()
        local TitleMenu = require("suwayomi/plugin/title_menu")
        local delegated
        local plugin = {}
        for name, method in pairs(TitleMenu.methods) do
            plugin[name] = method
        end

        local options = plugin:getTitleBarMenuOptions({
            title = "Library",
            actions = { { id = "refresh", text = "Refresh" } },
            onSelect = function(action, menu)
                delegated = { action = action, menu = menu }
            end,
        })
        local source_menu = { name = "library-menu" }

        assert.are.equal("appbar.menu", options.title_bar_left_icon)
        assert.is_function(options.on_title_bar_left_tap)

        options.on_title_bar_left_tap(source_menu)

        assert.are.equal("Library", shown_action_menu.title)
        assert.are.equal("home", shown_action_menu.actions[1].id)
        assert.are.equal("refresh", shown_action_menu.actions[2].id)

        action_callback({ id = "refresh", text = "Refresh" })

        assert.are.equal("refresh", delegated.action.id)
        assert.are.equal(source_menu, delegated.menu)
    end)

    it("handles home centrally by closing plugin screens and showing the hub", function()
        local TitleMenu = require("suwayomi/plugin/title_menu")
        local events = {}
        local plugin = {
            closeSuwayomiPlugin = function()
                table.insert(events, "close")
            end,
            showHome = function()
                table.insert(events, "home")
            end,
        }
        for name, method in pairs(TitleMenu.methods) do
            plugin[name] = method
        end

        plugin:performTitleBarAction({ name = "menu" }, { id = "home" }, {})

        assert.are.same({ "close", "home" }, events)
    end)
end)
```

- [ ] **Step 2: Run the new spec and verify it fails**

Run: `PATH="$HOME/.luarocks/bin:$PATH" busted spec/suwayomi_plugin_title_menu_spec.lua`

Expected: FAIL because `suwayomi/plugin/title_menu` does not exist.

- [ ] **Step 3: Implement the controller**

Create `suwayomi/plugin/title_menu.lua`:

```lua
-- Boundary: TitleMenuController.
--
-- Responsibility: Owns shared title-bar burger action menus and the universal
-- Suwayomi home title action for full-screen plugin menus.
-- Owned state: none; callbacks and screen-specific actions are supplied by callers.
-- Dependencies: Suwayomi UI action menu renderer and gettext.
-- External data: screen actions are controller-owned and treated as opaque action tables.

local SuwayomiUI = require("suwayomi/ui")
local _ = require("gettext")

local TitleMenuController = {}
TitleMenuController.__index = TitleMenuController

function TitleMenuController:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

function Methods:buildTitleBarActions(screen_actions)
    local actions = {
        { id = "home", text = _("Suwayomi home") },
    }
    for _, action in ipairs(screen_actions or {}) do
        table.insert(actions, action)
    end
    return actions
end

function Methods:performTitleBarAction(menu, action, screen_options)
    screen_options = screen_options or {}
    if not action then
        return false
    end
    if action.id == "home" then
        if self.closeSuwayomiPlugin then
            self:closeSuwayomiPlugin()
        end
        if self.showHome then
            self:showHome()
        end
        return true
    end
    if screen_options.onSelect then
        return screen_options.onSelect(action, menu)
    end
    return false
end

function Methods:showTitleBarActionMenu(menu, screen_options)
    screen_options = screen_options or {}
    return SuwayomiUI.showActionMenu({
        title = screen_options.title or _("Suwayomi"),
        actions = self:buildTitleBarActions(screen_options.actions),
    }, function(action)
        return self:performTitleBarAction(menu, action, screen_options)
    end)
end

function Methods:getTitleBarMenuOptions(screen_options)
    screen_options = screen_options or {}
    return {
        title_bar_left_icon = "appbar.menu",
        on_title_bar_left_tap = function(menu)
            self:showTitleBarActionMenu(menu, screen_options)
            return true
        end,
    }
end

TitleMenuController.methods = Methods

return TitleMenuController
```

- [ ] **Step 4: Install controller in `main.lua`**

Add require near `HomeController`:

```lua
local TitleMenuController = require("suwayomi/plugin/title_menu")
```

Add `TitleMenuController` immediately after `HomeController` in the controller list.

- [ ] **Step 5: Run controller specs**

Run: `PATH="$HOME/.luarocks/bin:$PATH" busted spec/suwayomi_plugin_title_menu_spec.lua spec/main_spec.lua`

Expected: PASS.

## Task 2: Generic Action Menu Renderer and Native Callback Plumbing

**Files:**
- Modify: `suwayomi/ui.lua`
- Modify: `suwayomi/ui/menu_utils.lua`
- Test: `spec/suwayomi_ui_spec.lua`
- Test: `spec/suwayomi_ui_browse_spec.lua`
- Test: `spec/suwayomi_ui_downloads_spec.lua`

- [ ] **Step 1: Write failing specs**

In `spec/suwayomi_ui_spec.lua`, add a test that `showActionMenu` renders two-column action buttons and delegates selection. Update the existing chapter/manga action tests to assert wrappers still call the same renderer behavior.

In `spec/suwayomi_ui_browse_spec.lua` and `spec/suwayomi_ui_downloads_spec.lua`, assert menus with `title_bar_left_icon` use `title_bar_fm_style = true`.

- [ ] **Step 2: Run focused UI specs and verify failure**

Run: `PATH="$HOME/.luarocks/bin:$PATH" busted spec/suwayomi_ui_spec.lua spec/suwayomi_ui_browse_spec.lua spec/suwayomi_ui_downloads_spec.lua`

Expected: FAIL because `showActionMenu` is missing or wrappers still own duplicated logic.

- [ ] **Step 3: Add `showActionMenu` and wrappers**

Move the body of `showChapterActionsMenu` into:

```lua
function SuwayomiUI.showActionMenu(options, onSelectCallback)
    local UIManager = require("ui/uimanager")
    local dialog
    local buttons = {}
    local row = {}
    options = options or {}
    for _, action in ipairs(options.actions or {}) do
        table.insert(row, {
            text = action.text,
            callback = function()
                UIManager:close(dialog)
                if onSelectCallback then
                    onSelectCallback(action)
                end
            end,
        })
        if #row == 2 then
            table.insert(buttons, row)
            row = {}
        end
    end
    if #row > 0 then
        table.insert(buttons, row)
    end
    dialog = ButtonDialog:new{
        title = options.title or _("Actions"),
        buttons = buttons,
        close_callback = options.close_callback,
    }
    UIManager:show(dialog)
    return dialog
end

function SuwayomiUI.showChapterActionsMenu(options, onSelectCallback)
    options = options or {}
    options.title = options.title or _("Chapter actions")
    return SuwayomiUI.showActionMenu(options, onSelectCallback)
end

function SuwayomiUI.showMangaActionsMenu(options, onSelectCallback)
    options = options or {}
    options.title = options.title or _("Manga actions")
    return SuwayomiUI.showActionMenu(options, onSelectCallback)
end
```

- [ ] **Step 4: Wrap title-bar callbacks with the menu instance**

Update `menu_utils.applyTitleBarOptions`:

```lua
if options.on_title_bar_left_tap then
    menu.onLeftButtonTap = function(...)
        return options.on_title_bar_left_tap(menu, ...)
    end
end
```

Update `SuwayomiUI.showChapterMenu` and `SuwayomiUI.updateChapterMenu` similarly when assigning `menu.onLeftButtonTap`.

- [ ] **Step 5: Run focused UI specs**

Run: `PATH="$HOME/.luarocks/bin:$PATH" busted spec/suwayomi_ui_spec.lua spec/suwayomi_ui_browse_spec.lua spec/suwayomi_ui_downloads_spec.lua`

Expected: PASS.

## Task 3: Migrate Chapters and Downloads

**Files:**
- Modify: `suwayomi/chapters/menu.lua`
- Modify: `suwayomi/downloads/controller.lua`
- Test: `spec/suwayomi_chapters_menu_spec.lua`
- Test: `spec/suwayomi_downloads_controller_spec.lua`

- [ ] **Step 1: Write failing specs**

Add chapter spec asserting `buildChapterMenuOptions` uses `getTitleBarMenuOptions`, and the title menu actions include `home` before chapter bulk actions.

Update downloads controller spec so `showDownloads` title bar options come from `getTitleBarMenuOptions` and the actions passed into it contain only download-specific actions; `home` is added by the shared title-menu controller.

- [ ] **Step 2: Run focused specs and verify failure**

Run: `PATH="$HOME/.luarocks/bin:$PATH" busted spec/suwayomi_chapters_menu_spec.lua spec/suwayomi_downloads_controller_spec.lua`

Expected: FAIL because modules still hand-build title-bar callbacks.

- [ ] **Step 3: Migrate chapter menu options**

In `buildChapterMenuOptions` and `buildQuickChapterMenuOptions`, replace direct `title_bar_left_icon` and `on_title_bar_left_tap` fields with:

```lua
local title_options = self:getTitleBarMenuOptions({
    title = _("Chapter downloads"),
    actions = self:getBulkChapterActions(),
    onSelect = function(action)
        return self:performBulkChapterAction(action.id)
    end,
})
```

Copy `title_options` into the returned options table.

- [ ] **Step 4: Migrate downloads title menu**

Replace `showDownloadsActions` with helpers that build download-specific title actions:

```lua
function Methods:getDownloadsTitleActions(snapshot)
    local actions = {}
    if #(snapshot.queued or {}) > 0 then
        table.insert(actions, { id = "cancel_queued", text = _("Cancel queued downloads") })
    end
    if #(snapshot.failed or {}) > 0 then
        table.insert(actions, { id = "clear_failed", text = _("Clear failed") })
    end
    return actions
end
```

Use `self:getTitleBarMenuOptions({ title = _("Downloads"), actions = ..., onSelect = ... })` in `showDownloads`.

- [ ] **Step 5: Run focused specs**

Run: `PATH="$HOME/.luarocks/bin:$PATH" busted spec/suwayomi_chapters_menu_spec.lua spec/suwayomi_downloads_controller_spec.lua`

Expected: PASS.

## Task 4: Migrate Library, Browse, and Global Search

**Files:**
- Modify: `suwayomi/client.lua`
- Modify: `suwayomi/browse/source_catalog.lua`
- Modify: `suwayomi/plugin/home.lua`
- Test: `spec/suwayomi_client_spec.lua`
- Test: `spec/suwayomi_browse_source_catalog_spec.lua`
- Test: `spec/suwayomi_plugin_home_spec.lua`

- [ ] **Step 1: Write failing specs**

Update client specs so Library category and manga menus receive title-bar options with `appbar.menu`. Update Browse source/global-search specs to assert action callbacks are expressed through `getTitleBarMenuOptions`.

Update home controller specs to remove direct `getHomeMenuOptions` expectations.

- [ ] **Step 2: Run focused specs and verify failure**

Run: `PATH="$HOME/.luarocks/bin:$PATH" busted spec/suwayomi_client_spec.lua spec/suwayomi_browse_source_catalog_spec.lua spec/suwayomi_plugin_home_spec.lua`

Expected: FAIL because current code still uses `getHomeMenuOptions` in browse and no title options in Library.

- [ ] **Step 3: Replace client helper**

In `suwayomi/client.lua`, replace `getHomeMenuOptions` with:

```lua
function SuwayomiClient:getTitleBarMenuOptions(options)
    if self.plugin and self.plugin.getTitleBarMenuOptions then
        return self.plugin:getTitleBarMenuOptions(options)
    end
    return nil
end
```

Update callers to use `getTitleBarMenuOptions`.

- [ ] **Step 4: Apply title menus to screens**

Use:

```lua
self:getTitleBarMenuOptions({ title = self:translate("Suwayomi Library") })
```

for Library category and manga menus.

For source list, include `Global search`.

For global search results, include `Cancel search` while active.

For browse source mode and manga results, use Home-only title menus.

- [ ] **Step 5: Remove `getHomeMenuOptions` from HomeController**

Delete `Methods:getHomeMenuOptions()` from `suwayomi/plugin/home.lua`.

- [ ] **Step 6: Run focused specs**

Run: `PATH="$HOME/.luarocks/bin:$PATH" busted spec/suwayomi_client_spec.lua spec/suwayomi_browse_source_catalog_spec.lua spec/suwayomi_plugin_home_spec.lua`

Expected: PASS.

## Task 5: Full Verification, Device Push, and Commit

**Files:**
- Runtime and specs touched by earlier tasks.

- [ ] **Step 1: Search for stale direct home title options**

Run: `rg -n "getHomeMenuOptions|appbar.filebrowser|showDownloadsActions|title_bar_left_icon = \"appbar.menu\"" suwayomi spec`

Expected: no `getHomeMenuOptions`, no `appbar.filebrowser`, and no hand-built `title_bar_left_icon = "appbar.menu"` in controllers outside title-menu tests.

- [ ] **Step 2: Run full tests**

Run: `PATH="$HOME/.luarocks/bin:$PATH" busted spec`

Expected: all specs pass.

- [ ] **Step 3: Run lint**

Run: `PATH="$HOME/.luarocks/bin:$PATH" luacheck --codes spec suwayomi main.lua _meta.lua`

Expected: `Total: 0 warnings / 0 errors`.

- [ ] **Step 4: Push runtime files to Palma**

Run:

```powershell
$target = '/sdcard/koreader/plugins/suwayomi.koplugin'
adb -s E035AD62 shell "mkdir -p $target"
adb -s E035AD62 push _meta.lua "$target/_meta.lua"
adb -s E035AD62 push main.lua "$target/main.lua"
adb -s E035AD62 push README.md "$target/README.md"
adb -s E035AD62 push suwayomi "$target/"
```

Restart KOReader to reload Lua modules.

- [ ] **Step 5: Manual Palma verification**

Open Library, Browse, Chapters, and Downloads.

Expected:

- every full-screen plugin menu shows burger, centered title, close cross
- burger opens an action dialog containing `Suwayomi home`
- Library burger contains only `Suwayomi home`
- Chapter burger contains `Suwayomi home` plus chapter bulk actions
- tapping the centered title does not navigate

- [ ] **Step 6: Commit implementation**

Run:

```powershell
git status --short
git add main.lua suwayomi spec docs/superpowers/plans/2026-05-10-unified-title-menu.md
git commit -m "feat: unify plugin title menus"
```
