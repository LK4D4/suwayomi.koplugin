# Manga Info Poster Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show manga information posters from a poster-sized decoded cache instead of stretching square row thumbnails.

**Architecture:** Keep remote image download and decode in the existing thumbnail subprocess worker. Extend thumbnail cache paths with a non-leaking variant key so list thumbnails stay `96x96` and manga information can request a `poster` bitmap. Manga information reads poster cache first and falls back to existing placeholder when no poster has been decoded yet.

**Tech Stack:** LuaJIT, KOReader `RenderImage`, KOReader `ImageWidget`, Busted, Luacheck.

---

### Task 1: Cache Variants

**Files:**
- Modify: `suwayomi/ui/thumbnail_cache.lua`
- Test: `spec/suwayomi_ui_thumbnail_cache_spec.lua`

- [x] Add failing specs proving decoded poster paths differ from decoded thumbnail paths, do not leak source data, and can be found via variant options.
- [x] Implement optional `options.variant` for `getKey`, `getPath`, `find`, `writeDecoded`; default stays `thumbnail`.
- [x] Run `rtk busted spec/suwayomi_ui_thumbnail_cache_spec.lua`.

### Task 2: Worker Target Size

**Files:**
- Modify: `suwayomi/ui/thumbnail_worker.lua`
- Test: `spec/suwayomi_ui_thumbnail_worker_spec.lua`

- [x] Add failing spec where `worker:run(..., { variant = "poster", width = 240, height = 360 })` passes `240x360` to `RenderImage:renderImageData` and writes decoded cache with same options.
- [x] Keep default run path at `96x96`.
- [x] Run `rtk busted spec/suwayomi_ui_thumbnail_worker_spec.lua`.

### Task 3: Manga Info Poster Lookup

**Files:**
- Modify: `suwayomi/ui/manga_info.lua`
- Test: `spec/suwayomi_ui_spec.lua`

- [x] Add failing spec proving manga info uses `ThumbnailCache.find(credentials, thumbnail_url, { variant = "poster" })`.
- [x] Update lookup to prefer poster variant before any legacy `manga.thumbnail_path`.
- [x] Keep `ImageWidget` guarded with `pcall` and `scale_factor = 0`.
- [x] Run `rtk busted spec/suwayomi_ui_spec.lua`.

### Task 4: Verification And Commit

**Files:**
- Modify: no additional files.

- [x] Run `rtk luacheck --codes spec suwayomi main.lua _meta.lua`.
- [x] Run `rtk busted spec`.
- [x] Review `rtk git diff`.
- [x] Commit with Conventional Commit subject.

### Task 5: Loading Placeholder Follow-Up

**Files:**
- Modify: `suwayomi/ui/manga_info.lua`
- Test: `spec/suwayomi_ui_spec.lua`

- [x] Add failing spec proving manga info shows `Loading...` while the poster worker is active.
- [x] Keep `No poster` for rows with no thumbnail URL.
- [x] Clear loading state and refresh content when poster worker finishes, times out, or errors.
