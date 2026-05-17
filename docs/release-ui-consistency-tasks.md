# Release UI Consistency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make pre-release plugin menus feel consistent by moving action-choice and settings-choice screens toward the shared button-menu and list-row patterns.

**Architecture:** Keep behavior in existing UI facades. Use `suwayomi/ui.lua` for shared action-button menus, `suwayomi/ui/browse.lua` for Browse-specific entry points, and `suwayomi/plugin/settings_controller.lua` for settings orchestration. Preserve form and native picker exceptions where the current KOReader widget is the right primitive.

**Tech Stack:** LuaJIT/Lua 5.1, KOReader `ButtonDialog`, KOReader `Menu`, `suwayomi/ui/list_rows.lua`, `suwayomi/ui/list_menu.lua`, Busted specs, Luacheck.

---

## Current Shared UI Baseline

- Shared row/list screens use `suwayomi/ui/list_rows.lua` plus `suwayomi/ui/list_menu.lua`.
- Shared action menus use `SuwayomiUI.showActionMenu()` in `suwayomi/ui.lua`.
- Existing matching surfaces: Sources, Extensions list, Global search results, Browse manga results, Library category/manga, Downloads, and Chapters.
- Intentional exceptions should remain native forms/pickers: search prompts, login, onboarding connection, directory chooser.

## Candidate Priority

1. `BrowseUI.showSourceModeMenu()` in `suwayomi/ui/browse.lua`: strongest release mismatch. `Popular`, `Latest`, and `Search` are action choices but currently render as plain menu rows.
2. `SuwayomiUI.showSettingsMenu()` in `suwayomi/ui.lua` and `Methods:buildSettingsMenu()` in `suwayomi/plugin/settings_controller.lua`: visible central settings surface, currently raw nested KOReader menu.
3. Settings choice submenus in `suwayomi/ui.lua`: `showParallelDownloadsMenu()`, `showLibraryCategoryPickerBehaviorMenu()`, `showDeleteFinishedWhileReadingMenu()`, and possibly `showLanguageMenu()`.
4. `BrowseUI.showExtensionActionMenu()` in `suwayomi/ui/browse.lua`: already button-like, but duplicates shared action-menu behavior.

## Files And Responsibilities

- Modify: `suwayomi/ui.lua`
  - Keep `showActionMenu()` as shared button-menu renderer.
  - Add small reusable choice-menu helper only if it removes duplication between settings choice screens.
  - Keep `showLoginDialog()` and `showOnboardingConnectionDialog()` as `MultiInputDialog` form exceptions.
- Modify: `suwayomi/ui/browse.lua`
  - Convert source mode and extension action screens to shared action-menu behavior.
  - Keep search prompts as `MultiInputDialog` form exceptions.
- Modify: `suwayomi/plugin/settings_controller.lua`
  - Shape Settings root data into consistent groups/actions if needed.
  - Preserve current callbacks and settings persistence behavior.
- Modify: `spec/suwayomi_ui_browse_spec.lua`
  - Cover source mode and extension action menu renderer/behavior.
- Modify: `spec/suwayomi_ui_spec.lua`
  - Cover shared action-menu usage and settings choice menu shape.
- Modify: `spec/suwayomi_plugin_settings_controller_spec.lua`
  - Cover Settings root wiring and unchanged callbacks.
- Review: `docs/ARCHITECTURE.md`
  - Update only if UI ownership or helper boundaries change.

## Leave As-Is Unless Follow-Up Says Otherwise

- `BrowseUI.showSourceSearchPrompt()` in `suwayomi/ui/browse.lua`: search input form.
- `BrowseUI.showGlobalSearchPrompt()` in `suwayomi/ui/browse.lua`: search input form.
- `SuwayomiUI.showLoginDialog()` in `suwayomi/ui.lua`: credentials form.
- `SuwayomiUI.showOnboardingConnectionDialog()` in `suwayomi/ui.lua`: setup wizard form.
- `SuwayomiUI.showHomeDialog()` in `suwayomi/ui.lua`: home launcher can keep distinct hub style.
- `DirectoryUI.showDirectoryChooser()` in `suwayomi/ui/directory.lua`: native `PathChooser` is correct for filesystem selection.

---

### Task 1: Convert Source Mode Menu To Shared Action Menu

**Files:**
- Modify: `suwayomi/ui/browse.lua`
- Test: `spec/suwayomi_ui_browse_spec.lua`

- [ ] **Step 1: Add failing spec for shared action-style source mode**

In `spec/suwayomi_ui_browse_spec.lua`, extend the `showSourceModeMenu` coverage so the shown widget is a button/action dialog rather than a plain `Menu:new` list. Assert:

