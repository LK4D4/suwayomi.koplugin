# Suwayomi KOReader Plugin Roadmap

This roadmap tracks the practical path from the current experimental plugin to a solid, everyday reading tool.

Current scope assumption:
- The plugin is currently considered usable only with Suwayomi **Local Source**.
- We should make the Local Source flow boringly reliable before expanding support to other sources.

## Current Status

Implemented already:
- [x] Basic auth login flow
- [x] Source browsing
- [x] Manga browsing
- [x] Chapter browsing
- [x] Source language filtering
- [x] Download directory selection
- [x] Single-chapter `.cbz` download flow
- [x] Persistent download queue state
- [x] Recovery for interrupted downloads
- [x] Chapter actions dialog
- [x] Chapter actions: `Open`
- [x] Chapter actions: `Download`
- [x] Chapter actions: `Delete from device`
- [x] Chapter actions: `Mark as read`
- [x] Chapter actions: `Mark as unread`
- [x] Chapter selection mode
- [x] Read-state merge from Suwayomi, local ledger, and KOReader sidecar metadata
- [x] Background retry for pending read/unread syncs
- [x] Backgrounded `Mark as read` sync to avoid blocking the UI
- [x] App Store installation path

Known limitations:
- [x] Only Local Source is considered supported right now
- [x] Bulk actions currently start with selected chapter downloads only
- [x] Non-Local Source reading/downloading is not considered production-ready yet

## Phase 1: Finish the Local Source MVP

Goal: make the current Local Source reading loop feel complete and predictable.

- [x] Add chapter selection mode
- [x] Add bulk chapter actions entry point
- [x] Add bulk `Download`
- [x] Add bulk `Delete from device`
- [x] Add bulk `Mark as read`
- [x] Polish chapter status labels so `read`, `downloaded`, `queued`, and `failed` remain easy to scan
- [x] Decide and implement final `Mark as unread` behavior:
  Local plus Suwayomi sync
- [x] Improve small UX feedback after chapter actions where useful

Exit criteria:
- The plugin is comfortable for normal reading and library management inside KOReader without manual file cleanup.

## Phase 2: Real Bulk Download Policy

Goal: define what the plugin should download next, not just how to download one chapter.

- [x] Add `Download next N unread chapters`
- [x] Add `Keep next N unread chapters downloaded`
- [x] Add `Delete read chapters from device`
- [x] Define queue ordering clearly for chapter batches
- [x] Show lightweight queue/progress state in the chapter list for batch operations
- [x] Prevent obviously excessive queue sizes or duplicate batch requests

Exit criteria:
- Large manga can be managed from KOReader without one-by-one downloading.

## Phase 3: Read-State Model

Goal: make read state trustworthy across KOReader and Suwayomi.

- [x] Add manual `Sync read state now`
- [x] Add a ledger reconciliation sweep for downloaded chapters
- [x] Decide whether `Mark as unread` should sync back to Suwayomi
- [x] If yes, implement unread sync mutation flow
- [x] Improve diagnostics for read-state conflicts and sync failures

Exit criteria:
- Offline reading, KOReader state, and Suwayomi state converge predictably.

## Phase 4: Queue Robustness

Goal: make downloads survive interruption and failure cleanly.

- [x] Persist richer active download progress
- [x] Improve recovery after KOReader restart / Android process kill
- [x] Harden partial file cleanup and validation
- [x] Add clearer retry / cancel behavior
- [x] Improve failure messages so bad chapters are easier to diagnose

Exit criteria:
- Interrupted downloads recover safely and predictably.

## Phase 5: Expand Beyond Local Source

Goal: support non-Local Source flows only after the Local Source path is solid.

- [ ] Investigate non-Local Source chapter/page behavior against real instances
- [ ] Document source-specific quirks and unsupported cases
- [ ] Verify whether the current page-to-CBZ path is reliable across non-Local sources
- [ ] Add tests for at least one non-Local Source workflow
- [ ] Update README when non-Local Source support is genuinely usable

Exit criteria:
- The plugin can stop warning that only Local Source is considered supported.

## Phase 6: Release Polish

Goal: make the plugin easier for other users to install, understand, and debug.

- [ ] Add screenshots or short demo media for README
- [ ] Add release notes / changelog discipline
- [ ] Improve support diagnostics and debug logging guidance
- [ ] Add a short in-plugin about/version surface if useful
- [ ] Keep README and roadmap aligned with the real shipped state

Exit criteria:
- New users can install, configure, and understand the plugin without conversation context.

## Recommended Order

1. Phase 1: Finish the Local Source MVP
2. Phase 2: Real Bulk Download Policy
3. Phase 3: Read-State Model
4. Phase 4: Queue Robustness
5. Phase 5: Expand Beyond Local Source
6. Phase 6: Release Polish
