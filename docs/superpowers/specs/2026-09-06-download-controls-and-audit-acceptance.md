# clear download controls and issue-2 acceptance

Published as [GitHub issue #23](https://github.com/LK4D4/suwayomi.koplugin/issues/23), labeled ready-for-agent. Accepted for autonomous planning; implementation remains pending.

## Problem Statement

Download controls conceal important limits and selection rules. “Download all” can promise every chapter while admitting at most 50 new downloads. Download next and Download ahead count different things, and “third to last read chapter” suggests chapter-list position rather than recorded completion order. These ambiguities make working behavior look broken and complicate verification of the defects in [issue #2](https://github.com/LK4D4/suwayomi.koplugin/issues/2).

The audit also found previously repaired behavior and an unproved crash report. A passing synthetic test or eventual download completion does not establish device lifecycle correctness or a crash cause. This specification covers section 5 and the remaining evidence/acceptance work; sections 1–4 have separate feature specifications.

## Solution

Keep existing batch limits and retention values, but describe their effects before the user acts. Show honest eligible, admitted, skipped, and capped outcomes. Use one consistent explanation of next-download selection, the ahead buffer, manual deletion, and finish retention.

Complete a focused acceptance matrix across ordinary loading, source refresh, continuous reading, download ownership, cleanup, and failure handling. Record whether each result is demonstrated, failed, or unverified. Treat an application crash as a separate evidence question unless a reproduction establishes its cause.

## User Stories

1. As a reader, I want a bulk action to disclose its 50-new-download limit before confirmation, so that its promise matches what it can queue.
2. As a reader, I want downloaded and queued chapters excluded before the cap is applied, so that they do not waste new-download capacity.
3. As a reader, I want all-unread and all-chapter actions to identify their selection scope, so that I know whether read chapters are included.
4. As a reader, I want confirmation to show eligible new downloads and any remaining capped count, so that I can decide whether to continue.
5. As a reader, I want changing queue state while a dialog is open to be revalidated, so that stale counts cannot cause duplicate or extra downloads.
6. As a reader, I want final summaries to show actual admissions and failures, so that a failed save is never reported as a queued download.
7. As a reader, I want another explicit batch action to reach remaining eligible chapters, so that a cap does not make them inaccessible.
8. As a reader, I want Download next N explained as N additional eligible unread chapters, so that I do not confuse it with a buffer.
9. As a reader, I want Download ahead N explained as the earliest N unread positions, so that existing queued/downloaded entries visibly consume positions.
10. As a reader, I want both selectors to respect complete chapter order and my saved scanlator filter, so that they agree across entry points.
11. As a reader, I want missing saved-filter matches explained without silently selecting other scanlators, so that downloads stay within my choice.
12. As a reader, I want the supported refill triggers and Stop download ahead behavior explained, so that I can predict automatic work.
13. As a reader, I want terminal failures to remain inspectable until explicit retry, so that automatic refill does not conceal errors.
14. As a reader, I want retention choices expressed as keeping zero through four newest completions, so that I can understand what values one through five mean.
15. As a reader, I want reader completion distinguished from merely reaching the final page, so that I know when cleanup and refill are eligible.
16. As a reader, I want manual-delete requests distinguished from finish retention, so that disabling one setting does not appear to revoke the other.
17. As a reader, I want per-manga completion order and pathless completion behavior explained, so that historical read chapters are not mistaken for deletion candidates.
18. As a reader, I want localized menus and help to use the same semantics, so that behavior does not depend on entry point or language.
19. As a maintainer, I want the audit's contrasting device workflows recorded with reproducible preconditions, so that a favorable workflow cannot hide a failing one.
20. As a maintainer, I want prior transient-retry and archive-fallback repairs preserved, so that planning does not reintroduce or misattribute old bugs.
21. As a maintainer, I want application exits distinguished from child-download failures, so that crash claims reflect evidence.
22. As a contributor, I want a redacted evidence checklist using generic device wording, so that troubleshooting does not expose personal data.
23. As a maintainer, I want revision and payload provenance recorded independently of the displayed version, so that two installations with the same version label are not assumed identical.
24. As a maintainer, I want incomplete device evidence marked unverified, so that specification and ticket completion are not mistaken for runtime acceptance.

## Implementation Decisions

### Bounded bulk actions

Keep the maximum of 50 newly admitted chapter downloads per explicit action. Do not add a background “download everything” plan, another queue, a new limit setting, or automatic continuation. Existing all-chapter/all-unread actions continue selecting their corresponding filtered scopes; change their visible labels to disclose the limit, for example “Download all chapters (up to 50 new)” and “Download all unread (up to 50 new)”.

Compute candidate eligibility before counting the cap. Reuse the queue admission rules and downloaded-file checks rather than introducing a UI-only notion of availability. Existing downloaded, queued, running, stopping, or finalizing work cannot be admitted twice. Retain explicit retry behavior and the manual-delete supersession contract from specification #12.

Confirmation describes at most 50 new admissions from the captured candidate identities, the count already unavailable for admission, and how many eligible candidates remain outside this batch. A zero-candidate action reports its reason without a misleading confirmation. Selected and next-N actions must disclose the same cap whenever it limits their candidates. Do not require a new confirmation for existing small actions solely for consistency.

On confirmation, revalidate only the captured candidates against current state. Do not broaden to unrelated chapters, another manga, or another filter because the old view changed. Accept fewer if eligibility changed; a new action can recompute remaining candidates. Show actual queued, skipped, capped, and failed/unconfirmed results after checked admission. Never derive “Queued 50” from the configured cap. Preserve selection clearing and menu behavior unless the operation was rejected before acceptance.

### Selection and setting explanations

Use short in-context descriptions and fuller help with concrete examples. Keep numeric storage values and action identities compatible; this is not a retention migration.

| Control | Required explanation |
| --- | --- |
| Download next N | Add up to N eligible unread downloads in normalized source order after the saved scanlator filter. Skip existing local files and owned queue work. The current reader page is not an anchor. |
| Download ahead N | Fill missing downloads among the earliest N filtered unread positions. Queued/downloaded positions count; terminal failures remain visible and require explicit Retry. Reader completion on close, manual read/unread and reconciliation, successful context load/return/refresh, and policy changes request recomputation under the refill specification. Snapshot repaint does not. |
| Stop download ahead | Stop pending/future automatic refill for this manga. Already accepted chapter jobs remain; use download cancellation separately. |
| Cancel download | Cancel that job and retire its manga's outstanding refill evaluation atomically. It does not disable the ahead policy; a later qualifying event can select the missing chapter again. Cancel all also retires all outstanding evaluations; cancellation cannot immediately refill itself. |
| Delete after manual mark-read | New plugin single/selected/previous mark-read actions create independent durable removal requests. Accepted requests continue if this setting is switched off; unread, explicit cancel, and later accepted deliberate downloads follow specification #12. |
| Finish retention values 1–5 | Keep the newest 0–4 recorded completions per manga. Value 0 is disabled. Use labels such as “Keep 2 newest completions”, not ordinal chapter-list positions. |
| Reader completion | Completed document status plus close, including direct reader-to-reader navigation. A final page/100 percent alone is not this trigger. A live-owned archive remains protected. |
| Completion enrollment | Plugin manual completions also count; ordinary historical/server read state does not retroactively authorize deletion. Pathless completions can occupy retention positions without gaining authority over a later archive. |

Include examples: ahead five with two existing downloads queues only three missing positions; next five can queue five additional chapters farther ahead. With retention value three and eligible completions A, B, C in order, A becomes removable after C while B and C remain, subject to live-reader and ownership safety. Keep help accurate for the separately implemented durable refill/manual-delete changes and the missing-scanlator behavior.

All new plugin-authored strings use existing localization boundaries. Update source catalogs/template as required by the repository's workflow; do not invent translations or expose implementation details in normal UI explanations.

### Evidence and release acceptance

Use the existing highest-level public action/lifecycle seams, supported by physical filesystem/process checks already specified for ownership and deletion. Add a single focused audit acceptance record that links the feature results and identifies what remains unverified, rather than duplicating every feature's test report.

Required controls:

1. More than 200 stored chapters, unread candidates beyond page one: ordinary reopening and explicit source refresh show identical normalized chapter identities/order and next/ahead candidates. Include saved filter and tied order values.
2. Ahead five, at least six eligible unread chapters: compare plugin-list return with KOReader Open next file and reader-to-reader transitions without a plugin screen. Both queue the new missing position after durable completion. Repeat offline then reconnect, and quit/relaunch with pending refill.
3. Ownership: reuse the Downloads-only versus reader-navigation control, concurrency two then one, worker/attempt continuity, zero-view completion, and bounded shutdown results from the ownership acceptance ticket.
4. Cleanup: reuse manual deletion with retention off and three; independent retention three over A/B/C with restart between B and C; retention one while still live then after close; final-page-without-completed-status negative control. Inspect archives, owned/retained metadata, ledger, and visible rows together.
5. Downloads: preserve durable transient retries, quiet background failures, terminal-error details, and HTTP 400/404 archive-to-page fallback. The repaired later HTTP 400 regression cannot be asserted as the original September 1 crash cause.
6. UI: compare promised versus accepted batches with more than 50 eligible chapters and concurrent queue changes; inspect compact and translated layouts on a device.

For suspected crashes, distinguish KOReader disappearing/restarting from a failed download row or exited child. Record a timestamp, plugin revision and validated runtime-payload extent, KOReader version, generic operating environment, batch size, chapter-worker concurrency, navigation sequence, storage availability category, and sleep/network transitions. Use consistent anonymous source aliases and a minimal relevant redacted crash/log interval. Never commit raw logs or downloaded test content.

Before any evidence leaves the device, remove credentials, tokens, headers, server endpoints, filesystem paths, personal library/source names, manga/chapter titles, and identifying device model/manufacturer. Do not introduce telemetry, automatic log uploads, or a new diagnostics service. Use synthetic fixtures and existing redaction helpers. If full payload provenance was not checked, state which extent was verified without claiming more.

An unreproduced crash remains unresolved. The acceptance record may conclude “no application exit observed under these controls”; it must not say the original crash was fixed. Creating any follow-up bug or contacting the original reporter requires a separately authorized action. This planning task does not close or modify the original report.

## Testing Decisions

Test public menus/actions through actual candidate selection and queue acceptance, then assert the rendered confirmation/result plus committed state. Cover 0, 1, 49, 50, 51, and larger eligible batches; mixed read/downloaded/queued/failed candidates; stale confirmations; canceled confirmation; and failed/uncertain persistence. Prior art is the composed download-failure UX fixture and chapter/manga action and menu specifications.

Test retention labels for all six persisted values and one shared mapping across settings summary and picker. Test localized interpolation/plurals through existing i18n seams. Preserve prior cleanup behavior tests and add only missing cases; refresh-call counts alone are insufficient.

Run the full LuaJIT suite, lint, and localization checks for implementation changes, plus repository-required GitHub Actions before a separately authorized merge. Device execution and real-process evidence are implementation acceptance work; writing this specification proves none of them.

## Out of Scope

Changing the 50-download cap, downloading every remaining chapter automatically, adding new retention values, changing read-sync conflict policy, reopening historical bugs already repaired, proving a crash cause from source inspection, introducing telemetry, or implementing/deploying runtime changes in this planning task.

## Further Notes

This specification covers the remaining semantics and evidence sections of the September 6 issue-2 investigation. Ownership specification #3 and manual-deletion specification #12 remain authoritative for their accepted safety decisions. The [complete-retrieval specification #21](https://github.com/LK4D4/suwayomi.koplugin/issues/21) and [durable-refill specification #22](https://github.com/LK4D4/suwayomi.koplugin/issues/22) define the new selection/trigger behavior summarized here.

The user authorized autonomous planning and publication, choosing simplicity without further questions. Local ADRs and the audit are not pushed; the public specification intentionally contains the required behavior and acceptance contract without depending on unpublished links.
