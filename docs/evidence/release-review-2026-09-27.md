# Release review, 2026-09-27

## Recommendation

Release the current fixes after normal version, release-note, packaging, and CI preparation. This round found no confirmed product defect requiring another fix first. Do not delay these repairs for the separate, unmerged Next chapter investigation in [#58](https://github.com/LK4D4/suwayomi.koplugin/issues/58).

The reviewed code repairs legacy chapter controls and reader return, pending unread precedence after path changes, verification-save failure recovery, deleted categories, and stale controls. Remaining verification limits below are explicit; this is not a claim that every device or physical failure mode has been tested.

No GitHub issue was created: neither review axis nor runtime verification established a new actionable product defect. The requested `to-tickets` workflow and repository tracker/triage guidance were read; there was no confirmed defect to turn into an implementation ticket.

## Frozen candidate and review

- Candidate: `6fc5f70192b6aa1e6bd123cfbb5a17ea1633b505`, matching local and remote `master` when pinned.
- Baseline: latest published release, `v1.2.0` (`e7d4d193c82636a81ea1638eb18e8669ed018cbd`). Reviewed `git diff v1.2.0...6fc5f70` and its full commit list.
- The independent Standards and Spec reviewers inspected the changed runtime boundaries and surrounding callers. Specifications included the full current bodies/comments for #55, #56, #59–#70, the Browse PR #57, relevant architecture, and accepted ADRs.
- **Standards: zero actionable findings. Spec: zero actionable findings.** No cosmetic or speculative refactor tickets were added.
- Exact candidate GitHub Actions [Test run 36267452708](https://github.com/LK4D4/suwayomi.koplugin/actions/runs/36267452708) passed. The release itself was not prepared, tagged, pushed, or published by this task.

## Automated evidence

Checks ran from the isolated review worktree against the frozen candidate, before this documentation addition.

| Check | Result |
| --- | --- |
| `busted --lua=luajit spec` under WSL | 1,789 successes; zero failures, errors, or pending cases. |
| `luacheck --codes spec suwayomi main.lua _meta.lua` | Zero warnings/errors across 179 files. |
| `./scripts/check-l10n.sh` | Passed; regression-suite discovery inspected 80 tracked runtime Lua files. |
| Canonical release staging/allowlist | Passed; 98 payload files. |
| `python3 -m unittest discover -s scripts -p test_sandbox_upgrade.py -v` | Seven tests passed. |
| Native Git whitespace/cleanliness checks | Passed; runtime candidate clean. |

WSL used system LuaJIT and Lua native libraries with verified worktree Git paths. Native Git and the acceptance runner confirmed a clean candidate. A preliminary WSL status invocation transiently listed two CRLF files; native Git found no source changes, and the actual acceptance metadata recorded no dirty files. Generated packaging output was moved into private task evidence before the acceptance run.

## Fresh desktop acceptance

Environment: KOReader `v2026.07.1`, Suwayomi `v2.3.2243`, WSLg, Basic Auth, disposable loopback server/profile. The opt-in `upgrade-acceptance` command ran its complete fixed assertion set, using normal widgets and labeled synthetic preconditions/faults.

| Required scenario | Result |
| --- | --- |
| Native Search entry, download, Open, reader return, page-two resume | Demonstrated |
| Mixed unknown/current/foreign archive authority | Demonstrated |
| Pending unread with absent old archive and changed destination | Demonstrated |
| Rejected/uncertain verification saves, fencing, explicit recovery | Demonstrated |
| Stale controls and fresh Auto-download Off | Demonstrated |
| Publication-stage failures, empty/stale responses, real action preload | Demonstrated |
| Deleted selected category followed by Refresh | Demonstrated |
| Browse layouts, item preservation, pagination to final fixture | Demonstrated |

All eight scenarios passed on the first desktop attempt, `upgrade-20260927-084443-d1e2d5`. Its report recorded a clean candidate, matching deployed hashes before/after, and graceful reader/server cleanup. Native-return and Browse screenshots were visually inspected.

All 98 source/deployed payload files matched. SHA-256 of the sorted compact JSON path-to-hash manifest: `dbd70d7288c376a1058294fdac88605136fc60db5ef88fcb760812a6a4f282b2`.

## Fresh Palma evidence

Environment: physical Palma, installed KOReader `v2026.03`, the same disposable Suwayomi server and 98-file payload, Windows ADB USB reverse/forward through task-owned relays. One coordinator owned the device, server, and isolated synthetic profile. Every deployed payload hash matched before and after the device checks.

The following checks were demonstrated through the normal UI, with independent archive, saved-state, event, and process observations:

- Native Search > Suwayomi reached Library; a real Chapter 001 download contained the exact three fixture pages.
- Open reached the exact archive; native return and reopen preserved page two.
- Two injected rejected verification saves each showed useful feedback, opened no document, released inspection, and preserved archive/sidecar hashes.
- An injected uncertain save reported the fence. Repeated Verify created no extra save worker; clearing the fault and explicitly retrying recovered without changing archive/progress bytes.
- After ordinary automatic downloads settled, a real background response invalidated the open Auto-download control. Stale Off explained expiration without changing the policy or full ledger. Fresh Off cleared the saved policy and refill request.

Feedback and reader-return screenshots were inspected. These checks are fresh device evidence for the listed routes; this run did not repeat the entire eight-scenario Palma matrix.

The [2026-09-26 full Palma matrix](issues-67-70-acceptance-2026-09-26.md) remains separately dated evidence. There are no tracked runtime-payload changes between its accepted runtime candidate and this candidate. Comparing retained deployment manifests found 96/98 files byte-identical; the other two differed only in LF/CRLF line endings, verified by byte comparison after newline normalization. Today's complete desktop run and focused Palma checks used today's exact manifest, without presenting the earlier matrix as a new run.

## Preserved failures and restoration

The fresh desktop acceptance had no failed attempt. Palma checks completed through recorded continuations after local setup/adapter failures:

- Streaming synthetic staging through the host ADB adapter produced an incomplete payload; hash validation rejected it before original-profile takeover. Native ADB push then staged all files correctly.
- The initial synthetic profile retained a desktop color setting. KOReader displayed its grayscale-device warning before normal startup; the warning was captured and the test setting disabled. The profile's external plugin path and inspector restart preference were then made explicit.
- An early inspector request was not retried with the correct connection-error type. After listener readiness was independently observed, the adapter was corrected.
- The first event-log read assumed a file existed before any chapter event. The adapter now treats that initial absence as an empty log, as the desktop driver does.
- A host-side Windows-to-WSL argument-quoting error interrupted the stale-control check after the native-reader and verification-fault checks had passed. Direct WSL execution corrected the transport, and the stale-control assertions subsequently passed unchanged.

Earlier attempt files and startup screenshots remain private. These were setup/adapter failures, not demonstrated product failures or silently reclassified passes. No runtime source was changed to obtain a pass.

The automatic approval review rejected copying the complete personal profile to the PC. The safer completed procedure kept all original profile contents on Palma: record every file hash, rename the intact original profile into a device-local backup, activate a separate synthetic profile, and restore the original afterward. All **1,220 original file hashes matched**, including after restoring the original disabled-user package state (`enabled=3`). The reader is stopped and both original empty ADB mapping lists are restored. No personal archive was opened or copied to the host.

The disposable desktop reader/server and both task-owned relays are stopped; their listener ports are clear. The review worktree/branch and private synthetic evidence remain available. Retained resources include the desktop sandbox, synthetic Palma profile/downloads, redacted-report source, private screenshots, and failed-attempt diagnostics. No raw settings, credentials, device identifiers, logs, manga, CBZs, or personal profile files are committed.

USB checks do not establish Wi-Fi behavior. Physical sleep/wake, power loss, storage exhaustion, and human e-ink usability were not tested. The historical unrelated Palma stall has no newly established root cause.
