# Issues #72–#74 Library acceptance, 2026-10-04

The combined implementation is committed and demonstrated by the automated, desktop, and focused Palma controls below. The original Palma profile was restored with all 1,224 file hashes matching. Human e-ink usability and unrelated hardware fault cases remain unverified.

## Candidate and scope

- Base: `d63bcd80a1a24a14846b85a704c0f90d070d419a` (v1.3.0).
- Frozen runtime candidate: `5211ddc08c36a232ab113e5ceb2daea856435b50`, clean branch `codex/library-followups-72-74` before acceptance. This report and its index are subsequent documentation only.
- Issues [#72](https://github.com/LK4D4/suwayomi.koplugin/issues/72), [#73](https://github.com/LK4D4/suwayomi.koplugin/issues/73), [#74](https://github.com/LK4D4/suwayomi.koplugin/issues/74), and completed [#71](https://github.com/LK4D4/suwayomi.koplugin/issues/71) were read in full, including comments (none present). Follow-ups replace only their stated parts of #71.
- Three fresh GPT-6.1 Sol/medium workers edited serially in separate worktrees based on the then-combined candidate. Each worker committed and handed off references, actual checks, and risks before the next started. Workers did not delegate. The main agent owned integration and runtime validation.
- Canonical 99-file payload passed the packaging allowlist. All deployed plugin hashes matched the runtime candidate on desktop and Palma; device hashes were checked again after acceptance. Private observer/fault patches and the authenticated loopback inspector were outside that payload.
- Real Suwayomi `v2.3.2243`, Basic Auth, synthetic Local source: 12 manga, one long Unicode title, two categories, and three-page fixture archives. Independently captured GraphQL metadata supplied expected ordering; saved settings and all projected manga IDs were compared separately from visible controls.
- Desktop KOReader Linux `v2026.07.1`, WSLg/X11, 600 × 800. Palma Android KOReader `v2026.03`, 824 × 1648, isolated synthetic profile/download directory. USB ADB reverse plus a task-owned Windows loopback relay routed the device to the disposable server. This establishes USB controls, not Wi-Fi behavior.

## Implementation and review

| Issue | Commit and ownership | Result |
| --- | --- | --- |
| #72 | `34fe47a`; [Library controller](../../suwayomi/client/library.lua), [browse UI](../../suwayomi/ui/browse.lua), [list menu](../../suwayomi/ui/list_menu.lua), [rows](../../suwayomi/ui/list_rows.lua), README, catalogs/specs | Native compact subtitle replaces the permanent status row; About Library explains discovery/count/read/refresh semantics; rows say Latest found. |
| #73 | `8575933`; controller and focused specs, README/catalogs | Manga-only explicit checked choices, effective fallback checkmark, and page-one reset for every explicit selection, including reselecting the active order. Ordinary Refresh preserves page. |
| #74 | Worker `6832950`, integrated as `5211ddc`; [settings](../../suwayomi/settings.lua), controller/specs, architecture/README/catalogs | Validated device-wide `library_sort_mode` through the existing checked store; immediate session selection, confirmed persistence, and failure feedback. Fallback/load/refresh do not overwrite the requested preference. |

Main integration repairs `bd67968` and `e119ede` addressed two real native-widget problems found during desktop acceptance: title shrink/rebuild reused an old stored subtitle, and rebuilding an unchanged title disturbed menu geometry. Focused regressions and real screenshot controls passed after the repairs. No prerequisite refactor or extra feature was added.

One fresh GPT-6.1 Sol/high independent correctness reviewer examined the complete `d63bcd8..5211ddc` candidate against all four issue contracts and native KOReader behavior. It reported **no actionable findings**; 214 focused specs and `git diff --check` passed. No second full review was run.

## Automated evidence

Final combined runtime checks from the task worktree:

- `luacheck --codes spec suwayomi main.lua _meta.lua`: **zero warnings/errors**, 182 files.
- `busted --lua=luajit spec`: **1,884 successes**, zero failures/errors/pending.
- `./scripts/check-l10n.sh`: passed extraction and catalog compilation.
- `bash .github/scripts/stage-release-payload.sh <disposable-target>`: passed, 99 files.
- `git diff --check`: passed.

WSL used explicit LuaJIT and process-local `LUA_CPATH=/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;`. An earlier worker full run found an unrelated stale local LuaSec binary requiring absent OpenSSL 1.1. The distro LuaSec override passed targeted transport checks and the final full suite; no package was changed. An initial gettext write failure was retried successfully with no catalog loss.

Focused coverage includes subtitle priority and native stored-subtitle updates; explanation dismissal; zero/unknown and unchanged Browse rows; checked supported/unsupported sorts and unknown dates; active-choice and alternate-choice resets; category/refresh retention; stale controls; absent/invalid/valid saved preference; rejected saves; ambiguous-save fencing; reopen/reader return; and no projection-triggered download/read/cache mutation.

## Real desktop evidence

All successful final controls below used the frozen runtime candidate. Native **Search > Suwayomi** entered Library. Screenshots were inspected, including both checkmarks, About Library, the long title, loaded/refreshing/unsaved/retained subtitles, and offline rows.

| Control | Observed result |
| --- | --- |
| Categories and About Library | No permanent banner row. Categories omit sort actions. About Library has all six required explanations; ordinary dismissal preserves the category screen. |
| Manga help and checked choices | Both sort actions visible, exactly one checked. About Library from page two dismisses back to page two with the same order. |
| Later-page explicit sorting | Title, active Title, arrivals, and active arrivals each reset page two to page one. Full 12-ID order matched independently sorted server metadata each time. |
| Ordinary Refresh | From page two, retained page two and order. Saved cache, ledger, jobs, retention policy, and reader-return contexts were unchanged across the controlled refresh/sort projection comparison, apart from the explicit preference. |
| Reopening and category selection | Selecting Default and reopening through Library retained Title; saved `library_sort_mode` independently matched the visible order. |
| Real reading and return | Ordinary Download/Open rendered the exact three-page fixture. Every PNG matched its source. Native Go to page selected page two. Go to Suwayomi, then Library, retained Title order and saved preference. |
| Controlled rejected cache save | Profile-only rename rejection produced Loaded, not saved for restart; native subtitle matched the model and all 12 rows remained usable. This is injected rejection, not real exhausted storage. |
| Failed Refresh | Stopping only the owned server, then explicit Refresh, retained rows and reported failure/unsaved status. The saved settings file remained byte-for-byte unchanged. |
| Offline cold restarts | Separate fresh launches with saved Title and saved Latest arrivals restored the expected 12-ID order, saved dates/counts, and checked preference while the server stayed stopped. Automatic failure remained nonmodal; retained-information status was visible. |

## Focused physical Palma evidence

The original reader was stopped and its package disabled at takeover. A verified tar backup and the preserved on-device original both matched all 1,224 hashes. Only the synthetic profile was enabled and launched during acceptance.

| Control | Observed result |
| --- | --- |
| Native entry and touch layout | Actual Search > Suwayomi entry. Native touches opened the title menu, selected each sort, and used the footer to reach page two. Screenshots showed one correct checkmark, source/cover/count/date columns, and a wrapped long title without row overlap. |
| About Library | Category and manga help screenshots showed every explanation. Dismissal returned to the same screen; manga help retained page two. |
| Sorting and Refresh | Active arrivals selection reset page two to page one; Title selection did likewise. Refresh retained page two. All 12 projected IDs and saved preference matched independent expected ordering. |
| Download/Open/reader return | Ordinary chapter controls downloaded and rendered a three-page fixture. All downloaded PNG bytes matched the source. Returning through Go to Suwayomi and Library retained Title; independently read settings confirmed it. |
| Offline cold Title and arrivals | With the owned server stopped, fresh Android launches restored each saved order and all 12 rows with dates/counts. An offline explicit arrivals selection persisted. The arrivals cold-launch failure settled to a nonmodal retained-information subtitle. The longest failure subtitle uses native ellipsis at the trailing sort text; failure and retained-data status remain visible on one line. |
| Integrity and restoration | All 99 payload hashes still matched after acceptance. All **1,224/1,224 original profile hashes** matched after restoration. Original installed/stopped/disabled package state was restored, reader process absent, and task ADB forward/reverse mappings removed. Device returned to sleep. |

The installed Android APK did not bundle HTTP Inspector. Its matching `v2026.03` native inspector plugin was added only to the synthetic profile for the authenticated task patch. It was not added to the candidate or original profile.

## Retained attempts, limits, and resources

- Before the two native-widget repairs, desktop screenshots exposed stale status and title-rebuild geometry. Those first attempts are retained privately and are not counted as passing final-candidate evidence.
- Private setup/control failures included expected absent-process exit status, passing a Linux host path to Windows ADB, an asleep launch, Windows Unicode output encoding, selecting an already-active native tab, and insufficient Android shutdown sequencing. They were corrected using observed state, without changing the candidate payload. Normal Exit closed Lua/inspector but left the Android activity alive; force-stopping that remaining activity and checking process absence preceded the successful fresh launch. The later arrivals control used an explicit force-stop cold launch after independently confirming its saved preference. These are process-restart controls, not power-loss tests.
- A relay cleanup identity check initially rejected a slash-format mismatch and preserved the process. Normalizing separators verified the exact task script before stopping it; relay absence was then checked.
- Unsupported schemas, reconstructed/empty/missing states, preference-save rejection/ambiguity, and unrelated #71 read/download edge cases are established by automated coverage here; their previous full desktop/device fault matrices were not repeated.
- Human readability/ghosting judgment, physical sleep/wake behavior, Wi-Fi transitions, real storage exhaustion, and power loss remain **unverified**. ADB touch and framebuffer inspection do not establish those cases.
- Owned server and desktop reader are stopped; the Windows relay is stopped; no owned device reader or ADB mappings remain. Restoration and stopped-state checks completed on 2026-10-04. Raw observations, screenshots, settings, logs, backup, and archives remain private outside the repository.
- Main worktree `library-followups-72-74` and worker worktrees `library-72`, `library-73`, `library-74` are retained with their task branches. The disposable sandbox, host backup, device synthetic profile, and synthetic download directory are retained for diagnosis/review. Unrelated worktrees and the primary master checkout were preserved.

This is a committed implementation candidate, not finalization. Work-branch GitHub Test verifies the exact documentation-inclusive candidate separately from the frozen runtime controls above. No master integration, release, production deployment, or issue publication is authorized by this task.
