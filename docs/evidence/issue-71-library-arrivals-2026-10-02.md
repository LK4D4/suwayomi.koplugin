# Issue #71 Library arrivals acceptance, 2026-10-02

Implementation is committed. Automated, desktop, and focused physical Palma acceptance below is demonstrated. Palma used an isolated synthetic profile; its original profile and recorded package state were restored with all 1,224 file hashes matching. Human e-ink usability and unrelated hardware fault cases remain unverified.

## Candidate and controls

- Base: `ed7e817a4c5d83d0087bac7791dc693c9f00a1ad`.
- Frozen runtime candidate: `7453a291505694a30838147fe9210d81abb6ab99`, branch `codex/latest-arrivals-71`, clean before acceptance.
- Isolated synthetic Local-source manga and CBZs; no personal server/library data. One coordinator owned the desktop services and inspected device availability.
- Real Suwayomi `v2.3.2243` and `v2.4.2366`, Basic Auth, separate disposable roots/ports. The newer server archive matched its upstream release SHA-256 `7a469f8c820e65305f795d61f1776c783919884531497b587bdff898a7e0fa73`.
- Real KOReader Linux `v2026.07.1` and `v2026.03`, WSLg/X11, 600 × 800 window. The March runtime used the same isolated profile for focused compatibility checks.
- Canonical 99-file runtime payload: staging allowlist validated; every deployed file matched the frozen candidate. The inspector stayed authenticated and loopback-bound, outside the release payload.
- Raw observations, screenshots, fixture metadata, and first-attempt errors remain private. Repository sandbox/upgrade helpers were reused with disposable orchestration scripts; no production acceptance harness was added.

## Automated evidence

Final checks after the two review repairs:

- `luacheck --codes spec suwayomi main.lua _meta.lua`: zero warnings/errors, 182 files.
- `busted --lua=luajit spec`: **1,865 successes**, zero failures/errors.
- `./scripts/check-l10n.sh`: passed, including catalog compilation and current extraction.
- `.github/scripts/stage-release-payload.sh <disposable-target>`: passed.
- `git diff --check`: passed.

The WSL runs used distro LuaSec/OpenSSL with process-local `LUA_PATH`/`LUA_CPATH` and explicit task-worktree `GIT_DIR`/`GIT_WORK_TREE`. An earlier worker full run had one environment-only LuaSec failure; the corrected final run above supersedes it.

Coverage includes timestamp numeric strings/unknown/unrenderable values; optional-field-only fallback through actual transport sanitization for HTTP 200/400; unrelated/authentication failures; complete worker capability publication; deterministic ordering without cache-order mutation; session sort/category preservation; authoritative emptiness and unsaved live results; endpoint/ID collisions and relocated pending choices; zero versus unknown counts; localized Library rows and unchanged Browse formatting; stale nested-action metadata.

One code-review workflow ran its Standards and Spec axes independently. Standards found no actionable violation. Spec found two defects: malformed present unread counts became zero, and an older nested action could replace newer Library discovery metadata. Both received failing regressions, minimal repairs, and targeted independent verification. No findings remain from that review.

## Real-server and desktop evidence

| Control | Result and scope |
| --- | --- |
| Actual Library query on both Suwayomi versions | Demonstrated through the production API facade: complete four-manga responses, supported discovery capability, positive normalized timestamps, and server unread counts. No per-manga chapter fetching was used to construct Library. |
| Native entry | Demonstrated through real **Search > Suwayomi**, rather than the direct-entry helper. |
| Latest arrivals / Title | Demonstrated deterministic ordering against independently captured server metadata, normal title-menu switching, unchanged repeated refresh order, and preserved category/sort selection. |
| Categories and nested reading | Created a synthetic category on the server, refreshed through Library, selected it, and retained selection through another refresh. Manga tap opened the existing action dialog and chapter flow. |
| Rows and scope | Framebuffers inspected on both KOReader versions: source labels, long Unicode title, Found date, qualified unread count, compact layout, and the all-scanlator explanation. An old cache initially rendered unknown arrival dates and then acquired real dates from the supported live response. |
| Legitimate zero | A synthetic server-side read precondition produced a visible **Server unread: 0** and matching saved aggregate for the exact manga ID. The Local source rediscovery changed its display title; identity-based checks confirmed the same manga. |
| Native footer jump-search | Expanded synthetic Library to eight manga/two pages; used the visible native footer input and Search to jump to the target on page two. Ledger, download policy, and jobs remained unchanged across this projection action. |
| Download / Open / saved position | Ordinary chapter actions downloaded two synthetic CBZs. Every page matched its source fixture. Native reading reported three pages; Go to page set page two, and a fresh explicit Open resumed page two. |
| Native Next / reader return | Ordinary native end-of-document popup offered Next chapter; selecting it verified and switched to the exact second downloaded chapter, with three rendered pages. Go to Suwayomi returned to the existing chapter list, and its title-menu Library action restored normal Library navigation. |
| Failed Refresh | Stopped only the owned server. Explicit Refresh displayed retained-information feedback, kept four usable manga, and preserved the checked Library cache. |
| Offline cold reopen | Restarted real KOReader while the owned server stayed stopped. Saved dates/counts appeared, categories remained usable, and the saved chapter flow remained available. |
| KOReader March compatibility | Focused native entry, dates/counts/rows, both sort controls, offline Open/return, paging, and footer jump-search demonstrated on `v2026.03`. July carried the complete changed-Library workflow. |

