# Issues #59–#62 acceptance evidence — 2026-09-26

Initial desktop handoff: **implemented; physical Palma verification pending at that time**. Subsequent physical results and restoration are recorded in [Palma follow-up](issues-59-62-palma-2026-09-26.md). Desktop observations below establish only their recorded controls. GitHub issues [#59](https://github.com/LK4D4/suwayomi.koplugin/issues/59), [#60](https://github.com/LK4D4/suwayomi.koplugin/issues/60), [#61](https://github.com/LK4D4/suwayomi.koplugin/issues/61), and [#62](https://github.com/LK4D4/suwayomi.koplugin/issues/62), including comments, remain the specifications.

Base: `9500b0d2ba0b340ea6cbcf48162117d965485d1c`. Frozen runtime candidate: `aaa6d64865dc18e39ad9da831b18ffdffc4de738`, with no dirty runtime changes. This evidence and its index are a subsequent documentation-only commit. Integration branch: `codex/issues-59-62-integration`.

## Automated checks and review

| Check | Result on the runtime candidate |
| --- | --- |
| `busted --lua=luajit spec` | **1,729 successes**, zero failures/errors/pending. |
| `luacheck --codes spec suwayomi main.lua _meta.lua` | **176 files**, zero warnings/errors. |
| `./scripts/check-l10n.sh` | Passed; generated catalogs committed and stable. |
| Release payload script, `validate-only` on installed plugin | Passed canonical allowlist. |
| `git diff --check` | Passed. |
| Independent combined review, Sol/high | One standards/specification pass. One P2 foreign-path finding repaired in `86df020`; targeted follow-up closed it. No outstanding finding. |

Workers first reproduced the defects with composed regressions. The integrated suite initially exposed two older manga-controller fixtures missing the real local-download mixin; `15bd8d1` repaired those fixtures before the passing final run. WSL used LuaJIT, process-local distro LuaSec paths, and verified `GIT_DIR`/`GIT_WORK_TREE` for Windows worktree metadata.

Controlled specs cover row and current-context unread state, scoped/unscoped/foreign/reused identities, path collisions, pending-read/no-pending controls, missing metadata, foreign caches, endpoint changes, superseded requests, bounded bulk admission, selection/filter preservation, and rejected/uncertain persistence. These deterministic cases are not all desktop or hardware observations. Relevant composed suites are `issue59_legacy_actions_spec.lua`, `issue61_pending_unread_spec.lua`, `complete_chapter_loading_spec.lua`, and `suwayomi_client_library_spec.lua`, alongside existing download/read/publication suites.

## Desktop environment and method

Dedicated disposable WSLg sandbox: `issues-59-62-desktop-20260926`; KOReader **v2026.07.1**, Suwayomi **v2.3.2243**, Basic Auth. The coordinator alone owned live resources; workers used isolated worktrees and offline checks. No personal server or library was used.

All **98 payload files** matched source and installed SHA-256 values, including the compiled catalogs. Final comparison after restoring the disposable profile also passed. SHA-256 of the deployment file-to-hash map, encoded as sorted compact JSON: `b4eb7208da62ceec76be5c288778f7847dcfa694b3b43750febbc247b9e36509`. The authenticated inspector patch remained outside the release payload.

Tests entered through native KOReader Search > Suwayomi and used ordinary widgets, including the native reader's Go to Suwayomi action. Native input targeted the owned window. Assertions compared rendered controls with independent authenticated server queries, persisted settings, archive contents, sidecar data, and file hashes. Screenshots of unread rows, saved policy, deleted selection, and empty Library were visually inspected.

Synthetic fixtures Alpha and Beta each had three chapters with three generated PNG pages. A normal download and native page-2 reading established the baseline. Between scenarios, the reader was stopped before controlled settings edits and the relevant profile/download baseline restored. Removing origin fields, inserting a pending choice, changing identity metadata, and installing a saved filter were **injected preconditions**, not evidence of user actions creating those states.

## Per-issue results

| Issue and control | Desktop result on `aaa6d64` |
| --- | --- |
| **#59 — mixed safe/legacy bulk** | **Demonstrated.** With one existing unscoped archive, Download next 5 produced the two eligible archives. All downloaded PNGs matched source bytes; the legacy archive hash remained unchanged. |
| **#59 — selection/filter limits** | **Demonstrated.** A retained missing scanlator filter admitted no download. After explicit All scanlators, Download selected skipped a pathless unknown record with an association-specific message, downloaded the safe selected chapter, and preserved the existing archive. Independent server read flags and the pathless record remained unchanged. |
| **#59 — auto policy/refill** | **Demonstrated.** First 5 unread persisted and downloaded eligible chapters beside the legacy archive without changing that record or its bytes. A saved First 10 unread policy survived a cold reader restart. Explicit Off persisted. Unknown-origin refill non-association and failed-policy-write controls have composed-spec evidence. |
| **#59 — mixed Mark previous as read** | **Demonstrated.** The real chapter action reported an association refusal rather than a storage-write error. Independent server flags remained unchanged. |
| **#60 — native return/Refresh/progress** | **Demonstrated.** Opening the legacy archive resumed page 2 of 3. Native Go to Suwayomi returned all three server chapters, including undownloaded chapters; independent membership matched. Refresh chapters was available and succeeded. Local reading and archive preservation remained available. |
| **#60 — offline/empty** | **Demonstrated.** Stopping the owned server retained the full saved list on native return; explicit Refresh reported connection refusal and retained that list. A separate authenticated loopback responder injected a successful empty chapter response while the real server was stopped: native return showed no chapters, and a cold offline restart retained that authoritative empty list despite the archive. This empty-success case was an injected response, not a real-server deletion. |
| **#60 — identity/navigation** | **Demonstrated.** Conflicting source metadata with the same IDs kept return local and withheld server controls; ordinary Library navigation still opened the full list. Suspending only the owned server process held a request while navigating back to Library; resuming it did not reopen the obsolete chapter screen. Other foreign/missing/reused identity and endpoint-change permutations have composed-spec evidence. |
| **#61 — pending unread over completed sidecar** | **Demonstrated for rendered row and preservation.** A normal Mark as read created completed-sidecar/server-read evidence, then a pending explicit unread with unknown origin was injected. Saved offline rendering, normal Refresh, and Library reopen showed Downloaded without Read. Archive/sidecar hashes, ledger, return records, and completed sidecar status stayed unchanged; no refill request appeared. The server stayed read, proving no unknown-origin synchronization. Current-context unread state is separately asserted by composed specs. |
| **#61 — foreign path control** | **Demonstrated.** A pathless pending choice with a foreign-owned guessed archive did not override server Read or expose Downloaded. Records/files and the server flag stayed unchanged through refresh. |
| **#62 — deleted selection/Back** | **Demonstrated.** Deleting the selected disposable category through the server API, then ordinary Refresh, immediately showed All manga with independently matching membership. Back opened the fresh picker without the deleted category. |
| **#62 — retained selections/failure/empty Library** | **Demonstrated.** Rename retained the category by ID and refreshed its name; an existing empty category remained empty. Default and All stayed usable. A failed refresh preserved the selected category and saved manga. Removing all server Library membership produced a genuine empty Library despite three local archives; archives remained, and server membership was restored afterward. |

## Initial desktop handoff and retained resources

**At this initial handoff, Palma was unverified for all four issues.** A connected device had KOReader open with no test inspector or forwarding routes. Other relevant Codex chats were idle, but ownership of the active reading session was unresolved. The coordinator requested clearance to interrupt it; no answer arrived during this run. No device deployment, profile change, process interruption, or ADB mapping change was performed. USB detection alone establishes no repaired behavior.

After session clearance, back up device plugin/profile/progress, deploy and hash the same candidate's canonical payload, then repeat the relevant mixed bulk/auto/read-refusal, native return/Refresh/offline/identity/progress, pending-unread, and deleted-category/Back flows against disposable fixtures. Restore the device state and mappings afterward. Android behavior, physical network changes, sleep/wake, and e-ink usability are not established here. Storage-failure cases retain controlled-spec evidence; no real storage exhaustion or power-loss test was performed.

At **2026-09-26 12:09:28 UTC**, both owned desktop services were independently confirmed stopped. The controlled profile/download baseline was restored, retaining the tested runtime payload. Prior fixture states, private manifests, screenshots, and acceptance helpers remain available locally; none of their credentials, raw settings, logs, or archives are committed.

All four task worktrees and branches are retained: `codex/issues-59-62-integration`, `codex/issues-59-61`, `codex/issue-60-reader-return`, and `codex/issue-62-library-category`. No push, master merge, publication, issue modification, or worktree removal occurred. GitHub Actions was not run because pushing was explicitly prohibited; repository finalization remains a separate authorized step.
