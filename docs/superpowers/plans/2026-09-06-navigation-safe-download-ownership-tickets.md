# Navigation-safe downloads: one implementation and device acceptance

Revised 2026-09-07. [Spec #3](https://github.com/LK4D4/suwayomi.koplugin/issues/3) mirrors the [authoritative local specification](../specs/2026-09-06-navigation-safe-download-ownership.md) verbatim. [ADR-0002](../../adr/0002-navigation-safe-download-ownership.md) supersedes the earlier reboot/ownership-recovery protocol. Runtime implementation and device acceptance remain pending.

## Current routing

| Issue | Disposition | Native blocked by |
| --- | --- | --- |
| #4: Make plugin state writes atomic and report failed commands | Completed; unchanged. Existing master protections remain required. | None |
| #5: Keep downloads and views stable across reader navigation | The single implementation, ready-for-agent | #4 (already completed) |
| #6–#10 | Closed as superseded/not planned, with wontfix; not implemented completion | None |
| #11: Verify navigation-safe downloads on a device | Focused device acceptance, ready-for-human | #5 |

No new replacement issue or infrastructure sequence is needed. #3 stays open. Original report #2 remains open and unchanged. Current #5 and #11 bodies are reproduced below; update the issue and its local body together.

## Dependency repair

Before editing, read current bodies, comments, canonical labels, native blocking edges, and parent relationships. #6–#10 were open with no comments or completed acceptance evidence; the rejected reference branch does not establish acceptance of this revision.

| Consumer | Former blockers | Revised blockers |
| --- | --- | --- |
| #11 | #9, #10 | #5 |
| #36 (manual deletion) | #9, #10 | #5 |
| #26 (refill) | #25, #36, #10 | #25, #36, #5 |
| #37 (manual-deletion device acceptance) | #36, #11 | Unchanged |

Remove the obsolete chain #6 blocked by #5, #7 by #6, #8 by #7, and #9/#10 by #8. Remove every incoming/outgoing native blocker on #6–#10 after adding replacements. None of #3–#11 had native parent/sub-issue relationships; preserve that hierarchy. Preserve unrelated blockers, parents, labels, and completion records, including completed #4 and the #12/#36/#37 hierarchy.

Direct dependency corrections in #12/#36 and their local documents now refer to #5's process service and known-worker behavior, not nonexistent archive-generation or OS-lock guarantees. Archive identity and conditional manual-removal coordination remain owned by #36; uncertain targets remain blocked by that feature's existing contract. They cannot expand #5 or require the rejected global legacy gate.

Likewise, #22/#26/#27 and ADR-0004 retain refill semantics and durable refill requests, but stop inheriting the removed lock/launch/publication machinery. Their context helper reuses existing subprocess facilities and #5's bounded quit integration. Chapter transfers interrupted by a restart remain terminal failures until explicit Retry under revised #3.

## History and review

The historical investigation evidence is unchanged; only its planning routing reflects the revised tickets. Prior ADR/spec/ticket versions remain in git and issue edit history. Superseded #6–#10 retain their original requirements below an explicit historical banner, with obsolete active Blocked by sections removed and a closure explanation linking #3/#5. Do not mark their checkboxes complete. The rejected codex/ownership-5-10 branch/worktree remains unchanged.

Use 0c86149 and follow-ups d3029d9, 5f87f3d, and 94498ab only as implementation references against current master. No cherry-pick, runtime edit, device operation, merge, push, or branch/worktree deletion is part of this cleanup.

Consistency review must compare #3's exact local/public text, #5/#11 bodies, native dependencies, closure reasons, canonical labels, and preserved #2/#4 fields/comments. No feature or device pass is established here. The reduced implementation has no remaining crash-recovery or cross-process prerequisite; focused tests and device evidence remain necessary.

Readback verified all 14 edited issue bodies, including the exact local/public #3 text, and all five NOT_PLANNED closures with wontfix. The complete dependency graph changed only by the three replacement edges and ten removals listed above. Native parents/sub-issues, #2/#4, and unrelated issues remained unchanged. #11 is open with ready-for-human; #3/#5 remain open with ready-for-agent. Local review checked documentation scope, relative links, whitespace, and preserved investigation evidence. No runtime tests or device checks were run for this documentation-only revision.

## #5: Keep downloads and views stable across reader navigation

## Parent

[Spec #3: navigation-safe local downloads](https://github.com/LK4D4/suwayomi.koplugin/issues/3), revised 2026-09-07 under ADR-0002.

## What to build

Keep one download queue through FileManager–ReaderUI and reader-to-reader navigation. This issue owns the complete reduced implementation: the service/view seam, completion without screens, simple restart failure handling, ordinary cancellation/retry file handling, and bounded quit. Reuse the existing modules and KOReader subprocess helper. Scope is one focused coding session plus separate device acceptance in #11, with necessary tests included.

This replaces the narrowly necessary completion, cancellation, and shutdown work previously split across #6–#10. Their reboot/legacy gate, process/attempt locks, publication journal, and automatic crash salvage are not planned. Those closures do not mean the feature is implemented. #4's atomic settings protections already on master remain unchanged.

## Acceptance criteria

- [ ] Every production plugin instance gets the same process-owned queue. Initialize once on a fresh main process; navigation, screen/document closure, and sleep/wake do not recover, requeue, replace workers, or remove active files. Keep main.lua as composition glue.
- [ ] Use disposable host subscriptions and current snapshots. Detach on CloseWidget without consuming it; queued deliveries after detach do nothing and release retired callback references. Reopened chapter, Downloads, and home views show current state. Subscriber exceptions cannot interrupt service work or other views.
- [ ] Move archive completion and existing finished-cleanup wakeups out of UI callbacks. Through the existing checked store, commit queue completion, ledger path, and reader-return context while preserving current read/pending-sync state. Retain in-session completion-save retries through navigation, zero screens, and store reconciliation without another transfer or a watchdog failure.
- [ ] Preserve process-wide chapter concurrency and ordinary in-session transient retry behavior, full diagnostics, quiet failures, captured directory, current credentials per attempt, archive layout, and existing settings semantics. A lower limit lets current workers finish; navigation/wake alone does not spend retries.
- [ ] Reuse active_jobs and ffi/util launch/termination/completion helpers. Extend existing terminating-worker tracking only enough to retain chapter/file associations and defer cleanup/replacement while a known child is stopping. Failed/cleared rows and sent signals do not terminate children. Apply this to public Cancel/Cancel all, timeout, automatic retry, and explicit Retry; keep known stopping and completion-pending chapters busy. Preserve final CBZs. Use existing narrow temporary cleanup after known completion; deferred cleanup or a clearly failed/repeated transfer is acceptable.
- [ ] On real startup, change unfinished persisted queued and downloading jobs, including queued delayed retries, to terminal failed with “Interrupted; retry download” and no automatic scheduling. Preserve existing permanent-failure diagnostics. If existing lookup finds a usable final archive, preserve it and reconcile completion bookkeeping instead. Leave already completed downloads and unsupported records unchanged. Do not sweep legacy temporary files or invent a migration to the rejected branch's protocol.
- [ ] First launch/upgrade admits ordinary use without device reboot, storage relocation, or global legacy-worker proof. Explicit chapter/Downloads Retry succeeds after interruption using existing file handling. State honestly that an untracked surviving old child can still write shared paths and retry can conflict; do not add cross-process recovery guarantees.
- [ ] Add one idempotent UIManager.quit integration that chains the previous method and preserves arguments/returns. Stop admission and invalidate service callbacks; attempt to stop/check known workers through existing helpers within at most two seconds total of added work. Always invoke original quit, even on failure. No per-worker wait budget, custom fork/waitpid wrappers, required final save, future UI tick, or network work. Leave unconfirmed worker files untouched.
- [ ] Reuse existing composed fixtures. Drive real public menu/plugin actions through shell/service/queue/scheduler, checked persistence, filesystem effects, and rendered state. Cover both navigation routes at concurrency two and one, zero-screen completion, detached/throwing subscribers, completion-save failure/reconciliation, cancellation/retry while a child stops, fresh-process startup states, and quit/relaunch. Verify helper stop behavior and relevant real temporary-file effects; no exhaustive crash-boundary or lock/publication matrix.
- [ ] Run full LuaJIT tests, Luacheck, and localization checks. Before a separately authorized merge, run required branch GitHub Actions. Update architecture and user guidance only for implemented behavior; leave device evidence to #11.

## Boundaries and references

Do not broaden chapter retrieval, Download ahead, read-sync, manual deletion, retention, or settings policy. Future archive-generation or refill requirements belong to their own tickets; they do not make #5 an infrastructure prerequisite for removed guarantees. No mandatory reboot, directory change, inherited attempt locks, boot identities, receipt/content-hash protocol, multi-phase publication journal, automatic crash salvage, or coordination between simultaneously writable KOReader processes.

Read early navigation commit 0c86149 and follow-ups d3029d9, 5f87f3d, and 94498ab on the preserved rejected branch codex/ownership-5-10 as implementation references only. They predate current master changes; do not cherry-pick unchanged or import the later rejected machinery.

## Blocked by

- [#4: Make plugin state writes atomic and report failed commands](https://github.com/LK4D4/suwayomi.koplugin/issues/4) — completed and integrated; preserve its protections.

Implementation remains open. Planning and reference-branch work are not acceptance of this revision.

## #11: Verify navigation-safe downloads on a device

## Parent

[Spec #3: navigation-safe local downloads](https://github.com/LK4D4/suwayomi.koplugin/issues/3), revised 2026-09-07 under ADR-0002.

## What to verify

Verify the single implementation in #5 on a device using controlled test data. The target is navigation continuity and usable restart/retry behavior. The former lock, reboot-proof, publication, and crash-salvage matrix is removed. Keep this issue open until actual device evidence exists.

## Acceptance criteria

- [ ] Review #5's focused composed tests, helper/file checks, LuaJIT suite, lint, localization, and required CI evidence for the tested implementation. Record missing evidence; planning or CI alone does not prove device acceptance.
- [ ] On first launch/upgrade, use the existing settings and download directory without reboot, relocation, or a global old-worker gate. Include empty and unfinished persisted queue cases using controlled fixtures. Do not damage storage or alter real library data to provoke failures.
- [ ] Queue 8–10 missing test chapters at concurrency two and establish a Downloads-only control. Repeat while opening an already downloaded chapter, returning to FileManager, opening another, and switching reader-to-reader. Repeat at concurrency one.
- [ ] Record chapter-worker counts and progress around navigation. Require the same queue and known workers, no navigation-triggered reset/requeue/replacement or active-file removal, and bounded concurrency. Distinguish chapter workers from thumbnail, search, and read-sync workers.
- [ ] Close all Suwayomi screens while downloads complete. Verify the final archives, persisted ledger/reader-return context and queue completion, existing cleanup behavior, and current chapter/Downloads/home state on return. Retired screens receive no callbacks.
- [ ] Exercise sleep/wake and a lower concurrency setting without queue reconstruction. Separate a real network failure and ordinary retry from navigation-triggered loss; retain quiet errors and on-demand full details.
- [ ] Exercise ordinary cancellation and explicit Retry, including known workers still stopping. Verify deferred temporary cleanup/replacement and final-archive preservation using the implementation's controlled helper evidence where unsafe timing cannot be induced on-device.
- [ ] Quit normally with unfinished work and relaunch. Confirm bounded best-effort shutdown, no transfer auto-resumption, interrupted queued/downloading jobs (including delayed retries) shown failed with “Interrupted; retry download”, existing permanent errors retained, and completed archives/metadata preserved. Explicit chapter/Downloads Retry must then complete successfully.
- [ ] Record plugin revision, KOReader version, runtime-payload verification extent, generic environment, batch/concurrency, navigation and sleep/network controls, actual results, and gaps. Mark each case demonstrated, failed, or unverified. Redact credentials, URLs, private paths, library/source/chapter titles, identifying device details, and raw logs.
- [ ] Document accepted limits: abrupt death may leave an untracked child writing shared paths; retry can fail or repeat a transfer and temporary cleanup can be deferred. No orphan-isolation, crash-salvage, simultaneous-writer, or mandatory reboot acceptance is required. Keep original report #2 open and unchanged; do not claim its unexplained crash is resolved.

## Blocked by

- [#5: Keep downloads and views stable across reader navigation](https://github.com/LK4D4/suwayomi.koplugin/issues/5) — the complete reduced implementation must be available for testing.

Device acceptance remains pending. This issue is ready-for-human.
