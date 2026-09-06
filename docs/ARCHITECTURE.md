# Suwayomi KOReader Plugin Architecture

This document describes the current runtime boundaries after the module refactor. It is the active architecture reference for humans and AI agents working in the repo.

## Runtime Shape

KOReader loads `_meta.lua` and `main.lua` from the plugin root. `main.lua` is the plugin shell: it registers the dispatcher action, wires the main menu entry, constructs shared dependencies, restores the download queue, and installs controller methods onto the KOReader plugin object. Feature behavior belongs under `suwayomi/`.

Runtime files shipped in releases are:

- `_meta.lua`
- `main.lua`
- `README.md`
- `suwayomi/`
- `l10n/<locale>/suwayomi.mo` when compiled catalogs exist

Tests, docs, CI files, worktrees, `AGENTS.md`, source `.po` files, and template `.pot` files are development-only and must not be included in manual Android plugin pushes or release payloads.

## Public Facades

The public runtime facades are intentionally small and stable:

- `suwayomi/api.lua` exposes Suwayomi GraphQL and binary HTTP helpers, including source extension fetch/install/update/uninstall operations. It delegates query construction to `suwayomi/api/queries.lua`, response decoding to `suwayomi/api/parsers.lua`, and HTTP/auth/URL handling to `suwayomi/api/transport.lua`.
- `suwayomi/ui.lua` exposes KOReader menu/dialog helpers. It delegates Browse menus to `suwayomi/ui/browse.lua`, shared manga/source/chapter row formatting to `suwayomi/ui/list_rows.lua`, KOReader thumbnail list rendering to `suwayomi/ui/list_menu.lua`, Downloads menus to `suwayomi/ui/downloads.lua`, directory picking to `suwayomi/ui/directory.lua`, and shared menu plumbing to `suwayomi/ui/menu_utils.lua`. Directory chooser chrome routes through `suwayomi/i18n.lua`; selected paths remain external data.
- `suwayomi/downloads/queue.lua` is the public device-local download queue. It owns enqueue/retry/cancel/recovery/snapshot/status APIs and delegates active subprocess scheduling to `suwayomi/downloads/active_jobs.lua`, persistence to `suwayomi/downloads/job_store.lua`, progress-file IO to `suwayomi/downloads/progress_file.lua`, and chapter-row status text to `suwayomi/downloads/status_formatter.lua`.
- `suwayomi/client.lua` is the public Library/Browse client facade. It wires injected dependencies and installs focused flow modules from `suwayomi/client/`.
- `suwayomi/chapters/actions.lua` is the chapter action facade for download, delete, read/unread, selected/bulk, and shared manga-level chapter actions.
- `suwayomi/readsync/controller.lua` is the read-sync orchestration facade, with ledger and KOReader sidecar/history behavior split into sibling modules.

Callers should require slash-style modules under `suwayomi/`, for example `require("suwayomi/api")`. New runtime modules should stay in that namespace instead of adding top-level `suwayomi_*.lua` files.

## Module Ownership

Core plugin shell:

- `main.lua`: KOReader lifecycle, dependency construction, action/menu registration, queue recovery, and controller method installation.
- `suwayomi/navigation.lua`: route-aware stack for Suwayomi-owned KOReader widgets.
- `suwayomi/reader_return.lua`: reader-menu shortcut state and async chapter reload for returning from an opened CBZ to the originating Suwayomi chapter list.
- `suwayomi/plugin/home.lua`: Suwayomi hub and main-menu entry behavior.
- `suwayomi/plugin/title_menu.lua`: shared title-bar burger menus for full-screen plugin screens, including the universal Suwayomi home action.
- `suwayomi/plugin/settings_controller.lua`: grouped Settings menus, setup wizard orchestration, connection-test state, and settings action routing.
- `suwayomi/plugin/onboarding_connection_worker.lua`: subprocess-safe Suwayomi connection probe used by the setup wizard. It returns structured result IDs for plugin-authored success/failure text and raw `error` strings only for external API/network failures; `settings_controller` owns user-facing translation.

API:

- `suwayomi/api/queries.lua`: GraphQL query and mutation payload builders.
- `suwayomi/api/parsers.lua`: defensive parsing and normalization of Suwayomi responses.
- `suwayomi/api/transport.lua`: basic auth, endpoint construction, GraphQL requests, archive downloads, binary page fetches, and bounded response sinks for bad-network protection.
- `suwayomi/api.lua`: facade that composes the submodules and owns API debug logging.

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

- `suwayomi/downloads/controller.lua`: top-level Downloads hub, active/queued/failed actions, shared chapter/download error details, retry/clear/cancel, and downloaded-read reconciliation. Failed rows open details directly; scheduled retries retain queued actions and add Download error. Both use the same details as the chapter action menu. The controller resolves the current persisted job before opening details; Retry revalidates through the queue. `suwayomi/ui/downloads.lua` keeps row summaries compact and opens KOReader's scrollable `TextViewer` with context and Retry/Close only on request. Scheduled retries retain automatic timing and show a fixed local timestamp. Closing details leaves the originating screen in place. Plugin-authored UI text routes through `suwayomi/i18n.lua`; manga/chapter names, keys, and stored errors remain external data.
- `suwayomi/downloads/directory.lua`: download-directory chooser, summary, persistence callback flow, and default directory probing. Plugin-authored summary/save messages route through `suwayomi/i18n.lua`; directory paths remain external data.
- `suwayomi/downloads/queue.lua`: public KOReader-local queue facade, including the persisted terminal failure count. Retry snapshots retain the complete error across recovery. Queue transitions finish persistence and snapshot updates before notifying UI consumers. The home controller refreshes its existing Downloads button only when the terminal failure count changes; `main.lua` wires that refresh alongside chapter/download refresh callbacks. Duplicate enqueue messages route through `suwayomi/i18n.lua`; queue keys, persisted state, and progress state remain data.
- `suwayomi/downloads/active_jobs.lua`: bounded active chapter jobs, subprocess launch, progress polling, watchdog handling, persisted staggered retries for transient failures, and replacement scheduling. Background failures stay in queue state instead of opening one message per chapter. Plugin-authored fallback/startup failure text routes through `suwayomi/i18n.lua`; raw worker errors remain external data.
- `suwayomi/downloads/job_store.lua`: persisted queue schema, serialization-safe job metadata, duplicate handling, and recovery normalization.
- `suwayomi/downloads/progress_file.lua`: per-job progress path, read/write format, and fallback progress writing.
- `suwayomi/downloads/status_formatter.lua`: chapter status symbols and user-facing queue/download status text.
- `suwayomi/downloads/downloader.lua`: one-chapter download, page validation, ordered CBZ writing, `.part` cleanup, and final rename. The optional archive export falls back to device-local page downloading on HTTP 400 (no server download) or HTTP 404; transient failures retry, while authentication and filesystem failures remain failures.

Chapters and read state:

- `suwayomi/chapters/context.lua`: current manga/chapter context and visible chapter filtering state; remote chapter loading is owned by async manga request helpers. Plugin-authored title fallbacks, selected-count titles, scanlator menu chrome, and queue summaries route through `suwayomi/i18n.lua`; manga titles and scanlator values remain external data.
- `suwayomi/chapters/menu.lua`: chapter menu construction, updates, selection mode, and menu refresh behavior. Plugin-authored action labels, bulk-menu titles, and scanlator menu chrome route through `suwayomi/i18n.lua`; chapter names remain external data.
- `suwayomi/chapters/actions.lua`: chapter and selected-chapter action facade. Plugin-authored open/delete/download/read messages, confirmations, and summaries route through `suwayomi/i18n.lua`; chapter names, manga titles, and filesystem paths remain external data.
- `suwayomi/chapters/local_downloads.lua`: local archive existence/open/delete helpers.
- `suwayomi/chapters/delete_actions.lua`: device delete and batch cleanup flows. Plugin-authored delete refusal/failure messages route through `suwayomi/i18n.lua`.
- `suwayomi/chapters/read_actions.lua`: read/unread actions and mark-previous orchestration.
- `suwayomi/readsync/ledger.lua`: local read ledger persistence.
- `suwayomi/readsync/koreader_metadata.lua`: KOReader sidecar/history inspection.
- `suwayomi/readsync/worker.lua`: background read-sync worker behavior.
- `suwayomi/readsync/controller.lua`: pending read-sync scheduling, polling, retry, and reconciliation.
- `suwayomi/network/request_worker.lua`, `suwayomi/network/request_job.lua`: generic one-shot network request worker/launcher for Library, reader-return, manga actions, and chapter-context flows that need remote data without blocking KOReader UI callbacks. Callers keep active job tokens so newer requests cancel or ignore stale older results.

