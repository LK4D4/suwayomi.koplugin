# Suwayomi KOReader Plugin Architecture

This document describes the current runtime boundaries after the module refactor. It is the active architecture reference for humans and AI agents working in the repo.

The module map describes existing boundaries; it does not require every new behavior to gain another facade, adapter, or service.

## Runtime Shape

KOReader loads `_meta.lua` and `main.lua` from the plugin root. `main.lua` is the plugin shell: it registers the dispatcher action, wires the main menu entry, constructs dependencies, attaches disposable host subscriptions to one process-owned download service, and installs controller methods onto the KOReader plugin object. Feature behavior belongs under `suwayomi/`.

Runtime files shipped in releases are:

- `_meta.lua`
- `main.lua`
- `README.md`
- `suwayomi/`
- `l10n/<locale>/suwayomi.mo` when compiled catalogs exist

Tests, docs, `scripts/`, sandbox profiles and generated data, CI files, worktrees, `AGENTS.md`, source `.po` files, and template `.pot` files are development-only and must not be included in manual Android plugin pushes or release payloads.

## Download ownership

`suwayomi/downloads/service.lua` owns one queue for the KOReader main process. FileManager and ReaderUI hosts subscribe independently and detach on CloseWidget without consuming the event. Navigation and sleep/wake preserve workers, progress, retry deadlines, and the shared concurrency limit. Subscriber deliveries are deferred, isolated, and invalidated on detach; reopened and uncovered screens render current snapshots. The existing finished-cleanup policy runs through a process-owned adapter that resolves the current reader at use time.

Archive completion updates the queue, ledger path, and reader-return context in one checked settings transaction while preserving current read/pending-sync state. Completed transfers retain in-session ownership through rejected saves and existing store reconciliation; bookkeeping retries cannot trigger a network watchdog or another transfer. Known stopping children retain chapter/file associations and concurrency reservations until `ffi/util.isSubProcessDone` confirms exit. Cancel, retry, timeout, and reconciliation use the same tracking. Temporary cleanup preserves final CBZs; an archive produced during cancellation receives completion bookkeeping.

Startup runs once before admission. Unfinished queued/downloading jobs requeue while preserving retry counts and future deadlines; restart does not consume a retry. The ordinary bounded downloader workers validate existing archives before completion bookkeeping, rather than scanning archives on the UI thread. Permanent failures and unsupported keyed records remain unchanged. A failed startup save retries through the service while admission remains blocked. Startup never sweeps temporary files.

One idempotent `UIManager.quit` wrapper invalidates service callbacks and admission, cancels cleanup timers, and makes a nonblocking best-effort pass over known active/stopping children within one total two-second budget. It always chains the previous quit method with all arguments and returns. No final save, network work, or future UI tick is required. Unconfirmed worker files remain untouched.

This implements navigation ownership from [ADR-0002](adr/0002-navigation-safe-download-ownership.md) and automatic restart/validated publication from [ADR-0005](adr/0005-automatic-download-restart.md). Each transfer has an OS-random attempt ID and private archive/progress temporary files. Closed archives carry an embedded attempt tag and optional expected page count, are fully validated, then replace the final CBZ by same-filesystem rename. Failed rename never authorizes removing the previous archive. Known exited workers permit only their own attempt-file cleanup; unknown leftovers remain indefinitely. No locks, boot tracking, cleanup registry, or recovery journal are added. Untracked survivors may duplicate transfers or publish later, including after cancellation; pre-upgrade workers retain their old unsafe shared-file behavior. Hot reload and simultaneous writable KOReader processes remain unsupported. Device acceptance remains separate.

`DownloadQueue:verifyArchive` runs at most one explicit background inspection through the existing subprocess boundary and result-file IO. It retains worker files until confirmed exit, checks archive identity and the caller's live request before committing an outcome, and exposes damaged versus inconclusive results through existing failed-job snapshots. Archive identity here is observational, not ADR-0003's deletion-generation proof. `redownload` persists explicit repair authorization and retains the old archive and reading metadata until replacement succeeds. Normal admission and Download ahead cannot initiate repair. Plugin-mediated opens validate before reader dispatch; generic asynchronous reader failures are not intercepted. Rows show latest known status without full validation during rendering.

Manual archive deletion implements the amended [ADR-0003](adr/0003-durable-manual-delete-intent.md) contract through the same process service. `manual_archive_state` is a separately versioned collection in the checked shared document: monotonic generations/revisions, captured archive evidence/root, request progress, retry deadlines, and terminal preservation outcomes. Unknown versions and unproved original targets remain untouched. No library scan or historical adoption runs.

New queue admissions carry explicit/automatic provenance and allocate an archive generation in the checked admission transaction. Only actual accepted deliberate work supersedes manual intent. Launch and completion validate current authority; current-session stopping/finalizing ownership prevents manual admission while a worker may publish. Every publication has a distinct generation, including identical bytes at the same path. This is in-process coordination, not an inherited-lock or cross-process publication protocol.

The manual processor revalidates request revision, generation, device/inode plus change evidence, resolved containment/aliases, live reader, and download ownership before unlinking only the CBZ. Leaf symlinks and unsupported file identities block removal. Progress and matching bookkeeping are separate checked saves; confirmed absence after a crash completes only the original obligation. Newer read/sync, queue, archive, and reader-return state survives. Five-second exponential retries cap at five minutes without abandonment; bounded fair passes continue without views. Quit only cancels its timer and retains the existing total shutdown budget.

Archive verification observes existing files without publishing a new download generation or superseding manual removal. Deliberate Redownload uses checked explicit admission; cancellation, retry, and startup preserve its generation and archive-integrity evidence.