- title is source name.
- actions include `Popular`, `Latest`, and `Search` when latest is supported.
- actions include `Popular` and `Search` when `supports_latest == false`.
- selecting each action calls existing callback with `POPULAR`, `LATEST`, or `SEARCH`.
- title-bar back/close options still pass through if supported by the chosen shared helper.

- [ ] **Step 2: Run targeted failing test**

Run:

```bash
busted spec/suwayomi_ui_browse_spec.lua
```

Expected: new source-mode action-menu expectation fails against current plain menu implementation.

- [ ] **Step 3: Implement minimal source mode conversion**

In `suwayomi/ui/browse.lua`, rewrite `BrowseUI.showSourceModeMenu()` to build actions and call shared action-menu behavior. Preserve mode strings:

```lua
local actions = {
    { id = "POPULAR", text = _("Popular") },
}
if not source or source.supports_latest ~= false then
    table.insert(actions, { id = "LATEST", text = _("Latest") })
end
table.insert(actions, { id = "SEARCH", text = _("Search") })
```

Use shared action selection callback to call `onSelectCallback(action.id)`.

- [ ] **Step 4: Run targeted passing test**

Run:

```bash
busted spec/suwayomi_ui_browse_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add suwayomi/ui/browse.lua spec/suwayomi_ui_browse_spec.lua
git commit -m "fix: align source mode menu style"
```

---

### Task 2: Reuse Shared Action Menu For Extension Actions

**Files:**
- Modify: `suwayomi/ui/browse.lua`
- Test: `spec/suwayomi_ui_browse_spec.lua`

- [ ] **Step 1: Add failing spec for extension action menu delegation**

In `spec/suwayomi_ui_browse_spec.lua`, add coverage that `BrowseUI.showExtensionActionMenu()` uses the same button/action shape as `showActionMenu()`:

- installable extension shows `Install`.
- installed extension with update shows `Update` and destructive `Uninstall`.
- no-action extension shows `No actions available`.
- selected action ids remain `install`, `update`, and `uninstall`.
- anchor and close callback still pass through.

- [ ] **Step 2: Run targeted failing test**

Run:

```bash
busted spec/suwayomi_ui_browse_spec.lua
```

Expected: delegation/action-shape assertion fails against custom local `ButtonDialog:new` construction.

- [ ] **Step 3: Implement shared extension action menu**

In `suwayomi/ui/browse.lua`, replace custom `ButtonDialog:new` rows in `showExtensionActionMenu()` with shared action-menu construction. Keep title from `ListRows.getExtensionTitle(extension)`. Preserve destructive flag on uninstall.

- [ ] **Step 4: Run targeted passing test**

Run:

```bash
busted spec/suwayomi_ui_browse_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add suwayomi/ui/browse.lua spec/suwayomi_ui_browse_spec.lua
git commit -m "refactor: share extension action menu"
```

---

### Task 3: Make Settings Choice Screens Consistent

**Files:**
- Modify: `suwayomi/ui.lua`
- Test: `spec/suwayomi_ui_spec.lua`

- [ ] **Step 1: Add failing specs for settings choice menus**

In `spec/suwayomi_ui_spec.lua`, add or update tests for:

- `showParallelDownloadsMenu()`
- `showLibraryCategoryPickerBehaviorMenu()`
- `showDeleteFinishedWhileReadingMenu()`

Assert each screen renders choices with consistent action/button or shared list-row shape, keeps current selection visible, calls `onSelect(value)`, and supports update functions without losing current callbacks.

- [ ] **Step 2: Run targeted failing test**

Run:

```bash
busted spec/suwayomi_ui_spec.lua
```

Expected: new consistency expectations fail against raw radio `Menu:new` implementation.

- [ ] **Step 3: Implement shared choice menu helper**

In `suwayomi/ui.lua`, add one local helper if useful:

```lua
local function buildChoiceActions(choices, current, labelForChoice)
    local actions = {}
    for _, value in ipairs(choices or {}) do
        local selected = value == current
        table.insert(actions, {
            id = value,
            text = (selected and "* " or "") .. tostring(labelForChoice(value)),
        })
    end
    return actions
end
```

Use it for parallel downloads, library category picker behavior, and delete-finished-while-reading choices. Keep existing public function names and callback signatures.

- [ ] **Step 4: Preserve update behavior**

Update `updateParallelDownloadsMenu()`, `updateLibraryCategoryPickerBehaviorMenu()`, and `updateDeleteFinishedWhileReadingMenu()` to rebuild same consistent shape. If the chosen shared renderer cannot update in place, close and reopen only if existing tests and UX expectations allow it; otherwise keep `Menu:updateItems()` and align row formatting instead of switching widget class.

