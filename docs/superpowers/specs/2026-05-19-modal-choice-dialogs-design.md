# Modal Choice Dialogs Design

## Goal

Replace small option screens with KOReader-native modal dialogs so transient choices stay anchored to the screen that opened them.

The plugin should still use full-screen menus for primary surfaces: settings root, source catalog, extension catalog, manga result lists, global search results, source filter editor shell, chapter lists, and the downloads hub.

## Current State

Several local choices use full-screen `Menu` or nested `sub_item_table` menus even though the user is only choosing one value or toggling a small checklist:

- `showParallelDownloadsMenu`
- `showLibraryCategoryPickerBehaviorMenu`
- `showDeleteFinishedWhileReadingMenu`
- source language filter actions
- source filter `SelectFilter` choices
- source filter `SortFilter` choices
- small source filter `GroupFilter` rows

Other flows are already modal and should stay that way: login, onboarding connection, source search, global search prompt, extension search, source mode, extension actions, manga actions, chapter actions, and text filters.

## Product Behavior

Use full-screen menus only when the surface is primary, long, pageable, async, or stateful. Use modal dialogs when the user is making a bounded local choice, toggling a compact checklist, or confirming a destructive action.

Settings choice rows should open a modal, not a new full screen:

- `Parallel downloads` shows choices `1`, `2`, `3`, `4`.
- `Category picker` shows `Automatic`, `Always ask`, and `Never ask`.
- `Delete while reading` shows the six existing choices.

Selecting an option saves immediately, refreshes the parent settings menu, and closes the modal. The current option is visibly marked in the modal.

Source catalog language filtering should open a checklist modal or popout from the source catalog title action. Toggling languages updates the source list while keeping the source catalog underneath. The modal should support repeated toggles and a `Done` action.

Source filter editor remains full screen. Its individual option drilldowns follow these modal rules:

- `CheckBoxFilter` remains an inline toggle.
- `TriStateFilter` remains an inline cycle.
- `TextFilter` remains `MultiInputDialog`.
- `SelectFilter` opens a choice modal.
- `SortFilter` opens a sort modal with sort key and direction controls.
- `GroupFilter` opens a checklist modal only when the group is small and simple. Large or nested groups stay in full-screen or nested list form.

Failed download rows should stop retrying immediately on tap. Tapping a failed row opens an action modal with `Retry` and `Cancel`. If later UX adds clear actions here, they should be explicit actions in that same modal.

`Cancel all downloads` should show a confirmation before mutating the queue.

## Architecture

Add a focused UI helper module:

```text
suwayomi/ui/choice_dialogs.lua
```

Expose the helpers through `suwayomi/ui.lua`:

```lua
SuwayomiUI.showChoiceDialog = ChoiceDialogs.showChoiceDialog
SuwayomiUI.showChecklistDialog = ChoiceDialogs.showChecklistDialog
```

`showChoiceDialog(options)` builds a `ButtonDialog` for small single-choice lists.

Expected options:

```lua
{
    title = "Dialog title",
    choices = {
        { value = "automatic", text = "Automatic" },
        { value = "always", text = "Always ask" },
    },
    current = "automatic",
    onSelect = function(value, choice) end,
    anchor = anchor,
    close_callback = function() end,
}
```

The helper marks the current value with the existing `* ` text convention, closes before calling `onSelect`, and returns the dialog.

`showChecklistDialog(options)` builds a `ButtonDialog` for compact multi-toggle lists.

Expected options:

```lua
{
    title = "Dialog title",
    choices = {
        { value = "en", text = "English" },
        { value = "ja", text = "Japanese" },
    },
    isSelected = function(value, choice) return true end,
    onToggle = function(value, selected, choice) end,
    onDone = function() end,
    anchor = anchor,
    close_callback = function() end,
}
```

The helper shows selected items with the same `* ` convention, toggles without leaving the parent screen, and includes a `Done` button. If KOReader `ButtonDialog` cannot refresh button text in place, the helper may close and reopen on next tick while preserving the same public behavior.

Keep destructive confirmations in `SuwayomiUI.showConfirm`, backed by `ConfirmBox`.

## Settings Migration

Replace these full-screen settings menus with `showChoiceDialog`:

- `showParallelDownloadsMenu`
- `showLibraryCategoryPickerBehaviorMenu`
- `showDeleteFinishedWhileReadingMenu`

The settings controller should keep its existing save behavior:

- parallel download changes update `download_queue.max_active_chapters` and process the queue
- category picker behavior saves through `saveLibraryCategoryPickerBehavior`
- delete-while-reading saves through `saveDeleteChaptersSettings`

After each save, refresh the parent settings menu. Remove the old update helpers for these full-screen menus once their callers are migrated.

## Browse And Filter Migration

Keep the public `showLanguageMenu` facade name for compatibility, but replace its internals with `showChecklistDialog`. Preserve the existing source catalog controller behavior: toggling one language refreshes the filtered source list and updates the visible checked state.

In `buildSourceFilterRows`:

- `SelectFilter` rows should open `showChoiceDialog`.
- `SortFilter` rows should open a small sort dialog.
- `GroupFilter` rows should use a checklist dialog only when every child is an inline-compatible checkbox or tri-state filter and the group size is bounded.

For group size, start conservative: modal only when the group has at most 8 simple child filters. Larger or complex groups keep current nested menu behavior.

Remove duplicate source filter action rows for `Apply filters`, `Reset filters`, and `Search text` when title actions are available. Keep rows only as fallback if the title action menu is unavailable.

## Downloads Migration

Failed download rows should open a small action modal instead of retrying immediately. `Retry` should keep the current queue retry behavior and refresh the downloads hub after the user chooses it.

`Cancel all downloads` should call `SuwayomiUI.showConfirm` before clearing active and queued jobs.

## Testing

Add focused specs for the new helper module through the public `suwayomi/ui.lua` facade:

- `showChoiceDialog` marks the current choice, closes, and calls `onSelect`.
- `showChecklistDialog` marks selected choices and calls `onToggle`.
- checklist `Done` calls `onDone` and closes.

Update settings specs:

- parallel downloads opens a modal choice dialog and still updates queue concurrency
- library category picker opens a modal choice dialog and saves
- delete-while-reading opens a modal choice dialog and saves

Update browse specs:

- source language filter uses checklist dialog and preserves toggle refresh
- `SelectFilter` opens a choice dialog and updates row text
- `SortFilter` opens a sort dialog and updates row text
- small simple `GroupFilter` opens a checklist dialog
- large or complex `GroupFilter` keeps nested menu behavior
- source filter editor does not duplicate action rows when title actions are present

Update downloads specs:

- failed download row opens action dialog instead of retrying immediately
- choosing `Retry` retries and refreshes downloads
- `cancel_all` requires confirmation before queue mutation

Run local gates:

```bash
rtk luacheck --codes spec suwayomi main.lua _meta.lua
rtk busted spec
```

## Non-Goals

- Do not turn primary list surfaces into modals.
- Do not redesign source filter persistence or worker behavior.
- Do not add new Suwayomi API calls.
- Do not change chapter list, manga result, source catalog, extension catalog, global search result, or downloads hub layout beyond modal entry points.
