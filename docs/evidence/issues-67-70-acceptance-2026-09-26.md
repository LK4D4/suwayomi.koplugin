# Issues #67–#70 acceptance, 2026-09-26

## Candidate and prerequisites

Implementation branch: `codex/upgrade-workflows-67-70`. Common base: `99579f9fcaae97b377f21873d44bde6958f3832f`, verified against local and remote master before worker handoff. The #63–#66 owner confirmed completed integration and released exclusive sandbox/Palma ownership. Prerequisites were verified from implementation and [their acceptance evidence](issues-63-66-acceptance-2026-09-26.md), not issue closure alone:

- #63: `f9f6474`.
- #64: `68c8b3e` and acceptance repair `24092945f78e01f1c7a81b4a0a57be025c5966de`.
- #65: `7e85063` and `dc9957c`.
- #66: `813dfc0`; preserved as part of the common base.

Production/spec integration was complete at `1afaf4c1347256e36eb2309b1b44f2f1f09f6bfb`. Subsequent commits change acceptance tooling and documentation only. Final runtime acceptance used clean candidate `79d6545f01b441b87d3867b850f526345d22ee16`. This evidence is a later documentation-only addition.

All 98 canonical payload files matched source and deployment hashes. SHA-256 of the sorted, compact JSON path-to-hash manifest: `3661381b9c63f1f1936d5b5a03cedafa164066c98db172622108a8a2aca4113c`. The fault/observation patch lives only in disposable profiles, outside that payload.

## Issue outcomes

