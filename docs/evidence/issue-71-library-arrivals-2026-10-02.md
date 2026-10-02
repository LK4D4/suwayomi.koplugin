# Issue #71 Library arrivals acceptance, 2026-10-02

Implementation is committed. Automated and desktop acceptance below is demonstrated. Physical Palma acceptance remains **unverified**: its existing KOReader session was running, and the session-availability question remains unanswered. No device profile, plugin, package state, or ADB mapping was changed.

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

## First attempts and limits

- The first desktop deployment accidentally used the primary checkout because a shell-expanded source path was wrong. A source/deployment hash comparison identified it. Those screens were **not** counted as candidate acceptance; the explicit task-worktree deployment and subsequent candidate checks above replaced them.
- Private orchestration initially compared a generated archive against the wrong source filename, tapped an already-selected native tab, and guessed the wrong reader-menu location. Each retained failure was followed by fresh observation and corrected use of the existing controls, without replaying uncertain actions.
- One rapid reopen after reader return stayed on the chapter list during online background loading. A freshly selected Open subsequently resumed page two. The original attempt and diagnostics are retained; the exact cause is **unverified**. This is separate from the successful saved-position control and is not represented as a repaired reading defect.
- Footer search is disabled natively for a one-page menu. The two-page control exercised it successfully. An additional zero-count assertion initially used a stale synthetic display-name alias; the independent manga-ID/cache check resolved that harness mismatch.
- Unsupported older schemas, persistence faults, pending/foreign/relocated read choices, and unchanged download/retention/finish edge cases were covered by focused/composed automated checks; this task did not repeat their historical physical-device matrices.
- Palma touch/layout, saved-position reopening, and offline browsing remain unverified pending availability of its active session. Human e-ink scanning, ghosting, physical sleep/wake, Wi-Fi changes, and power/storage faults were not tested.

Both task-owned desktop server roots and the reader were stopped after acceptance. Disposable profiles, synthetic archives, private evidence, the task worktree, and API worker worktree are retained for the pending device pass. No push, merge, issue publication, or production-device deployment was performed.
