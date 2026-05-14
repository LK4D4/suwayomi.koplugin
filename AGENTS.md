# AGENTS.md

## Commands

- CI installs LuaJIT with `leafo/gh-actions-lua@v13` and LuaRocks with `leafo/gh-actions-luarocks@v6`; local development should use LuaJIT too.
- On fresh Ubuntu/dev containers, install local tools with `sudo apt-get install -y luajit luarocks`.
- Verify LuaRocks is using LuaJIT before installing deps: `luarocks config lua_interpreter` should print a LuaJIT executable.
- Install local test/lint deps with user-local LuaRocks packages: `luarocks install --local busted`, `luarocks install --local dkjson`, `luarocks install --local luasocket`, `luarocks install --local luasec`, and `luarocks install --local luacheck`.
- `luarocks --local` puts executables in `$HOME/.luarocks/bin`; use `PATH="$HOME/.luarocks/bin:$PATH" ...` unless that path is already exported.
- On Windows, do not use the Linux `$HOME/.luarocks/bin` PATH prefix. LuaRocks user-local executables normally live in `%APPDATA%\luarocks\bin`; in PowerShell run `$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"` before invoking `luacheck` or `busted`. If a Windows LuaRocks install differs, run `luarocks path --bin` and use the printed LuaRocks `bin` directory for the current shell.
- Windows PowerShell examples from the repo root: `$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; luacheck --codes spec suwayomi main.lua _meta.lua` and `$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; busted spec`.
- Run the full lint suite from the repo root: `PATH="$HOME/.luarocks/bin:$PATH" luacheck --codes spec suwayomi main.lua _meta.lua`.
- Run the full test suite from the repo root: `PATH="$HOME/.luarocks/bin:$PATH" busted spec`.
- Run one spec file from the repo root: `PATH="$HOME/.luarocks/bin:$PATH" busted spec/suwayomi_api_spec.lua`.
- `luacheck --codes spec suwayomi main.lua _meta.lua` provides project Lua parsing/linting while avoiding generated dependency directories such as `.lua` and `.luarocks`; do not add a separate `luac` syntax pass.
- Specs set `package.path = "?.lua;" .. package.path`; run `busted` from the plugin root or local module requires will not resolve.

## GitHub Actions Verification

- Before merging work to `master` or pushing `master`, first push the work
  branch and run the GitHub Actions `Test` workflow against that branch. GitHub
  Actions can only run commits available on GitHub, so local-only commits must
  be pushed to a branch before this check is meaningful.
- Use `gh workflow run test.yml --ref <branch>` for an explicit pre-merge run,
  then watch or inspect the run with `gh run watch` / `gh run view --log-failed`.
  Do not merge or push `master` until the branch workflow run passes.
- If GitHub Actions cannot be run because of authentication, network, or GitHub
  availability, report that blocker explicitly instead of treating local
  lint/tests as a substitute for the required Actions check.

## AGENTS.md Maintenance

- Keep this file agent-focused and actionable: commands, verification expectations, code ownership boundaries, packaging rules, product constraints, and safety notes that help agents work correctly without rereading the whole repo.
- Prefer repo-specific instructions over generic coding advice. If a rule does not change what an agent should do in this repository, remove it.
- Update this file when build/test commands, LuaRocks setup, module ownership, packaging boundaries, product support, or workflow expectations change. Update `docs/ARCHITECTURE.md` instead when the detailed architecture changes materially, and keep only the short agent-facing summary here.
- Keep guidance concise enough to stay comfortably below Codex's default instruction-chain cap. If future subdirectories need different commands or ownership rules, add a nested `AGENTS.md` close to that subtree instead of overloading the root file; closer instruction files override broader ones in Codex.
- Do not add `AGENTS.override.md` files unless the intent is to deliberately replace same-directory `AGENTS.md` guidance for that scope. Prefer ordinary nested `AGENTS.md` files for durable project guidance.
- When investigating stale instructions, compare against current source, specs, README, `docs/ARCHITECTURE.md`, and recent commits before editing. Remove outdated constraints rather than softening them into ambiguous language.

## Commit Messages