- [ ] **Step 5: Run targeted passing test**

Run:

```bash
busted spec/suwayomi_ui_spec.lua
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add suwayomi/ui.lua spec/suwayomi_ui_spec.lua
git commit -m "refactor: align settings choice menus"
```

---

### Task 4: Decide And Shape Settings Root

**Files:**
- Modify: `suwayomi/ui.lua`
- Modify: `suwayomi/plugin/settings_controller.lua`
- Test: `spec/suwayomi_ui_spec.lua`
- Test: `spec/suwayomi_plugin_settings_controller_spec.lua`

- [ ] **Step 1: Add failing tests for Settings root style**

In `spec/suwayomi_ui_spec.lua`, assert `showSettingsMenu()` no longer exposes raw nested `sub_item_table` rows directly to an unstyled root. In `spec/suwayomi_plugin_settings_controller_spec.lua`, assert current setting callbacks still route correctly:

- Setup wizard
- Login information
- Test connection
- Category picker
- Browse toggles
- Download directory
- Parallel downloads
- Delete after manual mark-read
- Delete while reading

- [ ] **Step 2: Run targeted failing tests**

Run:

```bash
busted spec/suwayomi_ui_spec.lua spec/suwayomi_plugin_settings_controller_spec.lua
```

Expected: new root-style expectation fails; behavior specs should document current callback contract.

- [ ] **Step 3: Implement conservative Settings root polish**

Prefer lowest-risk release shape:

- Keep top-level groups: `Setup wizard`, `Connection`, `Library`, `Browse`, `Downloads`.
- Render root with same native title-bar styling as plugin list screens.
- Convert group drill-downs to shared action menus where items are actions.
- Keep toggles and choice rows clear, with current value visible in text.

Do not change persisted setting keys or callback names.

- [ ] **Step 4: Run targeted passing tests**

Run:

```bash
busted spec/suwayomi_ui_spec.lua spec/suwayomi_plugin_settings_controller_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add suwayomi/ui.lua suwayomi/plugin/settings_controller.lua spec/suwayomi_ui_spec.lua spec/suwayomi_plugin_settings_controller_spec.lua
git commit -m "refactor: align settings menu style"
```

---

### Task 5: Optional Language Menu Polish

**Files:**
- Modify: `suwayomi/ui.lua`
- Test: `spec/suwayomi_ui_spec.lua`
- Test: `spec/suwayomi_browse_source_catalog_spec.lua`

- [ ] **Step 1: Decide if language menu is release-blocking**

Keep `showLanguageMenu()` raw `Menu:new` if multi-toggle behavior needs stable `keep_menu_open` and `Done`. Fix only if settings choice screens are already aligned and language menu still feels visibly inconsistent.

- [ ] **Step 2: Add failing spec only if changing**

If changing, assert:

- each language can toggle without closing menu.
- selected languages remain visibly marked.
- `Done` still runs close callback once.
- refresh/update preserves skip-next-close behavior.

- [ ] **Step 3: Implement minimal visual alignment**

Prefer row-format polish over widget replacement. Keep multi-select behavior first; visual consistency second.

- [ ] **Step 4: Run targeted tests**

Run:

```bash
busted spec/suwayomi_ui_spec.lua spec/suwayomi_browse_source_catalog_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Commit if changed**

```bash
git add suwayomi/ui.lua spec/suwayomi_ui_spec.lua spec/suwayomi_browse_source_catalog_spec.lua
git commit -m "refactor: polish language filter menu"
```

---

### Task 6: Final Verification

**Files:**
- Review: `docs/ARCHITECTURE.md`

- [ ] **Step 1: Run full local test suite**

Run:

```bash
busted spec
```

Expected: PASS.

- [ ] **Step 2: Run full lint**

Run:

```bash
luacheck --codes spec suwayomi main.lua _meta.lua
```

Expected: PASS.

- [ ] **Step 3: Review docs impact**

If UI helper ownership changed, update `docs/ARCHITECTURE.md`. If only existing functions changed internals, no docs update needed.

- [ ] **Step 4: Commit docs update if needed**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs: update UI menu ownership"
```

---

## Release Recommendation

Fix before release:

1. Source mode menu.
2. Extension action menu.
3. Settings choice menus.

Fix if time allows:

4. Settings root.
5. Language menu polish.

Keep as exceptions:

1. Search prompts.
2. Login dialog.
3. Onboarding connection dialog.
4. Directory chooser.
5. Home launcher.
