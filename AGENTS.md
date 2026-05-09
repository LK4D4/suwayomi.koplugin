# AGENTS.md

## Commands

- CI installs LuaJIT with `leafo/gh-actions-lua@v13` and LuaRocks with `leafo/gh-actions-luarocks@v6`; local development should use LuaJIT too.
- On fresh Ubuntu/dev containers, install local tools with `sudo apt-get install -y luajit luarocks`.
- Verify LuaRocks is using LuaJIT before installing deps: `luarocks config lua_interpreter` should print a LuaJIT executable.
- Install local test/lint deps with user-local LuaRocks packages: `luarocks install --local busted`, `luarocks install --local dkjson`, and `luarocks install --local luacheck`.
- `luarocks --local` puts executables in `$HOME/.luarocks/bin`; use `PATH="$HOME/.luarocks/bin:$PATH" ...` unless that path is already exported.
- Run the full lint suite from the repo root: `PATH="$HOME/.luarocks/bin:$PATH" luacheck --codes spec suwayomi main.lua _meta.lua`.
- Run the full test suite from the repo root: `PATH="$HOME/.luarocks/bin:$PATH" busted spec`.
- Run one spec file from the repo root: `PATH="$HOME/.luarocks/bin:$PATH" busted spec/suwayomi_api_spec.lua`.
- `luacheck --codes spec suwayomi main.lua _meta.lua` provides project Lua parsing/linting while avoiding generated dependency directories such as `.lua` and `.luarocks`; do not add a separate `luac` syntax pass.
- Specs set `package.path = "?.lua;" .. package.path`; run `busted` from the plugin root or local module requires will not resolve.

## Project Shape

- This is a LuaJIT/Lua 5.1 KOReader plugin, not a standalone Lua app; KOReader modules such as `ui/uimanager`, `dispatcher`, `datastorage`, `ffi/util`, and `ffi/archiver` exist at runtime and are usually stubbed in specs.
- `docs/ARCHITECTURE.md` is the active architecture reference. Keep this file as concise agent guidance and update the architecture doc when module ownership, public facades, packaging boundaries, or test strategy change materially.
- KOReader requires `_meta.lua` and `main.lua` at the top of the `suwayomi_dl.koplugin/` directory. Keep `main.lua` as a thin lifecycle/composition shell: action registration, KOReader plugin callbacks, dependency construction, and compatibility delegators only. Do not add new feature logic to `main.lua` unless it is truly KOReader lifecycle glue.
- Put runtime modules under the plugin-local `suwayomi/` namespace directory instead of adding top-level `suwayomi_*.lua` files. Use slash-style Lua requires that work with KOReader's plugin loader package path, for example `require("suwayomi/api")` or `require("suwayomi/downloads/controller")`.
- Current preferred layout for new/extracted code:
  - `suwayomi/api.lua`: public API facade and API debug logging.
  - `suwayomi/api/queries.lua`, `suwayomi/api/parsers.lua`, `suwayomi/api/transport.lua`: GraphQL payload builders, defensive response parsing, and HTTP/auth/URL handling.
  - `suwayomi/client.lua`: Library/Browse orchestration that is not KOReader lifecycle glue.
  - `suwayomi/ui.lua`: public KOReader UI facade.
  - `suwayomi/ui/browse.lua`, `suwayomi/ui/downloads.lua`, `suwayomi/ui/directory.lua`, `suwayomi/ui/menu_utils.lua`: Browse menus, Downloads menus, directory picking, and shared menu plumbing.
  - `suwayomi/settings.lua`, `suwayomi/paths.lua`, `suwayomi/debug.lua`: settings, source-scoped path layout, and debug logging.
  - `suwayomi/downloads/queue.lua`: public download queue facade, enqueue/retry/cancel/recovery/snapshot/status APIs.
  - `suwayomi/downloads/active_jobs.lua`: bounded active chapter jobs, subprocess launch, polling, watchdog handling, and replacement scheduling.
  - `suwayomi/downloads/directory.lua`: download-directory chooser, persistence callback flow, and default directory probing.
  - `suwayomi/downloads/job_store.lua`, `suwayomi/downloads/progress_file.lua`, `suwayomi/downloads/status_formatter.lua`: persisted queue schema, progress-file IO, and chapter download status text.
  - `suwayomi/downloads/downloader.lua`: one-chapter downloads, page validation, ordered CBZ writing, `.part` cleanup, and final rename.
  - `suwayomi/downloads/controller.lua`: top-level Downloads hub/menu orchestration, retry/clear/cancel actions, and keep-next-unread policy application.
  - `suwayomi/browse/controller.lua`, `suwayomi/browse/source_catalog.lua`, and `suwayomi/browse/source_fetch_worker.lua`: Browse entry flow, source filtering/cache/rendering, and source fetch worker lifecycle.
  - `suwayomi/manga/controller.lua`: manga action menu orchestration, library membership, refresh, first-unread helpers, and manga-level download/read actions.
  - `suwayomi/chapters/context.lua`, `suwayomi/chapters/menu.lua`, `suwayomi/chapters/actions.lua`: chapter context, menu construction, and the public chapter action facade.
  - `suwayomi/chapters/local_downloads.lua`, `suwayomi/chapters/delete_actions.lua`, `suwayomi/chapters/read_actions.lua`: local archive state, device deletion flows, and read/unread action orchestration.
  - `suwayomi/readsync/ledger.lua`, `suwayomi/readsync/koreader_metadata.lua`, `suwayomi/readsync/worker.lua`, `suwayomi/readsync/controller.lua`: read ledger, KOReader sidecar/history handling, worker code, and read-sync orchestration.
