# Suwayomi KOReader Plugin Architecture

This document describes the current runtime boundaries after the module refactor. It is the active architecture reference for humans and AI agents working in the repo.

## Runtime Shape

KOReader loads `_meta.lua` and `main.lua` from the plugin root. `main.lua` is the plugin shell: it registers the dispatcher action, wires the main menu entry, constructs shared dependencies, restores the download queue, and installs controller methods onto the KOReader plugin object. Feature behavior belongs under `suwayomi/`.

Runtime files shipped in releases are:

- `_meta.lua`
- `main.lua`
- `README.md`
- `suwayomi/`

Tests, docs, CI files, worktrees, and `AGENTS.md` are development-only and must not be included in manual Android plugin pushes or release payloads.

## Public Facades

The public runtime facades are intentionally small and stable:

- `suwayomi/api.lua` exposes Suwayomi GraphQL and binary HTTP helpers. It delegates query construction to `suwayomi/api/queries.lua`, response decoding to `suwayomi/api/parsers.lua`, and HTTP/auth/URL handling to `suwayomi/api/transport.lua`.
- `suwayomi/ui.lua` exposes KOReader menu/dialog helpers. It delegates Browse menus to `suwayomi/ui/browse.lua`, shared manga/source/chapter row formatting to `suwayomi/ui/list_rows.lua`, KOReader thumbnail list rendering to `suwayomi/ui/list_menu.lua`, Downloads menus to `suwayomi/ui/downloads.lua`, directory picking to `suwayomi/ui/directory.lua`, and shared menu plumbing to `suwayomi/ui/menu_utils.lua`.
- `suwayomi/downloads/queue.lua` is the public device-local download queue. It owns enqueue/retry/cancel/recovery/snapshot/status APIs and delegates active subprocess scheduling to `suwayomi/downloads/active_jobs.lua`, persistence to `suwayomi/downloads/job_store.lua`, progress-file IO to `suwayomi/downloads/progress_file.lua`, and chapter-row status text to `suwayomi/downloads/status_formatter.lua`.
- `suwayomi/client.lua` is the public Library/Browse client facade. It wires injected dependencies and installs focused flow modules from `suwayomi/client/`.
- `suwayomi/chapters/actions.lua` is the chapter action facade for download, delete, read/unread, selected/bulk, and manga-level chapter actions.
- `suwayomi/readsync/controller.lua` is the read-sync orchestration facade, with ledger and KOReader sidecar/history behavior split into sibling modules.

Callers should require these slash-style modules, for example `require("suwayomi/api")`. Do not add compatibility wrappers for old top-level `suwayomi_*.lua` names.

## Module Ownership

Core plugin shell:

- `main.lua`: KOReader lifecycle, dependency construction, action/menu registration, queue recovery, and controller method installation.
- `suwayomi/plugin/home.lua`: Suwayomi hub and main-menu entry behavior.
- `suwayomi/plugin/title_menu.lua`: shared title-bar burger menus for full-screen plugin screens, including the universal Suwayomi home action.
- `suwayomi/plugin/settings_controller.lua`: grouped Settings menus and settings action routing.

API:

- `suwayomi/api/queries.lua`: GraphQL query and mutation payload builders.
- `suwayomi/api/parsers.lua`: defensive parsing and normalization of Suwayomi responses.
- `suwayomi/api/transport.lua`: basic auth, endpoint construction, GraphQL requests, archive downloads, and binary page fetches.
- `suwayomi/api.lua`: facade that composes the submodules and owns API debug logging.

Browse and Library:

- `suwayomi/client.lua`: public Library/Browse client facade and dependency container.
- `suwayomi/client/runtime.lua`: lazy runtime dependency lookup and worker timeout/concurrency settings.
- `suwayomi/client/source_manga.lua`: source mode selection, source-specific search prompts, source manga worker loading, browse result rendering, and manga action refresh callbacks.
- `suwayomi/client/global_search.lua`: partial global search state, worker scheduling, cancellation, timeout handling, and live summary menu updates.
- `suwayomi/client/library.lua`: library category selection, paged library loading, category filtering, and library manga menu refresh callbacks.
- `suwayomi/client/browse_chapter_counts.lua`: bounded background chapter-count enrichment for browse result rows.
- `suwayomi/client/util.lua`: tiny shared helpers used by client flow modules.
- `suwayomi/ui/list_rows.lua`: pure shared row formatting for manga and source records, including subtitles, status markers, and thumbnail metadata.
- `suwayomi/ui/list_menu.lua`: KOReader Menu-compatible thumbnail rows with cached thumbnail slots for Library, Browse/Search, source results, and chapter-like lists.
- `suwayomi/ui/manga_menu.lua`: compatibility alias for `suwayomi/ui/list_menu.lua`; keep new renderer behavior in `list_menu.lua`.
- `suwayomi/ui/thumbnail_cache.lua`, `suwayomi/ui/thumbnail_worker.lua`: private thumbnail cache pathing and bounded background thumbnail fetch support.
- `suwayomi/browse/controller.lua`: Browse entry flow, source fetch worker lifecycle, polling, and source-cache refresh.
- `suwayomi/browse/source_catalog.lua`: source filtering, source cache IO, and source-list rendering.
- `suwayomi/browse/source_fetch_worker.lua`: subprocess worker for fetching sources into a result file.
- `suwayomi/browse/global_search_worker.lua`: subprocess worker for fetching one source's first search page into a result file for partial global search.
- `suwayomi/manga/controller.lua`: manga actions, refresh, library membership, first-unread helpers, and manga-level download/read actions.

