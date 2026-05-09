# AGENTS.md

## Commands

- On fresh Ubuntu runners/dev containers, install system tools first: `sudo apt-get install -y lua5.1 luarocks`.
- Install local test deps like CI: `luarocks install --local busted` and `luarocks install --local dkjson`.
- `luarocks --local` puts executables in `$HOME/.luarocks/bin`; use `PATH="$HOME/.luarocks/bin:$PATH" busted ...` unless that path is already exported.
- Run the full test suite from the repo root: `PATH="$HOME/.luarocks/bin:$PATH" busted spec`.
- Run one spec file from the repo root: `PATH="$HOME/.luarocks/bin:$PATH" busted spec/suwayomi_api_spec.lua`.
- Match CI syntax checking with a Lua 5.1-compatible compiler: `luac -p main.lua suwayomi_api.lua suwayomi_client.lua suwayomi_debug.lua suwayomi_download_queue.lua suwayomi_downloader.lua suwayomi_paths.lua suwayomi_read_sync_worker.lua suwayomi_settings.lua suwayomi_source_fetch_worker.lua suwayomi_ui.lua _meta.lua`.
- Specs set `package.path = "?.lua;" .. package.path`; run `busted` from the plugin root or local module requires will not resolve.

## Project Shape

- This is a Lua 5.1 KOReader plugin, not a standalone Lua app; KOReader modules such as `ui/uimanager`, `dispatcher`, `datastorage`, `ffi/util`, and `ffi/archiver` exist at runtime and are usually stubbed in specs.
- `main.lua` is the KOReader plugin lifecycle and top-level coordinator: action registration, hub/settings callbacks, chapter actions, queue/read-sync orchestration, and menu refresh behavior live there.
- Keep API query building, HTTP, and response parsing in `suwayomi_api.lua`; keep KOReader menu/dialog construction in `suwayomi_ui.lua`; keep client Library/Browse orchestration in `suwayomi_client.lua`.
- `suwayomi_download_queue.lua` owns persistent device-local queue state, subprocess launch, polling, recovery, and status text; `suwayomi_downloader.lua` owns one-chapter downloads, page validation, ordered CBZ writing, `.part` cleanup, and final rename.
- Path layout is source-scoped through `suwayomi_paths.lua`: `<download_directory>/<source_label>/<manga_title>/<chapter_name>.cbz`. Do not add old unscoped path detection unless explicitly requested.
- Downloads are KOReader-device-local CBZ downloads. Do not use Suwayomi server download mutations as a hidden side effect.

## Tests And Stubs

- Tests isolate KOReader/runtime dependencies with `package.preload` and clear `package.loaded`; follow that pattern instead of requiring real KOReader in unit tests.
- When changing a module with module-level state, clear its `package.loaded[...]` entry in specs before requiring it.
- For settings behavior, specs stub `datastorage` and `luasettings`; real settings are stored under KOReader's settings dir as `suwayomi_dl.lua`.
- Debug instrumentation is off unless KOReader settings contain `suwayomi_dl_debug.lua` with `enabled = true`; logs are redacted and use the `SuwayomiDL` prefix.

## Release/Runtime Packaging

- Release zips are built from `_meta.lua`, `main.lua`, `suwayomi_*.lua`, and `README.md` into a top-level `suwayomi_dl.koplugin/` directory; specs, docs, CI files, and `AGENTS.md` are not runtime payload.
- For Android manual QA, push only runtime plugin files to `/sdcard/koreader/plugins/suwayomi_dl.koplugin/`; avoid pushing `.git`, `spec`, docs, or CI files.

## Product Constraints

- The supported practical flow currently targets Suwayomi Local Source; remote sources may browse but are not the main tested reading/download path.
- The top-level Downloads hub action is still a placeholder even though the local queue and chapter-level bulk actions exist.
- Known performance-sensitive paths are synchronous UI GraphQL calls, chapter menu filesystem/metadata checks, batch delete cleanup, and background read-sync worker polling; use `docs/android-performance-testing.md` for Android stall evidence collection.
