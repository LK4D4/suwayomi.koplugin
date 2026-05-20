# Manga Info UI Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the manga information dialog stable and readable while rendering common description markup safely.

**Architecture:** Keep changes inside `suwayomi/ui/manga_info.lua` plus focused specs. Layout remains a small solver feeding KOReader widget construction. Markup normalization remains an allowlisted formatter for `ScrollHtmlWidget`.

**Tech Stack:** LuaJIT/Lua 5.1, KOReader widget stubs, Busted, Luacheck.

---

### Task 1: Lock Layout Regressions

**Files:**
- Modify: `spec/suwayomi_ui_spec.lua`
- Modify: `suwayomi/ui/manga_info.lua`

- [ ] Add failing specs proving e-reader portrait stays split even with long metadata, stacked description gets useful height, and stacked mode has one scroll owner.
- [ ] Run `rtk busted spec/suwayomi_ui_spec.lua`; expected fail on current layout.
- [ ] Change `computeDialogBounds()` and `computeContentLayout()` so screen class chooses layout and stacked description uses available body height.
- [ ] In stacked mode, avoid nested scroll owners by using a non-scrolling HTML description inside body scrolling.
- [ ] Run `rtk busted spec/suwayomi_ui_spec.lua`; expected pass.

### Task 2: Fix Description Markup

**Files:**
- Modify: `spec/suwayomi_ui_spec.lua`
- Modify: `suwayomi/ui/manga_info.lua`

- [ ] Add failing specs for `**bold**`, `_italic_`, headings, bullet lists, bare URLs, safe links, and literal angle-bracket text.
- [ ] Run `rtk busted spec/suwayomi_ui_spec.lua`; expected fail on current formatter.
- [ ] Rewrite `MangaInfo.buildDescriptionHtml()` to escape raw text, protect allowlisted markdown/html tokens, and preserve unsupported tags as text.
- [ ] Run `rtk busted spec/suwayomi_ui_spec.lua`; expected pass.

### Task 3: Verify And Review

**Files:**
- Verify all touched files.

- [ ] Run `rtk luacheck --codes spec suwayomi main.lua _meta.lua`.
- [ ] Run `rtk busted spec`.
- [ ] Dispatch reviewer subagent for manga-info UI diff.
- [ ] Fix any important reviewer findings.
- [ ] Commit with an imperative Conventional Commit subject.