## Physical Palma evidence

The device pass ran on 2026-10-02 against the same frozen runtime candidate and installed Android KOReader **v2026.03**. All **99 runtime payload hashes** matched before testing and remained unchanged before the offline control. One coordinator owned the device. Its original reader was stopped at takeover; the recorded package state was disabled. The test temporarily enabled it and used a separate profile and download directory. An authenticated, loopback-only inspector used USB ADB forwarding; a task-owned Windows loopback relay and ADB reverse routed requests to the isolated WSL Suwayomi **v2.3.2243** server. This route establishes USB acceptance, not Wi-Fi behavior.

| Control | Result and scope |
| --- | --- |
| Native entry and touch | Demonstrated actual Search > Suwayomi entry, native touch on the Library title menu and Title choice, and touch selection of a manga into its ordinary actions dialog. |
| Ordering and rows | Nine synthetic manga matched independently captured server discovery order. Title matched displayed-title ordering. Screenshots showed Found dates, source labels, qualified unread counts including zero, the all-scanlator explanation, and a wrapped long Unicode title with its date/count column intact. |
| Same-session navigation | Native Back returned to the category picker; selecting Reading, Refresh, and returning to All manga preserved Title order. Closing the manga dialog through its visible X also preserved Title. A new Library shortcut entry and cross-reader return correctly created a new session with Latest arrivals. |
| Download and saved position | Normal chapter actions downloaded a synthetic CBZ; every PNG matched the source fixture. The native three-page reader went to page two, returned through Go to Suwayomi, and a fresh Open resumed page two. The resumed framebuffer was inspected. |
| Failed Refresh | Stopped only the owned server. Explicit Refresh retained all nine usable rows and displayed retained-information status. The settings-directory hash comparison stayed unchanged across this projection action. |
| Offline cold restart | A normal quit stopped the Android process. With the server still stopped, cold startup and native entry restored saved categories and all nine dated/count-qualified rows in Latest arrivals order. Cached chapter actions reopened the downloaded chapter at page two; Go to Suwayomi returned successfully and the CBZ hash stayed unchanged. |
| Restoration | Before isolation, a host tar backup matched every original profile hash. The preserved original remained unchanged during testing; after restoration all **1,224/1,224 hashes** matched. Installed/stopped/enabled package flags matched the recorded takeover state; the reader was stopped, ADB mappings were empty, and both sandbox roots and the task loopback relay were stopped. Synthetic test data and private evidence were retained separately. Restoration verified at **17:55 UTC**. |

Device fixture/setup failures are retained separately from product results: the disabled package initially prevented launch; a desktop color setting prompted a native warning; Windows CRLF broke the private inspector token; direct Windows-to-WSL loopback routing failed before the relay was added; and an attempted server title patch was unsupported. A Local-source fixture supplied the long title instead. One assertion expected the wrong synthetic display label. Two navigation assertions incorrectly expected sort retention across a new Library session/cross-reader return, which the issue explicitly excludes; the corrected same-session controls passed. Android Back did not dismiss the existing manga information dialog, so its visible X was used. Normal quit made the forwarded inspector connection reset; independent process checks confirmed shutdown without replaying the quit action. These attempts did not alter the frozen runtime payload.

## First attempts and limits

- The first desktop deployment accidentally used the primary checkout because a shell-expanded source path was wrong. A source/deployment hash comparison identified it. Those screens were **not** counted as candidate acceptance; the explicit task-worktree deployment and subsequent candidate checks above replaced them.
- Private orchestration initially compared a generated archive against the wrong source filename, tapped an already-selected native tab, and guessed the wrong reader-menu location. Each retained failure was followed by fresh observation and corrected use of the existing controls, without replaying uncertain actions.
- One rapid reopen after reader return stayed on the chapter list during online background loading. A freshly selected Open subsequently resumed page two. The original attempt and diagnostics are retained; the exact cause is **unverified**. This is separate from the successful saved-position control and is not represented as a repaired reading defect.
- Footer search is disabled natively for a one-page menu. The two-page control exercised it successfully. An additional zero-count assertion initially used a stale synthetic display-name alias; the independent manga-ID/cache check resolved that harness mismatch.
- Unsupported older schemas, persistence faults, pending/foreign/relocated read choices, and unchanged download/retention/finish edge cases were covered by focused/composed automated checks; this task did not repeat their historical physical-device matrices.
- Focused Palma touch/layout, saved-position reopening, and offline browsing are demonstrated above. Human e-ink scanning/refresh/ghosting, physical sleep/wake, Wi-Fi changes, and power/storage faults were not tested.

Both task-owned server roots, readers, and the loopback relay were stopped after acceptance. Disposable profiles, synthetic archives, original-profile backup, private evidence, the task worktree, and API worker worktree are retained. Palma's original profile and package state were restored; no production plugin replacement remains. No push, merge, or issue publication was performed.