Retention leaves a generation with pending or blocked manual intent to the archive-only processor rather than invoking its metadata-removal boundary. Its eligibility and completion positions remain unchanged; matching manual retirement marks the retained authority resolved. A transient manual unlink failure therefore cannot let competing retention remove metadata.

Download ahead implements [ADR-0004](adr/0004-durable-download-ahead-refill.md) in `suwayomi/downloads/refill.lua`, owned by that same service. The separately versioned `download_refill` collection stores one coalesced request per manga plus minimal verified endpoint associations. It stores no credentials or chapter lists. Completed closes, manual read/unread, actual reconciliation, successful chapter context publication, and policy/filter actions enroll checked work; rendering and queue progress never enroll it. Read changes, manual intent, and enrollment share one transaction.

One read-only context helper runs across manga, independently of chapter concurrency. Its random result prefix prevents reuse of unknown old helper files. Current endpoint, policy, exact filter, destination, and read/pending-sync state are checked again before admission. Read-sync acknowledgment invalidates an older result even when it only clears pending flags. Automatic jobs and retirement of only the matching request revision share one checked transaction. Earliest unread positions consume the 5/10/50 limit even when owned, failed, or deletion-fenced; no backfill or automatic terminal Retry occurs.

Startup recovers only recorded requests. Transient failures retain five-second exponential retry deadlines capped at five minutes; rejected requests and unsupported/configuration/identity blockers remain quiet and inspectable. Downloads and chapter actions expose current reasons, scheduled times, guarded Retry, and Stop. Stop atomically turns policy Off and retires requests without canceling jobs. Accepted chapter cancellation retires that manga's evaluation; Cancel all retires every evaluation, without disabling policies. Only a later independent trigger can enroll new work.

Verified origin survives queue publication and explicit plugin Open. A close cannot associate an unknown legacy archive with the currently configured server. Fresh context plus an explicit association action establishes manga scope; opening an existing archive also records that archive's scope. Credential-bearing URL userinfo, query strings, and fragments are not valid endpoint scopes. The existing quit wrapper shares its single two-second budget across known context, inspection, and chapter workers; no final transaction or orphan-file cleanup is added.

## Public Facades

The public runtime facades are intentionally small and stable:

- `suwayomi/api.lua` exposes Suwayomi GraphQL and binary HTTP helpers, including source extension fetch/install/update/uninstall operations. It delegates query construction to `suwayomi/api/queries.lua`, response decoding to `suwayomi/api/parsers.lua`, and HTTP/auth/URL handling to `suwayomi/api/transport.lua`.
- `suwayomi/ui.lua` exposes KOReader menu/dialog helpers. It delegates Browse menus to `suwayomi/ui/browse.lua`, shared manga/source/chapter row formatting to `suwayomi/ui/list_rows.lua`, KOReader thumbnail list rendering to `suwayomi/ui/list_menu.lua`, Downloads menus to `suwayomi/ui/downloads.lua`, directory picking to `suwayomi/ui/directory.lua`, and shared menu plumbing to `suwayomi/ui/menu_utils.lua`. Directory chooser chrome routes through `suwayomi/i18n.lua`; selected paths remain external data.
- `suwayomi/downloads/queue.lua` is the public device-local download queue. It owns enqueue/retry/cancel/recovery/snapshot/status APIs and delegates active subprocess scheduling to `suwayomi/downloads/active_jobs.lua`, persistence to `suwayomi/downloads/job_store.lua`, progress-file IO to `suwayomi/downloads/progress_file.lua`, and chapter-row status text to `suwayomi/downloads/status_formatter.lua`.
- `suwayomi/client.lua` is the public Library/Browse client facade. It wires injected dependencies and installs focused flow modules from `suwayomi/client/`.
- `suwayomi/chapters/actions.lua` is the chapter action facade for download, delete, read/unread, selected/bulk, and shared manga-level chapter actions.
- `suwayomi/readsync/controller.lua` is the read-sync orchestration facade, with ledger and KOReader sidecar metadata behavior split into sibling modules.

Callers should require slash-style modules under `suwayomi/`, for example `require("suwayomi/api")`. New runtime modules should stay in that namespace instead of adding top-level `suwayomi_*.lua` files.

## Module Ownership

Core plugin shell:

- `main.lua`: KOReader lifecycle, dependency construction, action/menu registration, service subscription and retirement, and controller method installation.
- `suwayomi/navigation.lua`: route-aware stack for Suwayomi-owned KOReader widgets.
- `suwayomi/reader_return.lua`: reader-menu shortcut state and async chapter reload for returning from an opened CBZ to the originating Suwayomi chapter list. It validates the reader request/context immediately before intentional teardown, consumes the accepted result, and publishes through the live `FileManager.instance.suwayomi` plugin after FileManager initialization. It never publishes through the retired reader plugin.
- `suwayomi/plugin/home.lua`: Suwayomi hub, main-menu entry, and shared message helpers. Messages are measured with the current screen width and normal InfoMessage font in a bounded temporary viewport. Text exceeding 60% of screen height opens in KOReader's screen-sized, scrollable TextViewer until dismissed; short messages retain compact InfoMessage behavior and optional timeouts.
- `suwayomi/plugin/title_menu.lua`: shared title-bar burger menus for full-screen plugin screens, including the universal Suwayomi home action.
- `suwayomi/plugin/settings_controller.lua`: grouped Settings menus, setup wizard orchestration, connection-test state, and settings action routing.
- `suwayomi/plugin/onboarding_connection_worker.lua`: subprocess-safe Suwayomi connection probe used by the setup wizard. It returns structured result IDs for plugin-authored success/failure text and raw `error` strings only for external API/network failures; `settings_controller` owns user-facing translation.

API:

- `suwayomi/api/queries.lua`: GraphQL query and mutation payload builders.
- `suwayomi/api/parsers.lua`: defensive parsing and normalization of Suwayomi responses. Shared chapter validation rejects malformed identities/order and duplicate IDs. Source-fetch/refresh lists are sorted by source order then numeric ID; stored pages retain server order so API validation can detect backward pages. The stored chapter page parser retains validated `chapters`, `total_count`, and `has_next_page` for complete-load validation in the API facade.
- `suwayomi/api/transport.lua`: basic auth, endpoint construction, GraphQL requests, archive downloads, binary page fetches, and bounded response sinks for bad-network protection.
- `suwayomi/api.lua`: facade that composes the submodules and owns API debug logging. `queryChaptersForManga` retrieves sequential stored pages of 200 using actual received offsets and ascending source-order/numeric-ID order. It rejects changing totals, duplicates, backward order, and contradictory continuation before returning one complete result. `fetchChaptersForManga` uses source fallback only after verified stored-empty success. Both accept an optional `max_result_bytes` budget; stored accumulation defaults to 4 MiB and counts encoded chapter bytes incrementally. Completeness assumes a stable server dataset: detected count/order/identity changes fail, while offset pagination cannot detect every same-count concurrent edit or establish an atomic snapshot.

Browse and Library:

- `suwayomi/client.lua`: public Library/Browse client facade and dependency container.
- `suwayomi/client/runtime.lua`: lazy runtime dependency lookup and worker timeout/concurrency settings.
- `suwayomi/client/source_manga.lua`: source mode selection, source-specific search/source-filter prompts, saved-filter metadata orchestration, source filter worker loading, source manga worker loading, filtered browse result pagination/retry, and manga action refresh callbacks. Plugin-authored prompt chrome routes through `suwayomi/i18n.lua`; source names, saved-filter names/query text, and source filter labels/values remain external data.
- `suwayomi/client/global_search.lua`: partial global search state, worker scheduling, cancellation, timeout handling, and live summary menu updates.
- `suwayomi/client/library.lua`: async library category/paged manga loading, category filtering, and library manga menu refresh callbacks. Plugin-authored Library screen chrome routes through `suwayomi/i18n.lua`; category names, manga titles, source names, credentials URLs, and raw API errors remain external data.
- `suwayomi/client/browse_chapter_counts.lua`: bounded background chapter-count enrichment for browse result rows.
- `suwayomi/client/util.lua`: tiny shared helpers used by client flow modules.
- `suwayomi/ui/list_rows.lua`: pure shared row formatting for manga, source, category, and chapter records, including subtitles, status markers, count labels, and thumbnail metadata. Built-in row labels route through `suwayomi/i18n.lua`; record titles, source names, category names, and scanlator names remain external data.
- `suwayomi/ui/list_menu.lua`: KOReader Menu-compatible thumbnail rows with cached thumbnail slots and page-change callbacks for Library, Browse/Search, source results, and chapter-like lists.
- `suwayomi/ui/manga_menu.lua`: thin alias for `suwayomi/ui/list_menu.lua`; keep renderer behavior in `list_menu.lua`.
- `suwayomi/ui/thumbnail_cache.lua`, `suwayomi/ui/thumbnail_worker.lua`: private thumbnail cache pathing and bounded background thumbnail fetch support.
- `suwayomi/browse/controller.lua`: Browse entry flow, source fetch worker lifecycle, polling, and source-cache refresh. Plugin-authored Browse status text routes through `suwayomi/i18n.lua`; raw worker/server errors remain external data.
- `suwayomi/browse/source_catalog.lua`: source filtering, source cache IO, and source-list rendering. Plugin-authored menu chrome routes through `suwayomi/i18n.lua`; source names and source filter labels/values remain external data.
- `suwayomi/source_languages.lua`: source language code-to-label formatting for Browse filters and source rows; owns the static Suwayomi WebUI language label table.
- `suwayomi/browse/extensions.lua`: extension list rendering, extension install/update/uninstall action routing, and extension worker result handling. Plugin-authored extension UI text routes through `suwayomi/i18n.lua`; extension names, package names, and raw errors remain external data.
- `suwayomi/browse/source_fetch_worker.lua`: subprocess worker for fetching sources into a result file.
- `suwayomi/browse/extension_worker.lua`: subprocess worker for fetching available extensions and installing/updating/uninstalling a selected extension.
- `suwayomi/browse/global_search_worker.lua`: subprocess worker for fetching one source's first search page into a result file for partial global search.
- `suwayomi/browse/source_filter_worker.lua`: subprocess worker for fetching one source's filter schema before opening the KOReader filter editor.
- `suwayomi/browse/source_manga_worker.lua`: subprocess worker for source Popular/Latest/Search manga result pages, including search-only source filter changes.
- `suwayomi/browse/chapter_count_worker.lua`: subprocess worker for browse-result chapter-count enrichment.
- `suwayomi/source_filters.lua`: pure source filter draft/saved-filter normalization and Suwayomi `FilterChange` construction.
- `suwayomi/manga/controller.lua`: async manga actions, refresh, library membership, chapter-context preload, first-unread helpers, and manga-level download/read actions. Plugin-authored loading, confirmation, action, and fallback messages route through `suwayomi/i18n.lua`; manga titles, IDs, and raw API/worker errors remain external data.
- `suwayomi/manga/action_menu.lua`: shared manga action definitions used by manga row action menus and chapter-list title menus. Action labels route through `suwayomi/i18n.lua`; action IDs remain stable controller data.
- `suwayomi/ui/manga_info.lua`: read-only manga information dialog. Field labels, poster placeholders, default titles, and known status labels route through `suwayomi/i18n.lua`; manga metadata values remain external data.

Downloads:

- `suwayomi/downloads/controller.lua`: Downloads hub, active/queued/failed actions, shared chapter/download error details, Verify/Redownload, retry/clear/cancel, and downloaded-read reconciliation. Failed rows open current persisted details in a scrollable viewer; damaged archives offer explicit repair and inconclusive inspections offer verification retry. Scheduled retries retain queued actions and a fixed timestamp. Closing details preserves the originating screen. Plugin-authored UI text routes through `suwayomi/i18n.lua`; titles, keys, and stored external errors remain data.
- `suwayomi/downloads/directory.lua`: download-directory chooser, summary, persistence callback flow, and default directory probing. Plugin-authored summary/save messages route through `suwayomi/i18n.lua`; directory paths remain external data.
- `suwayomi/downloads/service.lua`: process singleton, disposable subscriptions, checked completion transaction, durable refill ownership, and shared quit integration.
- `suwayomi/downloads/refill.lua`: coalesced request/origin persistence, checked ledger enrollment, one context helper, current-choice selection, atomic automatic admission, retry/blocker scheduling, snapshots, and guarded Retry/Stop.
- `suwayomi/downloads/cleanup_adapter.lua`: process-owned receiver for the existing finished-cleanup policy, with live-reader lookup and scoped view notifications.
- `suwayomi/downloads/queue.lua`: public queue facade, startup requeue, checked repair admission, asynchronous explicit verification, observational damage status, busy-chapter checks, and persisted terminal failure count. Queue transitions finish persistence and snapshot updates before notifying UI consumers. The home controller refreshes its existing Downloads button only when the terminal failure count changes; `main.lua` delivers snapshots to the current chapter, Downloads, or home view.
- `suwayomi/downloads/active_jobs.lua`: bounded active chapter jobs, subprocess launch, progress polling, watchdog handling, persisted staggered retries for transient failures, completion-save retries, known stopping-worker associations, and replacement scheduling. Background failures stay in queue state instead of opening one message per chapter. Plugin-authored fallback/startup failure text routes through `suwayomi/i18n.lua`; raw worker errors remain external data.
- `suwayomi/downloads/job_store.lua`: persisted queue schema, serialization-safe job metadata, duplicate handling, and recovery normalization.
- `suwayomi/downloads/progress_file.lua`: attempt-private progress paths and atomic line-oriented progress IO, including archive-inspection evidence.
- `suwayomi/downloads/status_formatter.lua`: chapter status symbols and user-facing queue/download status text.
- `suwayomi/downloads/downloader.lua`: one-chapter download, existing-archive inspection, page validation, ordered CBZ writing, attempt-only cleanup, and validated atomic publication. Explicit repair bypasses existing-file adoption without deleting the old archive. The optional archive export falls back to device-local page downloading on HTTP 400 (no server download) or HTTP 404; transient failures retry, while authentication and filesystem failures remain failures.
  Repairs retain the inspected supported pathname through retry and restart, including legacy names. Before replacing an existing archive, the downloader delegates hash-sidecar preservation to the existing KOReader metadata boundary.
- `suwayomi/downloads/archive.lua`: private OS-random attempt IDs, bounded ZIP structure inspection, full native entry reads/checksums, embedded expected-count/attempt metadata, and cheap observational fingerprints. It does not extract contents, fetch server metadata, decode images, or provide deletion authority.

Chapters and read state:

Chapter menu loads and action preloads supersede each other on a plugin instance. Manga identity, prior context, request tokens, cancellation, and timeout guard publication; `main.lua:onCloseWidget` permanently retires that host's chapter requests without consuming KOReader's close event. Loading-message dismissal cancels its network request, while programmatic completion disarms the dismissal callback. Complete empty results replace old context/menu/selection; failed reloads retain the previous complete view without executing the failed action. Context and scanlator guards also invalidate captured manga/chapter actions, chapter error-detail Retry, confirmations, and directory continuations. Chapter title options retain their originating context but capture request freshness when the action menu opens, so new actions from a retained view remain usable after a failed reload. Chapter submenus guard both selection and Back callbacks. The shared title controller accepts an optional per-open guard for screen actions; Home and unguarded Downloads actions remain independent. Public manga dispatch rejects retired hosts, including loaded first-unread opens. Downloads-hub Retry remains independent of the chapter context. Admission rejects chapter IDs absent from the current filtered context.

The saved scanlator restriction remains exact even when absent from the complete list, with an explanation and no matching candidates. Read-ledger merging retains pending local read/unread precedence; merge, upsert, and settings normalization preserve unrelated entry fields, including on pathless entries whose pending unread choice is acknowledged.

Chapter-list and downloaded-ledger reconciliation require KOReader sidecar completed status, never progress or history membership. Reaching the final page does not mark a chapter read when KOReader leaves its status unfinished. Explicit plugin read/unread actions continue to update the corresponding metadata, and existing saved read choices are not retroactively cleared. Native completed-status-plus-close enrollment remains separate from this reconciliation.

Explicit bulk download admission shares `DownloadQueue:canEnqueue` with single and batch queue commands. This predicate checks active ownership, unavailable statuses, known archive damage, and device-local archives; it does not select read state, scanlator, or chapter positions. `enqueueBatch` retains its count/error returns and outcome table with `skipped`, `failed`, and `unconfirmed` counts. It deduplicates chapter keys before persistence. A rejected write admits zero jobs; a post-replacement ambiguity is unconfirmed, while a later command refused by the store fence is a failure. Retry admission never cleans files from an unknown attempt.

