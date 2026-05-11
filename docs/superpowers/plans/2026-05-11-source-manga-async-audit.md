# Source Manga Async Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the remaining UI-thread source manga network fallback after the async source manga merge.

**Architecture:** Keep `suwayomi/browse/source_manga_worker.lua` as the only source manga network path. `SuwayomiClient:showMangaForSource` starts the worker and otherwise reports that loading cannot start.

**Tech Stack:** LuaJIT/Lua 5.1, busted specs, KOReader subprocess helper stubs.

---

### Task 1: Test Missing Runtime Behavior

**Files:**
- Modify: `spec/suwayomi_client_spec.lua`

- [x] Add a spec that creates a client without `source_manga_worker`, without `ffi_util.runInSubProcess`, and with an `api.fetchMangaForSource` stub that flips a flag.
- [x] Call `client:showMangaForSource({ id = "s1", name = "MangaDex" }, { skip_mode_menu = true })`.
- [x] Assert the API flag is still false and the user sees `Could not start manga loading.`
- [x] Run `busted spec/suwayomi_client_spec.lua` and verify this new spec fails because the synchronous fallback still calls the API.

### Task 2: Remove Source Manga Sync Fallback

**Files:**
- Modify: `suwayomi/client.lua`
- Modify: `spec/suwayomi_client_spec.lua`

- [x] Delete or stop using `fetchMangaForSourceSync`.
- [x] Change `showMangaForSource` so a failed `startSourceMangaLoad` shows `Could not start manga loading.` and returns.
- [x] Update existing browse specs that intentionally need loaded results to use an immediate source manga subprocess fake instead of sync fallback.
- [x] Run `busted spec/suwayomi_client_spec.lua` and verify it passes.

### Task 3: Refresh ANR Notes

**Files:**
- Modify: `docs/android-performance-testing.md`

- [x] Update the known weak spots so source manga is no longer listed as synchronous.
- [x] Keep the remaining warnings for library, chapter list, read-state, local metadata, and delete IO.

### Task 4: Verify And Commit

**Files:**
- All modified files

- [x] Run `$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; luacheck --codes spec suwayomi main.lua _meta.lua`.
- [x] Run `$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; busted spec`.
- [x] Commit with subject `fix: require async source manga loading`.
