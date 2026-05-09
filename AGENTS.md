# AGENTS.md

## Commands

- On fresh Ubuntu runners/dev containers, install system tools first: `sudo apt-get install -y lua5.1 luarocks`.
- Install local test deps like CI: `luarocks install --local busted` and `luarocks install --local dkjson`.
- `luarocks --local` puts executables in `$HOME/.luarocks/bin`; use `PATH="$HOME/.luarocks/bin:$PATH" busted ...` unless that path is already exported.
- Run the full test suite from the repo root: `PATH="$HOME/.luarocks/bin:$PATH" busted spec`.
- Run one spec file from the repo root: `PATH="$HOME/.luarocks/bin:$PATH" busted spec/suwayomi_api_spec.lua`.
- Match CI syntax checking with a Lua 5.1-compatible compiler: `find . -name '*.lua' -not -path './spec/*' -not -path './docs/*' -print0 | xargs -0 luac -p`.
- On Windows, prefer PowerShell recursion for syntax checks: `Get-ChildItem -Recurse -Filter *.lua | Where-Object { $_.FullName -notmatch '\\spec\\|\\docs\\' } | ForEach-Object { luac -p $_.FullName }`.
- Specs set `package.path = "?.lua;" .. package.path`; run `busted` from the plugin root or local module requires will not resolve.

## Project Shape

- This is a Lua 5.1 KOReader plugin, not a standalone Lua app; KOReader modules such as `ui/uimanager`, `dispatcher`, `datastorage`, `ffi/util`, and `ffi/archiver` exist at runtime and are usually stubbed in specs.
- KOReader requires `_meta.lua` and `main.lua` at the top of the `suwayomi_dl.koplugin/` directory. Keep `main.lua` as a thin lifecycle/composition shell: action registration, KOReader plugin callbacks, dependency construction, and compatibility delegators only. Do not add new feature logic to `main.lua` unless it is truly KOReader lifecycle glue.
- Put runtime modules under the plugin-local `suwayomi/` namespace directory instead of adding top-level `suwayomi_*.lua` files. Use slash-style Lua requires that work with KOReader's plugin loader package path, for example `require("suwayomi/api")` or `require("suwayomi/downloads/controller")`.
- Preferred target layout for new/extracted code:
  - `suwayomi/api.lua`: GraphQL query building, HTTP, and response parsing.
  - `suwayomi/client.lua`: Library/Browse orchestration that is not KOReader lifecycle glue.
  - `suwayomi/ui.lua`: KOReader menu/dialog construction helpers.
  - `suwayomi/settings.lua`, `suwayomi/paths.lua`, `suwayomi/debug.lua`: settings, source-scoped path layout, and debug logging.
  - `suwayomi/downloads/queue.lua`: public download queue facade, subprocess launch, polling, and recovery orchestration.
  - `suwayomi/downloads/job_store.lua`, `suwayomi/downloads/progress_file.lua`, `suwayomi/downloads/status_formatter.lua`: persisted queue schema, progress-file IO, and chapter download status text.
  - `suwayomi/downloads/downloader.lua`: one-chapter downloads, page validation, ordered CBZ writing, `.part` cleanup, and final rename.
  - `suwayomi/downloads/controller.lua`: top-level Downloads hub/menu orchestration.
  - `suwayomi/browse/source_catalog.lua` and `suwayomi/browse/source_fetch_worker.lua`: source filtering/cache and source fetch worker lifecycle.
  - `suwayomi/chapters/context.lua`, `suwayomi/chapters/menu.lua`, `suwayomi/chapters/actions.lua`: chapter context, menu construction, and chapter-level actions.
  - `suwayomi/readsync/ledger.lua`, `suwayomi/readsync/koreader_metadata.lua`, `suwayomi/readsync/worker.lua`, `suwayomi/readsync/controller.lua`: read ledger, KOReader sidecar/history handling, worker code, and read-sync orchestration.
- Do not add compatibility wrappers for old top-level `suwayomi_*.lua` module names; update callers and tests to the slash-style module names instead.
- Document any code whose purpose is not immediately obvious with a short comment explaining why it exists; avoid comments that merely restate what the code says.
- Path layout is source-scoped through the paths module: `<download_directory>/<source_label>/<manga_title>/<chapter_name>.cbz`. Do not add old unscoped path detection unless explicitly requested.
- Downloads are KOReader-device-local CBZ downloads. Do not use Suwayomi server download mutations as a hidden side effect.

## Tests And Stubs

- Tests isolate KOReader/runtime dependencies with `package.preload` and clear `package.loaded`; follow that pattern instead of requiring real KOReader in unit tests.
- When changing a module with module-level state, clear its `package.loaded[...]` entry in specs before requiring it.
- For settings behavior, specs stub `datastorage` and `luasettings`; real settings are stored under KOReader's settings dir as `suwayomi_dl.lua`.
- Debug instrumentation is off unless KOReader settings contain `suwayomi_dl_debug.lua` with `enabled = true`; logs are redacted and use the `SuwayomiDL` prefix.

## Release/Runtime Packaging

- Release zips must include `_meta.lua`, `main.lua`, `README.md`, and the runtime `suwayomi/` directory. Specs, docs, CI files, and `AGENTS.md` are not runtime payload.
- For Android manual QA, push only runtime plugin files to `/sdcard/koreader/plugins/suwayomi_dl.koplugin/`; include `suwayomi/` and avoid pushing `.git`, `spec`, docs, or CI files.

## Product Constraints

- The supported practical flow currently targets Suwayomi Local Source; remote sources may browse but are not the main tested reading/download path.
- The top-level Downloads hub action is still a placeholder even though the local queue and chapter-level bulk actions exist.
- Known performance-sensitive paths are synchronous UI GraphQL calls, chapter menu filesystem/metadata checks, batch delete cleanup, and background read-sync worker polling; use `docs/android-performance-testing.md` for Android stall evidence collection.
