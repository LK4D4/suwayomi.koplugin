# Stability And Recovery Async Audit

Scope: Priority 1 from `docs/superpowers/specs/2026-05-22-plugin-roadmap.md`.

## Summary

Most stale-result protections already live at controller/client boundaries, not in pure worker modules. The remaining concrete Priority 1 gaps are:

- Library network requests can finish after full plugin close unless the client cancels them.
- Source fetch and extension workers can finish after full plugin close unless Browse cancels them or ignores late completions.
- Read sync has to stop active/scheduled UI-lifetime work on plugin close without deleting pending ledger state that must retry later.
- Library timeout copy is generic and does not tell the user what action to take.
- Browse chapter-count timeout state is boolean-only, so rows cannot explain that the chapter count failed while manga remains tappable.
- Golden-flow device QA existed only in roadmap prose, not in a reusable checklist.

## Coverage Map

| Surface | Owner | Existing coverage | Priority 1 action |
| --- | --- | --- | --- |
| Source manga and filters | `suwayomi/client/source_manga.lua` | `spec/suwayomi_client_source_manga_spec.lua` covers stale source-filter results, cancellable source manga load, timeout retry rows, stale source manga results, append retry, append close, and chapter-count page switch cancellation. | Keep controller-level stale tests; do not add worker-only stale tests. |
| Global search | `suwayomi/client/global_search.lua` | `spec/suwayomi_client_global_search_spec.lua` covers timeout cleanup, late finish handling, cancel active and pending jobs, and retry summary behavior. | No code change planned. |
| Library | `suwayomi/client/library.lua` | `spec/suwayomi_client_library_spec.lua` covers stale category request cancellation. | Add explicit `cancelLibraryNetworkRequests()` and plugin-close coverage; improve timeout copy. |
| Manga actions and chapter loads | `suwayomi/manga/controller.lua` | `spec/suwayomi_manga_controller_spec.lua` covers stale chapter loads, active request cancellation, route-close targets, and source-only close target branches. | No code change planned. |
| Reader return | `suwayomi/reader_return.lua` | `spec/suwayomi_reader_return_spec.lua` covers stale reader-return results after document/context changes and cancel paths. | No code change planned. |
| Read sync | `suwayomi/readsync/controller.lua` | `spec/suwayomi_readsync_controller_spec.lua` covers stale/failed entry preservation, timeout cleanup, failure backoff, manual sync, and document-close sync. | Add plugin-close cancellation while preserving pending ledger state. |
| Source fetch | `suwayomi/browse/controller.lua` | `spec/suwayomi_browse_controller_spec.lua` covers timeout cleanup, silent timeout cleanup, stale credential result drop, and silent refresh cancellation. | Add explicit close cancellation and late-finish ignore coverage. |
| Extension mutations | `suwayomi/browse/extensions.lua` | `spec/suwayomi_browse_extensions_spec.lua` covers timeout cleanup, stale worker drops, action-aware mutation timeouts, refresh warnings, close state, and focus after actions. | Add explicit close cancellation and late-finish ignore coverage. |
| Thumbnail jobs | `suwayomi/ui/list_menu.lua` | `spec/suwayomi_ui_list_menu_spec.lua` covers stale thumbnail generation and timeout refresh; close cancellation is implemented by `cancelThumbnailJobs(menu)`. | Run focused spec; add no new code unless it fails. |
| Download queue recovery | `suwayomi/downloads/queue.lua`, `suwayomi/downloads/active_jobs.lua`, `suwayomi/downloads/job_store.lua` | `spec/main_spec.lua`, `spec/suwayomi_download_queue_spec.lua`, and `spec/suwayomi_downloads_active_jobs_spec.lua` cover recovery on init, interrupted recovery, corrupt records, dedupe, archive-exists cleanup, failed-job recovery, and watchdog failure. | Keep existing specs and include recovery steps in golden-flow QA. |
| Release payload smoke | `.github/scripts/stage-release-payload.sh`, `.github/workflows/test.yml`, `.github/workflows/release.yml` | CI already runs release payload staging; local release workflow also uses it. | Include smoke command in golden-flow/pre-release gates. |

## Worker-Level Decision

Do not add stale-result tests to pure worker specs such as `spec/suwayomi_source_fetch_worker_spec.lua`, `spec/suwayomi_extension_worker_spec.lua`, `spec/suwayomi_source_manga_worker_spec.lua`, `spec/suwayomi_global_search_worker_spec.lua`, or `spec/suwayomi_ui_thumbnail_worker_spec.lua`. Those workers normalize request/result files and do not own UI route lifetime. Stale gating belongs to the caller that owns active tokens, close callbacks, and credentials.

## Verification Commands

Run after implementing this plan:

```bash
rtk busted spec/main_spec.lua spec/suwayomi_client_library_spec.lua spec/suwayomi_client_source_manga_spec.lua spec/suwayomi_ui_list_rows_spec.lua spec/suwayomi_ui_list_menu_spec.lua
rtk busted spec/suwayomi_browse_controller_spec.lua spec/suwayomi_browse_extensions_spec.lua spec/suwayomi_readsync_controller_spec.lua
rtk luacheck --codes spec suwayomi main.lua _meta.lua
rtk busted spec
rtk git diff --check
bash .github/scripts/stage-release-payload.sh
```
