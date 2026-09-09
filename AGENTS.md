# AGENTS.md

## Project and reference routing

- LuaJIT/Lua 5.1 KOReader plugin for Suwayomi. `main.lua` owns lifecycle/composition; feature code belongs in slash-style modules under `suwayomi/`, such as `require("suwayomi/api")`.
- For module ownership and runtime invariants, read the relevant sections of [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Update them when ownership, facades, packaging boundaries, or test strategy change.
- For terminology, persistence, lifecycle, or architectural decisions, follow [docs/agents/domain.md](docs/agents/domain.md). Retained `docs/superpowers/` files are planning/history, not default execution instructions; check their amendments and linked issues before reuse.
- Before ticket operations, read [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md); before triage, read [docs/agents/triage-labels.md](docs/agents/triage-labels.md).
- For translation work, read [docs/TRANSLATING.md](docs/TRANSLATING.md).
- Before planning verification, running integration/UI/device checks, or handing off manual QA, read [docs/agents/testing.md](docs/agents/testing.md).

## Engineering defaults

These defaults do not weaken explicit requirements or accepted contracts.

- Make the smallest coherent change. Prefer existing modules and KOReader helpers; tolerate small duplication rather than add unused abstractions.
- Add recovery, concurrency coordination, compatibility, or migration machinery only for an explicit requirement or demonstrated problem. A clear error, manual retry, repeated transfer, or delayed cleanup may be sufficient; explain deliberate behavior changes.
- Validate external input at existing boundaries. Preserve uncertain files and report failed writes; simplicity never justifies destructive guesses.
- Resolve routine tradeoffs directly. If a requirement demands disproportionate complexity, propose a smaller contract before implementation.
- Routine fixes need focused evidence, not new specs, ADRs, ticket trees, or multi-agent workflows. Fix concrete defects; leave unrelated refactors and stylistic preferences alone.
- When independent review is requested, use one full pass and targeted verification of repairs. Further full passes need a concrete reason.

## Worktrees and ownership

- Every editing agent uses its own worktree and branch, including for docs. The primary checkout is for inspection and authorized integration.
- Before editing, run `git worktree list` and `git status --short --branch`. Reuse only a worktree assigned to this task with no concurrent editor; otherwise create `.worktrees/<task>/` with a unique branch. Use the assigned base or local `master`, and report it.
- Run edits and checks from the task worktree root. Preserve others' worktrees, branches, and uncommitted changes; never reset, stash, or clean a shared checkout to make room.
- Assign non-overlapping file ownership and agree on interfaces before concurrent edits. Name one integration owner; workers hand off branch, worktree, commits or uncommitted state, checks, and risks. The owner verifies the combined candidate.
- Keep worktrees until handoff is accepted. Remove only your own after integration or explicit discard; never force-remove a dirty worktree.

## Code and data safety

- Read each runtime module's `-- Boundary:` header before editing; update it when ownership changes. Keep comments short and limited to non-obvious constraints.
- Keep lint policy in `.luacheckrc`, not inline repo-wide directives.
- Downloads are device-local CBZ files, never hidden Suwayomi server download mutations. Use the source-scoped layout `<download_directory>/<source_label>/<manga_title>/<chapter_name>.cbz`.
- Preserve archives, saved reading state, and credentials. Never commit settings, tokens, debug logs, manga, generated CBZs, or queue/progress state.
- Treat server URLs, auth headers, library-linked source names, paths, manga titles, and chapter titles as private in logs/screenshots. Use `suwayomi/debug.lua` and its redaction helpers.

## Tests and commands

Run from the plugin root so `package.path = "?.lua;" .. package.path` works. Use LuaJIT locally. Fresh Ubuntu/dev containers need `luajit` and `luarocks`; install user-local LuaRocks packages `busted`, `dkjson`, `luasocket`, `luasec`, and `luacheck`. Gettext tooling supports l10n checks; native archive fixtures use libarchive on Linux/WSL. CI dependencies are listed in `.github/workflows/test.yml`.

- Lint (POSIX or PowerShell): `luacheck --codes spec suwayomi main.lua _meta.lua`
- Specs (POSIX or PowerShell): `busted spec`
- Focused spec: `busted spec/<file>`
- L10n (POSIX): `./scripts/check-l10n.sh`

Luacheck already parses project Lua; do not add a separate `luac` pass.

- Isolate KOReader dependencies with `package.preload`; clear `package.loaded` and module state before requiring modules under test. Reuse existing fixtures.
- Keep `spec/main_spec.lua` focused on lifecycle/composition. Settings specs stub `datastorage` and `luasettings`; actual settings are KOReader's `suwayomi.lua`.
- Test the reported bug, normal workflow, and relevant nearby failures. Tests need no live server, KOReader install, or local manga library unless explicitly requested.
- Run focused checks while editing; run full lint, specs, and l10n on completed runtime changes. Repeat checks invalidated by later edits or integration; report unavailable checks.
- For prose, review the diff, links, consistency, and scope. Run executable checks when changed examples, commands, or packaging warrant them. Distinguish automated evidence from device observations; unrun cases are not passes.

## Packaging

Release zips and manual pushes contain only `_meta.lua`, `main.lua`, `README.md`, `suwayomi/`, and compiled `l10n/*/suwayomi.mo` catalogs when present. Exclude development files, `scripts/`, sandbox profiles/data, and source `.po`/`.pot` catalogs. `.github/scripts/stage-release-payload.sh` stages and validates this allowlist. Android destination: `/sdcard/koreader/plugins/suwayomi.koplugin/`.

## Finalization and CI gate

An explicit request to **finalize** authorizes the full sequence below: commit, push, merge to `master`, and clean up the task branch/worktree. An implementation or documentation request alone does not authorize this sequence. Respect explicit limits such as “do not push”.

Before any merge or push to `master`, the exact candidate must pass GitHub Actions `Test` on its work branch, including docs-only changes. Local checks do not replace this gate. Auth, network, or GitHub failure is a blocker.

1. Review the task diff, run applicable checks, and commit only in-scope changes with a short imperative subject; prefer Conventional Commits where useful.
2. Coordinate exclusive integration access. Fetch `origin`; incorporate current local `master` and `origin/master` into the task branch. Resolve conflicts there and repeat invalidated checks.
3. Push the candidate. Run `gh workflow run test.yml --ref <branch>`, identify the run for that branch and exact commit, then require `gh run watch <run-id> --exit-status` to succeed. Inspect failures with `gh run view <run-id> --log-failed`. Revalidate every changed candidate.
4. Fast-forward the clean primary `master` to the tested commit and push without force. If either master advances or the push is rejected, incorporate the new base and repeat verification. Preserve unrelated local changes instead of stashing/resetting them.
5. Require the `Test` push run on the exact published `master` commit to succeed. On failure or blockage, report published state and retain the task branch/worktree for repair.
6. After success, remove the clean task worktree from outside it, then delete its merged local and task-owned remote branches. Preserve others' resources. Report final commit, CI results, and retained resources; partial integration is not finalized.

## Maintaining this guidance

Keep repo-specific rules here and architectural detail in `docs/ARCHITECTURE.md`. Add nested guidance only for genuinely different subtree rules. Before revising stale guidance, compare current source, specs, README, architecture, and recent commits; preserve safety and authorization requirements when shortening text.
