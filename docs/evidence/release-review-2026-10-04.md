# Release readiness review, 2026-10-04

**Verdict: ready for release preparation within the demonstrated scope; no confirmed product defect requires a fix first.** Version metadata still declares the published `1.2.1`. A new release needs its own version, notes, and verification of the prepared commit.

## Candidate and scope

- Baseline: published `v1.2.1`, peeled commit `7e4b2f99acdf61d74e19e43350f1ceaa6241df2f`.
- Reviewed candidate: clean master `f126d7aa305fc091f5293a035d26a07eb5642207`. Remote master still matched at review time. Review used `git diff v1.2.1...f126d7a` and the complete intervening commit list.
- Changes: native finish-flow Next chapter ([#58](https://github.com/LK4D4/suwayomi.koplugin/issues/58)) and Library arrivals/count/status presentation ([#71](https://github.com/LK4D4/suwayomi.koplugin/issues/71)). Both issues are closed; #58's closure comment supersedes its earlier investigation-only wording. No open issues were returned by the tracker.
- Editing and verification used the isolated `codex/release-review-2026-10-04` task worktree, based on local master. This review changes evidence documentation only.

## Standards

**Zero actionable findings.** Independent review checked documented boundaries, governing persistence/offline-library ADRs, native lifecycle ownership, input normalization, scoped caches, and stale callback guards. Native adaptation remains reader-instance scoped and leaves completion/close to KOReader; Library changes remain projections behind existing owners. No material baseline smell warranted a release change. The reviewer performed source/spec inspection, not runtime checks.

## Spec

**Zero confirmed findings.** Independent review read current issue bodies and comments and checked accepted native popup/automatic Next behavior, immediate saved-successor selection, archive verification, optional-field fallback, session sorting, qualified server counts, pending-sync association, and retained/empty/unsaved states. No concrete crash, data-loss, navigation, or major usability defect emerged. The reviewer performed static inspection; current execution evidence follows below.

## Fresh verification

| Check | Result |
| --- | --- |
| `busted --lua=luajit spec` | 1,865 successes; zero failures, errors, or pending |
| `luacheck --codes spec suwayomi main.lua _meta.lua` | Zero warnings/errors across 182 files |
| `bash scripts/check-l10n.sh` | Passed extraction, catalog, and compilation checks |
| `python3 -m unittest discover -s scripts -p test_sandbox_upgrade.py` | Seven tests passed |
| Canonical release staging | 99 allowed files; independent source/staging/deployment hash comparison matched every file |
| Existing metadata contract | `check-release-version.lua _meta.lua v1.2.1` passed; this verifies the existing version only |
| Exact master GitHub Actions | [Test run 37194771958](https://github.com/LK4D4/suwayomi.koplugin/actions/runs/37194771958) passed on `f126d7aa305fc091f5293a035d26a07eb5642207` |
| `git diff --check` | Passed |

Local checks ran under WSL Ubuntu/LuaJIT with process-local distro LuaSec/OpenSSL module selection. The candidate stayed clean throughout runtime acceptance.

Real desktop acceptance used KOReader **v2026.07.1**, Suwayomi **v2.3.2243**, Basic Auth, WSLg, and isolated synthetic fixtures. Cached upstream application archives were checksum-verified against the pinned digests. Every deployed payload hash matched before and after testing; instrumentation stayed outside the payload.

All eight required upgrade scenarios were **demonstrated** in the completed run: native entry/reader return; mixed archive authority; relocated pending unread; rejected/uncertain verification-save recovery; stale controls/fresh Off; publication stages; deleted category; and Browse layouts/pagination. Required assertions were unchanged. Framebuffers for reader return and cover layout were inspected.

Additional normal-widget controls demonstrated:

- Library's qualified unread/date rows and both sort controls. A separate three-manga control produced distinct correct Latest arrivals and Title orders against loaded metadata.
- Native last-page forwarding displayed Next chapter. Activation verified and opened the exact second archive at its saved page two; the three archive PNGs matched the synthetic source fixture. Return used Go to Suwayomi.
- Explicit Library Refresh after stopping the owned server retained its checked cache and useful rows. Offline cold restart restored dates/counts; the second chapter reopened at page two with unchanged archive bytes.

## First attempts and disposition

Three earlier desktop attempts remain failed in their private reports. Two stopped because native Search stayed on page one after foreground keyboard paging; the third passed native return and the legacy-action assertion but could not dismiss an action dialog with foreground Escape. No failed product assertion was converted into a pass.

A focused control demonstrated that explicit key delivery to the exact owned KOReader window dismissed that same dialog. The completed run used that key route and screenshot-derived native Search footer paging, with unchanged candidate bytes and required assertions. Its private adapter SHA-256 is `4b01401cdcac2318d5e0fb29506dc36c03b54a1a21242bab554f73ad64358863`. An earlier setup helper had also used the wrong deploy signature; normal CLI deployment corrected it before acceptance.

## Dated device evidence and limits

The [2026-10-02 Library acceptance](issue-71-library-arrivals-2026-10-02.md) covers the frozen runtime candidate `7453a29`, both Suwayomi **v2.3.2243/v2.4.2366**, both desktop KOReader **v2026.03/v2026.07.1**, and focused Palma touch/layout, saved-position, and offline controls. There is **no tracked runtime-payload delta** from that candidate to reviewed `f126d7a`. Its 99-file device hash coverage and 1,224-file original-profile restoration remain separately dated evidence; this review did not repeat Palma operations.

The [native finish-flow record](issue-58-native-flow-acceptance-2026-09-27.md) supplies the broader two-version popup/automatic/sort/auto-mark matrix and focused Palma controls. The current combined desktop smoke above is fresh evidence for the representative changed flow. Current upstream stable release APIs still identify [KOReader v2026.07.1](https://github.com/koreader/koreader/releases/tag/v2026.07.1) and [Suwayomi v2.4.2366](https://github.com/Suwayomi/Suwayomi-Server/releases/tag/v2.4.2366).

Human e-ink scanning/refresh/ghosting, physical page buttons, Wi-Fi transitions, sleep/wake, power loss, and storage exhaustion remain **unverified**. Private KOReader status/dialog seams remain version-sensitive; other versions and third-party wrappers are unverified. The earlier #71 rapid-reopen anomaly still has no established cause; successful current normal reopen controls do not prove its cause or a repair.

## Preparation and retained resources

Choose the next version, update metadata/displayed version/catalogs, and add matching release notes covering these two features and both App Store/manual update routes. Then run required checks and exact prepared-candidate CI before separately authorized integration/tag/publication. Today's CI does not verify those future changes.

All four task-owned sandbox roots have stopped readers/servers and intact verified payloads. Private reports, failed-attempt diagnostics, synthetic profiles/archives, and the input adapter are retained. No device profile was modified by this review. The local review branch/worktree is retained; no release, issue, remote branch, or master mutation is part of this review. Raw credentials, settings, logs, device identifiers, paths, and screenshots are excluded from committed evidence.
