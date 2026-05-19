# Modal Choice Dialogs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace small full-screen option menus with reusable KOReader modal choice/checklist dialogs.

**Architecture:** Add `suwayomi/ui/choice_dialogs.lua` as the shared modal primitive and expose it through `suwayomi/ui.lua`. Migrate settings choices, source language/filter drilldowns, and downloads side-effect actions without changing primary full-screen list surfaces.

**Tech Stack:** Lua 5.1/LuaJIT, KOReader `ButtonDialog`/`ConfirmBox`, busted specs, luacheck.

---

## File Structure

- Create `suwayomi/ui/choice_dialogs.lua`: reusable `showChoiceDialog()` and `showChecklistDialog()` helpers.
- Modify `suwayomi/ui.lua`: facade exports and settings choice wrappers.
- Modify `suwayomi/ui/browse.lua`: source filter row behavior and language wrapper delegation.
- Modify `suwayomi/browse/source_catalog.lua`: keep controller behavior compatible with checklist dialog refresh.
- Modify `suwayomi/ui/downloads.lua`: failed row callback becomes action callback.
- Modify `suwayomi/downloads/controller.lua`: failed retry action dialog and cancel-all confirmation.
- Tests: `spec/suwayomi_ui_spec.lua`, `spec/suwayomi_ui_browse_spec.lua`, `spec/suwayomi_browse_source_catalog_spec.lua`, `spec/suwayomi_ui_downloads_spec.lua`, `spec/suwayomi_downloads_controller_spec.lua`.

## Task 1: Shared Choice Dialog Helpers And Settings Migration

**Files:**
- Create: `suwayomi/ui/choice_dialogs.lua`
- Modify: `suwayomi/ui.lua`
- Test: `spec/suwayomi_ui_spec.lua`
- Test: `spec/suwayomi_plugin_settings_controller_spec.lua`

- [ ] **Step 1: Write failing UI helper tests**

Add tests to `spec/suwayomi_ui_spec.lua` near existing dialog specs:

```lua
it("shows a choice dialog and marks the current value", function()
    local ui = require("suwayomi/ui")
    local selected

    ui.showChoiceDialog({
        title = "Pick count",
        current = 2,
        choices = {
            { value = 1, text = "1" },
            { value = 2, text = "2" },
        },
        onSelect = function(value)
            selected = value
        end,
    })

    assert.are.equal("Pick count", shown_dialog.title)
    assert.are.equal("1", shown_dialog.buttons[1][1].text)
    assert.are.equal("* 2", shown_dialog.buttons[2][1].text)

    shown_dialog.buttons[1][1].callback()

    assert.are.equal(shown_dialog, closed_dialog)
    assert.are.equal(1, selected)
end)

it("shows a checklist dialog and toggles selected values", function()
    local ui = require("suwayomi/ui")
    local toggled
    local done = false

    ui.showChecklistDialog({
        title = "Languages",
        choices = {
            { value = "en", text = "English" },
            { value = "ja", text = "Japanese" },
        },
        isSelected = function(value)
            return value == "en"
        end,
        onToggle = function(value, selected)
            toggled = { value = value, selected = selected }
        end,
        onDone = function()
            done = true
        end,
    })

    assert.are.equal("* English", shown_dialog.buttons[1][1].text)
    assert.are.equal("Japanese", shown_dialog.buttons[2][1].text)

    shown_dialog.buttons[2][1].callback()
    assert.are.same({ value = "ja", selected = true }, toggled)

    shown_dialog.buttons[3][1].callback()
    assert.is_true(done)
    assert.are.equal(shown_dialog, closed_dialog)
end)
```

- [ ] **Step 2: Run helper tests and verify RED**

Run:

```bash
rtk busted spec/suwayomi_ui_spec.lua
```

Expected: fail because `ui.showChoiceDialog` or `ui.showChecklistDialog` is nil.

- [ ] **Step 3: Implement helper module**

Create `suwayomi/ui/choice_dialogs.lua`:

