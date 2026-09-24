# Release-readiness review — 2026-09-24

Candidate: `81779eea90b84340721adf3e148e35734ee19226`, compared with `v1.1.1` (`35baddf2030e49a32278d60a937c6672d2376e5e`). Local and published master matched at review start. Issues [#53](https://github.com/LK4D4/suwayomi.koplugin/issues/53) and [#54](https://github.com/LK4D4/suwayomi.koplugin/issues/54) were closed; the issue tracker had no open issues. The previously accepted HTTPS certificate limitation is excluded.

**Verdict: no confirmed code blocker found; ready for release preparation within the tested scope.** The original #53/#54 repairs have regression coverage and runtime acceptance. A new release still needs a chosen version and matching release notes; `_meta.lua` declares the already-published `1.1.1`. The device and fault-coverage limits below remain explicit.

## Standards

The independent standards review found no actionable documented-rule violations or design smells after applying the repository's explicit exceptions. It covered download ownership and identity, checked persistence, chapter publication and reconstruction, local archive opening, and the sandbox inspector. ADR-0006 explicitly permits the queue/lifecycle split.

## Specification and behavior

The independent behavioral review found no confirmed missing requirement, unintended scope expansion, or implementation defect against the accepted contracts. It covered download ownership and endpoint guards, checked read transactions, Library/chapter caches, recovered-file authority, reader return, UI paths, and #53/#54 requirements.

A suspected follow-on #54 defect was investigated and withdrawn. A composed probe shows that an independent later full menu refresh can re-observe native completed metadata and change next-unread selection without a settings write. Pending explicit unread still wins. The [checked-read design](checked-read-persistence-design.md) leaves native metadata outside the transaction and prohibits unconfirmed effects from the failed operation; it does not promise to freeze native-state observation across subsequent independent refreshes. The probe's two failing assertions imposed that additional lifetime requirement, so they are not counted as product failures. The original four late-save controls pass. No production change was made to enforce the speculative requirement.

## Automated gates

| Check | Result |
| --- | --- |
| Full LuaJIT suite | 1,650 successes, zero failures/errors/pending. |
| WSL localization-extraction fixture | The first full-suite run printed a Windows-worktree Git-path error. The affected fixture was rerun with verified `GIT_DIR`/`GIT_WORK_TREE`: one success, no error. |
| Luacheck | Zero warnings/errors across 173 files. |
| Localization | Source extraction, catalog validation, and compilation passed with verified worktree metadata. |
| Release payload | 98 files staged; allowlist validation passed. |
| Sandbox tooling | All 12 `scripts/test_issue_48.py` tests passed. |
| Release diff whitespace | `git diff --check v1.1.1...81779ee` passed. |
| Published-master CI | [Test run 35972541568](https://github.com/LK4D4/suwayomi.koplugin/actions/runs/35972541568) passed on exact candidate `81779ee`, including lint, specs, localization, and payload staging. |

The review used ADR-0006, ADR-0007, checked-read persistence, existing safety contracts, and #53/#54 as specification sources. Automated checks establish their tested boundaries; they do not substitute for runtime observations.

## Fresh runtime evidence

The review includes fresh WSLg and physical Palma checks using synthetic fixtures and an unchanged candidate payload. Desktop uses KOReader v2026.07.1; Palma uses v2026.03; the disposable Suwayomi servers use v2.3.2243 with Basic Auth. Each deployed payload contains 98 hash-verified files. Device networking uses USB forwarding and a loopback-only relay.

The isolated #54 fault patch was unchanged from the earlier acceptance record (SHA-256 `bad3b4b64bcf5213104817f0192df0bf709585a055205920644c77cc7e7204c8`); the inspector matched `21189cdde4a97a05f95ab0584ec7541f9d9dfac9c058616a2577e9dd7edc948b`. Both remain outside the release payload.

| Control | Desktop | Palma |
| --- | --- | --- |
| Download, Open, Go to Suwayomi | Passed; three PNG pages matched the source and rendered. | Passed; three PNG pages matched the source and rendered. |
| Rejected late menu save | Fresh two-chapter server membership matched cache/context/menu; error visible. | Same outcome. |
| Uncertain late menu save | Fresh membership and active store fence at publication; ambiguity visible. | Same outcome. |
| Failed-write effects | Two writes, second failed in menu construction; no later write/refill during publication; committed serialization and local archive preserved. | Same outcome; archive and native sidecar hashes preserved. |
| Post-fault local Open/return | Passed. | Passed. |
| Offline cold restart | Committed two-chapter cache and local three-page Open passed with the server stopped. | Same outcome. |
| Offline saved progress | Native page view resumed at page 2 of 3 after a further cold restart. | Not separately repeated in this review. |
| #53 cold start and Retry under a different endpoint | A-origin queued job failed under B; actual Downloads Retry failed again with original-server guidance. No new archive appeared; all three existing archive/sidecar files were byte-identical. | Earlier [#53 acceptance](issue-53-acceptance-2026-09-23.md) retained; not separately repeated today. |
| #53 restore original endpoint and Retry | Restoring A through Connection settings let actual Retry finish. Queue emptied, ledger retained A scope, all three PNGs matched A and differed from B, and the retried archive rendered and returned to its manga. | Earlier #53 acceptance retained. |

The fresh #53 desktop control used two real disposable servers with colliding manga/chapter IDs and different PNG content. Connection changes and Retry used normal UI actions. The pending A job was an explicitly injected saved-state precondition while KOReader was stopped; it establishes cold-start launch and explicit Retry behavior, not another live queue-admission or active-worker-transition run. Automatic retry, same-endpoint credential renewal, malformed/unknown origins, and Redownload retain the composed regressions and earlier targeted acceptance; they were not each repeated in this review.

The storage failures are injected at real KOReader I/O boundaries, not physical storage exhaustion or power-loss tests. USB routing and stopping an owned server do not establish physical Wi-Fi transitions or sleep/wake behavior. Those controls, power loss, and real storage exhaustion remain unverified here. Private settings, raw observations, screenshots, fixture archives, and backups stay outside Git.

Palma restoration was verified against fresh pre-test backups: all 671 settings files, all 98 original plugin files, the patches directory, reader settings and backup, and history matched. Original disabled-app state was restored; the reader was confirmed stopped. Task-owned USB routes, active profile instrumentation, and device fixture directory were removed after retaining private evidence. The device sandbox server and Windows relay were confirmed stopped.

Both desktop sandbox readers and both servers were also confirmed stopped. Synthetic sandboxes and private evidence are retained locally. The withdrawn speculative probe was preserved privately and its temporary worktree removed. At the initial handoff, the review documentation worktree was retained for later finalization.

Final review totals: **Standards: 0 findings. Specification/behavior: 0 confirmed findings.** Neither axis has an unresolved release blocker.

## Release preparation

Choose the next version, update metadata and the displayed version, and add `docs/releases/<tag>.md`. The release workflow checks that tag, metadata version, and release notes agree. Run required checks and exact-candidate CI again for that changed candidate before release. Finalizing this review integrates its documentation; release publication is a separate step.
