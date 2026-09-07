---
status: accepted
date: 2026-09-06
---

# Preserve manual-delete intent independently of finish retention

## Amendment: reduced archive-only scope (2026-09-07)

This amendment supersedes the original choices below concerning captured-job cancellation, sidecar/backup removal and per-file manifests, dedicated Downloads management with Retry/Cancel controls, legacy adoption work, and broad retention integration. The original decision remains below as history, not active acceptance criteria. The revised [specification #12](../superpowers/specs/2026-09-06-durable-manual-delete-intent.md) is the single active contract; implementation and device acceptance remain pending.

- Keep existing single, selected, and previous-chapter mark-read selection, filtering, completion order, and read-sync coordination. Commit read state and accepted manual-delete requests through the checked shared store before any destructive work, preserving ADR-0001's ordering amendment.
- If queued, running, stopping, or finalizing download work owns the chapter at admission, preserve that work and report deletion as busy/not accepted. Mark-read may still succeed. The user must request deletion again after work finishes; an unaccepted request carries no eventual-deletion promise. There is no automatic cancellation or pending cancellation disposition.
- Accepted requests remove only the verified captured CBZ. Preserve all KOReader sidecars, backups, and other metadata files; explain retained metadata, which is not unfinished deletion work. Independent retention remains separate.
- Reuse the process service, checked shared store, ownership/identity infrastructure, and total two-second shutdown deadline. Keep durable, quiet retries across navigation, zero subscribers, and restart, with bounded fair processing and no retry-count abandonment. Persist enough archive-removal progress to recover after unlink but before bookkeeping.
- Revalidate exact archive generation, original managed root, containment, current request revision, live reader, and download ownership before removal. Preserve files when identity, ownership, containment, or persistence is uncertain. Pathname, timestamp, or content hash alone cannot establish replacement identity. Conditional recovery must preserve newer read/pending-sync, path/generation, queue, and reader-return state.
- Unread revokes remaining manual deletion. A later accepted deliberate download supersedes it in the same checked admission transaction; failed, uncertain, duplicate/no-op, or automatic admission cannot silently revoke it. Automatic work cannot race accepted deletion. Disabling manual deletion stops only new requests; directory changes never retarget accepted ones; confirmed absence grants no authority over future downloads.
- Use existing chapter status and immediate single/batch summaries for marked-read, removed, pending, busy, and blocked outcomes. No dedicated manual-deletion screen or new pending-deletion Retry/Cancel controls. Existing unread and deliberate-download actions supply revocation; a fresh manual action may authorize a currently proved target.
- Permit only minimal targeted identity establishment under existing ownership gates. No library scan, historical migration, or inferred historical authorization. Keep unproved original targets blocked. Limit publication, ordinary Delete, and retention changes to the identity/revision coordination needed to prevent stale removal or bookkeeping from harming replacements; retain completion positions, pathless eligibility, and retention policy.

The tradeoff is less automatic convenience and less reclaimed storage: busy deletion requires another action, metadata remains, and unproved targets may remain blocked. Durability and replacement safety are not reduced to a one-shot attempt. The [replacement ticket map](../superpowers/plans/2026-09-06-durable-manual-delete-tickets.md) assigns one implementation and one separate device-acceptance issue, including focused composed and real-filesystem evidence.

## Original decision (2026-09-06; superseded where amended above)

A manual mark-read action with deletion enabled creates its own durable removal request. The current fallback enrolls failures in while-reading cleanup, whose disabled state or retention positions can abandon that request. Keep manual-delete intent independent of retention, bind it to captured archive and job identities, and let the process-wide service recover it.

All 21 policy decisions below and the final shared-understanding review are confirmed. Implementation and acceptance testing remain pending.

## Scope and architectural relationships

This decision addresses section 4 of the [issue-2 investigation](../superpowers/audits/2026-09-06-issue-2-investigation.md#4-manual-mark-read-can-silently-abandon-a-failed-deletion): deletion after the plugin's single, selected, and previous-chapter mark-read actions. Preserve their existing target selection, scanlator filtering, completion order, read synchronization, and while-reading retention rules.

Build on [ADR-0002](0002-navigation-safe-download-ownership.md): one process owner, checked atomic shared settings, worker/attempt ownership, live UI subscriptions, and bounded shutdown. Its implementation remains pending. Manual-delete retry policy is additional work. Lasting archive generations extend its publication identity beyond completed-job bookkeeping.

Retain the coordination boundary from [ADR-0001](0001-manual-mark-read-coordination.md), but revise its destructive-action ordering: captured read-ledger changes and manual-delete intents must commit before cancellation or filesystem removal. Its original immediate-delete-before-bulk-save sequence cannot satisfy this decision.

## Request meaning and revocation

A manual-delete intent captures the local archive generation and queued/running jobs present at the action. Cancel that existing work, wait for proven worker shutdown, and remove only the captured targets. Never bind a request to whichever file appears later at the same chapter or path. If no archive or job exists and absence is confirmed, there is no future deletion entitlement.

| Later action or event | Effect on the manual-delete intent |
| --- | --- |
| Disable deletion after manual mark-read | Stop enrollment of new requests; accepted requests continue. |
| Change while-reading retention or disable it | No change to manual eligibility or retry lifetime. |
| Durably observe the chapter becoming unread | Revoke remaining manual removals. Do not resurrect removed files. |
| Accept a new deliberate download, including an explicit Retry that creates new work | Revoke the old manual request in the same checked transaction as admission. Failed or uncertain admission cannot silently revoke it. |
| Automatic refill, retry timer, stale callback, or duplicate/no-op enqueue | Cannot supersede or retarget the request. Revalidate deletion/cancellation state before launch or publication. |
| Cancel pending deletion | Stop remaining manual removals; preserve current read state. Do not restore removed files or restart already canceled downloads. Separate retention policy still applies. |
| Change download directory | Retain captured target and original managed root. Do not redirect the request to the new directory. |
| Retry pending deletion | Retry the original request after fresh validation; never acquire authority over a replacement archive. |
| Repeat a manual mark-read action | Capture current authorized targets again; coalesce an unchanged pending target without duplicating work. A new action can authorize a new verified generation. |

Distinguish deliberate download commands from automatic refill internally; current callers do not carry that distinction. A new command is accepted only when durable state changes, so a skipped/duplicate action is not an implicit cancellation control.

For a captured job that already published, ordinary cancellation still preserves the archive as required by ADR-0002. Finish ownership/finalization bookkeeping, then apply the separately authorized manual deletion to that exact generation. Revoking manual deletion does not revoke ownership-safe cleanup of canceled worker-private files.

## Service, state, and transaction boundaries

The process-wide service owns manual-delete scheduling, recovery, and snapshots with zero UI subscribers. Store a separately versioned manual-intent collection in the existing shared settings document. Reuse file inspection/removal helpers and live reader lookup; do not use a retention record or its setting as the manual request's scheduler or authorization.

Durable state must distinguish request identity/revision, captured archive generation, captured job/attempt identities, original managed root, authorized file targets, cancellation disposition, per-file progress, retry count/deadline, and blocked or retained-metadata outcomes. Completed archive identity outlives queue completion. Preserve unknown versions and unsupported records. Every writer and normalizer must preserve unrelated state and the new identity information.

Capture targets before refresh or another operation can change them. Commit local read-ledger changes, manual intents, and the captured jobs' stop/cancellation disposition together before acknowledging durable acceptance. Fence those jobs against new launches/publication immediately; deferred processing must not leave a window for them to restart. Reentrant or delayed work always checks current request revision and generation.

For batches, retain visible-order processing, selection clearing before the full rebuild, and reconciliation of non-target visible chapters before the shared ledger is committed. Replace the old immediate delete phase with target capture and durable admission. Publish completion records and schedule read-sync/refill in the established coordination boundary after the required commit. No unsafe file removal is allowed merely to preserve an immediate deletion count.

Preserve completion eligibility as an independent snapshot. A completion captured without an archive stays pathless and cannot acquire deletion eligibility from a later download. Removing a captured generation revokes authority over that generation without discarding its completion's retention position or transferring authority to a replacement.

The atomic boundary covers shared plugin state. KOReader metadata and server synchronization are not participants in a distributed transaction. A failed or uncertain shared save permits no download cancellation or removal and must not be reported as durable success, even if an earlier metadata write already changed a sidecar. Apply ADR-0002 reconciliation rules; never flush an old ledger over an uncertain committed transaction.

Filesystem removal is not atomic with settings replacement. Persist authorization before effects, then record observed progress. A crash after a removal but before its progress save must be recoverable from the same target identity and manifest. Once removal is complete, reconcile only matching archive/path bookkeeping against current state. Never clear newer unread state, a replacement ledger path/generation, a later queue job, or a newer reader-return context.

Download finalization must also merge into current read and pending-sync state rather than restore a captured ledger. Existing deletion helpers that clear paths or queue records by chapter key alone require generation-conditional bookkeeping before reuse.

## Archive and sidecar ownership

An archive generation identifies a particular published or explicitly adopted archive, even if a later archive has identical bytes and pathname. Content digests alone are not generation identity. Every plugin publication and removal path participates in generation bookkeeping, including ordinary Delete and finish-retention cleanup; their eligibility policies otherwise remain unchanged.

Adopt targeted legacy archives lazily under exclusive ownership and ADR-0002's old-worker safety gate. Verify the actual captured file and persist its generation before granting removal authority. Do not scan the library at startup, infer identity from filename alone, or reuse stale pathname-based hash caches. If capture cannot establish an original target, preserve a blocked outcome without authorizing deletion of a future file. A retry can use retained evidence; missing evidence requires a fresh authorized action.

Before each destructive step, validate current intent revision, generation, managed-root containment, relevant live reader ownership, and download ownership including terminating/finalizing work. Live-reader protection covers immediate/manual paths as well as deferred cleanup. Process-owned lookup must not retain a retired reader instance. Settings-directory changes do not invalidate the captured managed-root boundary or relax alias/symlink checks.

Persist exact approved metadata, backup, and archive targets before removal. Do not rediscover arbitrary metadata paths after the original archive disappears. Remove exclusively owned sidecars/backups before the archive, preserving enough durable evidence for recovery. A missing archive alone does not retire known unfinished sidecar or bookkeeping work.

KOReader hash metadata can be shared across archives and uses a pathname cache of a sampled content hash. Archive ownership therefore does not establish exclusive ownership of every resolved sidecar. Preserve shared or unassignable metadata and explain what was retained while removing the verified target archive. Temporary inspection failures remain pending/retryable; they are not evidence of safe sharing. Protect metadata currently owned by another live reader, even when its archive pathname differs. Unrelated directory contents remain untouched.

Use known archive and live-reader ownership to establish exclusive sidecar assignment. If that evidence is insufficient, preserve and report the metadata; do not scan the library or assume uniqueness from a hash/path. Captured sidecar paths still require revalidation because metadata can be recreated at the same location.

The guarantee covers coordinated plugin mutations. Detected unexpected external changes stop affected deletion; concurrent uncoordinated filesystem edits are outside this guarantee. Do not claim separate pathname inspection and later unlink provide universal protection against external writers.

## Retry, upgrade, and shutdown behavior

Persist retry deadlines using the existing cleanup timing: start at five seconds, double up to five minutes, and never abandon a request merely because its retry count is high. Use bounded fair passes and useful lifecycle/ownership wakeups. One blocked chapter cannot stall unrelated requests. Distinguish transient inspection/storage/ownership waits from identity or unsupported-version blockers requiring new evidence or user action.

Recovery continues across view changes, zero subscribers, and owning-process restarts. Respect the existing service's total two-second shutdown budget; do not add a second budget, require a final save, or depend on a future UI tick. Durable intent and worker ownership already establish restart obligations.

Create manual requests only from new actions. Old finished-cleanup records do not establish historical manual authorization. Preserve their retention positions and policy, but block deletion whenever their original archive generation cannot be proved. Never attach an old record to a new publication by matching pathname. A fresh authorized action can establish a new verified target.

Unknown journal/identity versions and failed migrations preserve records and files. No silent normalization to an empty intent collection, unchecked fallback, or PID/time-based ownership guess is permitted.

## User-visible outcomes

Successful read-state persistence and deletion are separate outcomes. Give one immediate single/batch summary that distinguishes marked-read chapters, pending/blocked removal, removed archives, and retained metadata. Do not claim an archive was deleted merely because the mark-read operation succeeded.

Show current pending work in Downloads and chapter views with waiting/error reason and Retry/Cancel controls. Background retries remain quiet. Views obtain fresh service snapshots, and actions revalidate the current request before acting. Full refresh after committed transitions prevents cached Downloaded indicators from hiding removal or pending state.

Cancellation reports partial physical progress accurately: removed sidecars or archives are not restored. Explain that canceling a manual request does not disable independent finish-retention cleanup. A removed archive with deliberately retained shared metadata is a reported resolved outcome, not an endless attempt to delete another archive's metadata.

## Required acceptance evidence

All three layers are required for future implementation; none is established by this ADR.

| Composed public-action case | Required observations together |
| --- | --- |
| Single, selected, and previous mark-read with retention off or three | Durable independent intent, read state, actual simulated file outcome, displayed status, preserved selection/order, and eventual retry convergence. |
| Zero views; FileManager–ReaderUI transitions; fresh process | Same outstanding requests, no UI-owned retry loss, current snapshot on return, and no navigation-triggered retargeting. |
| Live target reader or another reader sharing metadata | No removal of live-owned files; progress after ownership ends without relying on retired UI references. |
| Queued, running, terminating, or finalizing captured job | Durable cancellation first; proven release before removal; later jobs untouched; published generation follows finalization then explicit deletion. |
| Re-download at same path with identical contents | New generation and accepted command supersede old manual intent; stale callbacks, automatic retry/refill, old retention records, and bookkeeping cannot remove it. |
| Setting changes, directory changes, unread, explicit Cancel, repeated action | Exact chosen revocation/target rules, including no restoration of prior removals and no accidental retention exemption. |
| Known and unknown legacy records | Lazy verified adoption, no inferred historical manual intent, retained retention positions, and blocked unproved generations. |
| Failure or crash around admission and each sidecar/archive removal | No destructive action before durable admission; retained exact targets; idempotent progress/bookkeeping recovery; later read/path/job state preserved. |
| Shared, unassignable, missing, or unreadable metadata | Preserve shared/unassignable metadata with explicit outcome; retry transient inspection failures; known residual owned files do not disappear from intent. |
| Mixed batch, stale view action, blocked request, repeated failures | Honest aggregate outcomes, fair independent progress, quiet persisted retries, and revalidated controls. |

Use real temporary files and actual subprocesses to exercise the physical removal boundary, file identity checks, alias/symlink handling, metadata/backups, partial failures, surviving writers, and checked persistence/recovery on supported filesystems. Existing tests that stub file removal do not establish this layer. Verify actual device settings/download mounts and the relevant KOReader metadata behavior.

On a device, exercise manual deletion with retention off and three, single and bulk actions, a live chapter, reader transitions, zero-view progress, quit/relaunch, cancellation, and a later deliberate download. Check archive, metadata, read state, and UI together with test data. Do not damage storage to provoke failures. Share only redacted evidence using generic device wording.

Run the full suite, lint, localization checks, and required GitHub Actions before a separately authorized implementation merge. This decision does not authorize runtime edits, deployment, issue publication, branch switching, merging, or pushing.

## Evidence and trade-offs

Current manual deletion collapses rich deletion outcomes into a count and invokes a helper without the deferred cleanup processor's live-reader guard. Batch removal precedes the sole ledger save. Current journal/ledger records preserve path but not generation. These facts are traced in the section-4 investigation and the current read-actions, deletion, and finished-cleanup boundaries.

Pinned KOReader [DocSettings](https://github.com/koreader/koreader/blob/825b9bced0eb666b45af4208e1c0095b88d38b0d/frontend/docsettings.lua#L118-L145) and [partialMD5](https://github.com/koreader/koreader/blob/825b9bced0eb666b45af4208e1c0095b88d38b0d/frontend/util.lua#L1111-L1127) establish why hash sidecars need independent ownership checks.

Separate intent and generation records add persistence and migration work, but prevent retention settings, retired UIs, or later downloads from changing an accepted request's meaning. Deferring removal until checked admission changes immediate timing and failure reporting. Blocking unproved legacy identities favors preservation over immediate cleanup. Keeping shared metadata is deliberate: archive deletion must not remove another archive's reading state.