```lua
-- Boundary: reusable modal choice/checklist dialogs.
--
-- Responsibility: build small KOReader ButtonDialog-based option surfaces.
-- Owned state: none; callbacks own persistence and parent refresh behavior.
-- Dependencies: KOReader ButtonDialog/UIManager and gettext.
-- External data: labels and values are caller-provided display data.

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local ChoiceDialogs = {}

local function selectedText(selected, text)
    text = tostring(text or "")
    if selected then
        return "* " .. text
    end
    return text
end

local function choiceLabel(choice)
    if choice.text ~= nil then
        return tostring(choice.text)
    end
    return tostring(choice.value or "")
end

local function sameValue(left, right)
    return tostring(left) == tostring(right)
end

local function closeThen(dialog_provider, callback)
    UIManager:close(dialog_provider())
    if UIManager.nextTick then
        UIManager:nextTick(callback)
    elseif callback then
        callback()
    end
end

function ChoiceDialogs.showChoiceDialog(options)
    options = options or {}
    local dialog
    local buttons = {}
    for _, choice in ipairs(options.choices or {}) do
        table.insert(buttons, {
            {
                text = selectedText(sameValue(choice.value, options.current), choiceLabel(choice)),
                callback = function()
                    closeThen(function()
                        return dialog
                    end, function()
                        if options.onSelect then
                            options.onSelect(choice.value, choice)
                        end
                    end)
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = options.title or _("Choose"),
        buttons = buttons,
        anchor = options.anchor,
        close_callback = options.close_callback,
    }
    UIManager:show(dialog)
    return dialog
end

function ChoiceDialogs.showChecklistDialog(options)
    options = options or {}
    local dialog
    local buttons = {}
    for _, choice in ipairs(options.choices or {}) do
        table.insert(buttons, {
            {
                text = selectedText(options.isSelected and options.isSelected(choice.value, choice), choiceLabel(choice)),
                callback = function()
                    local selected = not (options.isSelected and options.isSelected(choice.value, choice) == true)
                    if options.onToggle then
                        options.onToggle(choice.value, selected, choice)
                    end
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Done"),
            callback = function()
                closeThen(function()
                    return dialog
                end, options.onDone)
            end,
        },
    })
    dialog = ButtonDialog:new{
        title = options.title or _("Choose"),
        buttons = buttons,
        anchor = options.anchor,
        close_callback = options.close_callback,
    }
    UIManager:show(dialog)
    return dialog
end

return ChoiceDialogs
```

- [ ] **Step 4: Expose helpers and convert settings wrappers**

Modify `suwayomi/ui.lua`:

```lua
local ChoiceDialogs = require("suwayomi/ui/choice_dialogs")
```

Expose:

```lua
SuwayomiUI.showChoiceDialog = ChoiceDialogs.showChoiceDialog
SuwayomiUI.showChecklistDialog = ChoiceDialogs.showChecklistDialog
```

Replace `showParallelDownloadsMenu`, `showLibraryCategoryPickerBehaviorMenu`, and `showDeleteFinishedWhileReadingMenu` bodies to call `SuwayomiUI.showChoiceDialog` with current labels and callbacks. Remove obsolete update helpers when no callers remain.

- [ ] **Step 5: Update settings tests**

In `spec/suwayomi_plugin_settings_controller_spec.lua`, change expectations that currently assert `list_menu` for these settings to assert a choice dialog was shown and selection still saves/refreshes.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run:

```bash
rtk busted spec/suwayomi_ui_spec.lua spec/suwayomi_plugin_settings_controller_spec.lua
```

Expected: all selected specs pass.

- [ ] **Step 7: Commit**

```bash
rtk git add suwayomi/ui/choice_dialogs.lua suwayomi/ui.lua spec/suwayomi_ui_spec.lua spec/suwayomi_plugin_settings_controller_spec.lua
rtk git commit -m "feat: add modal choice dialogs"
```

## Task 2: Source Language Checklist Modal

**Files:**
- Modify: `suwayomi/ui.lua`
- Modify: `suwayomi/browse/source_catalog.lua`
- Test: `spec/suwayomi_ui_spec.lua`
- Test: `spec/suwayomi_browse_source_catalog_spec.lua`

- [ ] **Step 1: Write failing language modal tests**

Update `spec/suwayomi_ui_spec.lua` language menu test to expect `ButtonDialog` buttons, selected `* ` labels, and no `renderer = "list_menu"`.