Shared support:

- `suwayomi/settings.lua`: KOReader settings persistence.
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
| Download queue, active jobs, progress files, status text, or one-chapter CBZ writing | `suwayomi/downloads/queue.lua`, `suwayomi/downloads/active_jobs.lua`, `suwayomi/downloads/progress_file.lua`, `suwayomi/downloads/status_formatter.lua`, `suwayomi/downloads/downloader.lua` | queue/download specs |
| Download directory selection or source-scoped path layout | `suwayomi/downloads/directory.lua`, `suwayomi/paths.lua` | directory/path specs |
| Read-sync ledger, KOReader sidecar/history handling, worker polling, or reconciliation | `suwayomi/readsync/ledger.lua`, `suwayomi/readsync/koreader_metadata.lua`, `suwayomi/readsync/worker.lua`, `suwayomi/readsync/controller.lua` | read-sync specs |
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

Coverage is organized around runtime boundaries:

- `spec/main_spec.lua` focuses on KOReader lifecycle: dispatcher/menu registration, lazy dependency construction, queue recovery, debug logger setup, and controller method installation.
- API specs cover the facade plus query/parser/transport submodules without live Suwayomi calls.
- Client specs are split by flow: `spec/suwayomi_client_source_manga_spec.lua`, `spec/suwayomi_client_global_search_spec.lua`, `spec/suwayomi_client_library_spec.lua`, and the small facade-focused `spec/suwayomi_client_spec.lua`.
- UI specs cover menu table construction and KOReader dialog/menu helper behavior with stubbed widgets.
- I18n specs stub KOReader `gettext` and `ffi/util.template` directly. Module specs that assert visible built-in labels should clear `suwayomi/i18n` from `package.loaded` before requiring the module under test so each spec controls the active gettext stub. Worker specs should prefer structured message/error IDs for plugin-authored text and reserve raw strings for server/API data.
- Browse and extension i18n specs use marker `suwayomi/i18n` stubs to prove plugin-authored menu chrome routes through the facade. Source names, extension names, package names, server errors, source filter labels, and source filter values remain external data and are asserted without translation markers.
- Library, manga, chapter, and downloads i18n specs use marker `suwayomi/i18n` stubs to prove plugin-authored menu chrome, confirmations, status summaries, and fallback errors route through the facade. Library category names, manga titles, chapter names, scanlator names, source names, category/genre metadata, filesystem paths, raw API errors, and raw worker errors remain external data and are asserted without translation markers.
- `spec/suwayomi_download_failure_ux_spec.lua` composes real queue persistence, controller actions, and download UI builders with KOReader widget/worker substitutes to verify error access, restart recovery, stale actions, quiet failures, and displayed queue transitions together.
- Queue/download specs cover persisted jobs, active worker scheduling, progress files, status text, and one-chapter CBZ behavior without real network or real subprocess timing.
- Controller specs exercise plugin-bound methods with KOReader/runtime stubs rather than requiring real KOReader.
- Read-sync specs isolate ledger, metadata/history handling, worker behavior, and controller polling/retry flows.
- L10n tooling tests are shell-script based: `scripts/check-l10n.sh` verifies extraction freshness, `.po` validity, and generated `.mo` availability without requiring gettext tools on KOReader devices.

Use the same checks as CI:

```bash
PATH="$HOME/.luarocks/bin:$PATH" busted spec
PATH="$HOME/.luarocks/bin:$PATH" luacheck --codes spec suwayomi main.lua _meta.lua
./scripts/check-l10n.sh
```

The Luacheck command covers project Lua parsing/linting while avoiding generated
dependency directories such as `.lua` and `.luarocks`.
