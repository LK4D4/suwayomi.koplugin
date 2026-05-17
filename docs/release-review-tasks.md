# Release Review Tasks

Generated from read-only architect and Staff Software Engineer review before release.
Do not treat checked boxes as complete until each task has its own fix, focused
test coverage, and local verification.

Fresh review baseline:

- Full specs: `busted spec` -> `564 successes`
- Lint: `luacheck --codes spec suwayomi main.lua _meta.lua` -> `124 files clean`
- Worktree at review time: `master...origin/master`, clean
- GitHub Actions were not run for this document-only follow-up by request.

## P1 Release Blockers

- [x] Drop stale extension worker results after credentials change.
  - Files: `suwayomi/browse/extensions.lua`, `spec/suwayomi_browse_extensions_spec.lua`
  - Risk: old server/auth can repaint the current Browse UI, then later extension install/update/uninstall can target the old server.
  - Direction: mirror the stale credential guard used by source fetch results before applying worker output or setting `current_extension_credentials`.
  - Test: simulate credentials changing while an extension worker is active; assert stale result is ignored and current extension credentials are unchanged.

- [x] Clear read-sync active state on subprocess timeout and cleanup.
  - Files: `suwayomi/readsync/controller.lua`, `spec/suwayomi_readsync_controller_spec.lua`
  - Risk: one read-sync timeout can leave `pending_read_sync_active` stuck forever, blocking manual and automatic sync until restart.
  - Direction: add timeout/cleanup handling that clears only the matching active job token after subprocess termination/reap.
  - Test: simulate timeout/reap path and assert a later sync can start.

- [x] Normalize persisted download queue before recovery.
  - Files: `suwayomi/settings.lua`, `suwayomi/downloads/job_store.lua`, `suwayomi/downloads/queue.lua`, settings/download queue specs
  - Risk: corrupt or legacy scalar `download_queue` can crash startup recovery through `ipairs`.
  - Direction: treat non-list persisted queue data as empty or recoverable invalid data before `JobStore` and queue recovery iterate it.
  - Test: recover from scalar/map/malformed queue settings without crashing and without losing valid jobs in mixed data.

## P2 Release Risks

- [x] Harden API parsers against malformed child nodes and missing IDs.
  - Files: `suwayomi/api/parsers.lua`, API parser specs
  - Risk: partial GraphQL responses can crash workers or turn missing IDs into the string `"nil"`.
  - Direction: reject non-table nodes and missing required IDs consistently in source, library update, page, and bulk-read parser paths.
  - Test: malformed source/update/page/bulk-read nodes return structured parse errors instead of crashes or `"nil"` IDs.

- [x] Cancel onboarding connection test when setup dialog closes.
  - Files: `suwayomi/plugin/settings_controller.lua`, `suwayomi/ui.lua`, plugin settings specs
  - Risk: user can cancel setup while the probe keeps running; stale result can update closed UI state or show a late toast.
  - Direction: wire cancel/back close to clear the active onboarding connection test and ignore stale completion.
  - Test: close setup while test active; assert worker canceled and no stale success/failure state is applied.

- [x] Avoid false "no chapters loaded" warning for Open first unread.
  - Files: `suwayomi/manga/controller.lua`, `spec/suwayomi_manga_controller_spec.lua`
  - Risk: valid first-unread action can show a warning before async chapter load/preload opens the chapter.
  - Direction: defer empty-context warning until after async load path has had a chance to populate chapters.
  - Test: first-time action with chapters not yet loaded does not emit the false warning.

- [x] Respect scanlator filter in Open first unread.
  - Files: `suwayomi/chapters/context.lua`, `suwayomi/manga/action_menu.lua`, chapter/manga specs
  - Risk: title action can open a hidden chapter from another scanlator while the filtered list shows only the selected scanlator.
  - Direction: share the filtered chapter iteration used by next-unread download behavior.
  - Test: with scanlator filter active, first unread comes from visible filtered chapters only.

- [x] Surface partial extension/source refresh failures after extension actions.
  - Files: `suwayomi/browse/extensions.lua`, `suwayomi/browse/extension_worker.lua`, browse extension specs
  - Risk: install/update/uninstall succeeds but follow-up catalog/source refresh fails silently, leaving stale UI with no retry clue.
  - Direction: preserve action success while warning about `extension_refresh_error` or `source_refresh_error`.
  - Test: worker returns partial refresh error; UI reports warning and avoids misleading full-success state.

- [x] Bound or page large library worker results.
  - Files: `suwayomi/network/request_worker.lua`, library/network worker specs
  - Risk: very large libraries can exceed the 4 MiB result cap and fail with generic network-request error.
  - Direction: avoid unbounded `all_manga` result growth or emit a clearer bounded failure before parent rejects the result file.
  - Test: large paged library data hits controlled behavior instead of opaque oversized-result failure.

- [x] Normalize persisted reader-return contexts.
  - Files: `suwayomi/settings.lua`, `suwayomi/reader_return.lua`, reader-return/settings specs
  - Risk: scalar `reader_return_contexts` setting can crash context save/open flow.
  - Direction: coerce non-table context stores to an empty table before assignment.
  - Test: scalar persisted contexts do not crash `rememberChapterContext`.

