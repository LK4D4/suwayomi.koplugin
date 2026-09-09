# Suwayomi KOReader Plugin Architecture

This is the current runtime map, not a plan for new abstractions. Prefer existing owners; a new behavior does not automatically need another facade, adapter, or service. See [domain guidance](agents/domain.md) for terminology, decision precedence, and historical specs.

## Runtime Shape

KOReader loads `_meta.lua` and `main.lua`. The shell registers actions/menus, constructs dependencies, installs controller methods, and attaches disposable FileManager/ReaderUI subscriptions to one process-owned download service. Feature behavior lives under `suwayomi/`.

A screen owns its requests and widgets, not download lifetime. Closing a host retires its requests/subscriptions without consuming KOReader's CloseWidget event. Downloads, completion bookkeeping, and cleanup continue while the main loop runs, even with no plugin screens open.

## Module Ownership

Use this map before broad searches. Directory-qualified paths are relative to the plugin root; bare filenames share the preceding module directory. Public entrypoints are marked **facade**; subordinate files own implementation, not competing APIs.

| Area | Owners and boundaries |
| --- | --- |
| Shell and settings UI | `main.lua`; `suwayomi/plugin/home.lua`, `title_menu.lua`, `settings_controller.lua`, and `onboarding_connection_worker.lua` own the hub, shared title menus, setup/settings, and connection probe. |
| Navigation and reader return | `suwayomi/navigation.lua` owns the widget stack. `suwayomi/reader_return.lua` reloads chapters asynchronously, validates the request before reader teardown, then publishes through the live `FileManager.instance.suwayomi`, never the retired reader plugin. |
| Server API | **Facade** `suwayomi/api.lua` composes `suwayomi/api/queries.lua`, `parsers.lua`, and `transport.lua`: GraphQL payloads, defensive normalization, and HTTP/auth/URL/byte limits. Complete stored pagination belongs to the facade. |
| Library and source browsing | **Facade** `suwayomi/client.lua` installs flows from `suwayomi/client/`: `library.lua`, `source_manga.lua`, `global_search.lua`, `browse_chapter_counts.lua`; `runtime.lua` and `util.lua` support those flows. Source browsing owns saved-filter metadata and result pagination. |
| Source catalog and extensions | `suwayomi/browse/controller.lua`, `source_catalog.lua`, and `extensions.lua` own source loading/cache, filtering, and extension actions. `suwayomi/source_languages.lua` owns language labels; `suwayomi/source_filters.lua` normalizes drafts/saved filters and builds `FilterChange` values. |
| Browse workers | `suwayomi/browse/*_worker.lua` isolates source fetch, extensions, source filters, source manga, global search, and chapter-count requests. Global search can publish partial results and isolate slow-source failures. |
| Manga actions | `suwayomi/manga/controller.lua` owns async chapter loading/preloads, library membership, first-unread, and manga-level actions. `action_menu.lua` shares action definitions with chapter menus. |
| Shared UI | **Facade** `suwayomi/ui.lua` delegates menus/dialogs to `suwayomi/ui/`. `browse.lua` builds Browse menus; `menu_utils.lua` owns shared menu plumbing. `list_rows.lua` formats rows; `list_menu.lua` renders thumbnail lists. `manga_menu.lua` is an alias for `list_menu.lua`, not another renderer. `thumbnail_cache.lua`/`thumbnail_worker.lua` own cached images and fetches. `manga_info.lua` renders the information dialog. |
| Chapter UI and commands | `suwayomi/chapters/context.lua` owns current context/filtering; `menu.lua` owns rendering/selection; **facade** `actions.lua` dispatches single/bulk actions and guarded Verify/Redownload/open. `read_actions.lua` owns checked read/unread coordination. |
| Download service and refill | `suwayomi/downloads/service.lua` owns the process singleton, subscriptions, checked completion, refill, and shared quit integration. `refill.lua` owns request/origin persistence, one context helper, automatic admission, and guarded Retry/Stop. `cleanup_adapter.lua` gives finished cleanup a process-owned receiver with current-reader lookup. |
| Download queue and workers | **Facade** `suwayomi/downloads/queue.lua` owns admission/retry/cancel/recovery/snapshots/verification. `active_jobs.lua` owns scheduling, progress, retries, completion-save retries, and known stopping workers. `job_store.lua`, `progress_file.lua`, and `status_formatter.lua` own persisted jobs, attempt progress IO, and status text. |
| Archive transfer and validation | `suwayomi/downloads/downloader.lua` obtains pages/archives and publishes validated CBZs. `archive.lua` owns attempt IDs, ZIP inspection/checksums, embedded metadata, and observational fingerprints. |
| Download UI and directory | `suwayomi/downloads/controller.lua` owns active/queued/failed actions and error/repair flows; `suwayomi/ui/downloads.lua` renders them. `suwayomi/downloads/directory.lua` handles choosing/persisting destinations through `suwayomi/ui/directory.lua`. |
| Manual archive removal | `suwayomi/chapters/manual_deletion.lua` owns generation-bound admission, revocation, processing/recovery, and snapshots. `archive_identity.lua` supplies filesystem evidence, containment/alias checks, and live-reader protection. |
| Ordinary Delete and retention | `suwayomi/chapters/local_downloads.lua` owns local existence/open helpers and metadata-before-archive removal. `delete_actions.lua` coordinates guarded removal/bookkeeping. `finished_cleanup.lua` owns finish order, retention positions, retries, and immutable target snapshots. |
| Read state and metadata | **Facade** `suwayomi/readsync/controller.lua` schedules sync/reconciliation and checked completed-close enrollment; `ledger.lua`, `worker.lua`, and `koreader_metadata.lua` own checked read/refill persistence, remote sync, and KOReader sidecar metadata. |
| Settings and paths | `suwayomi/settings.lua` normalizes settings and exposes persistence; `suwayomi/settings/store.lua` owns checked atomic replacement/reconciliation. `suwayomi/settings/retention_labels.lua` shares plural-aware labels for unchanged values 0–5. `suwayomi/paths.lua` sanitizes path segments and builds source-scoped paths. |
| One-shot requests | `suwayomi/network/request_job.lua`/`request_worker.lua` serve Library, reader return, and chapter-context requests. `suwayomi/subprocess/job.lua` owns JSON result files, polling, timeout/cancel, reaping, and cleanup; callers supply workers/parsers/callbacks. |
| Localization and diagnostics | `suwayomi/i18n.lua` owns gettext/template formatting; `suwayomi/i18n/locales.lua` owns locale aliases/fallbacks. `suwayomi/debug.lua` owns opt-in redacted diagnostics. |