Downloads:

- `suwayomi/downloads/controller.lua`: top-level Downloads hub, active/queued/failed actions, retry/clear/cancel, and downloaded-read reconciliation.
- `suwayomi/downloads/directory.lua`: download-directory chooser, summary, persistence callback flow, and default directory probing.
- `suwayomi/downloads/queue.lua`: public KOReader-local queue facade.
- `suwayomi/downloads/active_jobs.lua`: bounded active chapter jobs, subprocess launch, progress polling, watchdog handling, and replacement scheduling.
- `suwayomi/downloads/job_store.lua`: persisted queue schema, serialization-safe job metadata, duplicate handling, and recovery normalization.
- `suwayomi/downloads/progress_file.lua`: per-job progress path, read/write format, and fallback progress writing.
- `suwayomi/downloads/status_formatter.lua`: chapter status symbols and user-facing queue/download status text.
- `suwayomi/downloads/downloader.lua`: one-chapter download, page validation, ordered CBZ writing, `.part` cleanup, and final rename.

Chapters and read state:

- `suwayomi/chapters/context.lua`: current manga/chapter context and visible chapter filtering state.
- `suwayomi/chapters/menu.lua`: chapter menu construction, updates, selection mode, and menu refresh behavior.
- `suwayomi/chapters/actions.lua`: chapter and selected-chapter action facade.
- `suwayomi/chapters/local_downloads.lua`: local archive existence/open/delete helpers.
- `suwayomi/chapters/delete_actions.lua`: device delete and batch cleanup flows.
- `suwayomi/chapters/read_actions.lua`: read/unread actions and previous/through-here orchestration.
- `suwayomi/readsync/ledger.lua`: local read ledger persistence.
- `suwayomi/readsync/koreader_metadata.lua`: KOReader sidecar/history inspection.
- `suwayomi/readsync/worker.lua`: background read-sync worker behavior.
- `suwayomi/readsync/controller.lua`: pending read-sync scheduling, polling, retry, and reconciliation.

Shared support:

- `suwayomi/settings.lua`: KOReader settings persistence.
- `suwayomi/paths.lua`: source-scoped download path layout and path segment sanitization.
- `suwayomi/debug.lua`: opt-in redacted debug logging.
- `suwayomi/subprocess/job.lua`: shared helper for one-shot subprocess jobs that exchange compact JSON result files. Callers provide the worker body, result parser, poll/timeout values, and finish/error/cancel callbacks; the helper owns atomic `.tmp` writes, result path allocation, polling, timeout termination, and result-file cleanup.

Long-running subprocess patterns are intentionally split by shape: one-shot JSON result workers use `suwayomi/subprocess/job.lua`, while active downloads stay in `suwayomi/downloads/active_jobs.lua` because they require progress files, persisted queue state, and replacement scheduling.

## Where To Change Things

Use this map before broad searches. It points to the first files to inspect for
common changes and the specs that usually cover them.

