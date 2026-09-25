# Issue #56 chapter-lookup evidence — 2026-09-25

Runtime candidate: `de27becbf534ad6e1e1f161d98d0ab9104289356`, based on `12a2ac8cec7dcbc8a3baa9bbb8d7394ef708f54a`, with no dirty runtime changes. The change moves chapter record/read-authority decisions into `local_downloads.lua` while retaining menu reconciliation and persistence ownership. Library reconstruction and ADR-0007 are unchanged.

## Automated checks and review

Checks ran from the task worktree under WSL with LuaJIT. The full suite used process-local distro LuaSec paths for the installed OpenSSL-compatible module.

| Check | Result |
| --- | --- |
| Focused baseline: chapter actions, menu, and download service | 135 passed before changes. |
| New decision-interface tests | Each failed because its new method was absent, then passed after extraction. |
| Focused candidate: actions, menu, complete chapter loading, endpoint read scope, and service | 367 passed; one added test used a nonexistent store observation method. After correcting that fixture, its targeted rerun passed. |
| `busted --lua=luajit spec` | **1,657 passed**, zero failures/errors/pending. |
| Localization extraction follow-up | Full-suite Git discovery emitted a Windows worktree-path warning. The affected `suwayomi_l10n_extraction_spec.lua` passed again with explicit WSL `GIT_DIR` and `GIT_WORK_TREE`; independent enumeration confirmed 80 runtime Lua files. |
| `luacheck --codes --quiet spec suwayomi main.lua _meta.lua` | Zero warnings/errors in 173 files. |
| `./scripts/check-l10n.sh` | Passed with explicit WSL Git metadata; no tracked catalog changes. |
| `git diff --check` | Passed. |
| Standards review | Zero findings. |
| Spec review | Zero actionable findings. |

New checks exercise recorded-path authority versus guessed/pathless bytes, unknown versus foreign read-entry scope, mutable working-ledger decisions, caller-owned versus render-owned saves, and pending unread during quick recovered-row fallback. Existing composed coverage exercises recorded-path precedence, foreign identity/path collisions, explicit recovered selections, asynchronous verification revalidation, saved/confirmed rendering, and rejected/uncertain ledger saves. These are controlled specs, not physical-device observations. Review examined all changed hunks once against the issue's inspected baseline.

## Desktop runtime

The fresh disposable WSLg sandbox used KOReader v2026.07.1, Suwayomi v2.3.2243, and Basic Auth. All 98 deployed payload files matched both the deployment manifest and task-worktree source SHA-256 values, with matching file sets. The main agent independently repeated that comparison. The inspector patch remained outside the release payload.

Normal controls used the shipped sandbox helpers and actual widgets. No runtime fault patch was installed. The synthetic fixture had three chapters; one chapter was downloaded. Delete after mark-read was false and finished-while-reading retention was zero before read-state controls.

| Control | Observed outcome |
| --- | --- |
| Download, Open, and Go to Suwayomi | **Demonstrated.** Exactly one new CBZ; all three contained PNGs matched the synthetic source bytes. KOReader opened that three-page archive and returned through its ordinary action. Archive bytes remained unchanged. |
| Rendered fixture | **Demonstrated.** Main agent inspected the framebuffer capture: all three numbered fixture panels appeared in continuous view without an error overlay. |
| Mark as read | **Demonstrated.** Menu showed read and downloaded; independent server query and persisted ledger agreed on read=true. Pending sync cleared, and the archive remained. |
| Mark as unread | **Demonstrated.** Menu returned to downloaded without the read marker; independent server query and persisted ledger agreed on read=false. Pending sync cleared, and the archive remained. |
| Offline saved-list Open and return | **Demonstrated.** With the owned server stopped and KOReader still running, Home > Library > manga > Open chapters displayed the saved downloaded row. Its ordinary Open action opened the three-page archive; Go to Suwayomi returned to the chapter list. Archive count and hash remained unchanged, as did the confirmed unread ledger state. |

Commands used `sandbox.py setup`, `deploy`, `run server`, `run reader`, `smoke`, `ui home/tap/observe`, `stop`, and `status`, plus independent authenticated server reads and saved-ledger/archive inspection. The offline control stopped only the owned server; it was not a physical network transition or a reader restart. Private deployment manifests, fixture archives, captures, and the redacted acceptance summary remain in the disposable sandbox named `issue56-lookup-20260925`.

Acceptance and final independent status verification completed by 12:40:17 UTC. Both owned services were confirmed stopped. The sandbox is retained for inspection; no device profile or shared runtime was changed.

No physical-device run was performed. These desktop controls do not establish Android behavior, e-ink usability, sleep/wake, physical network changes, or storage-failure behavior. Scope/collision/failure cases retain controlled-spec evidence and were not all repeated in the desktop sandbox.