`chapters/actions.lua` captures at most 50 eligible identities and copied job metadata for each explicit batch, plus the original context, menu, filter, and chapter request/host guard. It builds one visible-ID lookup per batch so membership checks remain linear across long series. Confirmations show the captured count and any remainder beyond the cap; admission outcome counts go to opt-in debug events rather than success popups. Acceptance revalidates membership and unread/scanlator scope, then delegates current file/ownership checks to queue admission. Changed views reject the captured command, and reduced eligibility never backfills from the capped remainder. Bulk confirmation can report a rejected batch through its stale callback on a live host; retired hosts remain silent. These batch objects live only in their action callbacks; they are not persisted plans or refill requests. `chapters/context.lua` keeps the next-unread selector and returns its unavailable count alongside candidates. Download-ahead position selection remains unchanged.

Chapter/download action success is reflected in existing menus rather than acknowledgement dialogs. Completed manual removal adds no receipt to chapter status; pending or blocked removal remains visible. Ordinary bulk deletion aggregates failures into one message and logs outcome counts. Finished-cleanup retries remain quiet, with deduplicated warnings retained for unsafe files and unsupported journals. Diagnostic events use the existing `suwayomi_debug.lua` opt-in and redaction boundary; no notification preference or new logging format is introduced.


- `suwayomi/chapters/context.lua`: current manga/chapter context and visible chapter filtering state; remote chapter loading is owned by async manga request helpers. Plugin-authored title fallbacks, selected-count titles, scanlator menu chrome, and queue summaries route through `suwayomi/i18n.lua`; manga titles and scanlator values remain external data.
- `suwayomi/chapters/menu.lua`: chapter menu construction, updates, selection mode, and menu refresh behavior. Plugin-authored action labels, bulk-menu titles, and scanlator menu chrome route through `suwayomi/i18n.lua`; chapter names remain external data.
- `suwayomi/chapters/actions.lua`: chapter and selected-chapter action facade, including guarded asynchronous pre-open verification and explicit Verify/Redownload actions. Plugin-authored open/delete/download/read messages, confirmations, and summaries route through `suwayomi/i18n.lua`; chapter names, manga titles, and filesystem paths remain external data.
- `suwayomi/chapters/local_downloads.lua`: local archive existence/open helpers and ordinary Delete's metadata-before-archive removal boundary, with a captured-archive guard before destructive stages. Manual deletion never invokes this metadata-removal path.
- `suwayomi/chapters/delete_actions.lua`: ordinary device deletion and retention removal boundary. Fresh explicit targets establish checked identity; retention must supply its original generation. Bookkeeping retires only matching authority and preserves read/unread state and uncertain historical associations.
- `suwayomi/chapters/archive_identity.lua`: targeted filesystem evidence, resolved containment, alias/symlink checks, and current process-reader protection. Stat/unlink does not claim protection against uncoordinated external writers.
- `suwayomi/chapters/manual_deletion.lua`: shared checked admission/revocation, archive-generation evidence, archive-only unlink/recovery, conditional retirement, quiet retries, and committed status snapshots; owned by the process service. A strictly verified pre-history reader snapshot permits a ctime-only refresh after KOReader updates access time. The checked transaction updates only matching archive, manual-request, and retention targets without changing their generation, path, or authority.
- `suwayomi/chapters/finished_cleanup.lua`: existing finish order, retention eligibility/positions, bounded traversal, retries, and affected-view refresh. Records retain their captured archive generation and path; unproved historical targets block rather than binding to later downloads. Verified reader-access timestamp updates do not renew completion order or deletion authority. Pathless and retired-generation records keep their positions until displaced. Retention settings affect only this journal, not accepted manual requests. Ordinary Delete remains its destructive boundary.
- `suwayomi/chapters/read_actions.lua`: single, selected, previous, and unread coordination under ADR-0001's checked ordering. Capture precedes refresh; selected batches clear selection then reconcile visible non-target chapters into their shared ledger before the checked read/manual-intent/refill commit. Singles commit and publish before refresh. Immutable completions publish in order before manual processing and sync; refill runs later through service scheduling. Supplied ledgers and completion buffers do not bypass persistence. Failed or uncertain saves produce no durable-success claim or removal. Successful and pending outcomes remain quiet; one localized error reports failed saves or busy/blocked removal requests.
- `suwayomi/readsync/ledger.lua`: local read-ledger merging and persistence through the shared read/refill transaction, preserving pending local precedence and unrelated archive fields.
- `suwayomi/readsync/koreader_metadata.lua`: KOReader sidecar inspection and reading-metadata preservation before archive replacement. `getKoreaderMetadataPathForDocument` uses `DocSettings` to return the current metadata path, cleanup candidates, and hash metadata path without opening or mutating `DocSettings`. `preserveForReplacement` retains hash originals and copies raw primary/backup metadata into document-path storage before publication. Conflicting candidates or failed inspection/writes refuse archive replacement rather than discard reading state.
- `suwayomi/readsync/worker.lua`: background read-sync worker behavior.
- `suwayomi/readsync/controller.lua`: pending read-sync scheduling, polling, retry, reconciliation, and checked completed-close enrollment before deferred service work. `ReadSettings` captures verified archive evidence before KOReader's history touch; `ReaderReady` completes that bounded timestamp refresh and releases the snapshot. Failed persistence is reported. Automatic startup failures log and retry without a popup; explicit Sync reports startup failure. Successful startup is quiet.
- `suwayomi/network/request_worker.lua`, `suwayomi/network/request_job.lua`: generic one-shot network request worker/launcher for Library, reader-return, manga actions, and chapter-context flows that need remote data without blocking KOReader UI callbacks. Callers keep active job tokens so newer requests cancel or ignore stale older results. The worker passes the shared result-byte budget into stored chapter retrieval and checks the complete serialized envelope, including source-refresh and reader-return metadata, before writing. Incomplete/too-large categories and available transport status/retry details survive result handoff; chapter controllers publish only successful results.

Shared support:

- `suwayomi/settings.lua`: KOReader settings persistence facade.
- `suwayomi/settings/retention_labels.lua`: shared plural-aware summary/picker labels for unchanged persisted retention values 0–5.
- `suwayomi/settings/store.lua`: Checked atomic replacement of the complete shared settings document. Failed writes before replacement preserve committed values; uncertain replacement outcomes fence writes until the stored transaction is reconciled. The queue schedules reconciliation and reconstructs committed work before resuming launches and polling.
- `suwayomi/paths.lua`: source-scoped download path layout and path segment sanitization.
- `suwayomi/debug.lua`: opt-in redacted debug logging.
- `suwayomi/i18n.lua`: plugin-owned wrapper around KOReader gettext and template formatting for runtime UI strings. It loads compiled plugin catalogs from `l10n/<locale>/suwayomi.mo` when KOReader has a matching language, restores KOReader's native gettext state after loading, and intentionally does not persist plugin language settings or translate server-provided manga/source/chapter data.
- `suwayomi/i18n/locales.lua`: pure locale registry for supported plugin catalogs, WebUI aliases, KOReader aliases, and region fallback order.
- `suwayomi/subprocess/job.lua`: shared helper for one-shot subprocess jobs that exchange compact JSON result files. Callers provide the worker body, result parser, poll/timeout values, and finish/error/cancel callbacks; the helper owns atomic `.tmp` writes, result path allocation, polling, timeout/cancel termination, child reaping, and result-file cleanup.

Long-running subprocess patterns are intentionally split by shape: one-shot JSON result workers use `suwayomi/subprocess/job.lua`, while active downloads stay in `suwayomi/downloads/active_jobs.lua` because they require progress files, persisted queue state, and replacement scheduling.

## Where To Change Things

Use this map before broad searches. It points to the first files to inspect for
common changes and the specs that usually cover them.

| Change area | Start here | Usually covered by |
| --- | --- | --- |
| KOReader plugin lifecycle, dispatcher actions, menu entry, setup wizard, or dependency construction | `main.lua`, `suwayomi/plugin/home.lua`, `suwayomi/plugin/settings_controller.lua`, `suwayomi/plugin/onboarding_connection_worker.lua`, `suwayomi/plugin/title_menu.lua` | `spec/main_spec.lua`, plugin controller specs, `spec/suwayomi_plugin_onboarding_connection_worker_spec.lua` |
| GraphQL fields, mutations, response normalization, response timeout/byte limits, or legacy-schema fallback | `suwayomi/api/queries.lua`, `suwayomi/api/parsers.lua`, `suwayomi/api.lua`, `suwayomi/api/transport.lua` | API specs |
| Browse source list, source cache, source language/NSFW filtering, or source refresh | `suwayomi/browse/source_catalog.lua`, `suwayomi/source_languages.lua`, `suwayomi/browse/controller.lua`, `suwayomi/settings.lua` | `spec/suwayomi_browse_*`, `spec/suwayomi_source_languages_spec.lua`, settings specs |
| Source extension list, install/update/uninstall actions, or post-action source-cache refresh | `suwayomi/browse/extensions.lua`, `suwayomi/browse/extension_worker.lua`, `suwayomi/api/queries.lua`, `suwayomi/api/parsers.lua` | `spec/suwayomi_browse_extensions_spec.lua`, `spec/suwayomi_extension_worker_spec.lua`, API specs |
| Source row metadata such as icons, language labels, adult markers, or global-search summary rows | `suwayomi/ui/list_rows.lua`, `suwayomi/ui/browse.lua`, `suwayomi/browse/source_catalog.lua`, `suwayomi/api/queries.lua`, `suwayomi/api/parsers.lua` | `spec/suwayomi_ui_list_rows_spec.lua`, `spec/suwayomi_ui_browse_spec.lua`, API parser/query specs |
| Thumbnail list rendering, cached thumbnail slots, visible-row thumbnail jobs, or Menu-compatible row widgets | `suwayomi/ui/list_menu.lua`, `suwayomi/ui/thumbnail_cache.lua`, `suwayomi/ui/thumbnail_worker.lua` | `spec/suwayomi_ui_list_menu_spec.lua`, `spec/suwayomi_ui_manga_menu_spec.lua` |
| Source manga loading, source-specific search, source filters, saved filters, browse result pagination, and browse chapter-count enrichment | `suwayomi/client/source_manga.lua`, `suwayomi/client/browse_chapter_counts.lua`, `suwayomi/source_filters.lua`, `suwayomi/browse/source_filter_worker.lua`, `suwayomi/browse/source_manga_worker.lua`, `suwayomi/browse/chapter_count_worker.lua` | `spec/suwayomi_client_source_manga_spec.lua`, source filter specs, worker specs |
| Global search prompt/results, partial worker scheduling, cancellation, or timeouts | `suwayomi/client/global_search.lua`, `suwayomi/browse/global_search_worker.lua` | `spec/suwayomi_client_global_search_spec.lua`, worker specs |
| Library loading, category picker behavior, library paging, and library row refresh after manga actions | `suwayomi/client/library.lua`, `suwayomi/network/request_job.lua`, `suwayomi/network/request_worker.lua`, `suwayomi/client.lua` | `spec/suwayomi_client_library_spec.lua`, `spec/suwayomi_client_spec.lua` |
| Manga-level actions, async chapter loading/refresh/preload, library membership, shared action-menu shape, and first-unread behavior | `suwayomi/manga/controller.lua`, `suwayomi/manga/action_menu.lua`, `suwayomi/network/request_job.lua`, `suwayomi/network/request_worker.lua`, `suwayomi/client.lua` | manga/client/controller specs |
| Reader return from a CBZ back to Suwayomi chapters | `suwayomi/reader_return.lua`, `suwayomi/network/request_job.lua`, `suwayomi/network/request_worker.lua` | `spec/suwayomi_reader_return_spec.lua` |
| Chapter menu behavior, selected/bulk actions, local archive delete/open, or read/unread actions | `suwayomi/chapters/menu.lua`, `suwayomi/chapters/actions.lua`, `suwayomi/chapters/local_downloads.lua`, `suwayomi/chapters/delete_actions.lua`, `suwayomi/chapters/read_actions.lua` | chapter specs |
| Finished-chapter journal, retention cleanup, candidate revalidation, retry scheduling, or cleanup failure summaries | `suwayomi/chapters/finished_cleanup.lua`, `suwayomi/chapters/read_actions.lua`, `suwayomi/chapters/delete_actions.lua`, `suwayomi/readsync/controller.lua`, `main.lua`, `suwayomi/reader_return.lua` | `spec/suwayomi_finished_cleanup_spec.lua`, `spec/manual_read_completion_spec.lua` (public read actions, real menu/queue refresh, filesystem and durable state together) |
| Download queue, active jobs, progress files, status text, or one-chapter CBZ writing | `suwayomi/downloads/queue.lua`, `suwayomi/downloads/active_jobs.lua`, `suwayomi/downloads/progress_file.lua`, `suwayomi/downloads/status_formatter.lua`, `suwayomi/downloads/downloader.lua` | queue/download specs |
| Download directory selection or source-scoped path layout | `suwayomi/downloads/directory.lua`, `suwayomi/paths.lua` | directory/path specs |
| Read-sync ledger, KOReader sidecar metadata, worker polling, or reconciliation | `suwayomi/readsync/ledger.lua`, `suwayomi/readsync/koreader_metadata.lua`, `suwayomi/readsync/worker.lua`, `suwayomi/readsync/controller.lua` | read-sync specs |
| Settings persistence, source filter drafts, debug logging, or redaction | `suwayomi/settings.lua`, `suwayomi/debug.lua` | settings/debug specs |
| Plugin UI text, translation helpers, or shared i18n formatting | `suwayomi/i18n.lua`, then the specific UI/controller module that owns the string | `spec/suwayomi_i18n_spec.lua`, plus the owning module spec |
| Runtime packaging or Android manual push payload | plugin root `_meta.lua`, `main.lua`, `README.md`, `suwayomi/`, compiled `l10n/*/suwayomi.mo`, plus `AGENTS.md` packaging notes | release/manual QA checks |

