# Manga Info Entrypoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make manga row taps open Manga Information, with Chapters acting as the detailed chapter/download workspace.

**Architecture:** Keep existing row-list ownership in `suwayomi/client/library.lua` and `suwayomi/client/source_manga.lua`; those flows already route selected manga through the manga controller. Change controller-level `showMangaActions` to open `showMangaInformation`. Keep chapter/download actions in the existing manga action menu used by chapter title menus. Manga Information gets only `Open chapters`, conditional `Open next unread`, and `Add/Remove from library`.

**Tech Stack:** Lua 5.1/LuaJIT, KOReader widget stubs, Busted specs, Luacheck.

---

### Task 1: Add Regression Specs

**Files:**
- Modify: `spec/suwayomi_manga_controller_spec.lua`
- Modify: `spec/suwayomi_client_library_spec.lua`
- Modify: `spec/suwayomi_client_source_manga_spec.lua`

- [ ] **Step 1: Test Manga Information action surface**

Add assertions that `performMangaAction(manga, "manga_information")` exposes `open_chapters`, conditional `open_first_unread`, and the current library action, but not bulk/download/delete actions.

- [ ] **Step 2: Test Library row tap opens Manga Information**

Update library row-selection specs to expect `showMangaInformation` through `showMangaActions`, while preserving `onMangaUpdated` refresh callbacks.

- [ ] **Step 3: Test Browse row tap opens Manga Information**

Update source manga row-selection specs to expect `showMangaInformation` through `showMangaActions`, while preserving source attachment and refresh callbacks.

- [ ] **Step 4: Run focused tests and verify RED**

Run:

```bash
rtk busted spec/suwayomi_manga_controller_spec.lua spec/suwayomi_client_library_spec.lua spec/suwayomi_client_source_manga_spec.lua
```

Expected: failures showing missing `add_to_library` or `remove_from_library` in Manga Information, because implementation has not changed yet.

### Task 2: Implement Entrypoint Behavior

**Files:**
- Modify: `suwayomi/manga/controller.lua`

- [ ] **Step 1: Add a small Manga Information action builder**

In `suwayomi/manga/controller.lua`, build info actions separately from full manga actions:

```lua
local info_actions = {
    { id = "open_chapters", text = _("Open chapters") },
}
if MangaActionMenu.canOpenFirstUnread(self, manga) then
    table.insert(info_actions, { id = "open_first_unread", text = _("Open next unread") })
end
if manga and manga.id then
    if manga.in_library == true then
        table.insert(info_actions, { id = "remove_from_library", text = _("Remove from library"), destructive = true })
    else
        table.insert(info_actions, { id = "add_to_library", text = _("Add to library") })
    end
end
```

- [ ] **Step 2: Make `showMangaActions` open Manga Information**

Change `showMangaActions` to call `performMangaAction(manga, "manga_information", action_options)` when `showMangaInformation` is available. Keep fallback to `showChaptersForManga` when neither action UI nor Manga Information is available.

- [ ] **Step 3: Keep full action menu available for chapter title menus**

Do not add a long-press path. Leave `getMangaActions`, `showBulkDownloadMangaActions`, and shared chapter-menu action handling intact so downloads remain in Chapters.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
rtk busted spec/suwayomi_manga_controller_spec.lua spec/suwayomi_client_library_spec.lua spec/suwayomi_client_source_manga_spec.lua
```

Expected: all focused specs pass.

### Task 3: Verify And Commit

**Files:**
- All touched files.

- [ ] **Step 1: Run full test suite**

Run:

```bash
rtk busted spec
```

Expected: all specs pass.

- [ ] **Step 2: Run lint**

Run:

```bash
rtk luacheck --codes spec suwayomi main.lua _meta.lua
```

Expected: clean.

- [ ] **Step 3: Check diff and whitespace**

Run:

```bash
rtk git diff --check
rtk git status --short
```

Expected: no whitespace errors; only intended files changed.

- [ ] **Step 4: Commit**

Run:

```bash
rtk git add docs/superpowers/plans/2026-05-20-manga-info-entrypoint.md spec/support/suwayomi_client_spec_helper.lua spec/suwayomi_manga_controller_spec.lua spec/suwayomi_client_library_spec.lua spec/suwayomi_client_source_manga_spec.lua suwayomi/manga/controller.lua
rtk git commit -m "feat: make manga info row entrypoint"
```
