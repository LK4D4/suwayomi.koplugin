# Unified Title Menu Design

## Goal

Make every full-screen Suwayomi plugin menu use the same KOReader-native title bar:

- left burger button
- centered title
- right close button
- consistent font, spacing, icon sizing, and KOReader press feedback

The burger button should always open a title action menu. That action menu must always include `Suwayomi home`, even when it is the only available action.

## Current Problem

Title-bar behavior is spread across multiple modules:

- Library currently has no left title button.
- Chapters and Downloads hand-build burger callbacks in their controllers.
- Browse still uses the old `getHomeMenuOptions()` direct-home title action.
- UI modules receive loose option tables, so visual style and title-button meaning can drift.

This creates inconsistent visuals and ambiguous navigation. A title-bar button may mean direct Home on one screen and actions on another.

## Architecture

Add a focused plugin-bound controller mixin:

`suwayomi/plugin/title_menu.lua`

This controller owns shared title-menu behavior only. It does not own screen-specific action semantics.

Public methods:

- `getTitleBarMenuOptions(screen_options)`
  Returns a native title-bar option table with `title_bar_left_icon = "appbar.menu"` and a left-tap callback that opens the title action menu.

- `buildTitleBarActions(screen_actions)`
  Returns a new action list with `Suwayomi home` prepended before any screen-specific actions.

- `showTitleBarActionMenu(menu, screen_options)`
  Opens the title action dialog for the current screen.

- `performTitleBarAction(menu, action, screen_options)`
  Handles `home` centrally and delegates non-home actions to `screen_options.onSelect`.

Install this mixin from `main.lua` alongside the existing plugin controllers.

## UI Responsibilities

Keep KOReader widget construction in UI modules:

- `suwayomi/ui/menu_utils.lua` keeps the native title-bar style helper and callback plumbing.
- `suwayomi/ui.lua` adds a generic `showActionMenu(options, onSelectCallback)` renderer.
- Existing `showChapterActionsMenu` and `showMangaActionsMenu` remain as compatibility wrappers around `showActionMenu`.
- `suwayomi/ui/browse.lua` and `suwayomi/ui/downloads.lua` continue to construct native `Menu` rows only.

All plugin screens with a title burger should pass through `menu_utils.applyNativeTitleBarStyle`, which sets `title_bar_fm_style = true` whenever a left title icon is present.

## Controller Responsibilities

Controllers remain responsible for screen-specific actions:

- Library and category screens provide no screen-specific actions at first, so burger contains only `Suwayomi home`.
- Browse source list provides `Global search`.
- Global search results provide `Cancel search` while a search is running.
- Chapters provide the existing bulk chapter actions.
- Downloads provides the existing hub actions such as cancel queued downloads and clear failed jobs.

The shared title-menu controller prepends Home and dispatches the selected action back to the owner callback.

## Screen Behavior

All full-screen plugin menus should use the same title structure: burger, title, close.

- Library category picker: `Suwayomi home`.
- Library manga list: `Suwayomi home`.
- Browse source list: `Suwayomi home`, `Global search`.
- Browse source mode: `Suwayomi home`.
- Browse manga results: `Suwayomi home`; previous and next page remain list rows for now.
- Global search results: `Suwayomi home`, and `Cancel search` while active.
- Chapters: `Suwayomi home`, then current bulk actions.
- Downloads: `Suwayomi home`, then current download hub actions when available.

Nested action dialogs should not become title-bar screens in this pass. For example, chapter burger opens the title action dialog, and choosing `Bulk downloads` may still open the existing nested bulk-download dialog.

## Deprecating Home Options

Replace `getHomeMenuOptions()` with `getTitleBarMenuOptions()`.

The old name and behavior are misleading because they mean a direct Home title-button action. The new model is a burger title menu with Home inside. Migration can keep a temporary alias only if needed, but the final state should remove direct callers of `getHomeMenuOptions()`.

## Implementation Steps

1. Add `suwayomi/plugin/title_menu.lua` and install it from `main.lua`.
2. Add `SuwayomiUI.showActionMenu` and keep chapter/manga action wrappers.
3. Update `menu_utils.applyTitleBarOptions` so left-tap callbacks receive the native menu consistently.
4. Migrate Downloads to use `getTitleBarMenuOptions`.
5. Migrate Chapters to use `getTitleBarMenuOptions`.
6. Migrate Browse and global search from `getHomeMenuOptions`.
7. Migrate Library category and manga screens to use the shared burger.
8. Remove or stop using `getHomeMenuOptions`.

## Tests

Add or update specs for:

- title menu actions always prepend `Suwayomi home`
- Home closes plugin screens and opens the hub
- non-home title actions delegate to the screen owner
- all full-screen plugin menus pass `appbar.menu` and `title_bar_fm_style`
- Library/category screens get burger title options
- Chapters keep existing bulk actions behind the shared title menu
- Downloads keeps existing hub actions behind the shared title menu
- Browse source/global search actions continue to work

Manual Palma verification:

- Library, Browse, Chapters, and Downloads show the same burger/title/cross layout.
- Buttons are fully visible inside the screen.
- Tapping the centered title does nothing.
- Tapping burger opens a menu containing `Suwayomi home`.
- Chapter burger opens actions rather than navigating directly Home.

## Risks

The main behavioral risk is changing users' muscle memory: Library and Browse will now require one extra tap to go Home. This is intentional for consistency and to avoid ambiguous title hit behavior.

The main implementation risk is nested dialogs. Keep nested chapter/download dialogs unchanged during this refactor to avoid broad menu-stack changes.

The title bar should stay KOReader-native. Do not reintroduce custom `TitleBar` construction for this feature.
