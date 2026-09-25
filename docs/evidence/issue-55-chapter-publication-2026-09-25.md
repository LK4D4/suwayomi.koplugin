# Issue #55 chapter-publication evidence — 2026-09-25

Runtime candidate: `dfd940c69152f772c70ea3a45619875f50869a61`, based on `77a70acf3bf9a0c68efdb9620370162c284056e5`, with no dirty runtime changes. Acceptance completed at 10:47:51 UTC. The isolated WSLg sandbox used KOReader v2026.07.1 and Suwayomi v2.3.2243 with Basic Auth. All 98 deployed payload files were hash-verified. Controller SHA-256: `db1ac5d639d358b129dd4bae5750b8db14cc62723230291d0c182f5360e59738`.

## Automated checks

Commands ran from the task worktree root under WSL with LuaJIT 2.1.0-beta3, Busted 2.3.0, and Luacheck 1.2.0. Process-local distro LuaSec paths selected the installed OpenSSL-compatible module; explicit `GIT_DIR` and `GIT_WORK_TREE` preserved worktree discovery during localization checks.

| Check | Result |
| --- | --- |
| Focused baseline: complete chapter loading, manual completion, chapter menu/actions | 290 passed before the refactor. |
| Focused candidate checks, also including manga controller | Existing cases passed. The added display/preload fixture needed KOReader's serialized status syntax and reader-return methods; both routes passed after fixture correction. |
| `busted --lua=luajit spec` | **1,652 passed**, zero failures/errors/pending. |
| `luacheck --codes --quiet spec suwayomi main.lua _meta.lua` | Zero warnings/errors in 173 files. |
| `./scripts/check-l10n.sh` | Passed, without tracked catalog changes. |
| `git diff --check` | Passed. |

Composed checks cover failed cache/ledger/menu publication, earlier successful acknowledgments, pending read/unread precedence, selection/filter preservation, stale requests, successful emptiness, and manual single/batch ordering. The added scenario establishes that successful preload skips finished-sidecar reconciliation while display retains it; archive and sidecar bytes remain unchanged.

Independent review found no documented standards violations or spec/correctness defects. Standards review suggested renaming the optional `show_menu` callback; this stylistic suggestion was left unchanged under the repository's scope guidance.

## Desktop runtime

Normal controls used actual KOReader widgets and the real sandbox server. Moving only synthetic Chapter 003 out of the server's source directory established a two-chapter replacement without editing the returned listing. Reading the persisted settings independently established cache membership.

| Control | Observed outcome |
| --- | --- |
| Normal download, Open, and Go to Suwayomi | **Demonstrated.** Three rendered pages; all three extracted PNGs matched the synthetic source bytes. |
| Ordinary refresh and real-server membership replacement | **Demonstrated.** Visible membership changed from 001/002/003 to 001/002. Persisted chapter cache contained exactly 001/002. |
| Offline cold restart | **Demonstrated.** After graceful reader/server stops, Library > manga > Open chapters displayed saved 001/002. Downloaded 001 opened with three pages and returned through Go to Suwayomi. |
| Instrumented cold action preload with rejected cache save | **Demonstrated through a fixture button.** The real server supplied three chapters; the prepared context retained all three using saved fallback. No chapter menu was built. The ordinary two-new-chapter bulk confirmation appeared and was canceled. |
| Rejected late menu save | **Demonstrated.** Explicit Refresh chapters received two chapters instead of the prior three. Cache, current context, and menu all showed 001/002. The second write was rejected inside menu reconciliation; a saved fallback built the menu and the error remained visible. Publication returned success without blocking the store. |
| Uncertain late menu save | **Demonstrated.** After restoring source 003, explicit Refresh chapters received three chapters instead of two. The second checked write reached replacement but failed directory sync inside menu reconciliation. Cache, context, and menu published 001/002/003; ambiguity feedback appeared and the store fence was active. |
| Uncertain-write fallback effects | **Demonstrated.** Exactly two writes and two menu builds. The confirmed settings document after publication equaled the snapshot immediately before the failed write. Refill state and all three observed archive/sidecar files were unchanged, with file hashes compared independently. |

The preload control used a disposable profile-only widget that dispatched the existing bulk-download action; it establishes the running publication/action path, not the shipped cold-action entrypoint. The ordinary saved-first manga dialog did not expose that bulk action without an existing chapter list. Normal cold-preload entry through the shipped UI remains unverified; a possible missing-cache Open next unread precondition was not attempted. Fault injection lived in the disposable profile, leaving the deployed plugin payload unchanged. Probe SHA-256 values were `4479b0824672c62c6033009601bdc71af3d2aa359db531380f44fbeb6c72b4ca` for preload/rejected writes and `995f10f0fc5027fdc0f0dabc0ca56c40946293f05776f0889160c088b392c01c` for the uncertain write. The earlier rejected-write probe did not independently snapshot the confirmed document or refill state. Inspector SHA-256: `21189cdde4a97a05f95ab0584ec7541f9d9dfac9c058616a2577e9dd7edc948b`.

One preload attempt received connection refused because the sandbox launcher requires all three source fixtures and Chapter 003 was still held aside. Its fault arm was not consumed. Restoring the synthetic fixture and verifying server readiness allowed the control above to run; the failed setup attempt supplies no candidate behavior evidence.

Commands used the repository's `sandbox.py setup`, `deploy`, `run`, `smoke`, `ui home/tap/observe`, `stop`, and `status`, plus disposable drivers `offline_saved_first.py`, `state_shape.lua`, and `hash_preservation.py` and the profile probe. Private probe snapshots, file manifests, and captures remain in the isolated sandbox; the drivers remain in the ignored task-worktree acceptance directory. Source Chapter 003 was restored. Both reader and server were confirmed stopped, including an independent final `status` check by the main agent.

The cold restart is not power-loss evidence. These desktop controls do not establish Android, e-ink, physical storage failure, sleep/wake, or Wi-Fi behavior. Pending read/filter/stale-result and authoritative-empty cases retain composed LuaJIT evidence; they were not all repeated as desktop controls.