- Keep commits small, reviewable, and about one logical change. If the subject needs "and", split the commit or make the body explain why the work cannot be separated.
- Prefer a Conventional Commit subject when the change has a clear type and the prefix helps scanning history: `docs: update agent commit guidance`, `fix: preserve chapter menu state`, `feat: add reader return path`, `refactor: share job helpers`, `test: cover queue recovery`, or `ci: update lint workflow`.
- Plain imperative subjects are still acceptable when they match nearby history and read better without a type prefix, for example `Stabilize chapter status refreshes`.
- Write the subject as an imperative command to the codebase, not a diary entry: `Fix queue recovery`, not `Fixed queue recovery` or `Fixes queue recovery`. Keep it concise, with a soft limit around 50 characters and no trailing period.
- Add a body when the change is not obvious from the subject and diff. Use the body to explain the motivation, user-visible behavior, important tradeoffs, test evidence, and known limitations; avoid merely listing files or restating the patch.
- Wrap body text at about 72 columns when practical, and keep the message self-contained enough to understand from `git log` without opening an issue tracker or PR page.
- Put structured metadata at the end as Git trailers after a blank line, one trailer per line, such as `Refs: #123`, `Fixes: #123`, `Signed-off-by: Name <email>`, or `Co-authored-by: Name <email>`.
- Do not add AI/tool `Co-authored-by` trailers unless the human explicitly requests them. Only use co-author trailers for real collaborators whose name and email are known.
- Avoid vague subjects such as `updates`, `fix stuff`, `wip`, `changes`, or generated summaries that describe the agent's actions instead of the repository behavior change.

## Project Shape

- This is a LuaJIT/Lua 5.1 KOReader plugin, not a standalone Lua app; KOReader modules such as `ui/uimanager`, `dispatcher`, `datastorage`, `ffi/util`, and `ffi/archiver` exist at runtime and are usually stubbed in specs.
- `docs/ARCHITECTURE.md` is the active architecture reference. Keep this file as concise agent guidance and update the architecture doc when module ownership, public facades, packaging boundaries, or test strategy change materially.
- KOReader requires `_meta.lua` and `main.lua` at the top of the `suwayomi_dl.koplugin/` directory. Keep `main.lua` as a thin lifecycle/composition shell: action registration, KOReader plugin callbacks, dependency construction, and controller method installation only. Do not add new feature logic to `main.lua` unless it is truly KOReader lifecycle glue.
- Put runtime modules under the plugin-local `suwayomi/` namespace directory instead of adding top-level `suwayomi_*.lua` files. Use slash-style Lua requires that work with KOReader's plugin loader package path, for example `require("suwayomi/api")` or `require("suwayomi/downloads/controller")`.
- Current preferred layout for new/extracted code:
  - `suwayomi/api.lua`: public API facade and API debug logging.
  - `suwayomi/api/queries.lua`, `suwayomi/api/parsers.lua`, `suwayomi/api/transport.lua`: GraphQL payload builders, defensive response parsing, and HTTP/auth/URL handling.
  - `suwayomi/client.lua`: public Library/Browse client facade and dependency container.
  - `suwayomi/client/runtime.lua`, `suwayomi/client/source_manga.lua`, `suwayomi/client/global_search.lua`, `suwayomi/client/library.lua`, `suwayomi/client/browse_chapter_counts.lua`, `suwayomi/client/util.lua`: client runtime lookups, source manga flow, global search flow, library flow, browse chapter-count enrichment, and tiny shared client helpers.
  - `suwayomi/ui.lua`: public KOReader UI facade.
  - `suwayomi/ui/browse.lua`, `suwayomi/ui/list_rows.lua`, `suwayomi/ui/list_menu.lua`, `suwayomi/ui/manga_menu.lua`, `suwayomi/ui/downloads.lua`, `suwayomi/ui/directory.lua`, `suwayomi/ui/menu_utils.lua`: Browse/Library manga and source menus, shared list-row formatting, KOReader thumbnail list rendering, the `manga_menu` list-menu alias, Downloads menus, directory picking, and shared menu plumbing.
  - `suwayomi/ui/thumbnail_cache.lua`, `suwayomi/ui/thumbnail_worker.lua`: private manga/source thumbnail cache paths and subprocess thumbnail fetches.
  - `suwayomi/settings.lua`, `suwayomi/paths.lua`, `suwayomi/debug.lua`: settings, source-scoped path layout, and debug logging.
  - `suwayomi/downloads/queue.lua`: public download queue facade, enqueue/retry/cancel/recovery/snapshot/status APIs.
  - `suwayomi/downloads/active_jobs.lua`: bounded active chapter jobs, subprocess launch, polling, watchdog handling, and replacement scheduling.
  - `suwayomi/downloads/directory.lua`: download-directory chooser, persistence callback flow, and default directory probing.
  - `suwayomi/downloads/job_store.lua`, `suwayomi/downloads/progress_file.lua`, `suwayomi/downloads/status_formatter.lua`: persisted queue schema, progress-file IO, and chapter download status text.
  - `suwayomi/downloads/downloader.lua`: one-chapter downloads, page validation, ordered CBZ writing, `.part` cleanup, and final rename.
  - `suwayomi/downloads/controller.lua`: top-level Downloads hub/menu orchestration, retry/clear/cancel actions, and downloaded-read reconciliation.
  - `suwayomi/browse/controller.lua`, `suwayomi/browse/source_catalog.lua`, `suwayomi/browse/extensions.lua`, `suwayomi/browse/source_fetch_worker.lua`, `suwayomi/browse/extension_worker.lua`, `suwayomi/browse/source_manga_worker.lua`, `suwayomi/browse/global_search_worker.lua`, and `suwayomi/browse/chapter_count_worker.lua`: Browse entry flow, source filtering/cache/rendering, source extension install/update/uninstall, and cancellable browse worker lifecycles.
  - `suwayomi/manga/controller.lua`: manga action menu orchestration, library membership, refresh, first-unread helpers, and manga-level download/read actions.
  - `suwayomi/chapters/context.lua`, `suwayomi/chapters/menu.lua`, `suwayomi/chapters/actions.lua`: chapter context, menu construction, and the public chapter action facade.
  - `suwayomi/chapters/local_downloads.lua`, `suwayomi/chapters/delete_actions.lua`, `suwayomi/chapters/read_actions.lua`: local archive state, device deletion flows, and read/unread action orchestration.
  - `suwayomi/readsync/ledger.lua`, `suwayomi/readsync/koreader_metadata.lua`, `suwayomi/readsync/worker.lua`, `suwayomi/readsync/controller.lua`: read ledger, KOReader sidecar/history handling, worker code, and read-sync orchestration.
  - `suwayomi/navigation.lua`, `suwayomi/reader_return.lua`, `suwayomi/plugin/home.lua`, `suwayomi/plugin/title_menu.lua`, `suwayomi/plugin/settings_controller.lua`: navigation stack, reader-return shortcut, Suwayomi hub, title-bar burger action menus, and grouped Settings controllers.
  - `suwayomi/subprocess/job.lua`: shared one-shot subprocess job helper for cancellable JSON-result workers.
