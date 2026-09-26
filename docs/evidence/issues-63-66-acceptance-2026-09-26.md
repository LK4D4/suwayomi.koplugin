# Issues #63–#66 acceptance, 2026-09-26

The four fixes passed the automated checks and the desktop and physical Palma cases recorded below. They are ready for the separately authorized finalization workflow. This record does not establish readiness for unrelated release work or diagnose the historical Palma stall.

## Candidate and environment

- Common base: `be01526725840d8c7d93e87576e6ee5fb4c21ef6`, matching local and fetched remote `master` when work began.
- Final runtime candidate: `24092945f78e01f1c7a81b4a0a57be025c5966de`, branch `codex/fixes-63-66`. The freeze check found a clean worktree. This evidence document is a later documentation-only addition.
- Canonical payload: 98 files, staged with `.github/scripts/stage-release-payload.sh`. Every deployed file matched on desktop and Palma, and matched again after testing. The final source files also matched the frozen manifest.
- Manifest digest: `9810f4ac7e7a85bc7a40eac8f3f8a3f1782a9df4957101c23cea09d7b04f0245`, SHA-256 over sorted UTF-8 `relative_path<TAB>file_sha256<LF>` records.
- Desktop: real KOReader `v2026.07.1` under WSLg, disposable Suwayomi `v2.3.2243` server, Basic Auth, synthetic three-page chapters. Downloaded PNG bytes were compared with the source fixture.
- Physical device: Boox Palma, installed KOReader `v2026.03`, isolated profile and synthetic downloads. Server traffic used USB ADB reverse through owned loopback relays; the authenticated inspector used ADB forward.
- The coordinator exclusively operated live resources. Workers performed offline implementation and checks only. Both platforms used native **Search > Suwayomi** entry for entry/restart claims.

The initial runtime payload was `dc9957c`. A desktop uncertain-write case exposed an additional popup, so acceptance stopped. The repair became `24092945`; both readers were stopped, the payload was rebuilt and hashed, and normal and persistence-fault cases were repeated. All final acceptance rows below refer to `24092945`.

## Issue results

