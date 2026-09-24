# Issue #51 chapter-cache desktop evidence — 2026-09-18

The disposable WSLg run used KOReader v2026.07.1, Suwayomi v2.3.2243, Basic Auth, baseline `1425ec6`, and the `feat/offline-chapter-cache` candidate. Raw settings, source fixtures, deployment manifests, screenshots, and observations stay outside the checkout. This is desktop evidence, not Android acceptance.

| Control | Observed outcome |
| --- | --- |
| Baseline download/Open/return | All three downloaded PNGs matched the generated source pages. |
| Offline reading and restart | Native page 2 resumed after cold restart; page 3 remained `reading` at 100%, with the archive retained. |
| Legacy reconstruction | With and without Library cache, incomplete unassociated metadata exposed the recorded file; Open/return left its scope unknown and created no pending sync. |
| Delayed server | Cached Library/chapter selection reached the visible local page while the owned server was suspended. The initial inspector rebind crash was repaired by listener handoff and the same reproduction then passed. |
| Real chapter removal | One removed source chapter disappeared from the normal list; its device archive and progress hashes were unchanged. Real source-empty failure retained the last complete list. |
| Injected complete empty | Both successful empty response envelopes reached the real reader/worker/storage path. The explicit empty screen survived offline cold restart despite retained downloads; ordinary reconnection restored current server membership. |
| Existing actions | Offline read choice persisted, Sync changed server read state, unread restored it, and confirmed deletion removed only the spare device archive. |
| Review-repair controls | Existing scanlator controls exposed an unassociated file without changing its saved filter; current-scoped missing-ID Open/return preserved scope without inventing IDs; newer Library title/membership won over injected stale chapter-cache metadata. |