- Do not add compatibility wrappers for old top-level `suwayomi_*.lua` module names; update callers and tests to the slash-style module names instead.
- Runtime Lua files should start with a short line-comment `-- Boundary:` header matching the current module convention. Use regular `--` comments for explanatory notes; avoid top-of-file `--[[ ... ]]` documentation blocks unless a future file has a specific reason to differ.
- Document any code whose purpose is not immediately obvious with a short comment explaining why it exists; avoid comments that merely restate what the code says.
- Keep lint policy centralized in `.luacheckrc`. Do not add inline `-- luacheck:` directives for routine repo-wide conventions such as unused `self`; update `.luacheckrc` instead when the rule should apply broadly.
- Path layout is source-scoped through the paths module: `<download_directory>/<source_label>/<manga_title>/<chapter_name>.cbz`. Do not add old unscoped path detection unless explicitly requested.
- Downloads are KOReader-device-local CBZ downloads. Do not use Suwayomi server download mutations as a hidden side effect.

## Tests And Stubs

- Tests isolate KOReader/runtime dependencies with `package.preload` and clear `package.loaded`; follow that pattern instead of requiring real KOReader in unit tests.
- When changing a module with module-level state, clear its `package.loaded[...]` entry in specs before requiring it.
- `spec/main_spec.lua` should stay focused on KOReader lifecycle and shell composition: dispatcher/menu registration, lazy dependency construction, queue recovery, debug logger setup, and controller method installation.
- For settings behavior, specs stub `datastorage` and `luasettings`; real settings are stored under KOReader's settings dir as `suwayomi_dl.lua`.
- Debug instrumentation is off unless KOReader settings contain `suwayomi_dl_debug.lua` with `enabled = true`; logs are redacted and use the `SuwayomiDL` prefix.

## Release/Runtime Packaging

- Release zips must include `_meta.lua`, `main.lua`, `README.md`, and the runtime `suwayomi/` directory. Specs, docs, CI files, and `AGENTS.md` are not runtime payload.
- For Android manual QA, push only runtime plugin files to `/sdcard/koreader/plugins/suwayomi_dl.koplugin/`; include `suwayomi/` and avoid pushing `.git`, `spec`, docs, or CI files.

## Product Constraints

- The supported practical flow currently targets Suwayomi Local Source; remote sources may browse but are not the main tested reading/download path.
- The top-level Downloads hub is implemented for KOReader-local active, queued, and failed jobs. Completed history and Suwayomi server download queue management are intentionally not implemented.
- Known performance-sensitive paths are synchronous UI GraphQL calls, chapter menu filesystem/metadata checks, batch delete cleanup, and background read-sync worker polling; use `docs/android-performance-testing.md` for Android stall evidence collection.
