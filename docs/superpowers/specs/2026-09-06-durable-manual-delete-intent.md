# Durable archive-only deletion after manual mark-read

Published as [specification #12](https://github.com/LK4D4/suwayomi.koplugin/issues/12). Active scope follows the 2026-09-07 amendment to ADR-0003. Runtime implementation and device acceptance remain pending.

## Problem Statement

Deletion after manual mark-read can be lost when its immediate attempt fails: fallback cleanup depends on unrelated finish-retention settings. A chapter can remain marked read and downloaded indefinitely. Bulk removal before checked read persistence, live-reader gaps, and pathname-only recovery also risk inconsistent state or deletion of a later replacement.

This feature addresses manual deletion in [report #2](https://github.com/LK4D4/suwayomi.koplugin/issues/2). Download ownership, complete chapter retrieval, completion-triggered refill, and the unexplained crash remain separately owned work.

## Solution

Keep the existing single, selected, and previous-chapter mark-read actions. Save read state and accepted deletion requests before removing only their verified captured CBZ archives. The process service retries accepted work independently of finish retention, across navigation, zero subscribers, and restart. Preserve sidecars, backups, and all other metadata files.

If queued, running, stopping, or finalizing download work owns a chapter at admission, deletion is busy/not accepted. Preserve that work. Mark-read may still succeed; explain that deletion must be requested again after work finishes. Never promise eventual deletion for that unaccepted request.

## User Stories

1. As a reader, I want single and bulk actions to preserve selection, filtering, and completion order, so that only my intended chapters change.
2. As a reader, I want read success reported separately from removed, pending, busy, and blocked deletion, so that results match stored state and files.
3. As a reader, I want accepted deletion retried with retention off or on, through navigation and restart, so that temporary failure does not lose my request.
4. As a reader, I want existing download work preserved with a busy explanation, so that mark-read never cancels that work unexpectedly.
5. As a reader, I want only the captured archive removed and metadata retained, so that this action does not erase reading metadata or backups.
6. As a reader, I want live readers and uncertain targets protected, so that deletion waits or blocks safely.
7. As a reader, I want unread and a later accepted deliberate download to revoke remaining deletion, so that my later choice protects replacement work.
8. As a reader, I want failed, uncertain, duplicate, and automatic downloads unable to revoke accepted deletion, so that background work cannot silently undo my choice.
9. As a reader, I want setting and directory changes to preserve accepted requests and their original targets, so that neither loses or redirects deletion.
10. As a reader, I want an absent or unproved target to grant no future authority, so that a later archive is safe even at the same pathname with identical contents.
11. As a reader, I want quiet fair retries and current chapter status, so that one blocked chapter does not interrupt reading or stall others.
12. As a maintainer, I want composed public-action, real-file recovery, and separate device evidence, so that planning and simulated checks are not mistaken for completed behavior.

## Implementation Decisions

### Prerequisites and read ordering

Use ADR-0003 as amended, ADR-0001's coordination boundary and checked-persistence-before-removal amendment, and ADR-0002's process owner/store/ownership protocol. [#9](https://github.com/LK4D4/suwayomi.koplugin/issues/9) and [#10](https://github.com/LK4D4/suwayomi.koplugin/issues/10) must be integrated before implementation starts. Reuse their identity and ownership evidence; do not assume a closed planning ticket proves runtime integration.

Capture target identity and original managed root before refresh. Revalidate admission against current chapter ownership in the same serialized checked boundary as read state and accepted intent. Failed or uncertain persistence permits no removal or durable-success claim; reconcile uncertainty before any unsafe write. KOReader metadata writes and server sync are not a distributed transaction with plugin state.

For selected/previous batches, preserve visible order and scanlator/predecessor scope, clear selection before the full rebuild, and include non-target visible reconciliation in the checked ledger commit. No target's removal may precede that batch commit. Publish captured completions in order and schedule read-sync and the existing keep-next-unread policy through the established post-commit coordination. Single actions retain save-and-publish-before-refresh behavior and supplied-ledger safety. Preserve empty-input behavior and independent completion snapshots.

### Admission, revocation, and lifetime

| Event | Required result |
| --- | --- |
| New manual action with deletion enabled and a proved archive, no owning download work | Commit read state and exact request before removal; coalesce an unchanged pending target. |
| Queued/running/stopping/finalizing work owns the chapter | Busy/not accepted, no cancellation or future request; mark-read may succeed. Ask for another deletion action after work finishes. |
| Confirmed archive absence and no owning work | No deletion request or future entitlement; do not claim this action removed a file. |
| Original identity cannot be proved | Preserve files and report blocked without authority over a future file. Only retained original evidence may resolve the blocker; otherwise require a fresh authorized action. |
| Accepted request meets a live reader or transient inspection/removal failure | Retain request and retry after safe revalidation; a live reader does not turn accepted work into a busy rejection. |
| Durably observed unread | Revoke remaining manual deletion in the read-state transaction; preserve removed-file history, never restore files. |
| Later accepted deliberate Download or explicit Retry creating actual new work | Supersede old deletion in the same checked transaction as admission. Carry deliberate versus automatic provenance through single/bulk and ahead admission callers. |
| Failed/uncertain/duplicate/no-op admission or automatic refill/retry | Do not silently revoke, retarget, or race accepted deletion. Validate fences at admission, launch, and publication. |
| Disable manual deletion | Stop new requests; accepted requests continue. |
| Change retention or download directory | No change to manual lifetime or captured target/root. |
| Fresh manual action | May authorize a currently proved target; blocked historical records never silently acquire that authority. |

### Archive identity, removal, and recovery

Persist a versioned request identity/revision, chapter association, exact captured archive generation/path, original managed root, sufficient verified ownership evidence, archive-removal/bookkeeping progress, and retry deadline/reason. Retain identity beyond queue completion using the existing infrastructure, extending only what this contract needs. Preserve unrelated state, unknown versions, and records that cannot be safely interpreted; never normalize them to an empty collection.

Before each removal, revalidate current request revision, generation, file identity, resolved containment including aliases/symlinks, live-reader protection, and queued/running/stopping/finalizing ownership. Lookup must reflect current process-owned readers, not a retained retired UI. Pathname, timestamp, or content hash alone cannot establish replacement identity. A new publication is a new generation even when path and bytes match. Detected unexpected external changes stop affected deletion; uncoordinated concurrent external writers remain outside the coordinated-plugin guarantee.

This path unlinks only the verified CBZ. It does not remove sidecars, backups, directories, or other metadata files, including shared, recreated, or unassignable metadata. Existing mark-read metadata updates remain unchanged; archive-only removal means no metadata deletion, not suppression of read-state writes. Explain retained metadata. Retained metadata is not a retry obligation and cannot prevent resolved archive removal from completing.

Filesystem unlink and shared-store replacement are not atomic together. Persist authorization before unlink, then observed progress. Recover after archive removal but before progress/bookkeeping save using retained exact identity and current state. Confirmed absence can complete matching bookkeeping only; it grants no future authority. Never clear newer unread/read or pending-sync state, replacement path/generation, later queue jobs, or a newer reader-return context. Finalization and removal merge conditionally into current state rather than restore captured ledgers.

Reuse existing publication, ordinary Delete, and retention ownership evidence and conditional bookkeeping. Add only coordination needed to prevent competing removers, stale callbacks, or old records from deleting replacements or clearing newer state. Ordinary Delete keeps its own eligibility/retry policy. Retention keeps completion order, positions, and eligibility; removal invalidates only the captured generation's authority. Pathless completions remain pathless, including after later downloads. Preserve existing historical records and positions, but block removals whose original generation cannot be proved. No historical migration, library-wide scan, or historical manual authorization is inferred. Minimal targeted identity establishment is permitted only for an authorized current target under existing exclusive-owner and old-worker gates.

### Service and user-visible outcomes

Reuse the process service, checked shared store, and single total two-second shutdown deadline. Recover durable requests after owning startup; navigation and zero subscribers never discard or reinitialize them. Do not require a final save or future UI tick during shutdown.

Persist retries starting at five seconds, doubling to a five-minute cap, with no retry-count abandonment. Use bounded fair passes and useful lifecycle/ownership wakeups. Distinguish transient waits from identity/containment/unsupported-state blockers requiring evidence or a fresh authorized action; preserve files in both cases. One blocker must not stall other requests.

Use existing chapter status and one immediate single/batch summary. Report marked-read, removed, accepted pending, busy/not accepted, and blocked honestly, including mixed batches and failed/unconfirmed saves. Show why an archive remains and explain retained metadata; never equate read success with removal. Refresh from committed service state after transitions and on return, with a full rebuild when necessary. Background retries stay quiet. No dedicated Downloads management interface, pending-work screen, or new manual-deletion Retry/Cancel controls is required. Revocation uses existing unread and accepted deliberate-download actions; fresh manual actions may retry authorization without retargeting old requests.

## Testing Decisions

Use the existing public manual-action seam with the actual coordinator, service/queue, checked persistence, retention, filesystem adapters, chapter menu dispatch, and rendered outcomes. Observe read/pending-sync state, durable requests, actual file outcomes, ownership, selection, and UI together. Preserve prior manual-completion integration patterns; refresh counts and a mocked queue per view are insufficient.

- Exercise single/selected/previous and mixed batches, retention off and three, selection/filter/order, pathless completion, and non-target reconciliation.
- Prove busy rejection for queued/running/stopping/finalizing work leaves jobs intact and no accepted deletion, including just-published ownership. Finish work and require a new action before deletion; mark-read can succeed independently.
- Exercise live readers, zero subscribers, FileManager/ReaderUI and direct-reader navigation, restart, repeated failure, fair processing, and persisted retry deadlines.
- Inject failure/uncertainty before and after admission, archive unlink, progress save, supersession/revocation, and final bookkeeping. Test same-path/same-content replacements and newer read, sync, queue, and reader-return state.
- Test accepted deliberate supersession versus failed/uncertain/duplicate/automatic admission, unread, setting Off, directory changes, confirmed absence, and fresh actions on blocked targets.
- Compose publication, ordinary Delete, and retention with pending/manual-completed removal; preserve positions and block unproved historical targets without migration or new eligibility rules.
- Use real temporary files and the actual removal boundary for unlink/restart recovery, metadata/backup preservation, identity and containment/alias checks, and replacement safety. Reuse established OS ownership evidence; add focused actual-process checks only where changed coordination requires them. Mocked unlink is not physical proof.
- Run full LuaJIT tests, lint, localization, and required GitHub Actions for future implementation. Update architecture/user guidance when runtime behavior is implemented. Keep separate device acceptance for single/bulk actions, retention off/on, live readers, busy downloads, navigation/restart, transient retry, replacement downloads, retained metadata, and honest outcomes. Use test data and generic device wording; never publish raw logs, credentials, private paths, library data, or identifying device details.

## Deferred / Not Planned

The original #13–#20 plan is superseded, not implemented. The following original promises are removed from active acceptance: automatic cancellation of download work; manual removal of sidecars/backups and metadata manifests; dedicated Downloads pending-work management and new deletion Retry/Cancel controls; legacy adoption as a separate feature, historical migration, or library scans; and retention eligibility redesign. Only minimal targeted identity establishment and necessary coexistence coordination remain.

Complete chapter retrieval and durable completion-triggered refill remain separately owned. No server-side download mutations, restoration of deleted files, distributed transaction with KOReader/server, or universal guarantee against external filesystem writers is added. This revision performs planning only, with no runtime changes, deployment, or device results.

## Further Notes

The existing manual-deletion ticket map records exactly two current issues under #12 and the downstream dependency migration. Keep #12, both replacements, and original report #2 open. Acceptance remains separate from implementation; specification publication does not fix the feature.

Current implementation: [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36). Separate device acceptance: [#37: Verify reduced manual deletion on a device](https://github.com/LK4D4/suwayomi.koplugin/issues/37). Both are native sub-issues of #12 and remain open.
