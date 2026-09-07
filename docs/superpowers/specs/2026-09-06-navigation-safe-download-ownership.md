# Navigation-safe local downloads

Status: revised and accepted on 2026-09-07; implementation and device acceptance pending. This file is the authoritative specification and is mirrored verbatim in [spec #3](https://github.com/LK4D4/suwayomi.koplugin/issues/3). Change both together. ADR-0002 records the decision; #5 implements it and #11 verifies it on a device.

## Problem and decision

The reproduced defect is download progress resetting or work requeueing when navigating between FileManager and ReaderUI. On master at `01ed3e3`, `main.lua` creates a queue per plugin instance and calls recovery during each initialization. Archive-ready callbacks and queue-triggered cleanup also capture that instance. Separate hosts can therefore compete for persisted work and shared files. The application-crash cause in original report #2 remains unproved; leave that report open and unchanged.

Keep one queue for the lifetime of the KOReader main process, with disposable UI subscriptions. Reuse the existing downloader and subprocess helper. Interrupted work may fail on genuine restart and require explicit retry. This specification supersedes the earlier reboot/ownership-recovery protocol, including its crash salvage and publication guarantees. It does not add exceptions around that protocol; the protocol is removed from active scope.

## Runtime contract

### One queue and live views

- Add a small process-owned service under `suwayomi/downloads/` around the existing queue. Keep `main.lua` as lifecycle/composition glue and retain existing application-facing queue methods.
- Every production queue access resolves to the same service. Startup normalization runs once before admission in a fresh main process. Reentrant initialization, attaching another host, screen/document closure, and sleep/wake never construct or recover another queue. Retry of a failed startup save is service work, not another host initialization.
- Keep process state alive with zero subscribers. The service owns polling, retry scheduling, known worker records, completion bookkeeping, and existing queue-triggered finished-cleanup wakeups. Resolve the live reader through current host lookup; do not retain the first or a retired UI as a background owner.
- Attach each live host independently and return current state. Detach idempotently on host CloseWidget without consuming the event; release callback references and invalidate already queued deliveries. Closed screens receive no rendering callbacks; hidden screens refresh from current state when shown. Opening chapter, Downloads, or home views reads current committed state.
- Deliver UI notifications after state changes and required persistence. Isolate subscriber exceptions so they cannot fail a transfer, block completion, or prevent another live view from updating.
- Children continue to execute only the existing downloader worker path, not service initialization, settings writes, or UI operations. No custom process registry across separate KOReader processes is needed.

### Concurrency, retry, and files during the session

Use the existing `downloads/active_jobs.lua` scheduler and KOReader `ffi/util.runInSubProcess`, `terminateSubProcess`, and `isSubProcessDone`. Do not replace them with custom fork/waitpid bindings. Preserve one process-wide chapter limit, ordinary transient retry classification/backoff/counts/deadlines, outage behavior, and quiet error inspection. Navigation retains queue order, current worker handles, progress files, and retry state. Sleep can cause a real network failure; it is not itself a restart. Lowering concurrency does not kill current workers and admits no replacement until capacity exists.

The current scheduler already tracks `terminating_pids` and pauses launches while a known child is stopping. Extend that narrow mechanism to retain the corresponding chapter and temporary-file information until the existing helper reports the known child done. A failed/canceled row, sent signal, or terminal progress message alone is not child termination. Keep known stopping workers counted and the chapter busy even if its visible row is cleared. Do not remove their progress/partial files or reuse those files for retry while they can still write. Ordinary Cancel, Cancel all, timeout, automatic retry, and explicit Retry must pass through this same handling; no new cancellation journal or control is required.

After the known child is done, use existing cleanup facilities for its progress, `.part`, and direct-download partial files, then allow replacement work. Keep cleanup narrow to that job. If removal fails, defer cleanup or let the next explicit retry fail clearly through the existing downloader; do not build a durable cleanup infrastructure project. Cancellation/retry cleanup never removes a final CBZ. If a worker completed just before cancellation, preserve the archive and finish necessary bookkeeping; cancellation does not mean Delete.

Keep the existing source-scoped final archive layout and downloader's validation, existing-archive lookup, and final rename behavior. Do not introduce a staging/publication protocol or claim atomic no-replace publication against arbitrary external writers. Capture the download directory at enqueue and read current connection settings for each attempt. Preserve duplicate admission behavior and existing Delete/live-reader guards, including known stopping or completion-pending work in the running process.

### Completion without a screen

When the existing downloader produces or finds a usable final archive, the service completes the existing metadata work independently of subscribers. Use the existing checked store transaction interface to update the downloaded ledger path, reader-return lookup context, and queue completion together, preserving current read/pending-sync choices and unrelated fields. Only then report completed state, release completion ownership, and wake existing cleanup and live views.

A rejected or ambiguous save must not become apparent success. Preserve master’s store fence/reconciliation behavior. Keep pending completion in the running service and retry the metadata transaction after reconciliation; do not start another transfer or let the network watchdog turn a completed archive into a network failure. This is ordinary in-session bookkeeping retry, not a durable publication journal. A real process death during bookkeeping has the restart behavior below.

### Genuine startup/restart

Apply this policy once to the existing settings-backed queue, using checked persistence before publishing normalized status or admitting new work:

| Existing persisted state | Startup result |
| --- | --- |
| `queued`, including never-started jobs and delayed transient retries with `retry_at` | If no usable final archive is found by the existing lookup, change to terminal `failed` with “Interrupted; retry download”. Retain identifying metadata, captured directory, and retry history for inspection; clear automatic retry scheduling. |
| `downloading`, including work whose transfer or completion bookkeeping was interrupted | Apply the same failed result when no usable final archive exists. Do not resume from old progress, restart a transfer automatically, or trust a persisted PID as a live child handle. |
| A usable final CBZ already exists for either unfinished state | Preserve the archive and reconcile its existing ledger/context/queue bookkeeping through the same checked completion operation. Do not re-download it or mark the completed download interrupted. This uses existing archive lookup, not staging salvage or content-hash identity. |
| Existing terminal `failed` | Preserve the job and its full permanent-failure diagnostic. Do not replace it with interruption text, clear it as a side effect of startup, or schedule an automatic retry. Existing archive discovery remains available through normal UI/explicit actions. |
| Already completed downloads, outside the pending queue | Leave archives, ledger/read state, and contexts unchanged. Completed runtime statuses are `downloaded`/`skipped`; successful jobs are normally removed from the persisted queue. |
| Unknown or unsupported records | Preserve them without interpreting them as launchable or deleting files. Do not invent a migration into the rejected branch's attempt schema. |

Store interruption as inspectable failure detail and localize the plugin-authored explanation. Startup failures stay quiet, using the existing failure count, rows, and on-demand full diagnostics. Explicit chapter/Downloads Retry revalidates current state, uses the existing retry/enqueue path and current credentials, and can complete successfully. No automatic retry survives a genuine restart merely because an old deadline is due; deadlines remain stable only within the running session.

Startup classification does not terminate any child. It must not sweep legacy progress/partial files or infer old-worker death from a failed queue, an empty queue, missing progress, or a PID. Defer temporary cleanup to ordinary job handling. First launch/upgrade requires neither device reboot nor storage relocation nor a global proof gate. A normal KOReader relaunch to load updated plugin code is sufficient to start using it; hot reload is unsupported.

### Normal quit

Install one narrow, idempotent wrapper around `UIManager.quit`, chaining the previous method with its arguments/returns intact. Stop service admission and invalidate polling/retry/subscriber callbacks. Use existing helper calls to signal known active/stopping workers and check them within one total budget of at most two seconds of service-added work. Do not wait per worker, introduce a custom kill/reap framework, perform network work, require a final settings save, or depend on another UI tick. Always call the original quit method even if service shutdown fails. Repeated quit does not restart the service.

The existing helper's termination/check behavior must be verified on the target KOReader version as part of implementation and device acceptance. Leave unconfirmed worker files untouched when the budget ends. Persisted unfinished work follows the startup table on relaunch; quit does not promise transfer completion or automatic resumption.

## Accepted limitations and exclusions

Abrupt process death can bypass shutdown and leave children running. A new process has no reliable ownership evidence for those children. Surviving old or legacy workers can still write shared partial/progress/final paths; explicit retry may conflict, fail, or repeat a transfer. Missing progress and `isSubProcessDone` on an unowned PID do not prove orphan exit. Do not claim safe orphan salvage or cleanup. Preserve existing final archives in normal paths and defer uncertain temporary cleanup; do not block ordinary first use behind reboot or a global legacy gate.

No device reboot requirement, directory change, inherited attempt locks, boot identities, receipt/content-hash protocol, multi-phase publication journal, automatic crash salvage, custom fork/waitpid wrappers, or coordination between simultaneously writable KOReader processes. Concurrent writable processes and hot reload are unsupported. The same-process known-worker checks above do not establish cross-process guarantees.

Preserve #4's atomic shared-settings protections already on master. Do not broaden chapter retrieval, Download ahead, read-sync, manual deletion, retention policy, settings semantics, quiet failure UX, or device-local download behavior. Existing cleanup wakeups move with the queue; new policy or durable manual-delete/refill work stays in its own issues. Those issues cannot impose their removed process/attempt infrastructure on #5.

## Focused acceptance

Reuse existing `spec/support/plugin_runtime_spec_helper.lua`, queue/active-job/downloader fixtures, download-failure UX composition, and manual-completion patterns. Drive real public plugin/menu actions through real service, queue, checked persistence, filesystem effects, controllers, and rendered rows. Stub KOReader/network/worker boundaries where needed; keep scheduled callbacks non-inline. Keep main specs focused on shell lifecycle. A per-host mocked queue or refresh-call count does not establish the fix.

- Through FileManager–Reader A–FileManager–Reader B and Reader A–Reader B, keep process modules loaded and prove identical queue/known workers/progress, no recovery or active-file removal, and bounded chapter concurrency at two and one. Sleep/wake and a lower limit preserve the same state.
- Complete with all Suwayomi screens closed. Assert the final archive, committed ledger/context/queue, unchanged read choices, existing cleanup wakeup, and current returned chapter/Downloads/home rendering together. Invoke queued callbacks after detach and include one throwing subscriber.
- Compose a failed completion save and master’s ambiguous-store reconciliation with navigation and zero views. Retry bookkeeping successfully in-session without another transfer or a watchdog failure.
- Exercise public Cancel/Cancel all and retry while a known worker stops. Observe its files and concurrency reservation until the existing helper reports done; then retry successfully. Preserve a final CBZ and existing quiet failure/error-detail behavior.
- Model a real restart with a fresh process service and retained settings/files, separately from host navigation. Cover both unfinished states, delayed retries, existing completed archives, pre-existing permanent failures, and successful explicit Retry. Startup neither deletes old temporary files nor launches unfinished jobs automatically.
- Verify first launch/upgrade without reboot, directory relocation, or old-worker gate. Cover empty and unfinished legacy queues. No attempt-protocol migration is required.
- Exercise direct quit, Exit/Restart routes reaching quit, repeated quit, and navigation negative controls. Verify original quit invocation, invalidated timers, bounded service work, and failed unfinished work after relaunch. Use focused actual-helper/process checks where needed to establish the bounded stop, plus real temporary files for completion/cancel/retry effects; no exhaustive crash-boundary or lock/publication matrix.

For the implementation, run full LuaJIT tests, Luacheck, localization checks, and the repository-required GitHub Actions before any separately authorized merge. Update architecture and user guidance only for behavior actually implemented. #11 separately requires device controls: 8–10 missing chapters, Downloads-only versus both navigation routes, concurrency two then one, zero-screen completion, sleep/wake, normal quit/relaunch, interrupted failure inspection, and successful explicit retry. Record revision, generic environment, observed worker counts/state, and demonstrated/failed/unverified results with redacted diagnostics. Do not damage storage to provoke failures.

## Delivery and references

One implementation issue, #5, includes the service/view seam, completion bookkeeping, simple startup failure policy, narrow cancellation/retry file handling, bounded quit, and focused tests. #11 owns device acceptance. #6–#10 are superseded/not planned, not successfully implemented; #4 stays complete and unchanged. No new infrastructure ticket sequence is needed. Scope is one focused coding session plus device acceptance, without skipping necessary tests.

ADR-0002 and the unchanged historical investigation record why the decision changed. The rejected branch `codex/ownership-5-10` remains an implementation reference only. Read early navigation commit `0c86149` and follow-ups `d3029d9`, `5f87f3d`, and `94498ab`; adapt their lessons to current master rather than cherry-picking them unchanged. This planning revision implements nothing and establishes no runtime or device pass.
