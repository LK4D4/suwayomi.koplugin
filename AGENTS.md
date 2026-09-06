# AGENTS.md

## Project

- LuaJIT/Lua 5.1 KOReader plugin for Suwayomi. KOReader runtime modules are usually stubbed in specs.
- Runtime payload is `_meta.lua`, `main.lua`, `README.md`, `suwayomi/`, and compiled `l10n/*/suwayomi.mo` catalogs when present. Specs, docs, CI files, worktrees, source `.po` files, template `.pot` files, and `AGENTS.md` are development-only.
- `main.lua` is only lifecycle/composition glue. Put feature code in slash-style modules under `suwayomi/`, for example `require("suwayomi/api")`.
- Use `docs/ARCHITECTURE.md` for the detailed module map. Update it when module ownership, facades, packaging boundaries, or test strategy change.

## Commands

- Run commands from the plugin root so `package.path = "?.lua;" .. package.path` works.
- Use LuaJIT locally. On fresh Ubuntu/dev containers: `sudo apt-get install -y luajit luarocks`.
- Install local deps with user-local LuaRocks packages: `busted`, `dkjson`, `luasocket`, `luasec`, and `luacheck`.
- POSIX lint: `luacheck --codes spec suwayomi main.lua _meta.lua`
- POSIX tests: `busted spec`
- POSIX l10n check: `./scripts/check-l10n.sh`
- Windows PowerShell lint: `luacheck --codes spec suwayomi main.lua _meta.lua`
- Windows PowerShell tests: `busted spec`
- Run one spec file with `busted spec/<file>`. Do not add a separate `luac` syntax pass; Luacheck already parses the project paths.

## Verification

- Before merging or pushing `master`, push the work branch and run GitHub Actions `Test` against that branch: `gh workflow run test.yml --ref <branch>`, then `gh run watch` or `gh run view --log-failed`.
- If GitHub Actions cannot run because of auth, network, or GitHub availability, report that blocker. Do not treat local lint/tests as a substitute for required pre-merge Actions.
- For docs-only changes, review the diff at minimum. Run Lua lint/tests only when docs affect commands, runtime layout, or agent/code behavior.

## Code Rules

- Runtime Lua files should start with a short `-- Boundary:` line. Read that header before editing a runtime module, and update it if your change makes it stale.
- Keep new runtime modules under `suwayomi/`; do not add top-level `suwayomi_*.lua` files.
- Keep lint policy in `.luacheckrc`; avoid inline `-- luacheck:` directives for repo-wide conventions.
- Path layout is source-scoped: `<download_directory>/<source_label>/<manga_title>/<chapter_name>.cbz`.
- Downloads are KOReader-device-local CBZ downloads. Do not use Suwayomi server download mutations as a hidden side effect.
- Add short comments only for non-obvious behavior or constraints.

## Tests

- Specs isolate KOReader/runtime dependencies with `package.preload` and clear `package.loaded`; follow that pattern.
- Clear module-level state in specs before requiring changed modules.
- Keep `spec/main_spec.lua` focused on KOReader lifecycle and shell composition.
- Settings specs stub `datastorage` and `luasettings`; real settings live under KOReader settings as `suwayomi.lua`.
- Tests must not require a live Suwayomi server, KOReader install, or local manga library unless the task explicitly asks for integration/manual QA.

## Data Safety

- Do not commit KOReader settings, Suwayomi credentials/tokens, debug logs, downloaded manga, generated CBZ files, queue/progress state, or other user data.
- Treat server URLs, auth headers, source names tied to a library, filesystem paths, manga titles, and chapter titles as user data in logs/screenshots.
- Keep debug output redacted through `suwayomi/debug.lua` or existing redaction helpers.

## Android Packaging

- Release zips and manual device pushes include only `_meta.lua`, `main.lua`, `README.md`, `suwayomi/`, and compiled `l10n/*/suwayomi.mo` catalogs when present.
- For Android QA, push the runtime payload to `/sdcard/koreader/plugins/suwayomi.koplugin/`; do not push `.git`, `spec`, docs, CI files, worktrees, `.po`, or `.pot` files.

## Maintenance

- Keep this file short, agent-focused, and repo-specific. Remove instructions that do not change agent behavior here.
- Put detailed architecture in `docs/ARCHITECTURE.md`; add nested `AGENTS.md` files only when a subtree needs different commands or rules.
- Before editing stale guidance, compare against current source, specs, README, `docs/ARCHITECTURE.md`, and recent commits.
- Commit messages should be small, imperative, and reviewable. Prefer Conventional Commit subjects when they add useful scan value.

## Agent skills

### Issue tracker

Use GitHub Issues. Before ticket operations, read `docs/agents/issue-tracker.md`.

### Triage labels

Use the five canonical triage labels. Before triage, read `docs/agents/triage-labels.md`.

### Domain docs

Use a single-context layout. Before codebase exploration, read `docs/agents/domain.md`.
