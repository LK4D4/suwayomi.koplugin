# C1 chapter publication runtime acceptance — 2026-09-23

The targeted C1 behavior is demonstrated in real KOReader on desktop and Boox Palma. The unfixed baseline reproduced the stale-screen defect; the candidate published successful server membership after the injected ledger failure. This record supplements, rather than substitutes for, the composed specs.

## Candidate and environments

- Baseline: `624af41204b5338c92d17b1a2ca2eb2380896b1a`.
- Candidate: `591cd2b6a24dd6a9ed537ad06d7ecfc5e263f0bb`.
- Desktop: actual KOReader **v2026.07.1**, Linux x86_64 under WSLg, fresh disposable profile.
- Device: connected **Boox Palma**, installed KOReader **v2026.03**, temporary isolated profile.
- Server: actual Suwayomi **v2.3.2243**, Basic Auth, generated Local source fixtures. Palma used USB reverse forwarding through a loopback-only Windows/WSL relay.
- Candidate payload: **98 files**, all hashes matched. The final archived device payload also matched all 98 staged files. Fault instrumentation lived exclusively in a private userpatch, outside the production plugin payload.

## Fault method

The server initially listed chapters 001/002/003. Moving the generated source archive for 003 aside and adding generated 004 made the real server return 001/002/004. Chapter 001 had already been downloaded and opened through the actual UI.

A private userpatch wrapped the real display/result-handler and action-preload/result-handler boundaries. Immediately before the measured call, it established committed fixture choices: pending read for 001 matching remote read, pending unread for 002 matching remote unread, and pending read for 004 opposing remote unread. It reset the fixture's native sidecar to unread as a deliberate precondition. This setup prevents unrelated synchronization timers from consuming the pending choices before the controlled attempt.

Within the unchanged result handler, instrumentation allowed the first checked write, verified that the new chapter cache had committed, and verified that the second attempted document cleared the matching pending acknowledgments. It then either:

- rejected that second write before replacement; or
- allowed replacement but rejected its directory synchronization, exercising the real store's uncertain-write fence.

Hooks were restored immediately after the handler. State was captured synchronously before returning to KOReader's event loop: committed document/ledger, published context and rows, error messages, native sidecar/archive bytes, reader-return records, refill snapshot, and fence state. This timing matters: normal scheduled reconciliation can resolve an uncertain transaction afterward. An eventual disk read is not evidence that the acknowledgment was confirmed at publication time.

Display used ordinary chapter UI → title menu → **Refresh chapters**. Cold action-preload used a private, visible fixture button dispatching the unchanged `confirmDownloadAllChaptersForManga` action with no current context. The real network worker, `withMangaChapterContext`, preload handler, and normal bulk confirmation ran. This was an instrumented entrypoint, not a claim that the shipping manga-information dialog exposes that cold bulk action. Every resulting confirmation was canceled; no bulk download was accepted.

## Observed results

| Control | Observation |
| --- | --- |
| Baseline desktop, display, second-write rejection | Reproduced C1: cache contained 001/002/004, screen/context retained 001/002/003, handler returned false, and ledger error was displayed. |
| Candidate desktop, same display fault | Screen/context contained 001/002/004; 003 disappeared; handler returned true and error was reported. |
| Candidate Palma, display, rejection | New membership/order displayed; committed pending choices survived; error reported. Screenshot visually inspected. |
| Candidate Palma, cold action preload, rejection | New membership/order installed in context; normal two-chapter bulk confirmation appeared; pending choices survived. Confirmation canceled. |
| Candidate Palma, display, uncertain write | New membership/order displayed; confirmed pending choices survived at publication; store fence active immediately afterward. |
| Candidate Palma, cold action preload, uncertain write | New membership/order installed; normal confirmation appeared; confirmed pending choices survived at publication; store fence active. Confirmation canceled. |
| Desktop and Palma normal download/Open/return | Actual downloaded archive's three PNG pages matched source bytes; KOReader rendered three pages and returned through **Go to Suwayomi**. |
| Desktop and Palma Open after rejected display write | Existing downloaded fixture opened and rendered three pages; normal reader return succeeded. Screenshots inspected. |

Each of the four Palma fault cases recorded exactly **two checked write attempts**. The cache had committed before the failed ledger write. Immediately after publication, the confirmed document equaled the document after the cache commit: ledger/pending choices, reader-return records, refill state, and other settings were unchanged. Recorded archive and native sidecar bytes were also unchanged during fallback publication. Rows preserved pending read/unread, including the pending read opposing remote unread.

The private display-probe SHA-256 was `17727a137fbad45c8617786424e77c83097bd7d282b4aecd62e6fcdfcda6849e`. The later probe adding the cold-action fixture button was `2947d009661e237db3e3b0f95a931e60cfc5eda2cc39584904d332e17b107794`. Both were outside the runtime payload.

## Restoration and evidence limits

The original Palma profile was preserved by directory rename while KOReader was stopped. After testing, normal KOReader quit completed, the original profile was restored, and **1,220/1,220 original file hashes matched**, with zero mismatches. The original disabled/stopped package state was restored. The temporary device profile and task-owned USB routes were removed. The Windows relay and owned desktop reader/server were stopped and checked.

Private JSON observations, screenshots, deployment manifests, probe scripts, device evidence archive, and hash audits remain outside tracked files in the task's ignored evidence directory and disposable desktop sandbox. No credentials, raw settings, personal paths, or device identifiers are included in this record.

These checks establish the targeted publication behavior with real widgets, network workers, storage, reader transitions, and Android execution. They do not establish physical Wi-Fi transitions, sleep/wake behavior, other devices/versions, or TLS certificate verification. Immediate uncertain fencing was observed; confirmation acceptance under that fence remains covered by composed specs, not by an accepted device queue operation. Successful empty responses, stale-context controls, and first-cache-write failure retain their automated coverage and were not separately repeated on hardware here. The separate later menu-reconciliation failure path was not changed or tested by this C1 acceptance.

Before runtime acceptance, the candidate passed **1,627 LuaJIT specs**, full lint, localization checks, and independent Standards/Spec review with no actionable findings. This follow-up changed no runtime code. No push, merge, release, or new GitHub Actions run was performed.