- [x] Recheck credentials before scheduled silent source refresh starts.
  - Files: `suwayomi/browse/controller.lua`, browse controller specs
  - Risk: delayed background refresh can still send old credentials after login/server change, even if stale result is later dropped.
  - Direction: compare current credentials at timer fire/start time and cancel if changed.
  - Test: schedule refresh, mutate credentials before timer fires, assert no worker starts with old credentials.

- [x] Normalize persisted download directory.
  - Files: `suwayomi/settings.lua`, `suwayomi/downloads/directory.lua`, `suwayomi/paths.lua`, settings/directory/path specs
  - Risk: non-string truthy setting can bypass chooser and crash path construction or create bad target paths.
  - Direction: treat non-string directory values as unset before path joins.
  - Test: scalar/table download directory settings fall back to chooser/default behavior.

- [x] Guard release tag against `_meta.lua` version drift.
  - Files: `.github/workflows/release.yml`, `_meta.lua`
  - Risk: `v*` tag can publish a zip whose KOReader metadata still reports an older version.
  - Direction: fail release if tag name does not match `_meta.lua` `version`.
  - Test: add workflow/script check or local equivalent for tag/version sync.

- [ ] Add PR CI smoke check for release payload.
  - Files: `.github/workflows/test.yml`, `.github/workflows/release.yml`
  - Risk: payload packaging regressions are discovered only at tag-release time.
  - Direction: build or stage the release payload during Test workflow and assert it includes only `_meta.lua`, `main.lua`, `README.md`, and `suwayomi/`.
  - Test: CI fails if docs/spec/.github/AGENTS or other dev-only files enter payload.

- [ ] Prune selected chapter state after same-manga refresh.
  - Files: `suwayomi/chapters/context.lua`, `suwayomi/chapters/actions.lua`, chapter specs
  - Risk: UI can show selected actions for stale chapter IDs, then act on a smaller set or say no chapters selected.
  - Direction: when chapter list refreshes for the same manga, drop selected IDs not present in the current visible/current chapter set.
  - Test: same-manga refresh removes stale selected IDs and updates selected count/actions.

- [ ] Verify CBZ exists before accepting terminal downloaded/skipped progress.
  - Files: `suwayomi/downloads/active_jobs.lua`, download queue/active job specs
  - Risk: stale/corrupt progress can mark missing CBZ downloaded, remove retry state, and notify archive-ready for a dead path.
  - Direction: check archive existence before clearing persistent job or notifying ready state for terminal progress.
  - Test: terminal `downloaded` or `skipped` progress with missing archive becomes failed/retained and sends no archive-ready notification.

- [ ] Deduplicate failed jobs against recovered active/queued jobs.
  - Files: `suwayomi/downloads/queue.lua`, `spec/suwayomi_download_queue_spec.lua`
  - Risk: corrupt settings can show same chapter active and failed; clearing failed can wipe status for active key.
  - Direction: apply recovered key dedup to failed jobs too.
  - Test: recovery with queued/downloading plus failed duplicate keeps only one canonical job state.

- [ ] Document collision suffixes in download path layout.
  - Files: `README.md`, `docs/ARCHITECTURE.md`
  - Risk: docs say `<chapter_name>.cbz`, while source can write `Chapter [id-398].cbz` for duplicate-safe names.
  - Direction: describe base layout plus duplicate-safe suffix behavior.
  - Test: docs review against `suwayomi_paths_spec.lua` duplicate-title coverage.

## P3 Polish

- [ ] Improve GraphQL oversized response error message.
  - Files: `suwayomi/api/transport.lua`, API transport specs
  - Risk: byte-cap failure reports as generic reachability, making support/debug harder.
  - Direction: preserve guarded sink error reason for GraphQL responses.
  - Test: oversized GraphQL response returns size-specific error.

- [ ] Improve archive stream timeout error message.
  - Files: `suwayomi/api/transport.lua`, API transport specs
  - Risk: network timeout can report as write failure.
  - Direction: distinguish stream timeout from local write error in final user-facing message.
  - Test: archive timeout path returns timeout-specific retryable error.

- [ ] Reap onboarding connection worker before deleting result path on timeout.
  - Files: `suwayomi/plugin/settings_controller.lua`, onboarding settings specs
  - Risk: low-impact orphan result file if child writes after early cleanup.
  - Direction: follow `SubprocessJob` normal terminate-and-reap cleanup pattern.
  - Test: timeout path keeps polling until child done, then removes result path.

- [ ] Show success feedback after selected delete removes files.
  - Files: `suwayomi/chapters/actions.lua`, chapter action specs
  - Risk: destructive action appears silent except row refresh, inviting repeat action.
  - Direction: always show bulk delete result message when at least one file was deleted.
  - Test: selected delete success asserts success toast/message.

- [ ] Guard `JobStore.upsertMany()` against malformed existing jobs.
  - Files: `suwayomi/downloads/job_store.lua`, job store specs
  - Risk: bad old settings entry without `key` can crash bulk download enqueue.
  - Direction: skip or normalize existing entries without valid keys before indexing.
  - Test: malformed existing job without key does not crash upsert.

- [ ] Fix duplicate numbering in README usage list.
  - Files: `README.md`
  - Risk: low doc polish issue.
  - Direction: renumber usage list.
  - Test: markdown diff review.

- [ ] Correct downloads UI boundary header.
  - Files: `suwayomi/ui/downloads.lua`, `README.md`
  - Risk: source header says completed rows exist while README says completed history is not implemented.
  - Direction: update boundary comment to match actual UI responsibility.
  - Test: source diff review only.