| Issue | Implementation and evidence |
| --- | --- |
| [#67](https://github.com/LK4D4/suwayomi.koplugin/issues/67) | Existing owners expose distinct positive decisions for current listing identity, applicable read choice, associated archive read state, and archive mutation. Local presence remains separate from validated Open. Callers retain unknown-versus-foreign behavior without inspecting lookup internals. No universal permission object, migration, or changed user flow. |
| [#68](https://github.com/LK4D4/suwayomi.koplugin/issues/68) | `prepareChapterMenuItems` owns reconciliation before the original save point; `buildChapterMenuItems` consumes prepared chapter/status observations and only formats/selects rows. Existing composed entry points preserve nil-versus-supplied working-ledger semantics, quick fallback, independent publication stages, and display-versus-preload behavior. Repeated construction is observational. |
| [#69](https://github.com/LK4D4/suwayomi.koplugin/issues/69) | Shared fixtures compose real classification, lookup, ledger, context, menu and commands. Critical collaborator identity guards fail explicitly. Scope/path/pending-unread and mixed-action cases assert rows, current context, command admission, durable state, and preservation together. Historical fault controls fail meaningfully. |
| [#70](https://github.com/LK4D4/suwayomi.koplugin/issues/70) | Opt-in `upgrade-acceptance` extends existing sandbox tools; [runbook](../upgrade-acceptance.md) defines release use and separate hardware evidence. Fixed required assertions reject empty/missing/swallowed checks; diagnostic selections and missing prerequisites cannot establish full acceptance. Each run retains failure evidence, candidate, dirty state, versions, instrumentation and payload hashes, and owned-service cleanup. Ordinary CI remains offline. |

## Automated checks and worker handoffs

The coordinator ran the full completed runtime suite once using system LuaJIT and verified Windows-worktree Git paths under WSL. Later changes affected tooling only; their checks were repeated.

| Check | Result |
| --- | --- |
| `busted --lua=luajit spec` | 1,789 successes; zero failures, errors, or pending cases. |
| Full runtime/spec luacheck | Zero warnings/errors across 179 files. |
| `./scripts/check-l10n.sh` | Passed; coverage inspected 80 tracked runtime Lua files. |
| Canonical release payload | Passed; 98 allowed files, matching deployed bytes. |
| Acceptance gate Python tests | Seven passed, covering missing/empty assertions, swallowed failures, retry retention, blocked outcomes, dirty/cleanup failure, and complete success. |
| Changed Python compilation and profile-patch/inspector Lua lint | Passed. |
| `git diff --check` | Passed. |

| Owner | Retained branch / worktree name | Worker commits | Integrated commits; focused checks |
| --- | --- | --- | --- |
| A, Astra/high, #67 | `codex/chapter-authority-67` / `chapter-authority-67` | `563b226` | `ab18b98`; 149 focused WSL specs, lint clean. |
| B, Astra/high, #68 | `codex/chapter-preparation-68` / `chapter-preparation-68` | `0cd9d9b` | `40f90c7`; 303 focused specs, lint clean. Sequenced after A for shared ownership. |
| C, Sol/high, #69 | `codex/upgrade-fixtures-69-migration` / `upgrade-fixtures-69` | `27ecbce`, `fa1962d`, `8ef7420` | `186834e`, `76ef826`, `c568f3b`; 62 focused specs, lint clean. |
| Coordinator, #70/integration | `codex/upgrade-workflows-67-70` / `upgrade-workflows-67-70` | Integration and tooling commits | Combined checks and all live resources. |

Native Windows bulk specs produced five failures also reproduced on the prerequisite baseline; the required LuaJIT checks passed under WSL. No production change was made to mask that environment difference.

One combined code-review pass covered standards and all four specifications. It found no production semantic defects. Runner findings concerned leaked server read preconditions, page-one-only Browse checks, insufficient independent stage/preload evidence, fresh Off without a true-policy precondition, and saved preference without observed mode. These were repaired. Targeted follow-ups verified the repairs, including actual safe-chapter download, native unassociated-reader close, populated Browse routing, durable download observation, and owned-window activation. No second full review pipeline was added.

## Runtime controls

Desktop: pinned KOReader `v2026.07.1`, Suwayomi `v2.3.2243`, WSLg, loopback. Palma: installed KOReader `v2026.03`, the same server release and runtime payload, physical device over USB ADB reverse/forward. One coordinator owned both isolated profiles and servers. Device transport normalized paths and copied observed files with hashes; production decisions were not stubbed.

| Scenario | Desktop | Physical Palma | Main independent evidence |
| --- | --- | --- | --- |
| Native entry/reader return | Demonstrated | Demonstrated | Real membership, exact three-page archive, page-two progress after return/reopen. |
| Mixed authority | Demonstrated | Demonstrated | Unknown-origin safe local controls; actual unrelated Chapter 002 download with matching bytes/scope; foreign Open/delete refusal and preservation. |
| Relocated pending unread | Demonstrated | Demonstrated | Server/cache Read, offline manual Unread, missing old archive/changed directory, Unread row/context and exact queued first unread. |
| Verification faults | Demonstrated | Demonstrated | Two rejected Open saves, released inspection, uncertain Verify fence, no duplicate worker, explicit recovery, preserved bytes/progress. |
| Stale controls | Demonstrated | Demonstrated | Background publication expires ordinary Off; feedback with unchanged policy/full ledger, then fresh Off removes policy/refill. Initial automatic downloads fully complete before the assertion. |
| Publication stages | Demonstrated | Demonstrated | Six separate stage faults; independent cache/membership/acknowledgment/preservation checks; empty/stale controls and real Open-next-unread preload. |
| Deleted category | Demonstrated | Demonstrated | Real category create/select/delete, ordinary Refresh restores All manga. |
| Browse layouts/pagination | Demonstrated | Demonstrated | Real Local-source Popular route, all three observed modes/preferences, preserved visible item and final fixture reached. |

Native Search > Suwayomi and shipped widgets drove entry and actions. Independent server API, saved settings, document identity/pages, archive/sidecar hashes, queue identity, and process evidence accompanied UI observations. Reader return retained page-two progress. Browse screenshots were inspected for layout and destination; asynchronous cover placeholders are allowed while thumbnails load.

Publication controls separately inject rename rejection and directory-sync uncertainty at cache save, initial merge, and visible reconciliation. A labeled three-to-two response subset distinguishes response membership from durable cache. Background read sync is held only in those cases to isolate acknowledgments. Disk contents after directory-sync uncertainty are recorded without claiming confirmed persistence. Empty/stale responses and cache/recorded-path removal for action preload are explicit injected preconditions. Actual archive bytes remain intact. Preload verifies exact opened archive/pages, cache/context, scoped choice, and zero display preparation inside the preload handler; a later verification refresh is separate.

## Negative controls and retained failures

- Offline #69: substituting the pre-#63 `local_downloads.lua` at `f9f6474^` made two of three selected current-pending-unread checks fail (missing recorded path and changed unassociated archive). The repaired implementation passed all three. The historical substitute was restored afterward.
- Runtime #70: exact historical `be01526725840d8c7d93e87576e6ee5fb4c21ef6` passed native download/Open/return, then failed the required `row_unread` assertion after server/cache Read and offline manual Unread with absent old bytes/changed destination. Report `upgrade-20260926-205231-e86246` remains failed; prerequisite flags are false, so it cannot pass the complete gate. Pre-stop diagnostics were captured.
- Earlier harness attempts remain in separate private report directories. Repairs addressed warm-versus-fresh WSLg input activation, ordinary widget discovery/timed feedback, durable download observation, preload incorrectly bypassed by recovered paths, and the native FileBrowser close appropriate to an unassociated read-only archive. No inspector mutation allowlist was expanded. A neutral pointer activation followed by native menu input passed on a completely fresh desktop root.
- Palma transport attempts retained normal inspector connection resets at reader exit (independent process checks proved termination), an expected missing-file probe mistakenly treated as an ADB failure, and a file-copy race while workers renamed scratch files. The transport now retries only changing filesystem snapshots with a bounded deadline; stable snapshots must match every hash.
- A later Palma attempt stopped before the stale assertion when a transient UI overlay changed the observed control route and the inspector returned HTTP 403. The private transport now requires a stable observed control before invocation; it does not retry rejected callbacks or broaden allowed methods. The original failure remains retained.
- A Palma stale-action attempt failed full-ledger equality while policy and expiration feedback passed. The enabled policy admitted ordinary remaining fixture downloads; saved completion records and production ownership supported concurrent refill as the cause, but that attempt did not capture both sides of the ledger delta. The corrected precondition waits for all three exact scoped associations, removed queue jobs and matching archive pages before opening the stale control. Full ledger equality remains required, and before/after snapshots are now retained. The earlier attempt remains failed, not retroactively passed.

Final clean reports: desktop `upgrade-20260926-211009-8e900b`; Palma `upgrade-20260926-211450-deea38`. An earlier complete desktop run, `upgrade-20260926-205927-43b31c` at `edd3da1`, also passed all eight scenarios; the final rerun includes the stronger refill precondition.

## Restoration, retained resources, and limits

The original 1,220-file Palma profile was preserved intact and independently verified against a host tar backup before takeover. After acceptance, the staged 98-file plugin still matched the frozen payload. The original profile/plugin/progress was restored and every original file hash matched again, including after package-state restoration. The reader is stopped, the original disabled-user state (`enabled=3`) is restored, and both ADB mapping lists are empty. All nine task sandbox roots report stopped readers/servers; both task-owned relays exited and their listener ports are clear. Synthetic device profiles/downloads and host backups remain private for recovery; no personal archive was opened.

Five task-owned managed worktrees remain: integration, A, B, C, and the historical control. Private roots retain raw reports, diagnostic screenshots/events/settings, synthetic archives, and failed attempts. Those artifacts, personal profile backups, credentials, device identifiers, and raw paths are not committed. Other worktrees and reading sessions were preserved.

USB acceptance does not establish Wi-Fi operation. Injected writes do not establish physical storage exhaustion, power-loss survival, sleep/wake reliability, or e-ink usability. These broader physical tests remain unverified. The earlier unrelated Palma stall has no newly established cause. None of these limits is hidden by the scenario pass labels.

The requested #67–#70 implementation and scoped automated, desktop, and physical Palma acceptance are complete and ready for separately authorized finalization. No push, merge, release publication, issue closure, or task-worktree removal was performed. GitHub Actions on the exact candidate and published master remain gates for a separately authorized finalization.