## Authentication

`suwayomi/api/transport.lua` owns Basic Auth, Simple Login, UI Login, endpoint construction, GraphQL requests, archive downloads, binary page fetches, and bounded response sinks. Credentials remain in settings; session cookies and JWT tokens never enter settings, worker results, or logs.

- Simple Login keeps one credential-scoped cookie in process memory. A rejected session permits one login and one request replay.
- UI Login keeps one credential-scoped access/refresh token pair in process memory. It renews reactively after definite rejection: one refresh, then one saved-credential login only if the refresh token is definitively rejected. Recovery permits at most one replay of the protected request. Refresh timeouts, network/server errors, and unrecognized responses do not permit login fallback. Token calls omit access credentials; refresh retains the existing, nonrotating refresh token. Rejection proof uses the pinned server's GraphQL error path, exception class, and refresh stack frames rather than arbitrary HTTP or error text.
- GraphQL's HTTP-200 auth errors are replayable only when every unaliased root emitted by a builder was rejected by Suwayomi's pre-resolver auth guard, with no returned data. This includes the two-root manga refresh. Ambiguous network failures and partially rejected mutations are never replayed by authentication recovery. Unsupported aliases, fragments, and directives cannot authorize replay.
- GraphQL diagnostics cross the transport boundary as safe classifications, not private response text. Transient source errors retain bounded download retries across authentication methods. Recognized validation-only responses preserve legacy schema fallback; partial execution never authorizes that fallback or authentication replay.
- External image origins receive no credentials, cookies, or tokens. Simple Login and UI Login requests do not follow redirects. HTTP remains supported; HTTPS is recommended.

