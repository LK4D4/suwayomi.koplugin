# Navigation-safe local download ownership

Published as [GitHub issue #3](https://github.com/LK4D4/suwayomi.koplugin/issues/3) with the `ready-for-agent` label. This file records the publication snapshot; use the issue for subsequent implementation tracking.

## Problem Statement

Readers lose download progress when moving between KOReader's FileManager and ReaderUI. Each plugin instance currently creates and recovers a queue even though workers from an earlier instance can remain alive. The queues can schedule the same chapter more than once, exceed the intended process-wide concurrency limit, and remove files that another worker is still using.

This specification addresses only navigation-safe download ownership from the investigation of [issue #2](https://github.com/LK4D4/suwayomi.koplugin/issues/2). The maintainer reproduced progress resets on the device; the original report's application-crash cause remains unproved. The other download-ahead, chapter-retrieval, and deletion-policy findings require separate work.

## Solution

Keep one download service for the lifetime of the owning KOReader process. Reader and FileManager plugin instances use that service and subscribe to current state. Opening or closing a view does not restart downloads, recover the queue, or change worker ownership.

Workers produce private staged archives. The service publishes the final archive and commits its download metadata. Process and attempt locks prevent another process or a surviving child from interfering with that work. Interrupted transfers, publication, and cleanup remain recoverable without depending on a screen or a shutdown callback.

Preserve the existing device-local download experience, retry policy, archive layout, and settings semantics. Explain ownership or storage blockers without claiming work succeeded. Perform a bounded attempt to stop workers on explicit quit and resume unfinished work safely on the next owning launch.

## User Stories

1. As a reader, I want active downloads to continue when I open a chapter, so that reading does not restart transfers.
2. As a reader, I want returning to FileManager to show current progress, so that navigation does not make a download appear newly queued.
3. As a reader, I want reader-to-reader transitions to preserve downloads, so that opening the next document does not create duplicate workers.
4. As a reader, I want downloads to complete with no Suwayomi screen open, so that I can use the rest of KOReader while they run.
5. As a reader, I want newly opened chapter, Downloads, and home views to agree, so that I can trust their download state.
6. As a reader, I want closing a screen to stop updates to that screen, so that retired views do not cause errors or interfere with reading.
7. As a reader, I want one broken view to leave downloads and other views working, so that rendering failures do not lose completed work.
8. As a reader, I want concurrency enforced across the process, so that changing views does not multiply downloads.
9. As a reader, I want lowering concurrency to let existing transfers finish, so that a settings change does not waste their work.
10. As a reader, I want each queued chapter to retain its chosen download directory, so that later settings changes do not move its destination.
11. As a reader, I want new attempts to use current connection settings, so that correcting connection details can repair subsequent attempts.
12. As a reader, I want scheduled retries to retain their timing, errors, and counts across navigation and restart, so that recovery does not discard retry history.
13. As a reader, I want sleep and wake to preserve the same queue, so that waking the device does not itself recover or duplicate downloads.
14. As a reader, I want quitting KOReader to add at most two seconds of download shutdown work, so that exit does not wait for chapters to finish.
15. As a reader, I want unfinished jobs preserved after quit or process death, so that I do not have to enqueue them again.
16. As a reader, I want a surviving old worker isolated from replacement work, so that a restart cannot corrupt archives or remove another attempt's files.
17. As a reader, I want a second KOReader process to explain why Suwayomi is unavailable, so that it cannot overwrite the first process's queue or settings.
18. As a reader, I want recovery to reuse a validated completed transfer, so that a metadata-write failure does not download the chapter again.
19. As a reader, I want a download reported complete only after its archive and required metadata are committed, so that opening it and returning to its chapter list work consistently.
20. As a reader, I want cancellation before publication to remain canceled across restart, so that stopped work does not silently return.
21. As a reader, I want an already published archive preserved if I cancel during final bookkeeping, so that cancellation does not unexpectedly delete a finished file.
22. As a reader, I want ordinary Delete to respect live and finalizing download ownership, so that deletion cannot race with an active attempt.
23. As a reader, I want unrelated existing archives preserved, so that a destination conflict cannot overwrite my files.
24. As a reader, I want temporary cleanup failures retried, so that abandoned attempt files eventually disappear without risking active files.
25. As a reader, I want failed storage operations reported accurately, so that an unsuccessful enqueue or cancellation is not presented as durable success.
26. As a reader, I want uncertain save outcomes reconciled before further writes, so that a stale settings cache cannot overwrite a transaction that reached disk.
27. As a reader upgrading the plugin, I want uncertain old workers stopped before recovery, so that legacy filenames cannot interfere with the new ownership protocol.
28. As a reader, I want unsupported locks or filesystem operations to stop affected work with an explanation, so that a compatibility problem does not become data loss.
29. As a reader, I want unfamiliar persisted versions preserved, so that opening a different plugin version cannot erase state it does not understand.
30. As a reader, I want existing finished-chapter cleanup to receive queue wakeups even without a view, so that removing UI ownership does not change cleanup behavior.
31. As a reader, I want background transfer failures to remain quiet and inspectable, so that downloading does not interrupt reading with repeated dialogs.
32. As a maintainer, I want one composed test boundary covering navigation, workers, files, persistence, and displayed state, so that mocks cannot hide competing queue instances.
33. As a maintainer, I want real process and filesystem checks, so that assumed lock and publication semantics are verified outside simulations.
34. As a maintainer, I want device acceptance evidence for the reported workflow, so that automated coverage is backed by actual device behavior.
35. As a maintainer, I want explicit recovery rules for each persisted phase, so that crashes between side effects have deterministic outcomes.
36. As a maintainer, I want library data and credentials excluded from shared diagnostics, so that ownership failures can be investigated without exposing user data.

## Implementation Decisions

### Architectural authority and module responsibilities

The accepted architecture source is ADR-0002, “Keep download ownership independent of reader navigation,” recorded at local commit `ca2ed07`. That commit is not published at the time of this specification. The contracts below are self-contained so implementation does not depend on an inaccessible link. Preserve the ADR's decisions; this specification supplies the implementation and acceptance contract.

- The download service owns the production queue, scheduling, recovery, worker registry, timer generations, file authority, and durable completion. The plugin shell only composes dependencies and connects host lifecycle events.
- Existing queue and controller interfaces remain the application-facing entry points. All production queue access resolves to the same service-owned queue; public UI actions must not instantiate or recover another queue.
- The active-job scheduler owns current child handles and reaping. The worker/downloader produces staged artifacts and receipts. It cannot publish final archives or write shared settings.
- A checked settings boundary owns all writes to the shared plugin settings document. Completion commits queue state, downloaded ledger path, and archive lookup context together. Preserve unrelated settings and metadata.
- A process-owned adapter preserves existing finished-chapter cleanup wakeups and resolves the live reader when needed. It must not retain a retired plugin instance or change cleanup policy.

### Service interface contract

| Operation | Contract |
| --- | --- |
| Obtain the service | Return the same owning service within the main process. Initialize once before admitting work. Reentrant initialization, a new UI, and an inherited child module cache cannot create another owner. |
| Enqueue, batch enqueue, retry | Preserve existing caller semantics and duplicate handling. Acknowledge a new durable job only after checked persistence. Capture destination at enqueue and connection settings at attempt launch. |
| Cancel and clear | Revalidate current durable job and publication state. Persist cancellation before acknowledging it. Clearing a visible row must not discard unfinished worker or cleanup ownership. |
| Read snapshots and status | Return independent snapshots with consistent queue, progress, error, ownership, and blocking information. Keep current active/queued/failed views usable; represent waiting and finalization without falsely reporting completion. |
| Subscribe and detach | Return a current snapshot on attachment. Detach idempotently and invalidate already queued callbacks. Each live host can subscribe independently. |
| Change concurrency | Update the single process-wide scheduler. Count live and terminating workers. Let existing workers finish after a limit reduction; launch only when capacity is available. |
| Query chapter/path ownership | Cover running, terminating, and finalizing attempts as well as durable cancellation cleanup. Deletion must not infer inactivity from a new internal status or a missing UI. |
| Shut down | Stop admission and publication, invalidate normal callbacks, and attempt termination/reaping within one two-second service budget. Preserve unfinished intent without requiring a final save. |

UI callbacks are notifications, not transaction participants. Commit state before delivering them, isolate exceptions, and validate subscription and service generations at delivery. Closed hosts release their callback references. Hidden or suspended views refresh from a current snapshot when shown; they do not repaint while hidden. Host `CloseWidget` detaches without consuming the event. Document close, screen close, and device wake never initiate queue recovery or service shutdown.

### Persisted record contract

Retain the shared settings layout and add explicitly versioned ownership records. The following are logical records, not a requirement for particular serialized field names. Keep job disposition, worker authorization, publication, and cleanup state distinct; a single overloaded status is insufficient.

| Record | Required information and invariants |
| --- | --- |
| Store transaction | Supported protocol version and unique transaction identity for the complete settings value. Reconciliation must distinguish the intended replacement from the prior committed value. |
| Service session | Unique owning-session identity. A copied process object can use its creator PID to reject child-side access; persisted PIDs are not recovery authority. |
| Download job | Stable chapter/job key, required manga/chapter metadata, queue order, captured destination, current disposition, and existing retry count, deadline, progress, and error information. |
| Attempt allocation | Unique attempt and session identities, job association, exact private artifact manifest, and a phase showing whether launch was authorized. Persist allocation before creating attempt files. |
| Launch authorization | Durable authorization created while the attempt lock is held, before fork. Its absence proves that an allocation never authorized a worker; its presence requires writer-exit proof before cleanup. |
| Completion receipt | Attempt identity, successful validation result, and staged artifact content identity, including byte length and an algorithm-tagged content digest. Validate it against the artifact; existence alone is insufficient. |
| Publication intent | Current attempt, canonical destination, and expected artifact identity. Commit before publication and retain until atomic completion bookkeeping succeeds. |
| Cancellation and cleanup | Durable cancellation disposition where applicable, writer-retired authorization, exact remaining private cleanup targets, and retry intent. Retain after removal failures and retire only after cleanup is complete. |
| Upgrade gate | Protocol-adoption state and verified evidence that legacy workers cannot remain. If boot identity establishes proof, retain the boot in which uncertainty was first recorded. |

Credentials, callbacks, live process handles, and mutable UI objects are not persisted. Every retry receives a new attempt identity; navigation retains the existing one. A new owning session may reconcile a prior attempt but must never fork that prior attempt again. Validate identifiers, phase combinations, and owned-path relationships before acting. Preserve unknown versions and uncertain records rather than normalizing them into an empty queue. Cleanup targets never include an unrelated or subsequently published final archive.

### Process and worker exclusion

Acquire a nonblocking process-associated `lfs.lock` on a stable dedicated lock file before mutable plugin initialization. Keep the handle for the service lifetime. Never unlink or recreate that process-lock file; avoid any other open/close of its inode in the owner process. The process registry remains necessary because this kernel lock does not distinguish two objects within the same process.

If another process owns the settings domain, disable that second Suwayomi instance, including every settings flush. KOReader remains usable. A process that later acquires ownership reloads shared state before initialization. Lock contention and unsupported locking must produce distinct explanations; neither permits an unsafe fallback.

Each attempt uses an inherited `flock`, with the following sequence:

1. Commit allocation, create/acquire its lock, and commit launch authorization.
2. Fork while holding that attempt lock. The child retains its inherited descriptor until process exit and its final possible write.
3. The parent immediately closes its copy without explicitly unlocking the shared lock. At every later fork, the parent must hold no descriptor for another attempt, including locks briefly opened during recovery.
4. Keep current child ownership and its concurrency slot through confirmed exit/reaping. A terminal receipt or a sent termination signal is insufficient. A subprocess-helper error does not prove exit.
5. After parent death, a new owner separately acquires each recorded attempt lock before touching its files. While any old writer remains unresolved, pause new chapter launches and retry ownership checks without deleting artifacts.
6. Persist writer-retired cleanup authorization before unlinking attempt locks or artifacts. Recovery may accept an intentionally absent lock only from that authorization, or an allocation that never authorized launch.

A fresh owning main-process service performs startup reconciliation once. Continued retries of blocked recovery are service work, not repeated initialization. UI attachment, sleep/wake, missing progress, timestamps, PID reuse, and `ECHILD` never authorize recovery or cleanup.

### State transitions and recovery

| Durable or observed state | Allowed next step | Recovery rule |
| --- | --- | --- |
| Queued or retry scheduled | Allocate an attempt when retry policy and capacity permit. | Preserve order, error, count, and deadline. Restart alone does not consume a network retry. |
| Allocated, launch not authorized | Create/acquire the lock and commit launch authorization, or retire the allocation. | No worker was authorized. A missing lock in this phase is recoverable. |
| Launch authorized, writer unresolved | Start the authorized child once, or observe/stop that child. | Require writer-exit proof; retain artifacts and block replacements while its lock remains held. |
| Child reports completion but remains alive | Continue monitoring and retain its slot. | Receipt alone permits neither publication nor cleanup. |
| Writer exited, incomplete artifact | Apply existing failure/retry policy and retire private files safely. | Restart an incomplete chapter from the beginning; byte/page resume is unchanged. |
| Writer exited, validated receipt and staging | Commit publication intent, then publish. | Reuse the validated artifact rather than transferring the chapter again. |
| Publication intent with matching final archive | Commit completion bookkeeping. | Verify content identity and retry only the missing transaction. |
| Publication intent with unrelated destination | Preserve the existing destination and report conflict. | Do not overwrite or adopt by filename. |
| Canceled before publication | Stop/reap, record writer retirement, and clean private files. | Do not requeue canceled work; retain cleanup intent. |
| Final archive published, metadata incomplete | Finish bookkeeping and retain archive. | Cancellation cannot reopen the pre-publication window; later removal uses explicit Delete. |
| Writer retired, cleanup incomplete | Remove only authorized private artifacts, then retire the record. | Retry removal failures. Intentional lock absence remains recoverable after a crash. |
| Unknown version, missing authorized lock, or uncertain transaction | Preserve state and explain the blocker. | Reconcile or obtain valid ownership proof before further destructive work. |

### Persistence and publication protocol

All writes to the shared plugin settings document use checked atomic replacement, preserving unrelated keys. Stage the entire prospective value, check serialization/write/flush/close results, and perform the file and directory synchronization required by the supported storage contract. A known pre-replacement failure must leave the committed cache unchanged and must not leave a rejected mutation available for an unrelated later flush.

Failure after replacement can mean the intended transaction reached disk. Block further plugin writes and destructive transitions, reconcile transaction identity against the stored value, and establish checked state before proceeding. Do not flush the old cache over a possibly committed replacement or acknowledge an uncertain enqueue/cancel as successful.

After writer exit, validate receipt and artifact, then commit publication intent. Publish on the destination filesystem with an atomic operation that refuses an existing target. A check followed by an overwriting rename does not meet the contract. Unsupported no-replace semantics stop publication with an explanation.

Commit downloaded ledger path, archive lookup context, and queue completion in one settings transaction. Only then expose completed status. If bookkeeping fails, retain the matching archive and publication record and retry metadata. Keep artifact verification from becoming an unbounded operation in a UI callback. Notifications and existing cleanup wakeups follow committed state; subscriber absence cannot suppress durable work.

### Shutdown and upgrade

Install one isolated, idempotent process-wide wrapper around `UIManager.quit`, chaining the existing method and preserving its arguments and returns. Public Exit/Restart events do not cover every quit route; normal plugin teardown is not a substitute.

Stop admission/publication and invalidate callbacks immediately. Signal known children and use nonblocking reaping within one monotonic deadline totaling two seconds across all service workers. Do not require network work, another UI tick, a final settings transaction, or chapter completion. Pre-launch durable intent already supports recovery. Shutdown errors must not prevent calling the original quit method. Fence plugin writers and retain the process lock through that method's synchronous work; release afterward or at process exit. Surviving children keep their attempt locks. The budget covers service-added work, not unrelated host shutdown time.

On first adoption, an empty, queued, or failed legacy queue does not prove old workers stopped: older cancellation/retry paths can remove active records before child exit. Whenever current-boot legacy worker history is uncertain, block scheduling and destructive recovery until verified worker-tree termination or a verified later device boot. Record the uncertain boot before using a boot change as proof. A confirmation button or KOReader relaunch alone is insufficient. Migrate recognized state once through checked persistence, preserve retries, and preserve old data if migration fails.

## Testing Decisions

Use the highest practical automated boundary: public plugin actions and host lifecycle with the real service, queue, scheduler, persistence rules, completion adapters, controllers, and rendered rows. This is the composed seam already accepted in ADR-0002. Retain focused adapter tests for physical guarantees that a simulated host cannot establish.

The composed fixture uses distinct FileManager and ReaderUI/plugin objects, one shared process registry, a controlled non-inline scheduler, explicit live/terminating worker records, and storage/filesystem substitutes. A normal reader opening closes FileManager through `ShowingReader` before constructing ReaderUI. Reader teardown closes its document before host `CloseWidget`. Keep modules alive through navigation; a simulated restart replaces process state while preserving durable files and any surviving child.

Test observable outcomes together: worker counts and ownership, file contents/existence, committed settings, and displayed rows. Do not use refresh-call counts or a separately mocked queue for each UI as proof of correctness. Prior art is the composed download-failure UX coverage and manual-completion coverage, supplemented by existing queue, active-job, progress-file, downloader, and lifecycle specifications.

| Acceptance case | Required observations | User stories |
| --- | --- | --- |
| FileManager–Reader A–FileManager–Reader B and Reader A–Reader B | One service; at concurrency two, no more than two live/terminating chapter workers. Preserve worker/attempt identity, paths, progress, and order. No navigation-triggered recovery, removal, or replacement. All returned views show current state. | 1–5, 8, 32 |
| Zero subscribers, stale callbacks, and view failures | Complete archive and metadata with no views. A new view immediately shows completion. Closed callbacks are inert and released; hidden views do not repaint. One subscriber exception does not affect other views or durable work. Existing cleanup wakeup remains available. | 4–7, 19, 30 |
| Retry, settings, and wake | Preserve retry metadata and quiet failures. Keep captured destination and reload connection settings only for the next attempt. Lower concurrency without killing current workers. Wake does not initialize another queue. | 9–13, 31 |
| Terminal receipt and cancellation races | Receipt before child exit releases no slot or file authority. Cancel before publication survives restart. Late old output cannot affect a replacement. Cancel after publication keeps the archive. Delete respects terminating/finalizing ownership. | 16, 20–22 |
| Quit routes and deadline | Exercise Exit, Restart, direct quit, Back-to-exit, and repeated shutdown. Service work stays within one two-second total deadline without future callbacks or a required final write. Unconfirmed children retain locked artifacts and durable jobs. | 14–16 |
| New process, surviving child, and competing process | Old attempt lock blocks cleanup and new launches despite PID reuse or misleading helper errors. Second plugin writes no shared state. A later owner reloads state before initialization. | 15–17 |
| Crash boundaries | Interrupt after allocation, lock creation, launch authorization, fork, receipt, publication intent, publication, metadata commit, and authorized lock unlink. Converge without duplicate publication, lost intent, or retransferring a validated artifact. | 18–21, 24, 35 |
| I/O and cleanup failures | Inject serialization, write, flush, close, replacement, and relevant sync failures, including post-replacement ambiguity. No false success or stale-cache overwrite. Retained cleanup converges after the failure clears. | 24–26 |
| Legacy, unknown state, and destination conflict | Gate uncertain legacy history even with an empty queue. Preserve unknown versions and unexplained missing locks. Preserve unrelated destination contents. Fail clearly when required primitives are unavailable. | 23, 27–29 |
| Diagnostic privacy | Shared diagnostics contain no credentials, server URLs, library names/titles, or local paths. Useful worker and transition evidence remains available through existing redaction boundaries. | 36 |

All three acceptance layers are required:

1. **Automated composition:** the cases above, the full LuaJIT suite, Lua lint, and localization checks. Update the architecture reference when module ownership and test strategy actually change. Run the repository-required GitHub Actions before an authorized implementation merge.
2. **Real filesystem/process checks:** isolated temporary files and synthetic small CBZs with actual OS children. Verify process-lock exclusion, the different fork inheritance rules, parent descriptor closure, surviving-child locks, sibling non-inheritance, reaping, no-replace publication, atomic settings replacement, and cleanup after release. Verify the chosen primitives on the actual Android settings and download mounts. Mocked workers and filesystem simulations do not satisfy this layer.
3. **Device workflow:** establish a Downloads-only control with 8–10 missing chapters at concurrency two. Repeat while opening an already downloaded chapter, returning, opening another, and changing readers directly. Repeat at concurrency one. Record worker/attempt continuity, progress and displayed state around navigation; distinguish chapter workers from other plugin workers. Verify zero-view completion and explicit quit/relaunch recovery. Use synthetic/familiar test data and do not damage device storage to simulate failures.

The specification and ADR are accepted design inputs, not evidence that implementation or these tests already pass.

## Out of Scope

- Stored chapter pagination and long-series retrieval.
- New download-ahead refill triggers or changes to candidate selection.
- Manual-delete retry policy and finished-chapter retention policy.
- Byte/page resume, preventing device sleep, or new wake locks.
- Suwayomi server-side download mutations.
- Concurrent writable Suwayomi processes, cross-process command routing, in-process hot reload, or running incompatible old/new plugin versions against an active store.
- Guarantees for arbitrary storage corruption or unverified power-loss behavior.
- Closing the original report as fully resolved, creating implementation tickets, or performing implementation in this specification task.

## Further Notes

This specification follows the accepted ADR and the section-1 investigation at base revision `dbe4f8d`. The ADR remains the architecture decision record; this issue is the implementation specification and acceptance contract. Changes to an accepted architectural choice must explicitly identify the decision being reconsidered rather than silently weakening this specification.

The investigation report and ADR exist only on the local work branch at publication time. Their behavior, boundaries, and required evidence are represented here without links to unpublished commits. Publishing this specification does not publish, merge, or switch that branch.

Implement through separately scoped, dependency-aware tickets in the next planning phase. Each ticket should deliver a verifiable behavior and inherit the relevant recovery, ownership, and test requirements above. Physical locking and publication support remain implementation acceptance gates, not assumptions established by source inspection.