- Keep new runtime code in slash-style modules under `suwayomi/`; do not introduce new top-level `suwayomi_*.lua` modules.
- Runtime Lua files should start with a short line-comment `-- Boundary:` header matching the current module convention. Use regular `--` comments for explanatory notes; avoid top-of-file `--[[ ... ]]` documentation blocks unless a future file has a specific reason to differ.
- When orienting in an existing runtime Lua module, read the first ten lines first and use the top-of-file `-- Boundary:` summary to understand the file's responsibility before making changes. If that summary is missing, misleading, or no longer matches the module after your edit, update it as part of the same change.
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

## Security And Data Handling

- Do not commit KOReader settings files, Suwayomi credentials or tokens, debug logs, downloaded manga archives, generated CBZ files, queue/progress state, or other user data.
- Treat Suwayomi server URLs, auth headers, source names tied to a user's library, filesystem paths, and manga/chapter titles from real libraries as user data when sharing logs or screenshots.
- Keep debug output redacted by default. New logging should go through `suwayomi/debug.lua` or existing redaction helpers instead of printing raw request headers, response bodies, or filesystem paths.
- Tests should use stubs, fixtures, and temporary directories for runtime data. Do not require a live Suwayomi server, KOReader install, or local manga library for unit tests unless a task explicitly asks for integration/manual QA.

## Release/Runtime Packaging

- Release zips must include `_meta.lua`, `main.lua`, `README.md`, and the runtime `suwayomi/` directory. Specs, docs, CI files, and `AGENTS.md` are not runtime payload.
- For Android manual QA, push only runtime plugin files to `/sdcard/koreader/plugins/suwayomi_dl.koplugin/`; include `suwayomi/` and avoid pushing `.git`, `spec`, docs, or CI files.

## Product Constraints

- The supported practical flow includes Suwayomi Local Source and remote sources. Remote source behavior can still vary by source/server, especially search timeouts and extension-specific browse/latest quirks.
- The top-level Downloads hub is implemented for KOReader-local active, queued, and failed jobs. Completed history and Suwayomi server download queue management are intentionally not implemented.
- Known performance-sensitive paths are synchronous UI GraphQL calls, chapter menu filesystem/metadata checks, batch delete cleanup, and background read-sync worker polling; use `docs/android-performance-testing.md` for Android stall evidence collection.
