# Navigation-safe download ownership: implementation tickets

Status: published and verified. Parent: [spec #3](https://github.com/LK4D4/suwayomi.koplugin/issues/3). All eight implementation issues use the ready-for-agent label and native blocked-by relationships.

## Execution contract

These are behavior slices of one unreleased feature, not independently shippable claims that all of spec #3 is complete. T1 is the prerequisite persistence refactor. Each later slice includes its own composed or physical acceptance checks; T8 verifies the assembled feature. Keep the evolving implementation out of a release until T8 passes. This planning task does not authorize branch changes, runtime edits, deployment, merging, or pushing.

Every ticket inherits spec #3 and accepted ADR-0002, preserves out-of-scope behavior, uses the existing redaction boundary, and keeps its relevant checks passing. Do not use an unsafe fallback to make an intermediate implementation appear complete. Adopt the new persisted protocol only when legacy proof and the new attempt pipeline are both available.

The approved dependency graph is intentionally mostly sequential. T6 and T7 may proceed independently after T5. The edges below omit redundant transitive blockers.

| Ticket | Delivers | Blocked by |
| --- | --- | --- |
| T1: Make plugin state writes atomic and report failed commands | A preference change or download command either commits complete state or reports failure without damaging saved jobs or later flushing rejected changes. | None |
| T2: Keep downloads and views stable across reader navigation | Downloads keep the same workers and progress through FileManager and ReaderUI transitions; newly opened views show current state and completion works without a screen. | T1 |
| T3: Exclude competing processes and guard legacy adoption | Only one KOReader process can use writable Suwayomi state, and an upgrade waits for proof that old workers cannot interfere. | T2 |
| T4: Stage and publish a chapter with explicit attempt ownership | One chapter downloads into private attempt files and becomes available only after the parent safely publishes its archive and commits completion metadata. | T3 |
| T5: Recover interrupted attempts and publication without duplicate transfers | After parent death, a new owner waits for surviving writers and resumes incomplete transfers or finishes validated archives without duplicate publication. | T4 |
| T6: Make cancellation, retries, and cleanup preserve attempt ownership | Cancel and retry actions survive restart, old output cannot affect replacement work, and temporary cleanup failures eventually converge. | T5 |
| T7: Stop download service within a bounded KOReader shutdown | All actual quit routes attempt to stop downloads within one two-second service budget while retaining safe restart recovery. | T5 |
| T8: Verify complete ownership behavior on a device | The assembled implementation satisfies the whole specification in composed tests, real OS/file checks, and the reported device navigation workflow. | T6, T7 |

## Publication record

Published one approved issue per ticket in dependency order, with real issue links and eight native blocked-by relationships. GitHub documents these relationships in its [issue-dependency API](https://docs.github.com/en/rest/issues/issue-dependencies).

The Parent section in each child references spec #3. The requested privacy correction replaces identifying device references in its current body and the local planning documents with generic wording. Parent status, labels, comments, and hierarchy remain unchanged. Current published bodies and labels were checked against the approved text; native blocking relationships were read back from GitHub.

Historical issue revisions and local Git commits have not been redacted. Removing the earlier issue-body revision requires an authenticated browser session; the available browser is signed out. The branch remains unpushed.

| Draft | Published issue | Native blockers |
| --- | --- | --- |
| T1 | [#4: Make plugin state writes atomic and report failed commands](https://github.com/LK4D4/suwayomi.koplugin/issues/4) | None |
| T2 | [#5: Keep downloads and views stable across reader navigation](https://github.com/LK4D4/suwayomi.koplugin/issues/5) | [#4](https://github.com/LK4D4/suwayomi.koplugin/issues/4) |
| T3 | [#6: Exclude competing processes and guard legacy adoption](https://github.com/LK4D4/suwayomi.koplugin/issues/6) | [#5](https://github.com/LK4D4/suwayomi.koplugin/issues/5) |
| T4 | [#7: Stage and publish a chapter with explicit attempt ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/7) | [#6](https://github.com/LK4D4/suwayomi.koplugin/issues/6) |
| T5 | [#8: Recover interrupted attempts and publication without duplicate transfers](https://github.com/LK4D4/suwayomi.koplugin/issues/8) | [#7](https://github.com/LK4D4/suwayomi.koplugin/issues/7) |
| T6 | [#9: Make cancellation, retries, and cleanup preserve attempt ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/9) | [#8](https://github.com/LK4D4/suwayomi.koplugin/issues/8) |
| T7 | [#10: Stop download service within a bounded KOReader shutdown](https://github.com/LK4D4/suwayomi.koplugin/issues/10) | [#8](https://github.com/LK4D4/suwayomi.koplugin/issues/8) |
| T8 | [#11: Verify complete ownership behavior on a device](https://github.com/LK4D4/suwayomi.koplugin/issues/11) | [#9](https://github.com/LK4D4/suwayomi.koplugin/issues/9), [#10](https://github.com/LK4D4/suwayomi.koplugin/issues/10) |

## Published tickets

### T1 / #4: Make plugin state writes atomic and report failed commands

#### Parent

[Spec #3: navigation-safe local download ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/3)

#### What to build

A preference change or download command either commits complete state or reports failure without damaging saved jobs or later flushing rejected changes.

This is one unreleased slice of spec #3. Preserve its accepted architecture and out-of-scope behavior. The complete feature is accepted only after final integration and device validation. Relevant user stories: 25, 26, 29.

#### Acceptance criteria

- [ ] Introduce one checked atomic write boundary for the complete shared plugin settings value, preserving unrelated settings. Route every plugin settings writer through it; hardening only download saves is insufficient.
- [ ] Stage changes separately from the committed cache. Check serialization, write, flush, close, replacement, and required synchronization results.
- [ ] Give transactions unique identities. A known pre-replacement failure leaves the committed state unchanged; post-replacement ambiguity blocks further writes and destructive transitions until stored transaction identity is reconciled.
- [ ] Exercise public preference changes and enqueue/cancel entry points with injected failures. No command reports durable success for a failed or uncertain save, and an unrelated later save cannot accidentally commit a rejected mutation.
- [ ] Preserve unfamiliar persisted versions and existing queue/ledger/context data. Add real temporary-file checks for atomic replacement and run the full existing suite, lint, and localization checks.

#### Blocked by

None (can start immediately).

### T2 / #5: Keep downloads and views stable across reader navigation

#### Parent

[Spec #3: navigation-safe local download ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/3)

#### What to build

Downloads keep the same workers and progress through FileManager and ReaderUI transitions; newly opened views show current state and completion works without a screen.

This is one unreleased slice of spec #3. Preserve its accepted architecture and out-of-scope behavior. The complete feature is accepted only after final integration and device validation. Relevant user stories: 1, 2, 3, 4, 5, 6, 7, 8, 9, 30, 32.

#### Acceptance criteria

- [ ] Introduce one process-owned service and return its queue from every production plugin instance. Construct dependencies without capturing the first UI. Reject parent-service access from an inherited child process object.
- [ ] Move durable download completion into the service, committing queue completion, ledger path, and archive lookup context through the checked store. Preserve existing finished-cleanup wakeups through a process-owned adapter with a live reader lookup.
- [ ] Give each live host an independent subscription and immediate snapshot. Detach idempotently on host CloseWidget without consuming it; reject queued callbacks after detach, release retired host references, and isolate subscriber exceptions.
- [ ] Refresh only live views, obtain fresh snapshots when views reopen, and enforce one scheduler and one process-wide concurrency limit. Screen/document closure and sleep/wake are not queue recovery or shutdown.
- [ ] Build the composed fixture using real shell/service/queue/scheduler/persistence/controller/row behavior with distinct host objects and a controlled non-inline clock/worker registry. Close FileManager before constructing ReaderUI, preserve modules through navigation, and model restart separately.
- [ ] Assert stable worker identity, progress, files, committed state, and displayed rows through FileManager–Reader A–FileManager–Reader B and reader-to-reader navigation. Prove zero-view completion, stale-callback rejection, and that one broken subscriber cannot interrupt another.

#### Blocked by

- [#4: Make plugin state writes atomic and report failed commands](https://github.com/LK4D4/suwayomi.koplugin/issues/4)

### T3 / #6: Exclude competing processes and guard legacy adoption

#### Parent

[Spec #3: navigation-safe local download ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/3)

#### What to build

Only one KOReader process can use writable Suwayomi state, and an upgrade waits for proof that old workers cannot interfere.

This is one unreleased slice of spec #3. Preserve its accepted architecture and out-of-scope behavior. The complete feature is accepted only after final integration and device validation. Relevant user stories: 17, 27, 28, 29, 33.

#### Acceptance criteria

- [ ] Acquire a process-associated lfs.lock on a stable dedicated lock file before mutable plugin initialization. Retain its handle, never replace/unlink that lock file, and avoid other descriptors whose close could release the owner's record lock.
- [ ] Disable the entire second writable Suwayomi instance, including all settings flushes, while leaving KOReader usable. Distinguish another owner from an unsupported or failed lock.
- [ ] A previously blocked process reloads shared settings after obtaining ownership. Startup is idempotent and reentrant-safe; UI attachment cannot repeat successful recovery.
- [ ] Persist protocol-adoption and legacy-proof state using the checked store. Uncertain old-worker history blocks scheduling/destructive recovery even when the old queue is empty, queued, or failed.
- [ ] Accept verified old-worker-tree termination or a verified boot change after recording the uncertain boot. A confirmation button, missing progress, or KOReader relaunch alone cannot bypass the gate. Keep proof separate from activation of the new attempt protocol.
- [ ] Preserve unknown versions and old state if migration fails. Never advertise full protocol adoption while the active worker path can still publish legacy shared files.
- [ ] Use actual OS processes to verify exclusion, stale-cache protection, and process-lock release. Check the actual Android settings mount; unsupported semantics must fail safely rather than use PID or timestamp guesses.

#### Blocked by

- [#5: Keep downloads and views stable across reader navigation](https://github.com/LK4D4/suwayomi.koplugin/issues/5)

### T4 / #7: Stage and publish a chapter with explicit attempt ownership

#### Parent

[Spec #3: navigation-safe local download ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/3)

#### What to build

One chapter downloads into private attempt files and becomes available only after the parent safely publishes its archive and commits completion metadata.

This is one unreleased slice of spec #3. Preserve its accepted architecture and out-of-scope behavior. The complete feature is accepted only after final integration and device validation. Relevant user stories: 16, 19, 23, 28, 33, 35.

#### Acceptance criteria

- [ ] Implement the specification's versioned attempt allocation, launch authorization, completion receipt, publication intent, and writer-retired records. Persist exact paths before creating attempt files and commit launch authorization while holding the attempt lock before fork.
- [ ] Use a unique attempt identity for every launch, including retries. Keep the child’s inherited flock descriptor until process exit; the parent immediately closes its copy without unlocking it. Later forks must not inherit any other attempt or recovery lock.
- [ ] Make workers write only private staging/progress/temporary files and a validated, identity-bound completion receipt. Remove child authority to publish canonical archives or write shared settings.
- [ ] Retain the worker slot and file authority through confirmed exit/reaping, including terminal-receipt, timeout, and stop races. A subprocess-helper error or a sent signal never proves exit.
- [ ] Validate the receipt and artifact, persist publication intent, and publish with an actual atomic no-replace operation on the destination filesystem. Preserve unrelated destination files and report conflicts; no existence-check/overwriting-rename fallback.
- [ ] Atomically commit queue completion, ledger path, and archive lookup context before displaying completion. Retain failed finalization work and keep deletion guards aware of terminating/finalizing ownership.
- [ ] Record writer-retired cleanup authorization before unlinking private artifacts or attempt locks. Never include the final archive in attempt cleanup.
- [ ] Demonstrate enqueue through displayed completion with real composition. Add actual-child/filesystem checks for attempt-lock inheritance, sibling non-inheritance, terminal-progress races, content validation, and no-replace publication; verify Android destination support.

#### Blocked by

- [#6: Exclude competing processes and guard legacy adoption](https://github.com/LK4D4/suwayomi.koplugin/issues/6)

### T5 / #8: Recover interrupted attempts and publication without duplicate transfers

#### Parent

[Spec #3: navigation-safe local download ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/3)

#### What to build

After parent death, a new owner waits for surviving writers and resumes incomplete transfers or finishes validated archives without duplicate publication.

This is one unreleased slice of spec #3. Preserve its accepted architecture and out-of-scope behavior. The complete feature is accepted only after final integration and device validation. Relevant user stories: 12, 15, 16, 18, 19, 24, 29, 35.

#### Acceptance criteria

- [ ] Reconcile persisted attempt phases once on fresh owning-service startup, then retry blocked recovery as service work. Never re-fork a prior session's attempt; allocate a new attempt when an incomplete chapter must be transferred again.
- [ ] Require independent acquisition of each old attempt lock before touching files. Pause new chapter launches while an old writer is unresolved; reject PID reuse, timestamps, missing progress, terminal receipts, and ECHILD as ownership proof.
- [ ] Recognize allocation-only records as never launch-authorized. Preserve unexpectedly missing authorized locks or unreadable/unknown records and explain the blocker.
- [ ] Recover validated staging after writer exit; recognize a matching published archive by content identity and retry only metadata. Preserve an unrelated target as a conflict.
- [ ] Preserve retry order, count, deadline, errors, and unfinished intent. Restart alone does not consume a network-failure retry.
- [ ] Recover durable canceled dispositions without requeuing, and honor writer-retired cleanup records after intentional lock removal. Seed each durable phase at the storage boundary, then exercise startup through the real service and UI snapshot.
- [ ] Interrupt after allocation, lock creation, launch authorization, fork, receipt, publication-intent commit, publication, metadata commit, and authorized lock unlink. Assert convergence, files, committed state, and displayed state together.
- [ ] Include a real surviving child across parent death to verify lock-based waiting and eventual progress. Recovered lock descriptors must close before any later child launch.

#### Blocked by

- [#7: Stage and publish a chapter with explicit attempt ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/7)

### T6 / #9: Make cancellation, retries, and cleanup preserve attempt ownership

#### Parent

[Spec #3: navigation-safe local download ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/3)

#### What to build

Cancel and retry actions survive restart, old output cannot affect replacement work, and temporary cleanup failures eventually converge.

This is one unreleased slice of spec #3. Preserve its accepted architecture and out-of-scope behavior. The complete feature is accepted only after final integration and device validation. Relevant user stories: 10, 11, 12, 13, 20, 21, 22, 24, 30, 31.

#### Acceptance criteria

- [ ] Persist cancellation before acknowledging it. Before publication, stop/reap and clean only the canceled attempt; after publication, preserve the archive and finish bookkeeping. Explicit Delete remains responsible for later archive removal.
- [ ] Clearing a visible failed/canceled row must not discard pending worker or cleanup ownership. Public Delete and existing finished-cleanup guards must treat terminating/finalizing paths as owned.
- [ ] Exercise cancellation before publication, after publication but before metadata commit, during uncertain persistence, and across restart through public actions. No falsely acknowledged cancellation or revived canceled transfer.
- [ ] Give retries fresh namespaces and reject late receipts/progress from retired attempts. Preserve existing transient retry classification, deadlines/counts, outage pausing, quiet failures, and retry inspection.
- [ ] Keep destination fixed at enqueue and read connection settings per attempt. Lowered concurrency lets current workers finish; navigation and wake retain the same queue and do not spend retries.
- [ ] Persist remaining cleanup targets and retry intent before retiring records. Removal failures retry during the session and after restart, eventually removing only authorized private artifacts.
- [ ] Verify public actions, real queue/cleanup behavior, committed state, files, and displayed rows together. Preserve existing cleanup wakeups without subscribers and keep diagnostic data redacted.

#### Blocked by

- [#8: Recover interrupted attempts and publication without duplicate transfers](https://github.com/LK4D4/suwayomi.koplugin/issues/8)

### T7 / #10: Stop download service within a bounded KOReader shutdown

#### Parent

[Spec #3: navigation-safe local download ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/3)

#### What to build

All actual quit routes attempt to stop downloads within one two-second service budget while retaining safe restart recovery.

This is one unreleased slice of spec #3. Preserve its accepted architecture and out-of-scope behavior. The complete feature is accepted only after final integration and device validation. Relevant user stories: 14, 15, 16.

#### Acceptance criteria

- [ ] Install one isolated, idempotent UIManager.quit wrapper that chains the prior method and preserves arguments/returns. Do not treat CloseWidget, CloseDocument, or plugin-screen closure as shutdown.
- [ ] Stop admission/publication and invalidate ordinary timers/subscribers immediately. Signal known children and use nonblocking reaping against one monotonic two-second total deadline, not a deadline per child.
- [ ] Require no final settings save, network request, future UI tick, or completed chapter on the shutdown path; pre-launch durable intent is the recovery record.
- [ ] Retain locked artifacts for unconfirmed children. Expiring the deadline does not grant cleanup or publication authority, and shutdown errors cannot prevent the original quit method from running.
- [ ] Fence plugin writers and hold process ownership through the original quit method's synchronous work. Release afterward or at process exit; a stopped service cannot restart in the exiting process.
- [ ] Drive Exit, Restart, direct quit, Back-to-exit, repeated shutdown, and navigation negative controls through host composition. Then start a fresh service and prove jobs recover under the attempt-lock rules.
- [ ] Measure the service-added budget with actual child processes, including a child whose exit is not confirmed before the deadline. Distinguish this budget from the original host's shutdown duration.

#### Blocked by

- [#8: Recover interrupted attempts and publication without duplicate transfers](https://github.com/LK4D4/suwayomi.koplugin/issues/8)

### T8 / #11: Verify complete ownership behavior on a device

#### Parent

[Spec #3: navigation-safe local download ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/3)

#### What to build

The assembled implementation satisfies the whole specification in composed tests, real OS/file checks, and the reported device navigation workflow.

This is one unreleased slice of spec #3. Preserve its accepted architecture and out-of-scope behavior. The complete feature is accepted only after final integration and device validation. Relevant user stories: 1, 2, 3, 4, 5, 8, 14, 15, 16, 32, 33, 34, 35, 36.

#### Acceptance criteria

- [ ] Audit every acceptance case and user story in spec #3 against the completed implementation. Fill composed coverage gaps without substituting refresh counts or per-UI queue mocks.
- [ ] Run the full LuaJIT suite, lint, localization checks, and complete real filesystem/process checks for exclusion, fork inheritance, orphan waiting, reaping, publication, atomic settings, and cleanup. Record unsupported platform behavior explicitly.
- [ ] On a device, establish a Downloads-only control with 8–10 missing chapters at concurrency two. Repeat while opening an existing chapter, returning, opening another, and switching readers directly; repeat at concurrency one.
- [ ] Record chapter-worker counts, attempt/progress continuity, and returned UI state. Require no navigation-triggered reset, requeue, replacement, or active-file removal. Distinguish other plugin workers from chapter workers.
- [ ] Verify zero-view completion, explicit quit/relaunch, and required platform primitives on actual settings and download mounts. Redact user data and never damage device storage to provoke failures.
- [ ] Update the architecture reference and user-facing upgrade/blocker guidance for implemented behavior. Preserve runtime packaging boundaries and all out-of-scope policies.
- [ ] Run required GitHub Actions before any separately authorized implementation merge. Record final evidence and unresolved blockers; do not claim acceptance if any required layer is missing.
- [ ] Keep parent spec #3 and original report #2 unchanged. This ticket verifies the scoped feature; closing or editing those parent reports remains separate work.

#### Blocked by

- [#9: Make cancellation, retries, and cleanup preserve attempt ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/9)
- [#10: Stop download service within a bounded KOReader shutdown](https://github.com/LK4D4/suwayomi.koplugin/issues/10)
