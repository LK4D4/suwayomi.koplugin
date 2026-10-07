# Release readiness review, 2026-10-07

**Verdict: ready for v1.4.0 preparation within the demonstrated scope; no confirmed product defect requires a fix first.** Preparation is separate from merge, tagging, and publication.

## Candidate and scope

- Published baseline: `v1.3.0`, peeled commit `d63bcd80a1a24a14846b85a704c0f90d070d419a`.
- Reviewed runtime candidate: clean `master` and `origin/master` at `cdf586300350d209fb236741aa49ba1666a5b1e7`, after fetching origin and tags. Review covered the complete `v1.3.0...cdf5863` diff and intervening commits.
- Changes: compact Library status/help, checked sort controls, remembered sort, narrow-row date visibility, and saved-scanlator counts/discovery dates/order. The latest repair rejects malformed scoped chapter nodes without erasing confirmed scoped metadata.
- Issues #72–#74 are closed. [#75](https://github.com/LK4D4/suwayomi.koplugin/issues/75) remains open with its implementation and dated acceptance committed; its body and comments revealed no additional requested blocker. This task does not change ticket state.
- Editing and checks use the isolated `codex/release-prep-20261007` worktree from local master. Preparation updates version metadata/display text, gettext package/version labels and compiled catalogs, and matching release notes. No runtime behavior is changed by preparation.

## Independent correctness review

One fresh GPT-6.1 Sol/high reviewer examined the frozen diff against issues #72–#75, documented module boundaries, and ADR-0007. It found **no actionable correctness blocker** in scoped queries/parsing, worker batching, cache retention, filter/endpoint guards, nested actions, sort persistence, or row/title behavior. The malformed-node repair rejects the scoped batch and retains confirmed matching facts through the composed controller/cache path.

The reviewer ran 276 focused LuaJIT specs, lint on all ten changed runtime files, and `git diff --check`; all passed. It performed no server, desktop, or device acceptance. The main agent owns the execution evidence below.

## Fresh verification

| Check | Result |
| --- | --- |
| `busted --lua=luajit spec` | 1,926 successes; zero failures, errors, or pending on the reviewed runtime candidate |
| `luacheck --codes spec suwayomi main.lua _meta.lua` | Zero warnings/errors across 183 files |
| `bash scripts/check-l10n.sh` | Passed source extraction, catalog validation, and compilation; repeated after version preparation |
| `python3 -m unittest discover -s scripts -p test_sandbox_upgrade.py` | Seven tests passed |
| Canonical desktop payload | All 99 source/deployment hashes matched before and after acceptance |
| Exact-master GitHub Actions | [Test run 37626099188](https://github.com/LK4D4/suwayomi.koplugin/actions/runs/37626099188) passed on `cdf586300350d209fb236741aa49ba1666a5b1e7` |
| `git diff --check` | Passed on the reviewed candidate |

Local checks used WSL Ubuntu, explicit LuaJIT, and process-local distro LuaSec selection. The Windows sandbox process helper failed during initial read-only setup; direct command execution restored access before verification. No product check was counted as passed because of that failure.

Fresh desktop acceptance used KOReader **v2026.07.1**, Suwayomi **v2.3.2243**, Basic Auth, WSLg, and a new disposable synthetic profile/server. The application archives were verified against pinned digests. The candidate remained clean; inspector and labeled fault instrumentation stayed outside the canonical payload.

All eight required upgrade scenarios were **demonstrated** in one completed attempt: native Search entry/reader return, mixed archive authority, relocated pending unread, rejected/uncertain verification-save recovery, stale controls/fresh Off, publication stages, deleted category, and Browse layouts/pagination. Required assertions were unchanged. Native-return, list, and cover-with-text framebuffers were inspected. This run has no failed first attempt. It tests normal and injected-fault upgrade paths, not physical storage exhaustion or power loss.

## Dated feature/device evidence and limits

The [#72–#74 record](issues-72-74-library-2026-10-04.md) supplies ordinary Library help/sort/reopen/reader-return/offline controls, compact subtitle checks, and the subsequent narrow-row repair on desktop and Palma. The [#75 record](issue-75-library-scanlators-2026-10-05.md) supplies real saved-filter controls against independently queried matching chapter records: excluded/matching/already-read arrivals, filter removal, zero matches, pending reads, offline cold restart, and complete ordering. Both records document exact deployed payload hashes and restoration of all 1,224 original Palma profile files.

Those results retain their recorded candidate/date scope. Compared with #75's `f32812a` runtime, the current payload adds the scoped-response parser rejection. Its malformed-input/retained-cache behavior is established by fresh targeted/composed specs and the full suite; the earlier device controls do not establish that later repair. Today's desktop upgrade run does not repeat the full scanlator-specific fixture matrix, and no new Palma operation was performed.

Human e-ink readability/ghosting, physical page buttons, Wi-Fi transitions, sleep/wake, power loss, real storage exhaustion, other locales, and untested reader/server versions remain **unverified**. No confirmed defect emerged from the selected release controls.

## Preparation and retained resources

Prepared v1.4.0 notes cover saved-scanlator Library updates, compact help/status, checked remembered sorts, row fixes, and both App Store/manual ZIP update routes. Version/catalog changes require their own validation and exact prepared-candidate CI before separately authorized integration/publication; the reviewed-master run above does not verify future changes.

The owned desktop reader and server stopped successfully; deployment hashes still match. The private disposable sandbox, synthetic fixtures, raw reports, and inspected screenshots remain retained. No personal device/profile was modified. The preparation branch/worktree and candidate ZIP are retained for handoff. Credentials, raw settings/logs, private library data, and device identifiers are excluded from committed evidence.