Add or update source catalog spec to assert `showSourceLanguageFilterActions()` calls `showLanguageMenu`, toggles a language, and refreshes source filtering without replacing `current_sources_menu`.

- [ ] **Step 2: Run tests and verify RED**

```bash
rtk busted spec/suwayomi_ui_spec.lua spec/suwayomi_browse_source_catalog_spec.lua
```

Expected: language menu still uses raw/full `Menu`.

- [ ] **Step 3: Convert `showLanguageMenu` internals**

Keep public function names in `suwayomi/ui.lua`, but delegate `showLanguageMenu` to `SuwayomiUI.showChecklistDialog`:

```lua
function SuwayomiUI.showLanguageMenu(options)
    options = options or {}
    local choices = {}
    for _, language in ipairs(options.languages or {}) do
        table.insert(choices, {
            value = language.code,
            text = language.label,
            language = language,
        })
    end
    return SuwayomiUI.showChecklistDialog({
        title = options.title or _("Suwayomi source languages"),
        choices = choices,
        anchor = options.anchor,
        close_callback = options.close_callback,
        isSelected = function(_, choice)
            return choice.language and choice.language.enabled == true
        end,
        onToggle = function(code, selected)
            if options.onToggle then
                options.onToggle(code, selected)
            end
        end,
        onDone = options.onClose,
    })
end
```

Update `updateLanguageMenu` to either rebuild `buttons` on the existing dialog if simple, or be a no-op compatible shim if the controller already opens a new dialog. Preserve tests for visible selected state.

- [ ] **Step 4: Run focused tests and verify GREEN**

```bash
rtk busted spec/suwayomi_ui_spec.lua spec/suwayomi_browse_source_catalog_spec.lua
```

- [ ] **Step 5: Commit**

```bash
rtk git add suwayomi/ui.lua suwayomi/browse/source_catalog.lua spec/suwayomi_ui_spec.lua spec/suwayomi_browse_source_catalog_spec.lua
rtk git commit -m "feat: show source languages as modal checklist"
```

## Task 3: Source Filter Drilldown Modals

**Files:**
- Modify: `suwayomi/ui/browse.lua`
- Test: `spec/suwayomi_ui_browse_spec.lua`

- [ ] **Step 1: Write failing source filter tests**

Update source filter editor tests so:

```lua
editor.item_table[4].callback()
assert.are.equal("Length", shown_dialog.title)
assert.are.equal("* Any", shown_dialog.buttons[1][1].text)
shown_dialog.buttons[2][1].callback()
assert.are.equal("Long", editor.item_table[4].mandatory)
```

Add sort test:

```lua
editor.item_table[6].callback()
assert.are.equal("Sort by", shown_dialog.title)
assert.truthy(shown_dialog.buttons[1][1].text:match("Name"))
assert.truthy(shown_dialog.buttons[3][1].text:match("Ascending"))
```

Add small group test where a group with at most 8 checkbox/tri-state children opens checklist dialog, and a large group with 9 children keeps `sub_item_table`.

Add assertion that editor does not append duplicate bottom action rows when `title_options.actions` exists.

- [ ] **Step 2: Run browse UI spec and verify RED**

```bash
rtk busted spec/suwayomi_ui_browse_spec.lua
```

Expected: tests fail because `SelectFilter`, `SortFilter`, and all `GroupFilter` rows use `sub_item_table`.

- [ ] **Step 3: Implement source filter modals**

In `suwayomi/ui/browse.lua`, require public UI lazily where callbacks need dialogs:

```lua
local function getUI()
    return require("suwayomi/ui")
end
```

For `SelectFilter`, replace `sub_item_table` with callback that calls `getUI().showChoiceDialog`.

For `SortFilter`, use `showChoiceDialog` twice or one combined modal with sort keys plus direction rows. Keep `row.mandatory = sortStateText(filter, entry.state)` after each selection.

For `GroupFilter`, add:

```lua
local function canShowGroupAsChecklist(filters)
    if #(filters or {}) > 8 then
        return false
    end
    for _, child in ipairs(filters or {}) do
        local child_type = type(child) == "table" and child.type or nil
        if child_type ~= "CheckBoxFilter" and child_type ~= "TriStateFilter" then
            return false
        end
    end
    return true
end
```