Credential dialogs explicitly select the authentication method. Changing the method invalidates the setup connection test. The connection test queries protected category access and validates the GraphQL result; public introspection alone does not prove authentication. Existing workers retain their captured credentials; later attempts load the current settings. Processes renew their own sessions without cross-process coordination. Authentication failures retain the existing manual download Retry behavior and pending read-sync policy.

## Download ownership

[ADR-0002](adr/0002-navigation-safe-download-ownership.md) owns navigation and bounded quit; [ADR-0005](adr/0005-automatic-download-restart.md) owns restart, isolated attempts, and archive validation. Navigation and sleep/wake preserve the queue, workers, retry deadlines, and concurrency limit. Subscriber deliveries are deferred, isolated, and invalidated on detach; reopened or uncovered screens render current snapshots.

### Persistence and worker lifetime

- `settings/store.lua` replaces the complete shared document atomically. Finite numeric keys and values round-trip without losing archive identity precision; historical rounded identities remain untrusted. A rejected pre-replacement write preserves committed state; an uncertain replacement fences writes until reconciliation. Queue reconciliation reconstructs committed work before resuming launches/polling.
- Completion commits queue state, ledger path, and reader-return context together, preserving current read/pending-sync choices. A rejected completion save retains in-session ownership and retries bookkeeping, not the transfer. UI notification follows persistence and snapshot updates.
- Known stopping children retain chapter/file associations and concurrency reservations until `ffi/util.isSubProcessDone` confirms exit. Unrelated ready jobs may use spare slots. Queue removal is not proof of worker exit. Cancel/retry/timeout/reconciliation share this tracking; temporary cleanup preserves final CBZs. An archive produced during cancellation receives completion bookkeeping.
- Startup runs once before admission. Supported unfinished jobs with complete identities and destinations requeue with retry counts and future deadlines intact; restart spends no retry. Startup and reconciliation preserve incomplete, unsupported, and permanently failed keyed records without scheduling them. Workers validate existing archives before completion. Failed startup saves retry while admission remains blocked. Startup never sweeps temporary files.
- One idempotent `UIManager.quit` wrapper stops admission/timers and makes a nonblocking best-effort pass over known context, inspection, and chapter workers within one total two-second budget. It preserves the previous method's arguments/returns and requires no final save or future UI tick. Unconfirmed worker files remain untouched.

### Archive publication and repair

Every transfer has an OS-random attempt ID and private archive/progress temporary files. The worker closes and validates the CBZ, embeds attempt/expected-count metadata when available, then publishes by same-filesystem rename. A failed rename never authorizes deleting the previous archive. Optional server archive export falls back to device-local page downloading on HTTP 400 or 404; it never queues server downloads. Transient failures retry; authentication/filesystem failures remain failures.

Full validation checks ZIP structure, entry reads/checksums, and a captured expected page count when available. It does not prove content correctness or fetch current server metadata for offline validation. Run it off the UI thread before publication, adoption of an existing archive, plugin-mediated open, or explicit Verify download—not during row rendering. KOReader FileManager opens and generic reader failures are outside this boundary.

`DownloadQueue:verifyArchive` allows at most one explicit background inspection, retains helper files until confirmed exit, and checks archive identity plus the live request before committing results. Damage and inconclusive inspection are distinct: an I/O/permission/validator failure does not authorize deletion or automatic open. Rows show the latest known status, not a guarantee of inspection.