| Issue | Change | Automated evidence | Desktop and physical Palma evidence |
| --- | --- | --- | --- |
| [#63](https://github.com/LK4D4/suwayomi.koplugin/issues/63) | Scoped pending read choices follow endpoint/manga/chapter identity across missing or changed archive paths. Archive mutation authority remains stricter. | Composed lookup, ledger, context, menu and unread-admission tests; scoped/unscoped, foreign identity/path and mismatch controls. | Normal Mark read and Refresh established server/cache Read. Normal offline Mark unread persisted a scoped pending false choice. Restart with the archive intact, then restart with it preserved outside the download roots and the configured directory changed, kept the row and current context Unread while cache stayed Read. Normal Download first unread admitted Chapter 001, confirmed from persisted queue identity. Foreign-endpoint and unknown-origin pending entries did not override current cached Read. Their pending choices remained stored. |
| [#64](https://github.com/LK4D4/suwayomi.koplugin/issues/64) | A failed verification save produces bounded persistence feedback after confirmed worker exit, releases inspection ownership, and permits a fresh explicit attempt. Uncertain storage remains fenced. Consumers avoid write-capable refresh before showing this failure. | Rejected/uncertain save, worker exit, cancellation, stale/duplicate callback, recovery and consumer-ordering regressions. | Fresh download, exact three-page Open, native return and Verify passed. Two rejected Open attempts each showed useful feedback without opening a document or leaving Verifying stuck. Removing the fault allowed explicit Open. An uncertain Verify save showed recovery guidance; another attempt respected the fence without another save worker. After reconciliation, explicit Verify succeeded. A delayed real inspection was canceled by navigating away: cancellation and inspection release were recorded, with no late open. Archive and sidecar hashes were unchanged during fault/cancellation windows. |
| [#65](https://github.com/LK4D4/suwayomi.koplugin/issues/65) | Stale chapter controls explain rejection. Same-screen bulk controls reopen current actions without replaying the obsolete command; retired hosts remain silent. | Stale Off/read/bulk/confirmation, same-screen recovery, selection/queue preservation, and retired-menu/host guards. | With ordinary controls open, the owned server was briefly paused and resumed to publish a real background chapter response. Stale Off, Mark as read and Download next 5 each showed expiration feedback without applying the old action. Saved policy/read-ledger comparisons bracketed the action after legitimate background reconciliation. Fresh Off saved and removed refill requests. A genuine cold entry repeated stale Off and fresh recovery; subsequent offline restarts confirmed Off persisted. |
| [#66](https://github.com/LK4D4/suwayomi.koplugin/issues/66) | Localization coverage requires successful, nonempty, complete, readable runtime-file discovery. It handles Windows worktree Git paths used from WSL. | Eight focused cases; actual valid Windows-worktree/WSL and clean Linux-tree runs each inspected 80 tracked runtime Lua files. Broken Git directory, unavailable Git and empty index failed. A real injected unextractable runtime literal failed, then original bytes were restored. Controlled I/O cases cover incomplete discovery and unreadable files. | Tooling-only issue; no device scenario required. |

## Verification layers and limits

The normal flows above used actual KOReader widgets, server responses, saved settings and filesystem evidence. The missing archive, changed download directory and identity-negative cases used labeled, reversible preconditions while readers were stopped. They were not claimed as settings UI operations.

Persistence faults came from a private profile userpatch outside the runtime payload. Rejected completion temporarily failed the existing rename seam. Uncertain completion failed the existing directory-sync seam after replacement and held destination reads until the fault was cleared. Worker/save/poll events recorded stage, fence and exit/release observations. A separate five-second validation delay allowed ordinary navigation to cancel a real subprocess. These are controlled fault cases, not physical storage exhaustion, power-loss or Wi-Fi tests.

After fault and identity testing, the valid synthetic settings were restored and the fault/timing userpatch was removed. Both readers then passed another native-entry, ordinary Open, native-return and Verify sequence without fault instrumentation. The inspector remained only as the UI driver/observer. Representative unread and feedback screenshots were visually inspected. Palma's short expiration toast ellipsized its longer guidance; the expiration reason and reopened current controls were visible and usable.

No personal archive was opened. Progress preservation means byte-identical archive/sidecar files during the specified fault and cancellation windows; ordinary successful reading was allowed to update normal reading state. The tests do not establish multi-page reading progress, physical filesystem failure, power-loss survival, sleep/wake behavior or the cause of the older Palma stall.

## Automated checks and review

| Check on the completed runtime candidate | Result |
| --- | --- |
| `busted --lua=luajit spec` | 1,780 successes; zero failures, errors or pending cases. Localization coverage reported 80 runtime files. |
| `luacheck --codes spec suwayomi main.lua _meta.lua` | Zero warnings/errors across 179 files. |
| `./scripts/check-l10n.sh` | Passed source freshness, format/plural validation and catalog compilation after the environment retry below. |
| Canonical release payload | Passed allowlist validation; 98 files. |
| `git diff --check` | Passed using native Git with the checkout's line-ending configuration. |
| Combined code review | One Standards/Spec workflow against the combined candidate. No substantive findings; an obsolete callback argument/comment was removed. Targeted follow-up review of the live-found persistence repair had no findings and passed 73 affected specs. |

LuaJIT used the installed system LuaSec/LuaSocket paths. The default local LuaSec binary could not load its older OpenSSL dependency, so it was not counted as validation and no production dependency change was made. WSL Git checks used the verified worktree/Git directory; the Windows checkout's CRLF behavior was accounted for. The full suite was repeated only when failures or the subsequent runtime repair invalidated earlier evidence.

Worker handoffs, all retained:

| Owner | Branch | Worker commits | Integrated commits |
| --- | --- | --- | --- |
| A, Astra/high, #63 | `codex/pending-choice-63` | `ea8d436` | `f9f6474` |
| B, Astra/high, #64 | `codex/verification-64` | `81984c4`, `bf6a40e` | `68c8b3e`, `2409294` |
| C, Sol/medium, #65 | `codex/stale-actions-65` | `b0c1e52`, `37dfa1c` | `7e85063`, `dc9957c` |
| Coordinator, #66 and shared files | `codex/fixes-63-66` | `813dfc0`, `e136beb` | Same commits |

## First attempts and corrections

- The first combined suite exposed six old bulk-confirmation expectations for the former message. Their stale-feedback expectations were updated while preserving retired-menu and retired-host distinctions. The completed suite passed.
- On `dc9957c`, uncertain verification persistence showed the intended guidance, then a second raw `persistence_failed` popup. UI state, events and a screenshot were captured before restart. The callbacks refreshed chapters before handling persistence failure, triggering fenced read reconciliation. The focused repair moved failure handling before refresh; the final desktop and Palma fault runs had no second popup.
- The first revised freeze overlapped a full-suite temporary request file and correctly rejected the dirty state. A subsequent strict freeze found no changes. No temporary request file entered a commit or payload.
- One localization run failed when `msgattrib` could not write a catalog on the Windows-mounted filesystem. The same check passed on retry without a source change. A Linux diff invocation also treated the Windows CRLF checkout as changed; native Git confirmed a clean tree and passed whitespace validation. Neither failed command was counted as a pass.
- The restart helper initially tried to reselect an already-selected Search tab, producing no visible change. State was captured and entry continued from the observed next page. A Palma start command returned an Android activity error because the package was disabled again; read-only inspection confirmed no reader process and `enabled=3`. The helper was corrected to re-enable this authorized temporary test session and require a ready inspector. This was not diagnosed as a plugin stall.
- Additional harness assumptions were corrected from captured UI/state: the normal Auto-download completion-preference dialog needed **Keep disabled**; a stale-action baseline had been taken before legitimate background metadata updates; empty Lua maps decoded as arrays; queue identities are nested under manga/chapter; and graceful desktop shutdown is asynchronous. Tests continued from observed state or were repeated, without treating those harness failures as product passes. Inspector connection resets after Palma Quit were checked against the actual stopped process before proceeding.

## Restoration, retained evidence and finalization

The original Palma profile was backed up, hashed and renamed intact before testing. Its 1,220 files matched the backup while retained, matched after restoration to the original path, and matched again after restoring the package state. KOReader is stopped with its original disabled-user state (`enabled=3`). Original ADB mappings were empty; task-owned forward/reverse mappings were removed and the lists are empty again.

The test profile is retained separately as `/sdcard/koreader.fixes-63-66-test-20260926`. Synthetic download roots and the held fixture archive are retained under the task's `suwayomi-fixes-63-66-20260926` names. Host backup archives, manifests, screenshots, controlled-fault logs, helpers and first-attempt evidence remain private in the integration worktree's ignored `.worktrees/acceptance/` directory. Desktop fixtures/profile/evidence remain in `/tmp/suwayomi-fixes-63-66-20260926`. No credentials, raw settings/logs, manga archives, queue state or device screenshots are committed.

The owned desktop reader, server, WSL relay and Windows relay are stopped; their task listeners are absent. The held desktop archive still matches its recorded hash. The integration and three worker worktrees/branches remain available, with no unrelated resources changed or removed.

No push, merge, release publication, issue closure or worktree removal was performed. GitHub Actions on the exact integration candidate and published master remain gates for a later authorized finalization; local and runtime acceptance do not replace those gates.