| Change area | Start here | Usually covered by |
| --- | --- | --- |
| KOReader plugin lifecycle, dispatcher actions, menu entry, or dependency construction | `main.lua`, `suwayomi/plugin/home.lua`, `suwayomi/plugin/settings_controller.lua`, `suwayomi/plugin/title_menu.lua` | `spec/main_spec.lua`, plugin controller specs |
| GraphQL fields, mutations, response normalization, or legacy-schema fallback | `suwayomi/api/queries.lua`, `suwayomi/api/parsers.lua`, `suwayomi/api.lua`, `suwayomi/api/transport.lua` | API specs |
| Browse source list, source cache, source language/NSFW filtering, or source refresh | `suwayomi/browse/source_catalog.lua`, `suwayomi/browse/controller.lua`, `suwayomi/settings.lua` | `spec/suwayomi_browse_*`, settings specs |
| Source row metadata such as icons, language labels, adult markers, or global-search summary rows | `suwayomi/ui/list_rows.lua`, `suwayomi/ui/browse.lua`, `suwayomi/browse/source_catalog.lua`, `suwayomi/api/queries.lua`, `suwayomi/api/parsers.lua` | `spec/suwayomi_ui_list_rows_spec.lua`, `spec/suwayomi_ui_browse_spec.lua`, API parser/query specs |
| Thumbnail list rendering, cached thumbnail slots, visible-row thumbnail jobs, or Menu-compatible row widgets | `suwayomi/ui/list_menu.lua`, `suwayomi/ui/thumbnail_cache.lua`, `suwayomi/ui/thumbnail_worker.lua` | `spec/suwayomi_ui_list_menu_spec.lua`, `spec/suwayomi_ui_manga_menu_spec.lua` |
| Source manga loading, source-specific search, browse result pagination, and browse chapter-count enrichment | `suwayomi/client/source_manga.lua`, `suwayomi/client/browse_chapter_counts.lua`, `suwayomi/browse/source_manga_worker.lua`, `suwayomi/browse/chapter_count_worker.lua` | `spec/suwayomi_client_source_manga_spec.lua`, worker specs |
| Global search prompt/results, partial worker scheduling, cancellation, or timeouts | `suwayomi/client/global_search.lua`, `suwayomi/browse/global_search_worker.lua` | `spec/suwayomi_client_global_search_spec.lua`, worker specs |
| Library loading, category picker behavior, library paging, and library row refresh after manga actions | `suwayomi/client/library.lua`, `suwayomi/client.lua` | `spec/suwayomi_client_library_spec.lua`, `spec/suwayomi_client_spec.lua` |
| Manga-level actions, refresh, library membership, and first-unread behavior | `suwayomi/manga/controller.lua`, `suwayomi/client.lua` | manga/client/controller specs |
| Chapter menu behavior, selected/bulk actions, local archive delete/open, or read/unread actions | `suwayomi/chapters/menu.lua`, `suwayomi/chapters/actions.lua`, `suwayomi/chapters/local_downloads.lua`, `suwayomi/chapters/delete_actions.lua`, `suwayomi/chapters/read_actions.lua` | chapter specs |
| Download queue, active jobs, progress files, status text, or one-chapter CBZ writing | `suwayomi/downloads/queue.lua`, `suwayomi/downloads/active_jobs.lua`, `suwayomi/downloads/progress_file.lua`, `suwayomi/downloads/status_formatter.lua`, `suwayomi/downloads/downloader.lua` | queue/download specs |
| Download directory selection or source-scoped path layout | `suwayomi/downloads/directory.lua`, `suwayomi/paths.lua` | directory/path specs |
| Read-sync ledger, KOReader sidecar/history handling, worker polling, or reconciliation | `suwayomi/readsync/ledger.lua`, `suwayomi/readsync/koreader_metadata.lua`, `suwayomi/readsync/worker.lua`, `suwayomi/readsync/controller.lua` | read-sync specs |
| Settings persistence, debug logging, or redaction | `suwayomi/settings.lua`, `suwayomi/debug.lua` | settings/debug specs |
| Runtime packaging or Android manual push payload | plugin root `_meta.lua`, `main.lua`, `README.md`, `suwayomi/`, plus `AGENTS.md` packaging notes | release/manual QA checks |

## Data And Packaging Boundaries

Downloads are KOReader-device-local CBZ files. The plugin does not use Suwayomi server download mutations as a hidden side effect and does not treat Suwayomi server downloaded state as local availability.

New downloads use the source-scoped layout:

```text
<download_directory>/<source_label>/<manga_title>/<chapter_name>.cbz
```

Old unscoped path detection is intentionally absent unless a future task explicitly adds migration behavior.

External data is treated as untrusted at module boundaries: API responses are parsed defensively, settings values are normalized before use, persisted jobs keep only serializable metadata, progress files are re-read and normalized by the parent queue, and filesystem paths are built through the paths module or local helper boundaries.

## Test Strategy

Specs run from the plugin root with `package.path = "?.lua;" .. package.path`. KOReader modules are stubbed through `package.preload`, and modules with state are cleared from `package.loaded` before requiring them.

Coverage is organized around runtime boundaries:

- `spec/main_spec.lua` focuses on KOReader lifecycle: dispatcher/menu registration, lazy dependency construction, queue recovery, debug logger setup, and controller method installation.
- API specs cover the facade plus query/parser/transport submodules without live Suwayomi calls.
- Client specs are split by flow: `spec/suwayomi_client_source_manga_spec.lua`, `spec/suwayomi_client_global_search_spec.lua`, `spec/suwayomi_client_library_spec.lua`, and the small facade-focused `spec/suwayomi_client_spec.lua`.
- UI specs cover menu table construction and KOReader dialog/menu helper behavior with stubbed widgets.
- Queue/download specs cover persisted jobs, active worker scheduling, progress files, status text, and one-chapter CBZ behavior without real network or real subprocess timing.
- Controller specs exercise plugin-bound methods with KOReader/runtime stubs rather than requiring real KOReader.
- Read-sync specs isolate ledger, metadata/history handling, worker behavior, and controller polling/retry flows.

Use the same checks as CI:

```bash
PATH="$HOME/.luarocks/bin:$PATH" busted spec
PATH="$HOME/.luarocks/bin:$PATH" luacheck --codes spec suwayomi main.lua _meta.lua
```

The Luacheck command covers project Lua parsing/linting while avoiding generated
dependency directories such as `.lua` and `.luarocks`.