Only explicit Redownload authorizes repair. Normal admission and Download ahead cannot repair known damage. The repair job retains authorization, its supported pathname (including older filenames), generation, and integrity evidence across retry/restart. The old archive and reading metadata remain until validated replacement succeeds. `koreader_metadata.lua` preserves hash originals and copies primary/backup metadata into document-path storage; conflicting candidates or failed inspection/writes refuse replacement. Changed contents may change the meaning of a saved page position.

Attempt cleanup covers only the worker's own files or files of a worker whose exit this process confirms. Unknown leftovers may remain indefinitely. Untracked survivors can exceed current-process concurrency, duplicate transfers, or publish later—even after cancellation. New attempt isolation does not fix surviving pre-upgrade workers. Hot reload and simultaneous writable KOReader processes are unsupported; no cross-process lock, boot tracker, or cleanup registry is implied.

## Download ahead

[ADR-0004](adr/0004-durable-download-ahead-refill.md) is implemented by the process-owned refill service. The versioned `download_refill` collection stores one coalesced request per manga and verified endpoint associations, not credentials or chapter lists. Completed closes, manual read/unread, actual reconciliation, successful context publication, and policy/filter actions enroll work. Read changes, manual intent, and enrollment commit together; rendering and queue progress are not triggers.

One read-only context helper runs across manga independently of chapter concurrency, with private random result paths. Before admission, recheck endpoint, policy, exact scanlator, destination, and read/pending-sync state. A sync acknowledgment invalidates an older result even when it only clears pending flags. Automatic jobs and consumption of the matching request revision commit together. Owned, failed, and deletion-fenced chapters still occupy the earliest 5/10/50 unread positions; no backfill or automatic terminal Retry occurs.

Startup recovers only recorded requests. Transient retries use persisted five-second exponential deadlines capped at five minutes. Rejected requests and unsupported/configuration/identity blockers stay quiet and inspectable. Stop atomically turns policy Off and retires requests, leaving jobs intact. Accepted chapter cancellation retires that manga's evaluation; Cancel all retires every evaluation without disabling policies. Only a later independent trigger can enroll new work.

Origin survives queue publication and explicit plugin Open. Closing an unknown legacy archive cannot associate it with the current server. Fresh context plus an explicit association action establishes scope; opening an existing archive also records its scope. Endpoint scopes exclude credential-bearing userinfo, query strings, and fragments.

Manga and chapter controls show the saved Download-ahead value and check the selected option when opened, not a captured default. Pending controls show current reasons and fixed retry times; Retry/Stop reject stale callbacks. Retention remains independent when Download ahead is Off.

## Manual deletion and retention

[ADR-0003](adr/0003-durable-manual-delete-intent.md) defines the archive-only manual contract. The process service owns its versioned `manual_archive_state`, monotonic generations/revisions, captured targets/roots, progress, and retry deadlines. Fresh authorized actions or publications establish identity; historical records and uncertain targets are not silently adopted.

Queued/running/stopping/finalizing download ownership prevents manual-delete acceptance without canceling that work. Accepted requests unlink only the captured CBZ and preserve all metadata. Before removal, the processor revalidates revision, generation, filesystem evidence, resolved containment/aliases, current reader, and download ownership. Leaf symlinks and unsupported identities block removal. Stat followed by unlink is not a guarantee against uncoordinated external writers.

Read state and accepted intent commit before removal. Progress and matching bookkeeping use separate checked saves, so recovery after unlink completes only the original obligation. Newer read/sync, queue, path/generation, and reader-return state survive. Unknown versions preserve records/files. Quiet retries start at five seconds, double to five minutes, and have no count-based abandonment; bounded fair processing continues with zero views.

Unread revokes remaining intent at the checked ledger boundary, including remote unread accepted during action preload. An absent read field has the same unread meaning during deferred processing; no menu refresh is required. Only an actually accepted deliberate download supersedes intent in the same checked admission transaction; failed, uncertain, duplicate, or automatic admission cannot. Directory changes do not retarget requests; disabling manual deletion stops new enrollment only. Archive verification observes identity without granting deletion authority or superseding removal.

