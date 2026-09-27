# Issue #58 native finish-flow acceptance, 2026-09-27

## Candidate and scope

Runtime candidate: `93f5be7059bfccc69c026cecb4f1176aabfcd265`, on `codex/next-chapter-58`. It incorporates local master `7e4b2f99acdf61d74e19e43350f1ceaa6241df2f` into the earlier `5d5b279` implementation, preserving the later persistence, archive-authority, and legacy-document fixes. This evidence addition changes no runtime files. Nothing was pushed, published, or merged into master; the task worktree remains for review.

The separate reader-menu Next action is removed. Native last-page forwarding offers **Next chapter** in the finish popup, or follows the configured automatic next-file action, including access/date sorting. **Go to Suwayomi** remains. Selection and verification retain the immediate-successor contract; KOReader owns completion, saved position, and close.

One independent correctness review found that sibling-context inference could intercept an unrecorded document. Native finish recognition now requires an exact recorded path; legacy inference remains available to ordinary reader return. Targeted review accepted that repair and the focus-layout repair below. No second full review was run.

## Automated checks

Checks ran from the task worktree under WSL Ubuntu with LuaJIT, against the runtime bytes committed above.

| Check | Result |
| --- | --- |
| `busted --lua=luajit spec` | **1,841 successes**, zero failures/errors/pending |
| `luacheck --codes spec suwayomi main.lua _meta.lua` | Zero warnings/errors, 181 files |
| `./scripts/check-l10n.sh` | Passed, including runtime message discovery |
| Release allowlist and deployed payload hashes | 99 files; zero mismatches on desktop and Palma |
| Focused repair verification | 94 lifecycle/return/finish specs passed; reviewer separately ran 64 relevant specs |

The finish-adapter specs exercise popup and automatic dispatch, all three sort modes, auto-mark on/off, previous/unrelated delegation, blocked recognition, repeated events, pending requests, stale/replaced readers, wrapper restoration, translated dialog recognition, unexpected layouts, and covered/suppressed sort notices. Existing selection/action specs cover endpoint, selection, archive identity, persistence, and stale asynchronous callbacks. These are automated boundaries, not device evidence.

## Real desktop acceptance

Environment: real KOReader **v2026.03 and v2026.07.1**, WSLg, disposable Suwayomi **v2.3.2243**, Basic Auth, generated three-page CBZ fixtures. The canonical runtime payload was deployed into the disposable profile; all 99 files matched the candidate. No upstream KOReader source was edited.

Entry used native **Search > Suwayomi**, followed by normal Library/chapter/download/Open controls. End-of-document actions used native page-forward key input. Popup cases activated the rebuilt native widget. Other preference and locale controls also used native command-line document opening. Saved page two was established with KOReader's Go to page and normal close, not by writing a completion flag.

| Requirement / control | Demonstrated outcome |
| --- | --- |
| Two versions × popup/automatic × ordinary/access/date sort × auto-mark off/on | All **24 cases** opened the immediate successor at saved page two; exact archive path and fixture page bytes matched. Native current-book summary remained reading with auto-mark off and complete with it on. |
| Offline, server stopped after complete-list caching | Automatic date-sort transition still opened the successor at page two. |
| Immediate successor absent, later archive present | Stayed in the current reader with explanation; did not skip ahead. The moved synthetic archive was restored. |
| Completed successor / rereading | Native Mark as finished followed by native Go to page and close established a completed successor at page two. Navigation opened it without skipping or resetting position. |
| Repeated page-forward while verification pending | One archive verification and one native document switch. |
| Close/reopen while verification pending | Late callback delivered after reopening; zero switches, current document retained. |
| Native completion, sync, refill, retention | Both native popup Mark as finished plus Go to Suwayomi close and automatic Next with native auto-mark synced chapters 1 and 2 to the server, refilled chapter 6 under First 5 unread, and removed chapter 1 while retaining chapter 2 under Keep 1. Each route started with fresh normal downloads and the same policies. |
| Unrelated book | Original Open next file popup and ordinary sibling-file navigation retained. |
| Other finish preferences | Go to beginning, Mark as finished, Book status, File browser, and Do nothing preserved their native outcomes on a linked book. |
| German and Arabic RTL finish dialogs | Translated native labels recognized; usable rebuilt 3×2 layout and actual Next activation reached saved page two. Arabic used native leftward page-forward. Next chapter used its untranslated English fallback. Screenshots were inspected. |

