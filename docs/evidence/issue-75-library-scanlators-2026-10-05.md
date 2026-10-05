# Issue #75 Library scanlator acceptance, 2026-10-05

The scoped Library behavior is demonstrated by the automated, desktop, and focused Palma controls below. The original Palma profile was restored with all 1,224 file hashes matching. Human e-ink usability remains unverified.

## Candidate and method

- Issue [#75](https://github.com/LK4D4/suwayomi.koplugin/issues/75); base `d7c36d4`; runtime candidate `f32812a8cdce8e22ef131baa049c5cf1f4a926ef`, branch `codex/library-scanlator-75`. Subsequent evidence-only changes do not alter the runtime payload.
- Canonical 99-file payload passed the allowlist. All desktop and Palma deployed hashes matched the committed source; all 99 device hashes matched again after cold restart. The initial deployment label preceded the commit, so file hashes supplied candidate identity.
- Real Suwayomi `v2.3.2243`, Basic Auth, disposable synthetic Local source. Four manga, two scanlator groups, different discovery/read states, and a long Unicode title. Controlled database edits occurred only with the owned server stopped. Restart preserved those fixtures without source rediscovery.
- Desktop KOReader Linux `v2026.07.1`, WSLg/X11, 600 × 800. Palma Android KOReader `v2026.03`, 824 × 1648, isolated profile and download directory. USB ADB reverse and a task-owned Windows loopback relay connected the device to the server; this does not establish Wi-Fi behavior.
- Both readers entered through native **Search > Suwayomi**. Saved filters changed through ordinary chapter controls. A profile-only observer recorded the actual Library row models without invoking production actions. Independent GraphQL chapter records supplied expected counts, maximum valid `fetchedAt`, and the complete four-manga ordering; saved settings and screenshots supplied separate persistence/layout evidence. Neither observer nor inspector was in the release payload.

## Automated and review evidence

- `luacheck --codes spec suwayomi main.lua _meta.lua`: **zero warnings/errors**, 183 files.
- `busted --lua=luajit spec`: **1,912 successes**, zero failures/errors/pending.
- `./scripts/check-l10n.sh`, canonical payload staging, and `git diff --check`: passed.
- WSL used Bash, explicit verified worktree Git paths, LuaJIT, and process-local distro `LUA_CPATH`; no system package changes were needed.
- One code-review workflow examined `d7c36d4..f32812a` with separate GPT-6.1 Sol/high Standards and Spec agents. Both reported **zero actionable findings**. The Spec reviewer ran 95 focused specs successfully.

Focused coverage includes exact scanlator queries/parsing, already-read discovery dates, duplicate chapter numbers, zero matches, malformed/incomplete/unsupported replies, bounded batches, complete membership despite scoped-query failure, old/wrong-scope caches, in-flight filter/endpoint changes, checked cache writes, offline reopening, and unchanged read/download state during projection.

## Real desktop controls

| Control | Expected and observed result |
| --- | --- |
| Saved restriction | Fixture A changed from aggregate unread 2/latest discovery 1850000000 to matching unread 1/latest discovery 1750000000. Its position moved below the other three manga. All four rows matched independent chapter records. |
| Excluded unread arrival | Aggregate facts changed; scoped count/date and full ordering stayed unchanged. |
| Matching unread arrival | Scoped unread became 2; discovery became 1900000100 and ordering changed accordingly. |
| Already-read matching arrival | Scoped discovery became 1900000200; unread remained 2. Injected arrivals shared a chapter number, so separate matching releases still counted. |
| Filter removal and Refresh | All scanlators restored aggregate facts and ordering. Normal Refresh retained the active restriction and refreshed known server data. |
| Remembered sort/offline cold restart | Explicit Title selection persisted. After stopping the owned server and launching a fresh reader process, all four scoped cached rows and Title order matched the previously queried records. Failure settled to retained-information status. |

## Focused Palma controls

The original reader exited before takeover; its remaining Android activity was stopped and package disabled. A verified tar backup and the preserved on-device original matched all 1,224 regular-file hashes. Only the synthetic profile was launched for these controls.

| Control | Expected and observed result |
| --- | --- |
| Native saved filter and Refresh | A controlled fixture lowered matching discovery dates before device acceptance. Native Team A touch changed Fixture A from aggregate unread 4/latest 1900000000 to matching unread 2/latest 1750000000 and demoted it below all three other manga. Completed Refresh preserved the restriction; all four rows/order matched independent records. |
| Native filter removal | All scanlators restored aggregate unread 4/latest 1900000000 and the corresponding order. Reapplying the restriction and selecting Title preserved scoped values and produced the independently expected Title order. |
| Confirmed zero matches | With the saved restriction unchanged, a controlled server scanlator edit removed every match. Normal Refresh displayed **Server unread: 0** and **Arrival date unknown**. Screenshots showed intact title/source/cover columns and the wrapped long title without overlap. |
| State preservation | Before the explicit pending-read control below, independently queried server read/download states and Library membership were unchanged across filter, Refresh, and sort actions. The isolated download directory remained empty. |
| Sync pending | With the server stopped, ordinary Mark as read on one cached chapter of a different manga created one pending local choice. Library retained that manga's observed server unread 3 and date, adding **Sync pending** without subtracting the local choice. Zero/unknown and pending rows remained fully visible in the inspected framebuffer. |
| Offline cold restart | Normal quit closed Lua/inspector; the remaining activity was stopped and process absence checked before relaunch. Native Search entry restored all four rows, scoped zero/unknown, pending status, and Title order while the server stayed stopped. Independently loaded settings confirmed Title, exact endpoint/manga/filter association, zero, and the one pending local choice. |
| Timestamp bound and payload | Android `os.date` accepted the parser's safe upper timestamp bound. All 99 runtime hashes still matched after restart; no local download files were created. |
| Restoration | All **1,224/1,224 original profile hashes** matched before resuming the original reader. Its original enabled/running/power state was restored, including sleep. Task-owned ADB forward/reverse mappings were removed. |

## Limits and retained resources

- Failed harness attempts are retained privately: a desktop string/numeric ID comparison, shell quoting, imported helper command dispatch, and an Inspector dialog route that selected Back instead of the requested button. Native touches repeated the affected device controls successfully. A quit connection reset required an explicit process check before cold launch. These attempts did not change the candidate and are not counted as passes.
- Unsupported-server, stale-callback, wrong-endpoint/filter, and save-failure boundaries are established by focused automated coverage; their full device fault matrices were not repeated. Other server/reader versions, physical Wi-Fi transitions, power loss, real storage exhaustion, and human readability/ghosting judgment remain **unverified**.
- Owned desktop reader and server are stopped, the Windows relay exited, and task ADB routes are absent. Raw observations, screenshots, settings, logs, verified backup, and controlled fixtures remain private. The disposable sandbox, host backup, device synthetic profile/download directory, and clean task worktree/branch are retained for review; unrelated resources were preserved.
- This implementation request authorizes local commits. No push, merge, issue update, or production deployment was performed.