Ordinary Delete and finish retention retain their separate metadata-removal boundary. Retention with a pending/blocked manual intent yields to the archive-only processor so a manual unlink failure cannot trigger sidecar removal. Pathless and retired-generation completion records keep their retention positions until displaced; an old record never acquires authority over a later download. Retention settings do not govern manual-request lifetime.

`finished_cleanup.lua` retains ordered completion snapshots in process memory when journal enrollment fails. It reports failed enrollment and retries through its existing timer before allowing cleanup against the old order. Later completions merge after pending snapshots without recapturing archive authority. A process exit cannot preserve an enrollment that storage rejected.

KOReader's history touch can change archive timestamps without replacing it. `ReadSettings` captures strictly verified pre-touch evidence; `ReaderReady` completes a bounded ctime-only refresh. The checked update touches only matching archive, manual-request, and retention targets; after success, matching pending completion snapshots receive the same evidence. Generation, path, completion order, and deletion authority do not change.

## Chapter loading and actions

### Complete data and live contexts

`queryChaptersForManga` retrieves stored pages of 200 using actual received offsets and ascending source-order/numeric-ID order. Parsers validate identities/order; the facade rejects changing totals, duplicates, backward pages, and contradictory continuation instead of returning partial success. Stored accumulation defaults to a 4 MiB encoded-chapter budget; callers may supply `max_result_bytes`. Workers also bound the complete serialized envelope and preserve incomplete/too-large categories and transport details. `fetchChaptersForManga` uses source fallback only after verified stored-empty success.

Completeness assumes a stable server dataset. Offset pagination cannot detect every same-count concurrent edit or establish an atomic snapshot. Source-fetch/refresh lists are sorted; stored pages retain server order for validation.

Chapter loads and action preloads supersede one another on a host. Manga/context identity, request tokens, cancellation, timeout, and host retirement guard publication. Dismissing a loading message cancels its request; successful completion disarms that callback. Complete empty results replace old context/menu/selection. Failed reloads retain the previous complete view and do not execute the failed action.

Context/scanlator guards also cover confirmations, directory continuations, error-detail Retry, and submenu selection/Back. Action menus capture request freshness when opened, allowing fresh actions on a retained view after reload failure. Retired hosts reject dispatch. Home and Downloads-hub actions remain independent of chapter context.

A saved scanlator restriction stays exact when absent from current data: explain the mismatch and return no candidates, not All. Pending local read/unread choices take precedence during ledger merging; normalization preserves unrelated fields, including on pathless entries.

Automatic reconciliation requires KOReader sidecar completed status, never final-page progress or history membership. Explicit plugin read/unread still updates metadata; existing saved read choices are not retroactively cleared. Native completed-status-plus-close enrollment is a separate trigger.

Explicit read-state updates select metadata using KOReader's native candidate order, including primary-before-paired-backup precedence. Backup-only metadata supplies the new primary without changing the backup. Inspection or loading uncertainty refuses the update. Cleanup discovers paths separately and never opens native metadata merely to find deletion targets.

### Bulk admission and read ordering

- `DownloadQueue:canEnqueue` checks ownership, unavailable statuses, known damage, and local files. Context selectors own read/filter/position choices. `enqueueBatch` deduplicates chapter keys and distinguishes skipped, failed, and unconfirmed outcomes. A rejected save admits zero jobs; ambiguous replacement is unconfirmed; a later fence-refused command is a failure.
- Explicit bulk actions capture at most 50 eligible identities and copied metadata before confirmation. Confirmation shows the count and remainder. Acceptance revalidates context/filter/request membership and current queue eligibility; reduced eligibility does not backfill from the capped remainder. Captures live only in callbacks, not persistent plans/refill requests. Retired hosts remain silent.
- `read_actions.lua` owns single, selected, previous, and unread coordination. Capture targets before metadata/menu changes. Selected batches clear selection and reconcile visible non-target chapters before the checked read/manual-intent/refill commit. Singles commit and publish before refresh. Captured completions publish in order before manual processing and sync; refill runs later through service scheduling. Supplied ledgers/completion buffers do not bypass persistence; caller-owned completion buffers defer processing until publication is possible.
- Single-call `skip_keep_policy` suppresses explicit and ledger-inferred refill enrollment without changing saved policies or existing requests. Read state and manual-delete intent still use checked persistence.
- A failed/uncertain save starts no removal and makes no durable-success claim. KOReader metadata and server synchronization are outside the shared-settings transaction.

