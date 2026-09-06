# Durable manual deletion after mark-read

Published as [GitHub issue #12](https://github.com/LK4D4/suwayomi.koplugin/issues/12), labeled ready-for-agent. Publication does not implement the feature or publish the local work branch.

## Problem Statement

When deletion after manual mark-read is enabled, a chapter can become read while its archive remains on the device indefinitely. Immediate deletion failures are reduced to a count, and fallback recovery depends on a different setting: while-reading cleanup. Disabling that setting loses the request; retaining several completed chapters can keep a failed manual deletion ineligible indefinitely.

The current immediate path also lacks the deferred processor's live-reader protection, and bulk actions can remove files before saving their read ledger. Existing chapter/path records cannot distinguish an old archive from a later replacement at the same pathname. A retry that simply repeats deletion by chapter or filename would risk deleting new work.

This specification addresses section 4 of [issue #2](https://github.com/LK4D4/suwayomi.koplugin/issues/2). Navigation-safe download ownership has its own [specification #3](https://github.com/LK4D4/suwayomi.koplugin/issues/3). The original report's other defects and unexplained application crashes remain separate work.

## Solution

Treat deletion requested by a manual mark-read action as durable work with its own lifetime. Save read-ledger changes and captured deletion intent before canceling downloads or removing files. Let the process-wide service retry that work across screen transitions and restarts, independently of while-reading retention.

Bind each request to the archive generation and jobs present when the action occurs. Respect live readers and workers, preserve replacement archives and shared metadata, and let later explicit actions revoke the old request. Show read-state success separately from pending, blocked, completed, or partially resolved deletion. Preserve existing chapter selection, read synchronization, and retention policy.

## User Stories

1. As a reader, I want failed manual deletion to survive navigation and restart, so that temporary failure does not silently abandon my request.
2. As a reader, I want deletion after manual mark-read to work with while-reading cleanup disabled, so that unrelated retention settings do not suppress explicit deletion.
3. As a reader, I want manual deletion to remain eligible when while-reading retention keeps several completions, so that retention positions do not indefinitely postpone my request.
4. As a reader, I want single-chapter mark-read to create the same durable deletion obligation as bulk actions, so that behavior does not depend on which action I choose.
5. As a reader, I want selected-chapter mark-read to preserve selection scope and visible order, so that only the chapters I selected are affected.
6. As a reader, I want previous-chapter mark-read to preserve its existing filtered predecessor selection, so that this repair does not expand which chapters become read or deleted.
7. As a reader, I want read changes and deletion requests saved before download cancellation or removal, so that a crash cannot leave destructive work without recoverable authorization.
8. As a reader, I want mark-read success and deletion progress reported separately, so that I know whether read state saved and whether the archive still exists.
9. As a reader, I want a clear failure when shared persistence fails or its outcome is uncertain, so that the interface does not claim durable acceptance that cannot be established.
10. As a reader, I want jobs already present when I mark a chapter read to be canceled safely, so that unwanted work stops without removing files still owned by a worker.
11. As a reader, I want a published captured job to finish its bookkeeping before manual deletion, so that finalization does not race with removal or overwrite newer read state.
12. As a reader, I want ordinary download Cancel to retain its existing published-archive behavior, so that adding manual deletion does not change what that separate command means.
13. As a reader, I want each deletion request bound to its captured archive generation, so that an old request cannot delete a later archive at the same path.
14. As a reader, I want identical-content replacements treated as new archive generations, so that matching bytes cannot accidentally authorize an old deletion.
15. As a reader, I want a newly accepted deliberate download to supersede an older manual deletion, so that I can change my mind without the old request removing new work.
16. As a reader, I want failed, uncertain, or duplicate download commands to leave existing deletion intent intact, so that an unaccepted command does not silently cancel it.
17. As a reader, I want automatic refills and scheduled retries unable to override pending deletion, so that background work cannot undo my explicit choice.
18. As a reader, I want marking a chapter unread to revoke remaining manual deletion, so that changing its read state preserves files not yet removed.
19. As a reader, I want Cancel pending deletion to stop remaining manual removals, so that I can revoke the request without changing read state or restarting canceled jobs.
20. As a reader, I want cancellation to explain completed removals and independent retention policy, so that I do not expect restored files or a retention exemption that was not granted.
21. As a reader, I want Retry pending deletion to retry only its original targets, so that retrying cannot silently authorize deletion of a replacement.
22. As a reader, I want repeated manual actions on an unchanged target to coalesce, so that repetition does not create competing deletion jobs.
23. As a reader, I want disabling manual deletion to stop new enrollment while accepted requests continue, so that changing the setting does not erase already requested work.
24. As a reader, I want changing download directory to preserve each request's original target, so that cleanup does not move to an unrelated file in the new directory.
25. As a reader, I want an action with no existing archive or job to grant no future deletion authority, so that a later download is not enrolled by an earlier empty action.
26. As a reader, I want live archive and metadata ownership respected, so that manual deletion cannot damage a document still in use.
27. As a reader, I want shared or unassignable sidecars preserved with a clear retained-metadata outcome, so that deleting one archive cannot erase another archive's reading state.
28. As a reader, I want temporary inspection failures distinguished from missing or shared files, so that uncertainty does not cause unsafe deletion or false completion.
29. As a reader, I want partially completed removal to resume from durable exact targets, so that crashes do not lose remaining sidecar or bookkeeping work.
30. As a reader, I want completed deletion bookkeeping to preserve newer read, queue, and archive state, so that recovery cannot overwrite actions taken after the original request.
31. As a reader, I want persisted retries with bounded backoff and no retry-count abandonment, so that transient failures eventually converge without busy background work.
32. As a reader, I want one blocked request to leave unrelated cleanup progressing, so that a difficult chapter does not stall the rest.
33. As a reader, I want pending work visible in Downloads and chapter views with reasons and Retry/Cancel controls, so that I can inspect and manage it after the initiating screen closes.
34. As a reader, I want one immediate action summary and quiet background retries, so that bulk cleanup remains understandable without interrupting reading repeatedly.
35. As a reader, I want deletion to continue with no plugin view open, so that a screen is not required to finish accepted work.
36. As a reader, I want quit and restart to preserve pending deletion within the existing service shutdown budget, so that cleanup neither delays exit indefinitely nor loses its obligations.
37. As a reader upgrading the plugin, I want legacy archive identity established lazily and safely, so that the plugin does not scan my library or guess which file an old request owns.
38. As a reader upgrading the plugin, I want old retention records preserved without invented manual-delete authorization, so that current settings cannot retroactively authorize historical deletions.
39. As a reader, I want unproved legacy target generations to block removal while preserving retention positions, so that an old record cannot attach itself to a newer same-path archive.
40. As a reader, I want unknown persisted versions and failed migrations preserved, so that incompatible state is not silently discarded.
41. As a reader, I want all plugin publication and removal paths to coordinate archive identity, so that ordinary Delete or retention cleanup cannot bypass replacement protection.
42. As a reader, I want detected external changes to stop affected deletion, so that unexpected files are preserved within the supported ownership model.
43. As a maintainer, I want public-action tests covering files, durable state, workers, and rendered outcomes together, so that isolated mocks cannot hide lifecycle or reporting failures.
44. As a maintainer, I want real filesystem and process tests for physical ownership guarantees, so that simulations are not mistaken for proof of safe removal.
45. As a maintainer, I want device acceptance of the navigation and restart workflows, so that automated coverage is checked against actual host behavior.
46. As a maintainer, I want shared diagnostics to exclude user and library data, so that failures can be investigated without exposing personal information.

## Implementation Decisions

### Architectural authority and prerequisites

Accepted ADR-0003, “Preserve manual-delete intent independently of finish retention,” is the architectural authority. ADR-0001 keeps manual single/bulk coordination in the chapter read-actions boundary; ADR-0003 explicitly replaces its destructive delete-before-save sequence. Preserve the existing selection rules, visible completion order, pathless completion protection, and reconciliation of non-target visible chapters.

Build on the service, checked shared store, process exclusion, attempt locks, parent-only publication, generation-aware callbacks, and bounded shutdown defined by spec #3 and ADR-0002. Those are prerequisite behaviors, not established runtime facts. This specification extends publication identity into durable archive generations that survive completed-job bookkeeping. Do not substitute the current per-UI queue or unchecked settings writes.

The accepted ADRs are local and unpublished at the time of this specification. The contracts below are self-contained; implementation must not depend on inaccessible repository links. Neither parent issue is edited or closed by publishing this spec.

### Domain and module responsibilities

A **manual-delete intent** is an outstanding request from a plugin manual mark-read action to remove the captured local archive and cancel work already present at that action. Its eligibility is independent of while-reading retention and never transfers to a later deliberate download.

An **archive generation** is a particular published or explicitly adopted local chapter archive. A later publication is a new generation even if chapter, pathname, and contents are identical. Chapter identity, pathname, and content digest are not substitutes for generation identity.

- The chapter read-actions coordinator owns single, selected, and previous-chapter operation scope, captured targets, read-ledger changes, and batch coordination. It submits durable manual-delete work rather than performing unjournaled deletion.
- The process-wide service owns intent admission, current revisions, job cancellation fences, scheduling, recovery, and snapshots with zero UI subscribers.
- The checked shared store persists a separately versioned manual-intent collection and lasting archive identity information while preserving unrelated settings. Every normalizer and writer must preserve that information, including ledger reconstruction and reconciliation.
- Archive publication and every removal path cooperate with generation bookkeeping. Ordinary Delete and finish-retention cleanup gain the same identity safeguards; their eligibility policies remain otherwise unchanged.
- File inspection/removal adapters verify captured archive, sidecar, managed-root, reader, and worker ownership. Existing helpers that clear paths or jobs by chapter key alone cannot be reused unchanged.
- Downloads and chapter views render service snapshots and submit commands. Retired views cannot own retries, durable completion, or bookkeeping.

### Public command and outcome contracts

| Operation | Required contract |
| --- | --- |
| Manual mark-read with deletion enabled | Capture current archive generation and existing job/attempt identities. Admit read-ledger changes, manual intent, and stop/cancellation disposition together. Confirmed absence of both archive and job grants no future deletion entitlement. |
| Manual mark-read with deletion disabled | Preserve read behavior without enrolling new manual-delete work. Existing accepted intents continue. |
| Single, selected, and previous actions | Preserve current target selection and ordering. Capture independent targets before refresh. Report accepted read changes separately from deletion outcomes. |
| Accept deliberate Download or an explicit download Retry creating new work | Revoke older manual deletion in the same checked transaction as new admission. Preserve already canceled attempts' private-file cleanup ownership. |
| Automatic refill or retry | Cannot supersede or retarget manual intent. Revalidate the cancellation/deletion fence before starting work or publishing. |
| Failed, uncertain, duplicate, skipped, or no-op enqueue | Does not implicitly revoke pending deletion. Admission must actually commit new work to supersede it. |
| Observe unread durably | Revoke remaining manual removals, whether unread was a local action or an accepted reconciled state. Respect existing read-sync conflict rules. |
| Cancel pending deletion | Durably revoke the current request's remaining removals. Leave read state, canceled downloads, and independent finish-retention policy unchanged. |
| Retry pending deletion | Revalidate and retry the original request. Never adopt a replacement or new target under the old authorization. |
| Repeat manual mark-read | Capture current authorized targets; coalesce unchanged pending work. A fresh action may authorize a newly verified generation. |
| Read pending work or invoke a view action | Return current pending/blocked/outcome information. Revalidate request revision when opening details and again before Retry/Cancel acts. |

Distinguish explicit user admission from automatic refill and scheduled retry throughout the call chain. Today these routes share enqueue helpers without provenance; relying on which UI happens to be open is insufficient. Existing queue clear/cancel controls must not silently discard manual intents or unfinished worker/file ownership.

Read acceptance must distinguish rejection or uncertain persistence from a committed read state with deletion pending. Preserve compatible public wrappers and empty-input behavior, but never preserve an unconditional success return at the expense of truthful durable outcomes.

### Durable record contracts

These are logical records and invariants, not prescribed serialized field names or a requirement for a new settings file.

| Record | Required information and lifetime |
| --- | --- |
| Archive generation | Unique generation identity, chapter association, captured archive path and original managed root, verified file evidence, and lifecycle/ownership information sufficient for conditional publication/removal. Identity survives queue completion. |
| Manual request | Unique identity and current revision, manual-action provenance, chapter association, captured generation and job/attempt identities, original target/root, disposition, and pending/blocked/retained-metadata outcome. |
| Removal manifest | Exact authorized archive, metadata, and backup targets; their ownership evidence and per-file removal state. Preserve enough evidence to recover after the archive disappears. |
| Retry state | Retry count and durable deadline, last relevant failure/wait reason, and remaining work. Keep through navigation and process restart. |
| Cancellation or supersession | Durable revocation visible before another removal step, tied to the affected request revision and captured job identities. It is not a chapter-key-only erase. |
| Store transaction | The checked whole-store transaction identity and reconciliation guarantees inherited from spec #3. An uncertain replacement blocks destructive work pending reconciliation. |

Keep request disposition, worker cancellation, file removal, retained metadata, and bookkeeping distinct. A single overloaded download status is insufficient. Live UI objects, callbacks, and process handles are not persisted. Unknown versions or fields governed by a future version must not normalize into an empty collection. Retiring records must preserve whatever generation/revocation evidence remains necessary to reject stale work.

### Admission and read-action ordering

1. Capture the action's targets and their authority before a menu refresh or another operation can change them. Capture no later filename-based entitlement for an absent archive.
2. Prepare read-ledger changes and intents in isolated prospective state. For batches, preserve visible-order processing, selected-state clearing before the full rebuild, and read reconciliation of non-target visible chapters before the shared ledger is committed.
3. Commit local read-ledger changes, captured manual intents, and captured jobs' stop/cancellation dispositions in one checked transaction. Fence those jobs immediately against new launches or publication. Deferred processing must not leave an admission window.
4. Only after confirmed admission may worker cancellation or file removal occur. Publish completion records and schedule read-sync/refill through the established coordinator after the required commit; preserve completion ordering.
5. Emit current read/deletion outcomes and subsequent view notifications from committed service state. A stale or broken subscriber cannot discard durable work.

Preserve independent completion snapshots. A completion captured without an archive remains pathless and cannot acquire deletion eligibility from a later download. Removing its captured generation does not discard its retention position or transfer its authority to a replacement.

The atomic boundary covers shared plugin state. KOReader metadata and server synchronization are not part of a distributed transaction. If a shared save fails or remains uncertain, do not cancel downloads, remove files, or report durable acceptance—even if an earlier metadata write changed a sidecar. Reconcile the stored transaction before proceeding; never overwrite a possibly committed value with the old ledger.

### Captured workers and published archives

Cancel only the job/attempt identities present in the accepted action. A chapter key alone cannot authorize cancellation of a later enqueue. Keep captured work fenced while it is queued, running, terminating, or finalizing, and use the ownership/reaping proof required by spec #3 before touching its files.

For a captured job already published or finalizing, ordinary download Cancel still preserves the published archive. Complete that generation's finalization bookkeeping, wait for ownership release, then apply the independently authorized manual deletion. Finalization must merge into current read and pending-sync state rather than restore an older ledger snapshot.

Revoking manual intent stops its remaining archive/sidecar removals. It does not revoke necessary ownership-safe cleanup of an already canceled worker's private files. Later accepted downloads may coexist with that private cleanup only under the prior attempt-ownership rules.

### Archive identity and safe removal

All plugin publishers and removers participate in generation bookkeeping, including ordinary Delete and finish-retention cleanup. A repeated publication receives a new generation even when bytes and pathname match. Preserve new identity data through ledger normalization, read reconciliation, queue completion, and migration.

Before each destructive step, validate the current request revision, captured generation, relevant file ownership, original managed-root containment, and current reader/download ownership. Recheck after asynchronous inspection, hashing, scheduling, or recovery. Managed-path checks include resolved aliases/symlinks; changing the configured download directory does not relax them or redirect an old request.

Live-reader protection applies to manual/immediate paths as well as deferred cleanup. Resolve live host state through the process service, not a retained initiating reader instance. Protect metadata owned by another live reader even when archive paths differ.

The guarantee covers coordinated plugin mutations. Detected unexpected external modifications stop affected deletion. Independent concurrent filesystem tools do not honor these locks and remain outside the guarantee; pathname inspection followed later by unlink is not universal protection against such writers.

### Sidecar ownership and per-file recovery

Resolve and persist exact approved metadata, backup, and archive targets before destructive work. Remove exclusively owned sidecars/backups before the archive, retaining sufficient evidence for retry. Do not discover arbitrary hash-metadata paths after the original archive disappears.

KOReader hash metadata may be shared between archives, and pathname-based cached sampled hashes are insufficient evidence of exclusive ownership. Use verified current archive and live-reader ownership. Do not infer uniqueness from a hash/path or scan the library to justify deletion.

Preserve metadata whose exclusive assignment cannot be established, including shared metadata, and report what was retained while removing the verified archive. Distinguish that deliberate preservation from transient inspection failure: temporary inability to inspect remains pending/retryable and cannot masquerade as safe sharing. Revalidate captured sidecar identity because a file can be recreated at the same location. Unrelated directory contents remain untouched.

Persist authorization before effects, then persist observed per-file progress. A crash after unlink but before saving progress must converge using the captured manifest without touching a replacement. Archive absence alone does not retire known unfinished sidecar or bookkeeping obligations. Once physical work resolves, conditionally update matching generation/path records against current state; preserve newer unread state, pending sync, replacement archives, later jobs, and reader-return context.

### Lifecycle, retry, and migration transitions

| State or event | Allowed behavior and recovery |
| --- | --- |
| New manual action; no confirmed existing target/job | Mark read under existing semantics; create no authority over future downloads. |
| Target identity cannot be established | Preserve blocked outcome without destructive authority over a future file. Retry only from retained original evidence; otherwise require a fresh authorized action. |
| Known pre-commit admission failure | No cancellation/removal or durable-success claim; rejected changes cannot leak into an unrelated later save. |
| Uncertain admission commit | Block effects and further unsafe writes; reconcile transaction identity before deciding whether admission occurred. |
| Accepted request; writer or reader still owns target | Retain request and wait for proven release. Progress other independent requests. |
| Some authorized files removed | Revalidate current revision and remaining exact targets; retry or record progress. Cancellation preserves whatever remains. |
| Captured archive absent | Reconcile known remaining owned targets and bookkeeping; never treat absence as proof all obligations finished. |
| Physical removal complete; bookkeeping pending | Merge conditional changes into current state without clearing newer read/path/job/generation information. |
| Unread, explicit Cancel, or accepted new deliberate download | Revoke remaining manual work durably; callbacks and per-file steps reject the old revision. Already removed files are not restored. |
| Shared/unassignable metadata deliberately retained | Report resolved archive deletion with retained metadata; do not retry forever to remove another archive's state. |
| Temporary failure | Persist retry deadline: five seconds initially, exponential backoff capped at five minutes, no retry-count abandonment. |
| Identity or unsupported-state blocker | Preserve work and explain needed evidence/action; no unsafe automatic fallback. |
| Disable manual-delete setting | Stop new enrollment only. Existing intents continue. |
| Change retention setting or download directory | Preserve manual eligibility and captured original target/root. Independent retention policy remains separate. |
| New view, view closure, or no subscribers | Keep the same service work; attach fresh snapshots and reject retired callbacks. |
| Quit/restart | Preserve prior durable intent within the existing total two-second service shutdown budget; no second budget or required final save. |
| Fresh owning-process startup | Recover supported durable records after ownership checks; continue unresolved waits without repeated UI-owned initialization. |

Use bounded fair processing and useful lifecycle/ownership wakeups. One blocked chapter cannot stall unrelated requests. Manual Retry cannot bypass ownership or identity proof. Existing queue retry policy remains unchanged outside its required interaction with manual cancellation fences.

Adopt legacy archives lazily when an authorized operation targets them, under exclusive process ownership and the accepted old-worker safety gate. No startup library scan. Verify and persist current generation before granting removal authority; never infer original ownership merely from filename.

Create manual intents only from new actions. Existing finished-cleanup records retain their retention positions and policy, but unproved original generations block deletion. Do not attach an old record to a new publication by pathname. A fresh authorized action can establish a new target. Preserve unknown versions and old records on migration failure.

### UI and action semantics

Downloads and chapter views show current pending or blocked work, reason, retry timing where relevant, and Retry/Cancel controls. Retain the distinction between an archive still present and a completed removal. Provide one immediate action/batch summary distinguishing marked-read chapters, pending/blocked deletion, removed archives, and retained metadata. Quiet background retries do not generate a dialog per attempt.

Refresh affected views from committed state with a full rebuild when necessary; cached Downloaded status must not hide pending work or resurrect removed indicators. Closing a view releases its subscription without stopping work. Reopening immediately obtains a current snapshot. Revalidate commands against current request identity/revision, so a stale row cannot cancel or retry a different request.

Cancel stops the manual request only. It restores no removed files, changes no read state, restarts no canceled download, and grants no exemption from ordinary retention. A resolved archive deletion with shared metadata retained is reported explicitly rather than presented as complete metadata removal or endless failure.

## Testing Decisions

The user already accepted the test boundary during ADR-0003's design review. Use one primary composed seam: public manual read actions, Downloads/chapter controls, and real FileManager/ReaderUI lifecycle composition with the actual read coordinator, service, queue, checked persistence behavior, deletion/metadata adapters, retention integration, and rendered outcomes. Preserve existing dependency-injection patterns rather than inventing a parallel per-UI ownership model.

Use distinct host objects, a controlled non-inline scheduler, explicit live/terminating/finalizing worker records, and durable state that survives simulated process replacement. Keep process state through ordinary navigation. Observe files, committed state, worker ownership, and displayed outcomes together; refresh-call counts, internal method-call assertions, or a separate mocked queue per view are insufficient.

Existing public manual-completion tests provide the principal foundation: single/selected/previous actions, selection clearing, full menu refresh, ledger/completion ordering, retained positions, and filesystem/UI convergence. Extend their missing retention-off/three, pending outcome, same-path generation, and live-reader cases. Existing download failure/details and composed lifecycle tests provide prior art for inspectable state and stale-action revalidation. Retain focused physical adapter tests only where simulation cannot establish the guarantee.

| Acceptance case | Required observations | User stories |
| --- | --- | --- |
| Single, selected, previous actions; retention off and three | Same independent durable obligation; unchanged selection/filter/order; read state and pending/removal display agree with files. | 1–8 |
| Empty target and repeated action | Confirmed absence creates no future entitlement; unchanged targets coalesce; fresh action captures only currently authorized targets. | 22, 25 |
| Failed/uncertain admission and mixed batches | No cancellation/unlink before confirmed commit; no false success or leaked rejected mutation; non-target reconciliation preserved; honest aggregate result. | 7–9, 34 |
| Queued/running/terminating/finalizing captured work | Correct identities fenced and canceled; ownership release proved; published job finalizes before separate manual deletion; ordinary Cancel retains archive. | 10–12 |
| Same-path, same-content replacement and later enqueue | New generation protected; failed/no-op admission leaves old intent; explicit admission supersedes it atomically; automatic paths cannot override it. | 13–17, 41 |
| Unread, Cancel, Retry, repeated action, setting/directory changes | Chosen revocation rules and captured roots hold; no restored files/jobs, accidental retention exemption, or retargeting. | 18–24 |
| Live target and another reader sharing metadata | No live-owned removals; stale reader references do not block later progress; shared metadata preserved. | 26–28 |
| Shared/unassignable, unreadable, missing, recreated, or cached-hash metadata | Preserve/report nonexclusive metadata; retry true inspection errors; stale hash cache and replaced sidecars cannot authorize removal. | 27–29 |
| Crash before/after each authorized sidecar/archive unlink and progress save | Exact remaining obligations survive; archive absence does not erase sidecar work; bookkeeping-only recovery preserves later state. | 29–30 |
| Unread/new download/Cancel after first sidecar unlink | Remaining manual removals stop; partial outcomes truthful; replacement metadata/archive and old worker-private cleanup remain correctly separated. | 15, 18–20, 29–30 |
| Retry timing and independent blocked requests | Durable five-second exponential/five-minute cap behavior, no abandonment, fair bounded progress, and useful wakeups. | 31–32 |
| FileManager–Reader A–FileManager–Reader B, reader-to-reader, and zero views | Same requests and workers, independent subscribers, current snapshots, no navigation-induced loss or retargeting. | 33–35, 43 |
| Quit and fresh owning launch with unresolved work | Existing total shutdown budget retained; no required final write; safe worker/intent recovery on startup. | 36 |
| Legacy identity and historical retention records | Lazy verified adoption, no new historical manual authorization, preserved positions, unproved targets blocked. | 37–39 |
| Unknown versions, migration failure, detected external change | Preserve records/files and explain blocker; no filename/PID/time guesses or destructive fallback. | 40–42 |
| Diagnostics and final device evidence | No credentials, server URLs, local paths, device identifiers, manga/chapter titles, or unrelated personal data shared. | 43–46 |

All three acceptance layers are required:

1. **Composed automation:** the cases above plus the full LuaJIT suite, lint, and localization checks. Update the architecture reference only when runtime ownership/test strategy actually changes. Include stale callbacks, view exceptions, generation-conditional finalization, and public Retry/Cancel interactions.
2. **Real filesystem/process checks:** isolated temporary files and actual children exercising identity, aliases/symlinks, metadata/backups, shared/recreated targets, partial removal, surviving writer locks/reaping, checked persistence, and crash boundaries. Call the physical removal implementation. Tests that replace file removal with mocks do not satisfy this layer. Verify chosen primitives and metadata behavior on supported device settings/download mounts.
3. **Device acceptance:** with test data, exercise retention off and three, single/bulk manual actions, a live chapter, reader transitions, zero-view progress, quit/relaunch, cancellation, and a later deliberate download. Check archive, managed metadata, read state, workers, and UI together. Do not damage storage to induce failure. Use generic device wording and redacted evidence.

Run repository-required GitHub Actions before any separately authorized implementation merge. Record missing evidence as an acceptance blocker rather than treating a design document or simulated test as physical/device verification.

## Out of Scope

- Stored chapter pagination and long-series retrieval.
- New completion-triggered Download ahead refill policy; existing automatic admission only gains the required manual-intent fence.
- Changes to chapter target selection, scanlator filtering, finish-retention eligibility, or read-sync conflict resolution.
- A historical cleanup command, automatic conversion of old read/retention state into manual deletion, or a startup library scan.
- Restoring removed files, undoing canceled downloads, or granting retention exemptions through Cancel pending deletion.
- A distributed transaction spanning shared settings, KOReader metadata, and the Suwayomi server.
- Suwayomi server-side download removal, new server mutations, byte/page resume, or wake-lock behavior.
- Universal protection against concurrent uncoordinated external filesystem writers or arbitrary storage corruption.
- Changing ordinary download Cancel to delete already published archives.
- Resolving the original report's unexplained application crash without diagnostic evidence.
- Implementing the feature, creating implementation tickets, editing/closing parent issues, deployment, branch switching, merging, or pushing as part of this specification task.

## Further Notes

This specification preserves all 21 accepted ADR-0003 decisions and supplies the implementation/acceptance contract for a later decomposition. It depends on navigation-safe ownership behaviors in spec #3; it neither claims those are already implemented nor silently broadens the existing ownership tickets.

Keep the eventual tickets independently verifiable and declare their real blockers. The durable store, process service, worker protocol, and generation-aware publication/removal must be available before manual retries can safely run. Exact ticket edges belong to that decomposition.

The new safety model deliberately preserves unproved legacy files and shared metadata. Retention eligibility can remain unchanged while destructive authorization becomes stricter. Delayed or blocked deletion must remain visible and durable; it is not permission to guess ownership or discard work.

Publishing this specification does not publish the local ADR commits or perform runtime work. Future implementation must preserve accepted decisions unless a new decision explicitly revisits them.
