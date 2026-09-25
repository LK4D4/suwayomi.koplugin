# Issue #55 chapter-publication evidence — 2026-09-25

Runtime candidate: `dfd940c69152f772c70ea3a45619875f50869a61`, based on `77a70acf3bf9a0c68efdb9620370162c284056e5`, with no dirty runtime changes. Initial acceptance completed at 10:47:51 UTC; the shipped cold-preload follow-up below completed at 12:23:53 UTC. The isolated WSLg sandbox used KOReader v2026.07.1 and Suwayomi v2.3.2243 with Basic Auth. All 98 deployed payload files were hash-verified. Controller SHA-256: `db1ac5d639d358b129dd4bae5750b8db14cc62723230291d0c182f5360e59738`.

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

The injected preload control used a disposable profile-only widget that dispatched the existing bulk-download action; it establishes the running publication/action path, not the shipped cold-action entrypoint. The ordinary saved-first manga dialog did not expose that bulk action without an existing chapter list. The shipped entrypoint was subsequently checked through Open next unread, as recorded below. Fault injection lived in the disposable profile, leaving the deployed plugin payload unchanged. Probe SHA-256 values were `4479b0824672c62c6033009601bdc71af3d2aa359db531380f44fbeb6c72b4ca` for preload/rejected writes and `995f10f0fc5027fdc0f0dabc0ca56c40946293f05776f0889160c088b392c01c` for the uncertain write. The earlier rejected-write probe did not independently snapshot the confirmed document or refill state. Inspector SHA-256: `21189cdde4a97a05f95ab0584ec7541f9d9dfac9c058616a2577e9dd7edc948b`.

One preload attempt received connection refused because the sandbox launcher requires all three source fixtures and Chapter 003 was still held aside. Its fault arm was not consumed. Restoring the synthetic fixture and verifying server readiness allowed the control above to run; the failed setup attempt supplies no candidate behavior evidence.

Commands used the repository's `sandbox.py setup`, `deploy`, `run`, `smoke`, `ui home/tap/observe`, `stop`, and `status`, plus disposable drivers `offline_saved_first.py`, `state_shape.lua`, and `hash_preservation.py` and the profile probe. Private probe snapshots, file manifests, captures, and drivers remain in the isolated sandbox's evidence directory. Source Chapter 003 was restored. Both reader and server were confirmed stopped, including an independent final `status` check by the main agent.

## Shipped cold-preload follow-up

The follow-up used published revision `12a2ac8cec7dcbc8a3baa9bbb8d7394ef708f54a`, whose runtime matches the candidate above. All 98 deployed hashes were rechecked against the deployment manifest; comparison with the current checkout accounted for Git's CRLF conversion. There were no dirty runtime changes. The earlier fault/button probe was disabled before a fresh reader start; only the standard sandbox inspector patch was active.

The controlled precondition removed the synthetic profile's chapter cache, reader-return contexts, and ledger paths while retaining the Library's first-unread hint and downloaded Chapter 001. Settings, reader preferences, archive, and sidecars were backed up first. This forced a cold chapter request while keeping the normal Open next unread control available. It is a prepared missing-metadata case, not evidence that metadata disappeared during ordinary use.

| Control | Observed outcome |
| --- | --- |
| Library > Sandbox Alpha > Open next unread, without opening the chapter list | **Demonstrated through the shipped UI.** The normal dialog contained Open chapters, Open next unread, and Remove from library. Open next unread showed Loading chapters, then opened the retained archive in the reader with three pages. No fixture button or product patch participated. |
| Independent saved-state comparison | **Demonstrated.** Immediately before the click, the chapter cache was absent. After the reader opened, the saved cache contained exactly 001/002/003, all unread. Ledger paths and reader-return contexts remained empty. |
| Archive and rendering identity | **Demonstrated.** The open document resolved to the retained Chapter 001 archive, whose SHA-256 remained `9278a7dd50e6381dc9e8a8936d12af7f35fcf4ffb25ff2975e1fc2200309a6d4`. All three extracted PNGs matched the source fixture byte-for-byte. The inspected 600 × 800 screenshot showed the three fixture page labels and a 1/3 reader indicator. |

The helper's `ui home` entered the plugin before the ordinary Library/manga controls; this does not establish native Search entry behavior. This stripped-association fixture had no Go to Suwayomi control, so the automatic close-reader helper timed out. The observed native file-browser action closed the document, and both services then stopped gracefully. This follow-up establishes cold publication and action dispatch, not reader-return behavior; the normal download/open/return control above supplies that separate evidence.

Private before/after observations, screenshot, preparation script, backups, and cleanup record remain under the sandbox's `evidence/shipped-preload` directory. Screenshot SHA-256: `88feba20fe19522c523b90b59738ec37140ce4c7bf768a9f282e0bd5b94d7a3b`. All 20 backed-up settings/archive/sidecar files were restored and byte-verified; the prior profile probe was restored with both services stopped. Final status confirmed reader and server stopped.

The cold restart is not power-loss evidence. These desktop controls do not establish Android, e-ink, physical storage failure, sleep/wake, or Wi-Fi behavior. Pending read/filter/stale-result and authoritative-empty cases retain composed LuaJIT evidence; they were not all repeated as desktop controls.