## Data And Packaging Boundaries

Downloads are KOReader-device-local CBZ files. The plugin does not use Suwayomi server download mutations as a hidden side effect and does not treat Suwayomi server downloaded state as local availability.

New downloads use the source-scoped layout:

```text
<download_directory>/<source_label>/<manga_title>/<chapter_name>.cbz
```

`suwayomi/paths.lua` appends duplicate-safe suffixes to chapter filenames when
stable chapter metadata is present, preferring `[id-<chapter_id>]`, then
`[order-<source_order>]`, then `[chapter-<chapter_number>]`. A chapter named
`Chapter 1` can therefore become `Chapter 1 [id-398].cbz` instead of plain
`Chapter 1.cbz` so same-titled chapters do not collide on disk.

Old unscoped path detection is intentionally absent unless a future task explicitly adds migration behavior.

External data is treated as untrusted at module boundaries: API responses are parsed defensively, settings values are normalized before use, persisted jobs keep only serializable metadata, progress files are re-read and normalized by the parent queue, and filesystem paths are built through the paths module or local helper boundaries.

## Test Strategy

Specs run from the plugin root with `package.path = "?.lua;" .. package.path`. KOReader modules are stubbed through `package.preload`, and modules with state are cleared from `package.loaded` before requiring them.

For opt-in live-server checks, local KOReader UI automation, and device evidence, use the [agent testing workflow](agents/testing.md). Normal specs remain offline and require neither installed applications nor a personal library.

Development tooling under `scripts/` stays separate from the production plugin:

- `sandbox.py` owns a disposable root, pinned application downloads, generated Local source fixtures, exact-hash runtime deployment, and foreground service lifecycle. Its launcher targets Linux x86_64 with a graphical session; Python uses only the standard library. It does not install OS packages, change network configuration, or manage unrelated services.
- `sandbox_ui.py` owns authenticated observations, existing-widget actions, bounded waits, framebuffer capture, and the single-chapter smoke against the real UI.
- `sandbox-inspector.lua` is installed only in the sandbox profile. It restricts KOReader's bundled inspector to loopback and a private token; it does not modify the production plugin or upstream runtime files.

Credentials, inspector access files, settings, archives, and raw evidence remain private sandbox data outside the runtime payload. Live checks complement isolated specs; desktop evidence does not establish device lifecycle, permissions, sleep/wake, or e-ink behavior.

Coverage is organized around runtime boundaries:

- `spec/main_spec.lua` focuses on KOReader lifecycle: dispatcher/menu registration, lazy dependency construction, service attachment, host retirement, debug logger setup, and controller method installation.
- API specs cover the facade plus query/parser/transport submodules without live Suwayomi calls.
- `spec/complete_chapter_loading_spec.lua` composes real query/parser/API, asynchronous worker result files, manga/chapter controllers, chapter menu data, read-ledger reconciliation, and queue persistence. External HTTP and host scheduling are controlled; assertions couple visible count/order, committed read state, candidate/admitted IDs, and failure preservation across long-series pagination and byte limits. Reopen/source/refresh parity, exact filters, empty replacement, stale callbacks, and reader-to-FileManager handoff use the same composed seam. The ledger preservation case writes and reopens a real temporary settings file. Device long-series comparison remains pending under #31.
- Client specs are split by flow: `spec/suwayomi_client_source_manga_spec.lua`, `spec/suwayomi_client_global_search_spec.lua`, `spec/suwayomi_client_library_spec.lua`, and the small facade-focused `spec/suwayomi_client_spec.lua`.
- UI specs cover menu table construction and KOReader dialog/menu helper behavior with stubbed widgets.
- I18n specs stub KOReader `gettext` and `ffi/util.template` directly. Module specs that assert visible built-in labels should clear `suwayomi/i18n` from `package.loaded` before requiring the module under test so each spec controls the active gettext stub. Worker specs should prefer structured message/error IDs for plugin-authored text and reserve raw strings for server/API data.
- Browse and extension i18n specs use marker `suwayomi/i18n` stubs to prove plugin-authored menu chrome routes through the facade. Source names, extension names, package names, server errors, source filter labels, and source filter values remain external data and are asserted without translation markers.
- Library, manga, chapter, and downloads i18n specs use marker `suwayomi/i18n` stubs to prove plugin-authored menu chrome, confirmations, status summaries, and fallback errors route through the facade. Library category names, manga titles, chapter names, scanlator names, source names, category/genre metadata, filesystem paths, raw API errors, and raw worker errors remain external data and are asserted without translation markers.
- `spec/suwayomi_download_failure_ux_spec.lua` composes real queue persistence, controller actions, and download UI builders with KOReader widget/worker substitutes to verify error access, restart recovery, stale actions, quiet failures, and displayed queue transitions together.
- `spec/suwayomi_download_service_spec.lua` composes the shell, shared service, queue, checked settings store, real temporary files, deferred scheduling, public actions, and rendered views. It covers navigation at concurrency two and one, zero-host completion/cleanup, detached/throwing subscribers, completion-save failures/reconciliation, known stopping workers, startup requeue, explicit retry, and quit/relaunch. Native reader-to-reader completed closes admit the sixth ahead position without chapter views; pending controls retain fixed retry times and reject retired callbacks. Ahead-Off completion retains its independent finish-retention behavior.
- `spec/durable_refill_spec.lua` composes service, settings, real result files, current read choices, and queue admissions. It covers stale request/read-sync results, terminal/deletion blockers, offline restart and fairness, cancellation, unknown versions/origin, rejected authentication, and failed/uncertain admission saves.
- `scripts/check-download-subprocess.lua` is an optional Linux probe against a supplied KOReader base checkout. It checks four real chapter children, bounded shutdown, result lifetime before known-child exit, canceled-result rejection, and known-exit cleanup. The refill probe used unmodified base `dd0e2522a1c2535c49b69f151a65fd506663c3a7`. A separate throwaway service smoke admitted chapter 6 with zero views, then stopped concurrent real context and chapter children under the shared deadline (0.000234 seconds on the test host), retaining durable work. Device timing, UI layout, offline/relaunch, and abrupt-power-loss behavior remain unverified.
- Queue/download specs cover persisted jobs, active scheduling, attempt-private files, status text, and CBZ behavior without real network or real subprocess timing. Native downloader fixtures exercise ZIP integrity through the system archive library on Linux/WSL; KOReader interfaces remain isolated. `spec/automatic_download_archive_spec.lua` preserves the regression where a truncated existing archive was silently accepted as complete.
- `spec/suwayomi_bulk_download_actions_spec.lua` composes public manga/chapter actions, real selection and confirmation builders, queue admission, and the checked settings store. Synthetic filesystem and host boundaries let it assert displayed promises/results alongside committed jobs, selection, ownership, and failed-retry artifacts. It covers cap boundaries, saved filters, stale views/identities, duplicate races, cancellation, and definitive versus uncertain persistence. Device layout and lifecycle acceptance remain separate.
- `spec/suwayomi_settings_atomic_failure_spec.lua` composes the real settings store, queue, and active lifecycle with injected storage failures and controlled timers. It checks committed jobs, snapshots, worker effects, and reconciliation together. `spec/suwayomi_settings_store_spec.lua` also replaces an existing file and reopens the store using actual filesystem operations.
- Controller specs exercise plugin-bound methods with KOReader/runtime stubs rather than requiring real KOReader.
- Read-sync specs isolate ledger, metadata/history handling, worker behavior, and controller polling/retry flows.
- `spec/manual_read_completion_spec.lua` composes real checked settings, service/queue publication, menu dispatch, ledger/metadata reconciliation, retention, and temporary files. It covers selection/filter/predecessor order, non-target reconciliation, pathless positions, supplied ledgers, unread precedence over old history, and admission failures. `spec/suwayomi_download_service_spec.lua` additionally exercises physical CBZ unlink and crash recovery, realpath containment, metadata/backup preservation, live readers, zero hosts, root/settings changes, unknown state, and explicit versus automatic replacement admission. `spec/suwayomi_finished_cleanup_spec.lua` retains isolated retention-policy and ordinary metadata-removal boundary coverage. These automated checks do not claim device acceptance; #37 remains separate.
  The maintainer accepted the exercised device workflows and the remaining verification gaps in #37. Unexercised device cases are not reported as passes; automated coverage and device observations remain distinct.
- L10n tooling tests are shell-script based: `scripts/check-l10n.sh` verifies extraction freshness, `.po` validity, and generated `.mo` availability without requiring gettext tools on KOReader devices.

Use the same checks as CI:

```bash
PATH="$HOME/.luarocks/bin:$PATH" busted spec
PATH="$HOME/.luarocks/bin:$PATH" luacheck --codes spec suwayomi main.lua _meta.lua
./scripts/check-l10n.sh
```

The Luacheck command covers project Lua parsing/linting while avoiding generated
dependency directories such as `.lua` and `.luarocks`.
