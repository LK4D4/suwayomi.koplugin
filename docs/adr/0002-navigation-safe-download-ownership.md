---
status: accepted
date: 2026-09-06
---

# Keep download ownership independent of reader navigation

One process-wide download service will own the device-local queue, workers, recovery, and durable completion. FileManager and ReaderUI plugin instances will submit commands and subscribe to views of that service. This addresses [section 1 of the issue #2 investigation](../superpowers/audits/2026-09-06-issue-2-investigation.md#1-download-queues-compete-across-reader-instances): a new UI currently recovers jobs whose previous workers can still be running.

This record specifies the intended architecture and acceptance criteria. Implementation is pending; no runtime change or device verification is part of this documentation task.

## Scope and preserved behavior

Downloads continue across FileManager–ReaderUI navigation and periods with zero Suwayomi subscribers, while KOReader's main loop runs. Navigation does not replace a worker, reset an attempt's progress, requeue a job, or perform recovery. Explicit KOReader quit or restart makes a bounded attempt to stop workers and preserves unfinished work for the next launch. Abrupt parent death and surviving children are also covered.

Keep the current directory captured at enqueue, connection settings captured afresh for each attempt, persisted retry counts/deadlines, quiet background failures, and transient retry policy. Lowering concurrency lets existing workers finish; it prevents new launches until the live and terminating worker count is below the new limit. Sleep and wake retain the same service and attempt; a real transfer failure can still invoke the existing retry policy. Byte/page resume, wake locks, and preventing device sleep are not added.

Stored chapter pagination, download-ahead refill triggers, manual-delete retries, and finished-chapter retention policy remain outside scope. Existing queue-triggered cleanup must still run. The investigation does not establish a KOReader crash cause.

## Service and UI ownership

- Add the service boundary under `suwayomi/downloads/`. Keep `main.lua` as composition and host-lifecycle glue. Every production `getDownloadQueue()` call returns the same service-owned queue; plugin initialization must not construct or recover another queue.
- The service owns the queue, scheduler, polling and retry timers, settings/connection providers, worker records, file ownership, recovery, publication, and completion persistence. Its dependencies must not capture the first plugin instance or a retired reader.
- Keep production service state in one process registry, independent of subscriber count. Record the creating PID and reject inherited child-side access to parent service operations. A forked child receiving a copied module cache must never bootstrap a replacement service. Module reload is not a recovery API.
- The service owns durable archive lookup context and downloaded ledger-path updates. These are currently in the UI-bound archive-ready callback and cannot become optional subscriber work.
- Preserve queue-triggered finished-chapter cleanup through a process-owned adapter with a live reader lookup. That adapter wakes the existing durable cleanup processor without retaining a UI instance. Cleanup policy and live-document protections stay unchanged; rendering remains subscriber work.
- Each live FileManager or ReaderUI plugin instance subscribes independently. Attachment returns a current snapshot, and opening a view reads a current snapshot. Queue snapshots must not expose mutable internal records.
- A subscriber updates only its live views. Hidden or suspended views receive their latest state when shown again. Closing the host detaches idempotently, invalidates queued callbacks through a subscription token, and releases callback references to that host. Closing one plugin screen affects that screen's rendering, not the queue. Closing all Suwayomi screens does not shut down the service.
- Host teardown uses `CloseWidget`; it must not consume the host event or prevent other modules from handling it. `CloseDocument`, screen closure, and subscriber detachment are never download shutdown signals.
- Complete state transitions and required persistence before notifying subscribers. Deliver notifications outside the mutation being committed, isolate subscriber exceptions, and reject callbacks from old subscription or service generations. One failed or closed view cannot interrupt durable work or other views.

## Process startup and exclusive ownership

The in-process registry prevents competing queues during navigation. A separate kernel lock prevents competing KOReader processes from mutating the same plugin state.

1. Acquire a nonblocking process-associated `lfs.lock` on a dedicated, stable lock file beside the shared settings store before initializing mutable plugin state or recovering jobs. Keep the handle for the service lifetime. Never unlink/recreate this lock file, and never open/close another descriptor for it in the owner process: POSIX record locks can be released by closing any descriptor for that inode.
2. A second KOReader process cannot initialize a writable Suwayomi instance while ownership is unavailable. Explain that Suwayomi is active in another process; the rest of KOReader remains usable. Block all plugin settings flushes, not only enqueue: the cached settings handle contains the queue, ledger, contexts, and preferences in one file.
3. If a previously blocked process later acquires ownership, reload shared settings before using or writing them. It starts its first service; it does not reuse a stale settings snapshot.
4. Create a unique service-session identity after ownership is acquired. Initialize and reconcile persisted work once before enabling launches. Reentrant access during initialization must not start another recovery pass. A failed initialization remains blocked until it can retry safely.
5. A genuine restart is a fresh owning main-process service starting against prior durable state. A new FileManager/ReaderUI object, a resumed device, a missing progress file, or a persisted `downloading` state does not establish a restart. After successful startup, recovery is never repeated on UI attachment.
6. PID values are diagnostic and can guard access to the current process object; they are not proof of old-worker death. Timestamps, terminal progress, and `waitpid` returning `ECHILD` are also not proof.
7. If ownership primitives are unavailable or the actual filesystem does not enforce them, stop affected work and explain the failure. Do not fall back to PID guesses, timestamp leases, or unchecked writes.

Only one cooperating Suwayomi process may write a shared settings domain. Simultaneous writable plugin processes, in-process hot reload, and coordination with an older plugin that does not honor these locks are not supported.

## Attempt and file ownership

The process lock uses `fcntl` through `lfs.lock` and is not inherited as a lock by children. Each download attempt instead uses an inherited `flock`. These different lifetimes are deliberate.

1. Give each attempt a unique identity distinct from its stable chapter/job key and service-session identity. Retries allocate new attempt identities; navigation does not. Record exact paths for staging archives, direct-archive staging, progress, progress temporary files, and the attempt lock. Preserve the canonical final CBZ layout.
2. Persist an allocation record with exact paths before creating attempt files. In this phase no worker is authorized to launch. Create and acquire the attempt lock, then commit launch authorization and unfinished job intent before forking. If either commit fails, launch no worker and report failure. This distinguishes an allocation interrupted before lock creation from an unexpectedly missing lock after launch authorization. The child receives an immutable attempt description and credentials for that attempt; credentials never enter persisted records.
3. Fork while holding the attempt's `flock`. The child retains its inherited descriptor until process exit, including its last possible write. The parent closes its copy immediately when fork returns, including error handling; it must not explicitly unlock the shared lock. Keep no attempt descriptors in the parent between launches, so later download, Browse, search, or read-sync children do not inherit another attempt's ownership.
4. Workers write only their own staging/progress namespace. They cannot rename to the final path, write shared settings, or remove another attempt's artifacts. Write a completion receipt only after the staged archive passes downloader validation; bind that receipt to the attempt and the artifact's content identity.
5. Terminal progress is not worker exit. Retain worker/file ownership and its concurrency slot until the known child exits and is reaped. Cancellation, timeout, or retry first stops the worker; cleanup follows confirmed exit, never merely a sent signal.
6. After a previous parent dies, open the recorded attempt lock separately and try a nonblocking exclusive `flock`. Until it succeeds, retain the files and durable job and pause new chapter launches. The old worker may finish its private staging, but cannot publish. Retry lock acquisition while KOReader runs; a timeout never authorizes cleanup.
7. An unexpectedly missing lock file after launch authorization, or an unreadable ownership record, is not evidence of worker exit. Preserve uncertain records and artifacts and report the blocker. Do not recreate a lock pathname and treat its new inode as proof that the old worker is gone. A checked allocation-only record is different: it proves launch was never authorized.
8. After proving no writer remains, persist a writer-retired record that authorizes cleanup of the exact attempt paths before unlinking its lock or artifacts. Never reuse that attempt. Retain this cleanup record until removal succeeds, then retire it through the checked store. Recovery recognizes intentional lock absence only from this durable authorization, so a crash after unlink but before final record removal remains recoverable. Temporary removal failures retry during the session and after restart. Do not use broad filename patterns.

The service is the authority for whether a chapter/path is still owned, including terminating workers and publication pending metadata. Existing delete and cleanup guards must consult that authority so a new internal state does not make an owned file appear inactive.

## Checked persistence and publication

Keep the existing shared settings layout. Add a versioned ownership/publication record and checked atomic persistence for all writes to that shared plugin store. Hardening only queue writes would still let an unrelated direct settings flush truncate the queue after a crash.

Use a complete staged settings value, check serialization and write/flush/close results, atomically replace on the same filesystem, and perform the required file/directory synchronization for the supported storage contract. Preserve unrelated settings. A failure known to precede replacement must not acknowledge durable success or leave an uncommitted mutation in the shared cache that a later unrelated flush can accidentally commit. A failure after replacement, such as a directory-sync error, has an uncertain commit outcome: block further plugin writes and destructive transitions, reread and reconcile the store's transaction identity, and establish a checked state before retrying. Never restore a stale cache over a possibly committed replacement. The guarantee covers process interruption and reported I/O failures; it does not claim recovery from arbitrary storage corruption or unverified power-loss behavior.

Publication proceeds as follows:

1. Confirm worker exit, validate the current attempt and its completion receipt, and verify the staged artifact. Ordinary file existence is insufficient.
2. Persist publication intent with the attempt identity, final path, and enough content identity to distinguish its artifact from an unrelated existing file. Do not publish if this write fails.
3. While still holding process ownership, publish from staging on the final archive's filesystem using an atomic operation that refuses to replace an existing destination. The parent service is the only publisher. An existence check followed by an overwriting rename is insufficient. If the destination contains a file unrelated to this publication record, preserve it and report a conflict; do not adopt or overwrite it merely because the filename exists. Verify the required publication primitive on the actual destination filesystem; do not substitute an unsafe fallback.
4. Commit downloaded ledger path, archive lookup context, and queue completion together in one checked settings transaction. Preserve unrelated metadata and use the service's current state, not a subscriber's copy.
5. Only then expose completed download state and notify UI subscribers. Until then, retain recoverable finalization work. Retry failed bookkeeping without removing or downloading the completed archive again.
6. Recovery reconciles each publication record idempotently. A matching final archive needs only the remaining metadata transaction. A validated completed staging artifact can be published after writer ownership is released. An incomplete transfer restarts the chapter. Preserve delayed retries and their existing counters; restart alone does not consume a network-failure retry.
7. Persist cancellation of an unpublished attempt before acknowledging it, then stop/reap and clean its private files. Retain canceled cleanup intent until cleanup finishes. If the cancellation save fails, report failure rather than claiming durable cancellation.
8. Once final publication occurs, cancellation cannot undo that archive. Finish its bookkeeping; explicit Delete handles later removal. A persistence failure between rename and metadata commit must not reopen the cancellation window.
9. Keep failed enqueue, publication, cancellation, and cleanup recoverable. Required write failures stop the affected transition with a clear error; uncertain commit outcomes enter reconciliation rather than assuming success or restoring old state. UI exceptions cannot turn a persisted transition into a failure or discard its retry intent.

Future or unrecognized record versions are preserved and block destructive recovery. A partially applied migration must not erase the previous committed representation.

## Shutdown

Install one process-wide wrapper around `UIManager.quit`. Chain the method that was present at installation, preserve arguments/returns, and make installation and shutdown idempotent. This is a narrow compatibility integration, not a claimed KOReader shutdown callback.

- Stop admission immediately, invalidate normal polling/retry callbacks and subscribers, and stop publication. Closing a Suwayomi view never invokes this path.
- The service adds at most two seconds of shutdown work, measured across all its workers rather than per worker. Signal known children and use nonblocking reaping within one monotonic deadline. A termination or cleanup error must not prevent calling the original quit method.
- Unfinished intent already committed before worker launch is the shutdown recovery record. Do not depend on a final disk write, network request, future UI tick, or finishing an entire chapter before exit. Defer file cleanup and incomplete publication bookkeeping to recovery when necessary.
- Do not delete files or free ownership because the deadline expired. Remaining children retain their inherited attempt locks; a new owner waits for those locks before recovery and replacement scheduling.
- Fence all plugin writers as the service stops and retain the process lock through the original quit method's synchronous work. Release it after that method returns, or let process exit release it if the method never returns. A stopped service does not resume or accept new work in the exiting process. Abrupt death may bypass every shutdown callback; kernel lock lifetimes and parent-only publication still enforce file safety.

The two-second limit covers the service's added work, not the duration of the original KOReader quit implementation. No new plugin persistence operation is required on this critical path.

## First-upgrade recovery

Legacy workers have shared filenames and no attempt locks. New locking cannot retroactively fence an old worker that can still publish its final CBZ. Old cancellation and retry paths can remove or requeue a persisted job before its worker exits, so queued, failed, or empty legacy state does not prove that no old worker remains.

When first adopting the ownership protocol, block download scheduling and destructive recovery whenever old-version worker history in the current boot cannot be proven safe, regardless of the persisted queue state. Leave possible legacy files untouched until the old worker tree is proven stopped. A device reboot is sufficient proof; merely restarting KOReader or observing missing progress is not. If using boot identity as proof, first durably record the boot in which uncertainty was observed, then require a verified different boot. A plain confirmation button or fabricated PID probe must not bypass the gate.

After proof, migrate recognized legacy state once through the checked store and recover. Preserve queued/failed jobs, retry metadata, and old data on migration failure. Do not run old and new plugin versions against the same active store or silently downgrade ownership records.

## Required acceptance evidence

Implementation is accepted only after all three layers below pass. This task records the requirements; it does not run or claim these tests.

### Composed FileManager–ReaderUI regression

Build a dedicated fixture that uses real `main.lua` composition, service, queue, active-job scheduler, job store, progress parser, completion adapters, controllers, and row builders. Use distinct host/plugin objects and one shared process registry/settings domain. Control the clock, worker registry, host widgets, storage and filesystem boundaries. Do not execute workers or next-tick callbacks inline.

Drive the host's actual ordering: normal `showReader` broadcasts `ShowingReader` and closes FileManager before constructing the new ReaderUI; ReaderUI closes its document before its host receives `CloseWidget`. Keep process modules loaded across navigation. Model a restart separately with a fresh registry and retained durable files; do not fake a restart by attaching another UI.

| Scenario | Required observations |
| --- | --- |
| FileManager–Reader A–FileManager–Reader B, plus Reader A–Reader B | At concurrency two, at most two live/terminating chapter workers; same service, attempt IDs, PIDs, paths, progress and queue order across transitions. No recovery, file removal, or replacement caused by navigation. Returned chapter, Downloads, and home views show the same current state. |
| Zero subscribers and reattachment | A worker completes with no Suwayomi view. Archive, ledger, lookup context, queue completion and existing cleanup wakeup succeed. A new subscriber immediately renders the committed result. |
| Retired, hidden, and failing subscribers | Invoke already queued callbacks after detach. No closed-widget mutation or retained callback reference; hidden views do not repaint. One throwing subscriber cannot interrupt another subscriber or persistence. |
| Retry, sleep/wake, and setting changes | Navigation/wake preserve retry deadline/count and attempt progress. Enqueued directory stays fixed; next attempt reads current connection settings. A lower limit launches no replacements until capacity exists without killing existing workers. |
| Terminal receipt while child still lives | No publication, private-file deletion, or released concurrency slot until exit/reaping. |
| Cancellation and replacement | Cancel before publication persists intent, stops/reaps, and cleans only that attempt. Late old progress cannot affect a new attempt. Cancel after publication keeps archive and completes metadata. Deletion guards protect terminating/finalizing ownership. |
| Explicit and implicit exit routes | Exercise Exit, Restart, direct quit, Back-to-exit, and repeated shutdown. Service work returns within two seconds total without future scheduler callbacks. Unconfirmed children retain locked artifacts and durable jobs. |
| Fresh process with surviving child | Process lock becomes available but old attempt lock stays held. No cleanup or new launch until release. Include PID reuse and the misleading `ECHILD` result; neither grants authority. |
| Competing KOReader process | Second plugin performs no shared settings write, recovery, or launch. After acquiring ownership, it reloads current state before first recovery. |
| Crash at each publication boundary | Interrupt after allocation commit, lock creation, launch authorization, fork, ready receipt, publication-intent commit, rename, and final metadata commit. Recovery converges without duplicate publication, metadata loss, or redownloading a validated completed artifact. |
| Storage and cleanup failures | Inject serialization, write, flush, close, rename and relevant sync failures, including failure after replacement. Uncertain outcomes block writes until reconciliation; no stale cache overwrites a committed result. Crash after authorized lock unlink but before record retirement also converges. Removal failure retains retry intent and eventually converges after failure clears. |
| Legacy, unknown, and conflicting state | Uncertain legacy workers block scheduling/recovery even with an empty, queued, or failed persisted queue. Their files remain until proof of exit. Unknown versions and unexpectedly missing attempt locks remain untouched. Unrelated final archive remains intact and visible as a conflict. |

Assert filesystem outcomes, committed settings, worker ownership/counts, and actual displayed row/snapshot state together. Refresh call counts or a per-instance queue mock cannot prove the fix.

Reuse relevant patterns from [download failure UX specs](../../spec/suwayomi_download_failure_ux_spec.lua), [manual completion specs](../../spec/manual_read_completion_spec.lua), [active-job specs](../../spec/suwayomi_downloads_active_jobs_spec.lua), and [queue specs](../../spec/suwayomi_download_queue_spec.lua). Keep [main specs](../../spec/main_spec.lua) focused on host composition and lifecycle. Run the full LuaJIT suite, Luacheck, localization check, and the repository's required pre-merge GitHub Actions when implementation is ready and integration is authorized.

### Real filesystem and subprocess checks

Use isolated temporary files and synthetic small CBZs with actual OS children. Verify process-lock exclusion, fork inheritance differences, parent descriptor closure, orphan-held attempt locks, known-child reaping, parent-only publication, atomic replacement, and cleanup after release. Include sibling workers to prove they do not inherit another attempt's lock.

Verify the actual Android settings and download mounts support the chosen locks and same-filesystem publication. Unsupported primitives or storage semantics must produce the agreed safe failure. Simulated files and mocked workers do not satisfy this layer; do not corrupt device storage to simulate failure.

### Device navigation acceptance

With a small test manga and concurrency two, queue 8–10 missing chapters and establish a Downloads-only control. Repeat with another batch while opening an already downloaded chapter, returning, opening another, and using a reader-to-reader transition. Repeat at concurrency one.

Record chapter-worker counts and attempt/progress continuity around each transition; thumbnail, search, and read-sync workers have separate limits. Require no navigation-triggered worker replacement, reset/requeue, or removal of active files, and correct displayed state on return. Also verify zero-view completion and explicit quit/relaunch recovery. Keep titles, library source names, credentials, URLs, and local paths out of shared diagnostics.

## Evidence and trade-offs

The host lifecycle was checked against KOReader v2026.03, commit `825b9bced0eb666b45af4208e1c0095b88d38b0d`, and its pinned base commit `7a46ea3812539083ee25b06f0c81ac58b1356ee0`:

- [PluginLoader](https://github.com/koreader/koreader/blob/825b9bced0eb666b45af4208e1c0095b88d38b0d/frontend/pluginloader.lua) caches plugin modules but constructs separate host instances; finalization only clears instance references. [ReaderUI](https://github.com/koreader/koreader/blob/825b9bced0eb666b45af4208e1c0095b88d38b0d/frontend/apps/reader/readerui.lua) and [UIManager](https://github.com/koreader/koreader/blob/825b9bced0eb666b45af4208e1c0095b88d38b0d/frontend/ui/uimanager.lua) establish the close-event ordering. Public exit events miss paths that reach `quit`, which clears scheduled work.
- The [pinned subprocess helper](https://github.com/koreader/koreader-base/blob/7a46ea3812539083ee25b06f0c81ac58b1356ee0/ffi/util.lua) forks without installing a parent-death signal. Its completion helper treats every `waitpid` error as done; this cannot establish orphan exit from a new parent.
- The [pinned LuaFileSystem dependency](https://github.com/koreader/koreader-base/blob/7a46ea3812539083ee25b06f0c81ac58b1356ee0/thirdparty/koreader-lfs/CMakeLists.txt) provides `lfs.lock` through [nonblocking POSIX record locking](https://github.com/lunarmodules/luafilesystem/blob/v1_9_0/src/lfs.c). [Process-associated locks](https://man7.org/linux/man-pages/man2/fcntl_locking.2.html) and [flock locks](https://man7.org/linux/man-pages/man2/flock.2.html) have different fork and close semantics. The attempt-lock adapter needs an explicit supported libc binding; it is not an existing plugin abstraction.
- [LuaSettings.flush](https://github.com/koreader/koreader/blob/825b9bced0eb666b45af4208e1c0095b88d38b0d/frontend/luasettings.lua) discards its writer's result. The [writer](https://github.com/koreader/koreader/blob/825b9bced0eb666b45af4208e1c0095b88d38b0d/frontend/util.lua) writes the destination directly and does not check every write/close/sync result. Existing save-wrapper returns therefore do not prove durable success.

Per-UI queue handoff would require transferring workers, timers, callbacks, and file authority at every transition. A process service avoids that protocol. Parent-only publication costs a staged completion/recovery protocol but removes stale children's authority over final archives. Separate process and attempt locks allow the new parent to start safely without mistaking a surviving child for dead. Waiting for locks favors ownership safety over immediate availability.

Keeping one checked shared store permits atomic completion metadata without introducing a second authoritative database, but requires hardening every plugin write to that file and disabling concurrent writable plugin processes. The quit wrapper covers host paths public events miss; crash recovery still stands independently because no shutdown hook is guaranteed to run.

The current runtime map remains in [ARCHITECTURE.md](../ARCHITECTURE.md). Update it when implementation changes module ownership or test strategy. No new domain glossary is needed: service, subscriber, process, and attempt ownership here describe technical boundaries rather than new domain terminology.