## UI, localization, and diagnostics

Routine success appears in existing menus, not acknowledgement dialogs. Completed manual removal adds no receipt; pending/blocked removal remains visible. Keep actionable errors and destructive/bulk confirmations. Ordinary bulk deletion aggregates failures into one message; background cleanup/retries stay quiet except deduplicated unsafe-file/unsupported-journal warnings.

Downloads shows persisted full errors in a scrollable viewer; closing details preserves the originating screen. Damaged archives offer repair, inconclusive inspections offer verification retry, and scheduled retries retain queued actions with a fixed timestamp. The home Downloads button refreshes when the terminal-failure count changes.

`plugin/home.lua` measures messages at current width/font: text beyond 60% of screen height uses a scrollable TextViewer until dismissed; short text keeps compact InfoMessage behavior and optional timeouts.

`ui/list_menu.lua` installs its bounded status renderer before assigning rows for the first render, so long status text cannot consume the chapter-title width.

Translate plugin-authored chrome through `suwayomi/i18n.lua` once at the UI boundary. Server/user values and raw external errors remain data. Workers return structured IDs for plugin-authored outcomes. The facade loads compiled plugin catalogs, restores KOReader's gettext state, and follows KOReader's language; there is no plugin language setting. Catalog/alias/plural rules are in [TRANSLATING.md](TRANSLATING.md).

Use existing opt-in `suwayomi_debug.lua` configuration and redaction for diagnostics. No notification preference or separate logging format is needed.

## Data And Packaging Boundaries