The pending/race controls used a **disposable-profile-only observer** that delayed the real archive-verification callback by three seconds and counted requests/switches. It did not fabricate verification results or alter runtime payload files. Server unread resets, policy settings, missing-file setup, and saved-position baselines were controlled preconditions. Native completion was always exercised through KOReader; no completion flags were injected as a substitute.

## Palma acceptance and restoration

Environment: physical Palma running installed KOReader **v2026.03**, USB ADB routing to the disposable server, isolated synthetic KOReader profile and download directory. Tests used Android-injected native touch input for last-page forwarding, actual native popup controls, and normal menu controls. This establishes device execution under those inputs, not human physical-button or e-ink judgment.

- Search > Suwayomi, normal downloads, native popup Next, exact successor path, rendered fixture content, and saved page-two resume passed.
- Automatic next-file under ordinary, access, and date sorting passed.
- Repeated native touch input during delayed real verification produced one request and one switch, resuming page two.
- All three downloaded CBZs contained the exact generated source pages. All 99 payload files matched before and after the device checks.
- The original profile remained on-device during isolation and was restored afterward. **1,220 original file hashes matched**; independently rechecked with zero mismatches. The package returned to its original stopped/disabled state; task-owned ADB mappings and relay were removed/stopped.

## Failed attempts and repairs

- An initial desktop deployment accidentally selected the primary checkout (98 files). Hash/payload inspection exposed it; those observations were excluded. Acceptance used the corrected explicit task path and 99-file manifest.
- The first candidate popup displayed Next chapter but retained freed controls in its focus layout after `reinit`. Clearing `dialog.layout` before rebuilding fixed actual widget activation; focused specs, review, both-version matrices, and Palma then passed.
- The first full spec attempt loaded a stale local LuaSec library requiring unavailable OpenSSL 1.1. The successful full run explicitly selected the installed system Lua 5.1 modules/native libraries.
- Harness continuations corrected grouped key arguments, Arabic forward direction, inactive file-manager controls, inspector startup timing, and Search-menu pagination. A synthetic Palma inspector token needed LF rather than Windows CRLF. These changes did not alter candidate code.
- Initial retention comparisons used the wrong policy value (Keep none), then copied archives whose saved identity no longer matched. Cleanup correctly refused uncertain generations. Fresh normal downloads and Keep 1 replaced those invalid preconditions. Restarting after downloads reloaded native history entries that had been marked missing during fixture replacement. Both final comparison routes passed.
- The unrelated-book control passed, but the sandbox's usual shutdown helper expected Go to Suwayomi on an unrelated book. Cleanup continued through native File browser and normal quit.

Failed-attempt diagnostics remain private. They are not presented as successful candidate acceptance.

## Limits and retained evidence

The adapter depends on private KOReader status methods, dialog structure, and UI-stack identity. Both named versions passed; other versions and third-party status/dialog wrappers remain unverified. Unexpected dialog output is deliberately left untouched rather than guessed at. No global preferences or global dialog hooks are changed.

Human physical page-button use, subjective e-ink refresh/ghosting, Wi-Fi transitions, sleep/wake, power loss, and exhausted storage were **not verified**. Static device screenshots do not establish temporal e-ink usability. Previous-file behavior is covered by adapter specs/source delegation; it was not separately exercised on hardware.

The disposable desktop reader and server are stopped. Private retained evidence includes that sandbox, per-version matrix records, extended/race records, fresh completion comparison, translated screenshots, synthetic Palma profile/downloads, and failed-attempt diagnostics. Raw logs, credentials, settings, CBZs, identifying device details, and private paths are excluded from this commit. The clean task branch/worktree is retained; GitHub CI was not run because pushing was prohibited.
