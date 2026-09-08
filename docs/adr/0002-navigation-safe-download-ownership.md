---
status: accepted
date: 2026-09-06
revised: 2026-09-07
---

# Keep one download queue through reader navigation

## Follow-on decision (2026-09-08)

[ADR-0005](0005-automatic-download-restart.md) supersedes this record's startup interruption policy and shared temporary-file handling with automatic restart, isolated attempts, validated publication, and best-effort cleanup. That implementation is pending; the process-owned navigation and bounded-quit decisions here remain in force. The superseded startup behavior below is retained as history and still describes the current runtime.

## Problem

The maintainer reproduced downloads resetting or requeueing during FileManager–ReaderUI navigation. On master at `01ed3e3`, `main.lua:getDownloadQueue()` caches a queue on each plugin instance and `init()` calls its recovery. A new host can therefore recover persisted work while an earlier host's workers still run. The [investigation](../superpowers/audits/2026-09-06-issue-2-investigation.md#1-download-queues-compete-across-reader-instances) preserves the original evidence; it does not establish an application-crash cause.

This revision supersedes the earlier reboot/ownership-recovery protocol in ADR-0002 and spec #3. The maintainer rejects mandatory reboot, storage relocation, and automatic crash salvage. The revised design is accepted; runtime implementation and device acceptance remain pending.

## Revised decision

Use one small process-owned service around the existing download queue. FileManager and ReaderUI instances share that queue and attach disposable view subscriptions. Navigation, document/screen closure, and sleep/wake neither construct nor recover another queue. Downloads and necessary completion bookkeeping continue while KOReader's main loop runs, even with no Suwayomi screen open.

Keep the existing queue, active-job scheduler, downloader, and KOReader `ffi/util` subprocess helper. Move archive completion bookkeeping and existing queue-triggered cleanup wakeups out of UI callbacks. Commit the ledger path, reader-return context, and queue completion through the checked shared store before notifying views. Retry a failed completion save during the current session without another transfer; this needs no publication journal. Detached views receive no callbacks, and reopened views read current state.

On genuine process startup, normalize unfinished persisted `queued` and `downloading` work to `failed` with “Interrupted; retry download”. This includes queued delayed retries. Preserve completed archives and their metadata, and preserve existing permanent-failure diagnostics. The [authoritative specification](../superpowers/specs/2026-09-06-navigation-safe-download-ownership.md), mirrored verbatim in [#3](https://github.com/LK4D4/suwayomi.koplugin/issues/3), defines the existing-archive case and focused acceptance.

Normal quit stops admission and timers, then makes a bounded best-effort stop of known workers through existing helpers. Use one idempotent `UIManager.quit` integration, preserving the prior method, with at most two seconds of added work across all workers. Do not require a final save or future UI tick. Closing a screen is not quitting KOReader.

Failing or removing a queue entry does not terminate its child. During the running session, retain known terminating workers and their file associations until the existing helper reports completion. Defer their temporary-file cleanup and replacement launch; preserve the existing final CBZ. This is a narrow extension of the current scheduler's terminating-worker tracking, not a new process framework.

## Preserved behavior

- Enforce one chapter-download concurrency limit, including known workers still stopping. Lowering the limit lets current workers finish before replacements start.
- Preserve ordinary transient retry classification, counts, deadlines, and quiet full-error inspection during the session. Navigation and wake alone do not spend retries.
- Keep the source-scoped archive layout, download directory captured at enqueue, current connection settings at each attempt, settings semantics, and device-local downloading.
- Keep #4's implemented atomic settings protections, ambiguous-save fence and reconciliation, unrelated metadata, live-reader protection, and existing cleanup policy.
- Do not broaden chapter retrieval, Download ahead, read-sync, manual deletion, or retention.

## Accepted limitations and scope

Interrupted transfers may fail and require explicit retry, including after normal quit. No automatic transfer salvage, receipt/content-hash protocol, parent-only publication pipeline, multi-phase journal, boot identity, inherited attempt lock, custom fork/waitpid wrapper, global legacy-worker proof gate, or coordination between simultaneously writable KOReader processes is required.

Abrupt death may bypass shutdown and leave a child running. A fresh process cannot establish the lifetime of an untracked old child from failed queue state, a PID, or missing progress. A surviving legacy worker can still write shared temporary or final paths; this revision does not guarantee isolation from it. Startup does not sweep those files or demand reboot. Explicit retry uses existing file handling and may fail or repeat a transfer; deferred temporary cleanup is acceptable. No final archive is removed as retry cleanup. Hot reload and simultaneous writable KOReader processes are unsupported.

Implement through one focused coding session plus device acceptance: [#5](https://github.com/LK4D4/suwayomi.koplugin/issues/5) owns the complete runtime change; [#11](https://github.com/LK4D4/suwayomi.koplugin/issues/11) owns device evidence. #6–#10 are superseded/not planned, not completed implementation. #4 remains complete and unchanged. Future manual-delete identity or refill requirements belong to their own tickets and must not expand #5.

## Acceptance checklist

- [ ] First launch/upgrade works without reboot, storage relocation, or a legacy proof gate.
- [ ] FileManager–ReaderUI and reader-to-reader navigation retain one queue, workers, progress, retry timing, and bounded concurrency; sleep/wake does not reinitialize it.
- [ ] Completion with all screens closed commits metadata and queue state; returned chapter, Downloads, and home views agree. Detached callbacks do nothing.
- [ ] Cancellation/retry waits for known stopping workers before temporary cleanup or replacement, preserves final archives, and keeps errors quiet.
- [ ] Normal quit is bounded; fresh launch fails unfinished queued/downloading work, preserves completed work and prior failure diagnostics, and explicit retry succeeds.
- [ ] Focused composed public-action tests assert persistence, filesystem effects, worker counts, and rendered state together. Reuse existing fixtures and run normal repository checks for implementation; no exhaustive crash-boundary matrix is required.

## Historical evidence and implementation references

The original investigation and this ADR's prior version in git remain historical evidence. The host analysis used KOReader `825b9bced0eb666b45af4208e1c0095b88d38b0d` and base `7a46ea3812539083ee25b06f0c81ac58b1356ee0`: separate plugin instances, close ordering, quit clearing scheduled callbacks, and a subprocess helper without parent-death termination motivated the ownership discussion. Earlier lock/publication analysis is not a requirement of this revision.

The preserved branch `codex/ownership-5-10` is a rejected implementation reference. Read `0c86149` and follow-ups `d3029d9`, `5f87f3d`, and `94498ab` for navigation, completion-save retry, and cleanup/view integration lessons. They predate current master changes and must not be cherry-picked unchanged. The branch's later locking, recovery, and publication machinery is outside this decision. [ARCHITECTURE.md](../ARCHITECTURE.md) describes implemented master behavior separately from this proposal.
