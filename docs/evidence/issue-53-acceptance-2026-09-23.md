# Issue #53 verification

Verified on 2026-09-23. Runtime candidate: `3345b95`; earlier queue controls ran on `829bd50`, whose runtime differs only by the subsequent empty-action dialog repair. Final deployment on both targets matched all 98 staged runtime files by SHA-256.

## Environments

- Desktop: WSLg, KOReader v2026.07.1, Suwayomi v2.3.2243, Basic Auth.
- Device: Boox Palma, KOReader v2026.03, the same disposable server version, USB reverse forwarding through a loopback relay.
- Each target used fresh synthetic A/B servers with colliding manga/chapter IDs and titles, but different PNG bytes. Inspector controls operated the real UI; the inspector patch stayed outside the runtime payload.

## Demonstrated behavior

| Control | Desktop | Palma |
| --- | --- | --- |
| Download, Open, Go to Suwayomi | Archive rendered and returned to its manga. | Archive rendered and returned to its manga. |
| Suspend owned A server; queue active and pending downloads; save B through connection UI; resume A | Active attempt finished from A; pending job failed with restore-original-server guidance. | Same outcome. |
| Actual Downloads Retry while B remains selected | Failed again without changing origin or downloading B pages. | Same outcome. |
| Cold reader restart with original A job restored to queued in saved test settings | Failed safely under B. | Final candidate failed safely under B; existing archives and sidecar were byte-identical. |
| Restore A through connection UI, then Retry | Succeeded with A pages and ledger origin. | Final candidate succeeded; all three archives contained A's three PNG pages. Existing two archives and sidecar remained byte-identical. |
| Wrong password, then corrected credentials at the same endpoint | Actual UI failure followed by successful Retry using corrected credentials. | Not separately repeated. |
| Persisted A repair job under B | Final candidate blocked cold boot and actual Retry; all four existing archives and sidecars unchanged. Restoring A allowed repair; replacement PNGs matched A. | Not separately repeated. |
| Foreign downloaded chapter with no eligible local actions | Prior crash reproduced on candidate and baseline `d5b36ce`. Final candidate displayed the existing not-downloaded message and remained alive. | Final candidate displayed the message and remained alive; screenshot inspected. |

The final retried Palma chapter rendered in the reader and returned to the correct manga through **Go to Suwayomi**. Source-page comparison independently verified bytes; successful tap acknowledgments alone were not treated as rendering evidence.

## Evidence limits

Cold-restart queued jobs and the desktop repair job were explicitly injected saved-state preconditions while the reader was stopped. The repair control did not enqueue through a live Redownload button. Unknown-origin, malformed identity, automatic retry, and bulk readmission boundaries have deterministic regressions; they were not each repeated on hardware. USB routing does not establish physical Wi-Fi, sleep/wake, or power-loss behavior.

Final repository checks: 1,645 LuaJIT specs passed; luacheck reported zero warnings/errors across 173 files; localization checks passed. Independent Standards and Spec reviews completed, with targeted review of subsequent repairs. These checks do not substitute for the runtime observations above. No GitHub CI or merge was requested for this verification follow-up.

## Cleanup

Both desktop servers/readers and both device test servers were stopped. The temporary relay and USB routes were removed. The original Palma profile was restored: all 1,220 file hashes matched, with zero mismatches. Its original disabled app state was restored. Synthetic profiles and private evidence were retained outside the repository; no settings, credentials, raw logs, archives, or personal content are committed here.