Suwayomi server downloaded state never establishes device-local availability. New archives use the source-scoped layout in [AGENTS.md](../AGENTS.md#code-and-data-safety). `paths.lua` prefers `[id-<chapter_id>]`, then `[order-<source_order>]`, then `[chapter-<chapter_number>]` suffixes to avoid collisions. It also recognizes older filenames inside the supported source directory; this is not discovery of old unscoped layouts.

Normalize external input at existing boundaries: API parsing, settings normalization, serializable job records, parent-side progress parsing, and sanitized path construction. Release/manual-push allowlists and the Android destination are defined once in [AGENTS.md](../AGENTS.md#packaging), enforced by `.github/scripts/stage-release-payload.sh`.

## Test Strategy

Use the commands and isolation rules in [AGENTS.md](../AGENTS.md#tests-and-commands). Most host/network boundaries are stubbed; selected composed specs use real temporary files. One-shot JSON jobs use `subprocess/job.lua`; downloads retain separate scheduling because they need progress files, persisted jobs, and replacement handling.

For opt-in live-server checks, local KOReader UI automation, and device evidence, use the [agent testing workflow](agents/testing.md). Normal specs remain offline and require neither installed applications nor a personal library.

Development tooling under `scripts/` stays separate from the production plugin:

- `sandbox.py` owns a disposable root, pinned application downloads, generated Local source fixtures, exact-hash runtime deployment, and foreground service lifecycle. Setup selects Basic Auth, Simple Login, or UI Login; readiness and seeding use the selected protocol without fallback. Sessions remain in the launcher's memory. Port probes allow stopped-service TIME_WAIT sockets while still rejecting live listeners. Its launcher targets Linux x86_64 with a graphical session and uses only Python's standard library. Reader readiness retries identifiable refused/reset inspector connections through the 90-second startup deadline; authentication, configuration, and reader exit fail promptly.
- `sandbox_ui.py` owns authenticated observations, existing-widget actions, bounded waits, framebuffer capture, and the chapter/auth smoke workflows. Auth smoke uses real credential fields, method selection, rejected-password correction, connection testing, and setup continuation before the chapter smoke.
- `sandbox-inspector.lua` is installed only in the sandbox profile. It restricts KOReader's bundled inspector to loopback and a private token. Input observations expose metadata, not values; bounded authenticated edits use ordinary InputText methods. Visible controls include nested confirmation buttons. It does not modify the production plugin or upstream runtime files.

Credentials, inspector access files, settings, archives, and raw evidence remain private sandbox data outside the runtime payload. Live checks complement isolated specs; desktop evidence does not establish device lifecycle, permissions, sleep/wake, or e-ink behavior.

| Change | Focused evidence |
| --- | --- |
| Host lifecycle, setup, service subscriptions | `spec/main_spec.lua` and plugin controller/connection-worker specs |
| API pagination, chapter context, stale actions | API/manga/chapter specs; `spec/complete_chapter_loading_spec.lua` composes API, workers, menus, ledger, and queue across complete-load/failure boundaries. |
| Browse, Library, source search, extensions | Matching `spec/suwayomi_client_*`, `suwayomi_browse_*`, source-filter and worker specs |
| Source cancellation and host retirement | `spec/issue_45_spec.lua` composes the real shared subprocess helper with host lifecycle and confirmed-exit artifact cleanup. |
| Menus, images, reader return | Matching UI specs and `spec/suwayomi_reader_return_spec.lua`; widgets are stubbed, not device-layout evidence. |
| Queue ownership, recovery, persistence | `spec/suwayomi_download_service_spec.lua`, queue/active-job specs, `spec/suwayomi_settings_atomic_failure_spec.lua`, and `spec/suwayomi_settings_store_spec.lua` |
| Durable refill and completed-close triggers | `spec/durable_refill_spec.lua` and `spec/suwayomi_download_service_spec.lua` cover stale revisions/read-sync results, endpoint identity, cancellation, quiet blockers/retry deadlines, failed or uncertain commits, and zero-view/native reader-to-reader refill. |
| Archive integrity and repair | `spec/automatic_download_archive_spec.lua`, downloader specs, and `spec/suwayomi_download_failure_ux_spec.lua`; native archive fixtures use the system archive library on Linux/WSL. |
| Bulk selection/admission | `spec/suwayomi_bulk_download_actions_spec.lua` composes actions, confirmations, queue, and checked storage. |
| Read coordination, manual removal, retention | `spec/manual_read_completion_spec.lua`, `spec/suwayomi_download_service_spec.lua`, and `spec/suwayomi_finished_cleanup_spec.lua` cover ordering, filesystem/persistence outcomes, ownership, and replacement safety. |
| Release regression boundaries | `spec/issue_38_spec.lua` through `spec/issue_46_spec.lua` cover remote-unread revocation, native metadata backups, rejected retention enrollment, safe source retries, numeric identities, inert recovery, spare worker capacity, source cancellation, and refill suppression. |
| Sandbox readiness deadline | `python3 -m unittest discover -s scripts -p 'test_issue_48.py'` covers the real inspector/launcher exception boundary with controlled time, transport, and child state. |
| Localization | `spec/suwayomi_i18n_spec.lua` plus owning UI/worker specs. Clear `suwayomi/i18n` between cases; marker translators distinguish UI chrome from external values. L10n tooling checks extraction, catalogs, and compiled output. |

Tests with simulated removal do not prove physical filesystem behavior; stubbed widgets do not prove device layout or lifecycle. [#37](https://github.com/LK4D4/suwayomi.koplugin/issues/37) records accepted manual-deletion observations and remaining gaps. [#31](https://github.com/LK4D4/suwayomi.koplugin/issues/31) tracks combined workflow/device evidence. Consult those records rather than treating an old checklist or a passing suite as device acceptance.
