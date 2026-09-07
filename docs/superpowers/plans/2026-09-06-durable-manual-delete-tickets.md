# Durable manual deletion: replacement ticket map

The 2026-09-07 amendment to [ADR-0003](../../adr/0003-durable-manual-delete-intent.md) reduces [specification #12](https://github.com/LK4D4/suwayomi.koplugin/issues/12) to durable archive-only removal. This map replaces the oversized #13–#20 plan. Runtime implementation and device acceptance remain pending.

## Current issues

Exactly two current native sub-issues belong to #12:

| Issue | Delivers | Blocked by |
| --- | --- | --- |
| [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36) | Complete reduced behavior with composed public-action and real-filesystem acceptance | #5, integrated before implementation starts |
| [#37: Verify reduced manual deletion on a device](https://github.com/LK4D4/suwayomi.koplugin/issues/37) | Separate device evidence for the integrated reduced feature | [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36) and #11 |

The implementation is fully specified (`ready-for-agent`) but blocked until prerequisites integrate. Device acceptance is `ready-for-human` and remains open. No feature result is established by publishing this map.

## Requirement ownership and supersession

| Superseded owner | Retained obligation in replacement implementation | Deferred / not planned |
| --- | --- | --- |
| #13 | Reuse and minimally extend archive identity across publication/removal and conditional current-state bookkeeping | Separate broad identity project |
| #14 | Minimal targeted identity establishment, containment/live-reader checks, blocked unproved originals | Legacy adoption feature, library scan/migration, metadata deletion/manifests |
| #15 | Checked single-action admission, durable archive request, existing chapter status and honest summary | Dedicated Downloads management and new deletion Retry/Cancel controls |
| #16 | Deliberate supersession, unread revocation, automatic-work fences, preservation of replacements | Automatic cancellation of existing downloads; busy work is not accepted for deletion |
| #17 | Quiet durable retry, zero subscribers, restart and unlink-before-bookkeeping recovery, shared shutdown deadline | Multi-file sidecar progress and metadata recovery obligations |
| #18 | Complete selected/previous actions with original coordination and honest mixed outcomes | Worker cancellation and metadata-removal batches |
| #19 | Necessary ordinary Delete/publication/retention coordination, unchanged positions and pathless eligibility, blocking unproved originals | Retention eligibility redesign and historical migration |
| #20 | Replacement device acceptance verifies retained feature and prerequisite ownership evidence | Device evidence for removed guarantees |

Revised #5 supplies only the process service, current-session known-worker tracking, and bounded quit, using #4's existing checked store. It does not supply archive-generation, publication, inherited-lock, or global legacy-proof infrastructure. #36 owns the minimal identity and conditional removal coordination its contract needs; unproved targets remain blocked. Superseded #9/#10 are not implemented prerequisites and must not expand #5.

## Dependency migration (manual-deletion history, updated ownership dependency)

Add replacement blockers before removing old blockers; preserve all unrelated edges.

| Consumer | Before | After | Required behavior supplied |
| --- | --- | --- | --- |
| #26 | #25, #16, #10 | #25, [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36), #5 | Checked manual admission, deliberate/automatic provenance, deletion fences; busy work is preserved, never canceled by mark-read |
| #28 | #27, #18 | #27, [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36) | Bulk checked read/intent coordination and unread revocation for refill enrollment |
| #30 | #28, #19 | #28, [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36) | Actual busy/archive-only outcomes, metadata retention, and required retention/identity coexistence; no eligibility redesign |
| #31 | #29, #30, #20 | #29, #30, [#37: Verify reduced manual deletion on a device](https://github.com/LK4D4/suwayomi.koplugin/issues/37) | Actual reduced-feature device evidence, including prerequisite #11 |

Refill scheduling remains owned by #26–#28; manual deletion preserves the existing policy boundary without implementing the new refill feature. #30 owns broader settings/help consistency. #31 owns combined audit controls and unresolved crash evidence. Their blockers remain genuine.

The original blockers were: #13 by #9; #14 by #13; #15 by #14; #16 by #15; #17 by #16/#10; #18 by #16; #19 by #15; and #20 by #17/#18/#19/#11. These become historical evidence only, with no active native edges left on superseded work. Original #13–#20 had no native parent relationships; the replacement pair gains native parent #12. Preserve original bodies/comments and completed-work evidence when closing still-open old issues as `not planned` and removing misleading `ready-for-agent` labels.

## Publication record

Pre-publication inspection found #13–#20 open, with no comments or completed acceptance checkboxes. Repository-wide issue bodies/comments, native incoming edges, and cross-reference timelines identified external consumers #26/#28/#30/#31 only. #22/#23 and ADR-0004 need semantic corrections, not new native blockers. Replacement issues did not already exist. Independent Astra High review found no scope or dependency gaps; its stale-publication-wording correction was applied before publication. Verify live bodies, labels, native parents/blockers, and closure reasons after mutations. Keep #12, replacements, #2, and unrelated issues open as applicable.

Original issue bodies and ADR history retain the superseded plan without representing it as implemented. The checked-in spec and this map carry current scope rather than another implementation tree.
