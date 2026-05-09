# Suwayomi KOReader Plugin Architecture

This document describes the current runtime boundaries after the module refactor. It is the active architecture reference; older design specs under `docs/superpowers/specs/` describe historical implementation slices and may use pre-refactor module names.

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
- `suwayomi/ui.lua` exposes KOReader menu/dialog helpers. It delegates Browse menus to `suwayomi/ui/browse.lua`, Downloads menus to `suwayomi/ui/downloads.lua`, directory picking to `suwayomi/ui/directory.lua`, and shared menu plumbing to `suwayomi/ui/menu_utils.lua`.
- `suwayomi/downloads/queue.lua` is the public device-local download queue. It owns enqueue/retry/cancel/recovery/snapshot/status APIs and delegates active subprocess scheduling to `suwayomi/downloads/active_jobs.lua`, persistence to `suwayomi/downloads/job_store.lua`, progress-file IO to `suwayomi/downloads/progress_file.lua`, and chapter-row status text to `suwayomi/downloads/status_formatter.lua`.
- `suwayomi/client.lua` coordinates Library and Browse flows that are not KOReader lifecycle glue.
- `suwayomi/chapters/actions.lua` is the chapter action facade for download, delete, read/unread, selected/bulk, and manga-level chapter actions.
- `suwayomi/readsync/controller.lua` is the read-sync orchestration facade, with ledger and KOReader sidecar/history behavior split into sibling modules.

Callers should require these slash-style modules, for example `require("suwayomi/api")`. Do not add compatibility wrappers for old top-level `suwayomi_*.lua` names.

## Module Ownership

Core plugin shell:

- `main.lua`: KOReader lifecycle, dependency construction, action/menu registration, queue recovery, and controller method installation.
- `suwayomi/plugin/home.lua`: Suwayomi hub and main-menu entry behavior.
- `suwayomi/plugin/settings_controller.lua`: grouped Settings menus and settings action routing.

API:

- `suwayomi/api/queries.lua`: GraphQL query and mutation payload builders.
- `suwayomi/api/parsers.lua`: defensive parsing and normalization of Suwayomi responses.
- `suwayomi/api/transport.lua`: basic auth, endpoint construction, GraphQL requests, archive downloads, and binary page fetches.
- `suwayomi/api.lua`: facade that composes the submodules and owns API debug logging.

Browse and Library:

- `suwayomi/client.lua`: user-flow orchestration for Library, Browse, source search, pagination, and manga actions.
- `suwayomi/browse/controller.lua`: Browse entry flow, source fetch worker lifecycle, polling, and source-cache refresh.
- `suwayomi/browse/source_catalog.lua`: source filtering, source cache IO, and source-list rendering.
- `suwayomi/browse/source_fetch_worker.lua`: subprocess worker for fetching sources into a result file.
- `suwayomi/manga/controller.lua`: manga actions, refresh, library membership, first-unread helpers, and manga-level download/read actions.

Downloads:

- `suwayomi/downloads/controller.lua`: top-level Downloads hub, active/queued/failed actions, retry/clear/cancel, and keep-next-unread policy application.
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
- UI specs cover menu table construction and KOReader dialog/menu helper behavior with stubbed widgets.
- Queue/download specs cover persisted jobs, active worker scheduling, progress files, status text, and one-chapter CBZ behavior without real network or real subprocess timing.
- Controller specs exercise plugin-bound methods with KOReader/runtime stubs rather than requiring real KOReader.
- Read-sync specs isolate ledger, metadata/history handling, worker behavior, and controller polling/retry flows.

Use the same checks as CI:

```bash
PATH="$HOME/.luarocks/bin:$PATH" busted spec
PATH="$HOME/.luarocks/bin:$PATH" luacheck --codes .
```