Use checklist dialog for simple groups; keep current `sub_item_table` fallback for complex/large groups.

Only append bottom `Apply filters`, `Reset filters`, `Search text` rows when `title_options.actions` is not present.

- [ ] **Step 4: Run focused tests and verify GREEN**

```bash
rtk busted spec/suwayomi_ui_browse_spec.lua
```

- [ ] **Step 5: Commit**

```bash
rtk git add suwayomi/ui/browse.lua spec/suwayomi_ui_browse_spec.lua
rtk git commit -m "feat: use modals for source filter choices"
```

## Task 4: Downloads Action Modals And Confirmation

**Files:**
- Modify: `suwayomi/ui/downloads.lua`
- Modify: `suwayomi/downloads/controller.lua`
- Test: `spec/suwayomi_ui_downloads_spec.lua`
- Test: `spec/suwayomi_downloads_controller_spec.lua`

- [ ] **Step 1: Write failing downloads tests**

In UI downloads spec, assert failed rows call `onSelectFailed` instead of `onRetryFailed`.

In controller spec, add:

```lua
it("opens failed download actions before retrying", function()
    -- build plugin with failed job
    plugin:showDownloads()
    state.downloads_callbacks.onSelectFailed(failed_job, state.downloads_menu)
    assert.are.equal("Download actions", state.action_options.title)
    -- invoke Retry action, assert queue:retryFailed called and downloads refreshes
end)
```

Add cancel-all confirmation test:

```lua
controller:performDownloadsTitleAction({ id = "cancel_all" }, menu)
assert.are.equal("Cancel all downloads?", state.confirm_options.text)
assert.is_false(queue.cancel_all_called)
state.confirm_options.ok_callback()
assert.is_true(queue.cancel_all_called)
```

- [ ] **Step 2: Run focused tests and verify RED**

```bash
rtk busted spec/suwayomi_ui_downloads_spec.lua spec/suwayomi_downloads_controller_spec.lua
```

- [ ] **Step 3: Implement downloads modal behavior**

Change `suwayomi/ui/downloads.lua` failed row callback to `callbacks.onSelectFailed`.

Add controller method `showFailedDownloadActions(job, menu)` using `SuwayomiUI.showChapterActionsMenu` or `showChoiceDialog` with `Retry` and `Cancel`.

Wrap `cancel_all` branch in `performDownloadsTitleAction` with `SuwayomiUI.showConfirm`.

- [ ] **Step 4: Run focused tests and verify GREEN**

```bash
rtk busted spec/suwayomi_ui_downloads_spec.lua spec/suwayomi_downloads_controller_spec.lua
```

- [ ] **Step 5: Commit**

```bash
rtk git add suwayomi/ui/downloads.lua suwayomi/downloads/controller.lua spec/suwayomi_ui_downloads_spec.lua spec/suwayomi_downloads_controller_spec.lua
rtk git commit -m "feat: confirm download side effects"
```

## Task 5: Full Verification And Cleanup

**Files:**
- Modify: any tests/docs needed after integration review

- [ ] **Step 1: Run full lint**

```bash
rtk luacheck --codes spec suwayomi main.lua _meta.lua
```

Expected: all files clean.

- [ ] **Step 2: Run full spec suite**

```bash
rtk busted spec
```

Expected: all specs pass.

- [ ] **Step 3: Review final diff**

```bash
rtk git diff master...HEAD --stat
rtk git diff master...HEAD --check
```

Expected: no whitespace errors, changes match spec.

- [ ] **Step 4: Commit final cleanup if needed**

Only if Step 1-3 require edits:

```bash
rtk git add suwayomi spec docs/superpowers/plans/2026-05-19-modal-choice-dialogs.md
rtk git commit -m "test: cover modal choice dialogs"
```

## Final Status

- Source filter modal refresh regression fixed.
- SelectFilter, SortFilter, and small GroupFilter modal callbacks now refresh the parent source-filter menu after draft row mutations.
- Large and complex GroupFilter rows remain nested.
- Title actions continue to receive the edited draft.
- Focused specs and lint passed before final commit.
