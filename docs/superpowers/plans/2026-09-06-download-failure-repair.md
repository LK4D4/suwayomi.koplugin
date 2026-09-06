# Download failure repair implementation plan

> **For agentic workers:** Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement the tasks below.

**Goal:** Restore local page downloads after an unavailable archive export and expose complete stored download errors on demand.

**Architecture:** Keep HTTP fallback classification in the one-chapter downloader. Keep action routing in the downloads controller and the scrollable viewer in Downloads UI, exposed through the existing UI facade.

**Tech stack:** LuaJIT/Lua 5.1, Busted dependency stubs, KOReader TextViewer, gettext.

**Spec:** `docs/superpowers/audits/2026-09-06-download-failure-regression.md` and the requested two-repair scope.

## Constraints

- Reuse the existing `codex/downloads-failure-investigation` worktree at investigation commit `599edab`.
- Download pages and build CBZ files locally; never enqueue server downloads.
- Preserve HTTP 404 fallback, transient retries, authentication failures, and filesystem failures.
- Keep background failures quiet and raw external data out of debug logs.
- Use dependency stubs; no live server, KOReader installation, or manga library is required.
- Commit on this branch only. Do not merge, push, release, or deploy.

## Task 1: Archive fallback

- [x] Extend `spec/suwayomi_downloader_spec.lua` to cover HTTP 400, HTTP 404, and legacy not-found responses through both downloader entry points. Verify page contents, final CBZ rename, and terminal progress. Add authentication and filesystem failure cases.
- [x] Run the downloader spec before changing runtime code; only the two HTTP 400 cases must fail.
- [x] In `suwayomi/downloads/downloader.lua`, allow `status_code == 400` alongside the existing not-found fallback, after transient retries.
- [x] Run downloader, active-job, and transport specs together.

## Task 2: Complete error viewer

- [x] Add controller and public UI tests proving an explicit details action forwards a long stored error without truncation and uses TextViewer.
- [x] Observe failures before adding the action in `suwayomi/downloads/controller.lua`, viewer in `suwayomi/ui/downloads.lua`, and export in `suwayomi/ui.lua`.
- [x] Verify focused UI tests. Update README, architecture ownership, and gettext catalogs for the new action.

## Final verification

- [x] Run the full Busted suite and Luacheck from the worktree root: 895 successes; 0 warnings/errors in 140 files.
- [x] Run localization checks and review the complete diff: checks pass; independent review has no findings.
- [x] Commit the focused repair and report checks and remaining limitations.

## Verification evidence

- Before the archive fix: 48 downloader successes and two expected HTTP 400 failures, one for each entry point. After the fix: 99 downloader/active-job/transport successes.
- Before the viewer fix: four expected UI/controller failures. After the fix: 83 focused UI/controller/downloads successes.
- Full suite: 895 successes, zero failures/errors/pending. Luacheck: zero warnings/errors in 140 files.
- `bash -lc './scripts/check-l10n.sh'`: exit 0, including catalog compilation. `git diff --check`: clean.
- Independent final code review: no findings.
- The supplied sibling worktree path does not exist on this host. Git registers the requested branch and investigation commit under the repository's `.worktrees/downloads-failure-investigation`; that existing worktree was reused.
- No live server or device QA was performed. Scrolling uses KOReader's existing TextViewer. Errors omitted by transport or never stored cannot be recovered by the viewer.
