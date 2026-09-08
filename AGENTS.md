# AGENTS.md

## Project

- LuaJIT/Lua 5.1 KOReader plugin for Suwayomi. KOReader runtime modules are usually stubbed in specs.
- `main.lua` is only lifecycle/composition glue. Put feature code in slash-style modules under `suwayomi/`, for example `require("suwayomi/api")`.
- Update `docs/ARCHITECTURE.md` when module ownership, facades, packaging boundaries, or test strategy change.

## Engineering defaults

These defaults govern unspecified choices. They do not weaken explicit task requirements or accepted feature contracts.

- This is a small KOReader plugin. Favor KISS, YAGNI, understandable code, and low maintenance cost.
- Solve the requested workflow with the smallest coherent change. Prefer existing modules and KOReader helpers. Add abstractions only when they simplify current code.
- Recoverable rough edges are acceptable. A clear error, manual retry, repeated transfer, or delayed cleanup can be preferable to complex recovery machinery. Describe deliberate behavior changes.
- Target normal supported use. Add crash recovery, concurrency coordination, compatibility layers, or migration machinery only for an explicit requirement or demonstrated problem.
- Small duplication is acceptable when extraction would add indirection. A possible future use is not enough reason to create a framework.
- Validate external input at existing boundaries. Unsupported input may produce a clear failure instead of a compatibility fallback.
- Preserve user archives, saved read state, and credentials. Keep uncertain files and report failed writes; simplicity does not justify destructive guesses.
- Make routine tradeoffs directly when requirements leave them open. If an explicit requirement demands disproportionate complexity, propose a smaller contract before building it.

## Proportionate workflow

- Routine fixes need a short explanation and focused tests, not a new spec, ADR, ticket tree, or multi-agent workflow.
- Test the reported bug, the normal workflow, and nearby failures relevant to the change. Reuse existing fixtures. Exhaustive edge-case matrices are not the default.
- Run focused checks while editing and required full checks on the completed candidate. Repeat checks when changes invalidate their evidence.
- When independent review is requested, use one full pass and targeted verification of repairs. Additional full passes need a concrete reason.
- Fix concrete defects and documented violations. Treat speculative refactors and stylistic code smells as advisory.
- Stop when the requested behavior works, relevant checks pass, and blocking findings are resolved. Leave unrelated improvements alone.

## Commands

- Run commands from the plugin root so `package.path = "?.lua;" .. package.path` works.
- Use LuaJIT locally. On fresh Ubuntu/dev containers: `sudo apt-get install -y luajit luarocks`.
- Install local deps with user-local LuaRocks packages: `busted`, `dkjson`, `luasocket`, `luasec`, and `luacheck`.
- POSIX and Windows PowerShell lint: `luacheck --codes spec suwayomi main.lua _meta.lua`
- POSIX and Windows PowerShell tests: `busted spec`
- POSIX l10n check: `./scripts/check-l10n.sh`
- Run one spec file with `busted spec/<file>`. Do not add a separate `luac` syntax pass; Luacheck already parses the project paths.

## Verification

- Before merging or pushing `master`, push the work branch and run GitHub Actions `Test` against that branch: `gh workflow run test.yml --ref <branch>`, then `gh run watch` or `gh run view --log-failed`.
- If GitHub Actions cannot run because of auth, network, or GitHub availability, report that blocker. Do not treat local lint/tests as a substitute for required pre-merge Actions.
- For prose and guidance changes, review the diff, links, consistency, and scope. Run relevant executable checks when documentation changes executable examples, commands, packaging, or other behavior those checks can validate.

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
- Exclude `.git`, `spec`, docs, CI files, worktrees, `AGENTS.md`, source `.po` files, and template `.pot` files from release zips and manual device pushes.
- For Android QA, push this runtime payload to `/sdcard/koreader/plugins/suwayomi.koplugin/`.

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

For changes involving domain terminology, ownership, persistence, lifecycle, or module boundaries, consult `docs/agents/domain.md` and the relevant sections of `docs/ARCHITECTURE.md`. Read relevant ADRs when their decisions govern the change. Small unrelated fixes do not require loading every domain document.
