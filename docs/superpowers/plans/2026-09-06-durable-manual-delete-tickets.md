# Durable manual deletion: implementation tickets

Status: published and verified. Parent: [spec #12](https://github.com/LK4D4/suwayomi.koplugin/issues/12). All eight implementation issues use ready-for-agent and have the approved native blocked-by relationships.

## Execution contract

These eight behavior slices implement one unreleased feature. Each includes an end-to-end public action or independently verifiable outcome and its own relevant checks. M1–M2 establish lasting archive identity and safe file ownership through existing download/Delete paths. M3 implements the narrow single-action path; later slices complete worker competition, recovery, batches, and retention integration. Keep the evolving feature out of a release until M8 passes. Unsupported intermediate transitions remain safely blocked rather than using current unsafe fallback behavior.

All tickets inherit accepted ADR-0003 and spec #12. The navigation-safe ownership foundation already has implementation tickets; do not recreate or silently expand them. This planning task authorizes no runtime edits, branch switches, deployment, merging, or pushing.

## Published breakdown

M1–M8 retain the approved draft identifiers; the issue links are the implementation tickets.

| Ticket | Delivers | Blocked by |
| --- | --- | --- |
| M1: [#13: Preserve archive generations across publication and removal](https://github.com/LK4D4/suwayomi.koplugin/issues/13) | A completed chapter retains its archive generation through restart and read-state changes, and a stale removal cannot clear or delete a later archive at the same path. | [#9: Make cancellation, retries, and cleanup preserve attempt ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/9) |
| M2: [#14: Delete verified legacy archives without harming shared metadata](https://github.com/LK4D4/suwayomi.koplugin/issues/14) | An authorized Delete can safely identify an existing archive, preserve live or shared metadata, and report exactly what was removed or retained. | [#13: Preserve archive generations across publication and removal](https://github.com/LK4D4/suwayomi.koplugin/issues/13) |
| M3: [#15: Make single-chapter manual deletion durable and inspectable](https://github.com/LK4D4/suwayomi.koplugin/issues/15) | Marking one downloaded chapter read admits a durable manual-delete request before removal, shows pending work when it cannot finish immediately, and provides safe Retry/Cancel controls. | [#14: Delete verified legacy archives without harming shared metadata](https://github.com/LK4D4/suwayomi.koplugin/issues/14) |
| M4: [#16: Coordinate manual deletion with existing and replacement downloads](https://github.com/LK4D4/suwayomi.koplugin/issues/16) | Mark-read cancels only work already present, while a later accepted deliberate download supersedes the old deletion without letting automatic or stale work override it. | [#15: Make single-chapter manual deletion durable and inspectable](https://github.com/LK4D4/suwayomi.koplugin/issues/15) |
| M5: [#17: Recover partial manual deletion across navigation and restart](https://github.com/LK4D4/suwayomi.koplugin/issues/17) | Interrupted or temporarily blocked manual deletion resumes safely with no view open, survives quit/restart, and makes progress without abandoning other requests. | [#16: Coordinate manual deletion with existing and replacement downloads](https://github.com/LK4D4/suwayomi.koplugin/issues/16); [#10: Stop download service within a bounded KOReader shutdown](https://github.com/LK4D4/suwayomi.koplugin/issues/10) |
| M6: [#18: Apply durable manual deletion to selected and previous chapters](https://github.com/LK4D4/suwayomi.koplugin/issues/18) | Bulk mark-read produces one durable, honest outcome for exactly the selected or previous chapters, including mixtures of removed, pending, and blocked targets. | [#16: Coordinate manual deletion with existing and replacement downloads](https://github.com/LK4D4/suwayomi.koplugin/issues/16) |
| M7: [#19: Preserve retention semantics while enforcing archive identity](https://github.com/LK4D4/suwayomi.koplugin/issues/19) | Manual requests and finish retention coexist without losing completion positions, inventing old deletion authorization, or deleting replacement archives. | [#15: Make single-chapter manual deletion durable and inspectable](https://github.com/LK4D4/suwayomi.koplugin/issues/15) |
| M8: [#20: Verify durable manual deletion on a device](https://github.com/LK4D4/suwayomi.koplugin/issues/20) | The assembled feature satisfies spec #12 across public-action composition, real filesystem/process checks, and device navigation/restart workflows. | [#17: Recover partial manual deletion across navigation and restart](https://github.com/LK4D4/suwayomi.koplugin/issues/17); [#18: Apply durable manual deletion to selected and previous chapters](https://github.com/LK4D4/suwayomi.koplugin/issues/18); [#19: Preserve retention semantics while enforcing archive identity](https://github.com/LK4D4/suwayomi.koplugin/issues/19); [#11: Verify complete ownership behavior on a device](https://github.com/LK4D4/suwayomi.koplugin/issues/11) |

## Why these blockers exist

- M1 depends on existing issue #9 because generation-conditional removal must build on cancellation and terminating/finalizing file ownership. Its earlier store/service/process/publication/recovery prerequisites are already transitive.
- M2 uses M1's durable generation boundary to adopt existing archives and protect shared/live metadata through an existing public Delete path.
- M3 needs both the identity boundary and verified physical targets before admitting any durable manual removal.
- M4 integrates M3's request revisions and admission boundary with captured workers and explicit-versus-automatic download provenance.
- M5 needs M4's complete worker/revocation behavior plus existing issue #10's real shutdown wrapper to verify recovery and the shared shutdown budget.
- M6 depends on M4 so a mixed batch can admit and cancel worker-bearing requests coherently. It can proceed independently of M5.
- M7 depends on M3's manual lifecycle and common generation boundary; it can proceed independently of M4–M6.
- M8 joins M5, M6, M7, and existing issue #11's base ownership acceptance. It is the complete-feature gate, not a substitute for checks within each slice.

Only genuine direct blockers are listed; transitive edges are omitted. No new ticket can start until issue #9 is complete. Foundation issue #10 can proceed independently of the early new slices. Parent issue #12 remains the specification, not a prerequisite ticket to close.

## Publication record

Published eight issues in dependency order with the ready-for-agent label. Added and read back all 12 native blocked-by relationships, including prerequisites #9, #10, and #11. Each published title/body and label was checked against the approved draft. Parent spec #12 was verified unchanged; specs #3 and report #2 were not edited, commented on, closed, or relabeled. No parent sub-issue lists were changed.

Ticket bodies below match the published content and contain no source-file paths, code snippets, personal details, or identifying device wording. Publication and this local record do not implement the feature or publish the work branch.

## Published tickets

### M1 / #13: Preserve archive generations across publication and removal

#### Parent

[Spec #12: durable manual deletion after mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/12)

#### What to build

A completed chapter retains its archive generation through restart and read-state changes, and a stale removal cannot clear or delete a later archive at the same path.

This is one unreleased slice of spec #12. Preserve accepted ADR-0003 and the navigation-safe ownership prerequisite contracts. Complete-feature acceptance requires final integration and device validation. Relevant user stories: 13, 14, 30, 40, 41, 42.

#### Acceptance criteria

- [ ] Retain unique archive generation identity beyond job completion, including chapter association, captured path/root, verified file evidence, and lifecycle authority. A later publication gets a new generation even when bytes and pathname match.
- [ ] Preserve generation information through checked shared-store transactions, publication/finalization, ledger reconstruction, read reconciliation, and every normalizer. Preserve unknown versions and unrelated state; never restore an older read or pending-sync snapshot.
- [ ] Route all plugin archive publication and removal bookkeeping through generation-conditional operations, including ordinary Delete and finish-retention cleanup. Old chapter-key-only path/job clearing must not erase a replacement or newer reader-return context.
- [ ] Keep unproved targets blocked without inventing ownership from path or content hash. This slice need not adopt legacy files; a later ticket supplies verified adoption. Existing retention positions and eligibility remain intact.
- [ ] Exercise public download completion, read reconciliation, fresh owning startup, ordinary Delete, and a stale removal against a same-path/same-content replacement. Assert final files, current generation, read/pending-sync state, queue/context records, and displayed outcome together.
- [ ] Add real temporary-file checks for generation evidence and conditional removal under coordinated ownership. Detected external change stops affected work; do not claim protection against uncoordinated concurrent writers.

#### Blocked by

- [#9: Make cancellation, retries, and cleanup preserve attempt ownership](https://github.com/LK4D4/suwayomi.koplugin/issues/9)

### M2 / #14: Delete verified legacy archives without harming shared metadata

#### Parent

[Spec #12: durable manual deletion after mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/12)

#### What to build

An authorized Delete can safely identify an existing archive, preserve live or shared metadata, and report exactly what was removed or retained.

This is one unreleased slice of spec #12. Preserve accepted ADR-0003 and the navigation-safe ownership prerequisite contracts. Complete-feature acceptance requires final integration and device validation. Relevant user stories: 24, 26, 27, 28, 37, 42.

#### Acceptance criteria

- [ ] Adopt targeted legacy archives lazily under exclusive process ownership and the accepted old-worker gate. Verify and durably register the captured generation before granting removal authority; never scan the library at startup.
- [ ] Use the public ordinary Delete path to exercise safe inspection/removal adapters end to end, preserving that command's existing failure/retry policy. This ticket does not add automatic durable manual-delete requests to ordinary Delete.
- [ ] Resolve and revalidate generation, captured managed-root containment, aliases/symlinks, live target reader, other live readers' metadata, and terminating/finalizing download ownership. Use current process-owned reader lookup rather than retired UI references.
- [ ] Expose exact approved archive, metadata, and backup targets plus ownership evidence to the later durable-manifest caller. Reject stale pathname hash caches and hash/path-only claims of exclusive metadata ownership.
- [ ] Preserve shared or unassignable sidecars with an explicit retained-metadata outcome while removing the verified archive. Temporary inspection errors remain failures/waits, not proof of missing files or safe sharing. Revalidate recreated sidecars and preserve unrelated directory contents.
- [ ] Exercise ordinary Delete and displayed status with a verified legacy archive, live reader, shared hash sidecar, stale same-path hash cache, detected external replacement, and inspection failure. Add physical temporary-file coverage of the removal helper, backups, aliases, and shared/recreated metadata.

#### Blocked by

- [#13: Preserve archive generations across publication and removal](https://github.com/LK4D4/suwayomi.koplugin/issues/13)

### M3 / #15: Make single-chapter manual deletion durable and inspectable

#### Parent

[Spec #12: durable manual deletion after mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/12)

#### What to build

Marking one downloaded chapter read admits a durable manual-delete request before removal, shows pending work when it cannot finish immediately, and provides safe Retry/Cancel controls.

This is one unreleased slice of spec #12. Preserve accepted ADR-0003 and the navigation-safe ownership prerequisite contracts. Complete-feature acceptance requires final integration and device validation. Relevant user stories: 1, 2, 3, 4, 7, 8, 9, 18, 19, 20, 21, 22, 23, 25, 33, 34, 35.

#### Acceptance criteria

- [ ] Introduce the separately versioned manual-intent collection and service-owned command/snapshot interface in the existing shared store. Include request revision, captured archive and job identities, original root, per-file manifest/progress, disposition, retry metadata, and blocked/retained outcomes.
- [ ] Complete the narrow single-chapter path for a verified archive without unresolved chapter workers: capture targets before refresh, commit read-ledger changes plus intent before any removal, persist exact approved file authorization, remove only the captured generation, and reconcile matching bookkeeping.
- [ ] Implement ownership/revocation checks in the core transition boundary before every destructive step. Capture and fence existing job identities durably, but leave worker-bearing cases safely pending until their integration ticket; no fallback to the current unsafe immediate-delete helper.
- [ ] Wire single mark-read with retention off and three, manual-setting enrollment semantics, confirmed no-target/no-job behavior, repeated unchanged-target coalescing, and the primary mark-unread/Cancel/Retry commands. Retry never retargets; cancellation changes no read state, restores no files, restarts no canceled jobs, and grants no retention exemption.
- [ ] Report durable read acceptance separately from pending/blocked/removed/retained-metadata outcomes. Failed or uncertain shared saves permit no cancellation/removal or false success, including when an earlier KOReader metadata write already happened.
- [ ] Expose current pending work in Downloads and chapter views, with reasons and Retry/Cancel controls that revalidate request revision. Use full committed-state refresh where needed; independent subscribers and zero-view service work cannot rely on an initiating UI.
- [ ] Test the public single action through admitted state, successful removal, an in-session retryable failure, live-reader wait, stale control, revocation after partial work, and displayed outcomes. Preserve the durable phases needed for the later comprehensive recovery ticket; keep unsupported transitions blocked.

#### Blocked by

- [#14: Delete verified legacy archives without harming shared metadata](https://github.com/LK4D4/suwayomi.koplugin/issues/14)

### M4 / #16: Coordinate manual deletion with existing and replacement downloads

#### Parent

[Spec #12: durable manual deletion after mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/12)

#### What to build

Mark-read cancels only work already present, while a later accepted deliberate download supersedes the old deletion without letting automatic or stale work override it.

This is one unreleased slice of spec #12. Preserve accepted ADR-0003 and the navigation-safe ownership prerequisite contracts. Complete-feature acceptance requires final integration and device validation. Relevant user stories: 10, 11, 12, 15, 16, 17, 18, 20, 30.

#### Acceptance criteria

- [ ] Commit read-ledger changes, the manual request, and captured jobs' stop/cancellation dispositions together. Fence captured queued/running/terminating/finalizing work before deferred processing can admit a replacement or publish.
- [ ] Stop/reap only captured job/attempt identities and wait for the established ownership proof before removing their files. Preserve owned worker-private cleanup even if manual deletion is later revoked.
- [ ] If a captured job has already published, preserve ordinary download Cancel semantics: finish finalization into current read/pending-sync state, release ownership, then apply the separate manual request to that exact archive generation.
- [ ] Carry explicit-versus-automatic provenance through single and bulk Download, initial Download ahead commands, automatic refill, explicit download Retry, and scheduled retry. Only admission of actual new deliberate work revokes the older manual request atomically.
- [ ] Failed, uncertain, skipped, duplicate, and no-op enqueue leave the old request intact. Automatic refill, delayed retry, or stale callbacks cannot supersede or retarget it; validate fences at admission, worker launch, and publication.
- [ ] Connect all durably accepted unread observations to request revocation while preserving existing read-sync conflict rules. Enqueue/unread/Cancel after a sidecar removal must prevent remaining old archive/sidecar removals without reviving canceled jobs.
- [ ] Exercise public commands and actual service/queue composition across queued, active, terminating, just-published, and finalizing cases. Assert worker identity, same-path/same-content replacement protection, current read state, files, durable records, and UI together; include actual-child release/cancellation checks.

#### Blocked by

- [#15: Make single-chapter manual deletion durable and inspectable](https://github.com/LK4D4/suwayomi.koplugin/issues/15)

### M5 / #17: Recover partial manual deletion across navigation and restart

#### Parent

[Spec #12: durable manual deletion after mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/12)

#### What to build

Interrupted or temporarily blocked manual deletion resumes safely with no view open, survives quit/restart, and makes progress without abandoning other requests.

This is one unreleased slice of spec #12. Preserve accepted ADR-0003 and the navigation-safe ownership prerequisite contracts. Complete-feature acceptance requires final integration and device validation. Relevant user stories: 1, 9, 24, 28, 29, 30, 31, 32, 33, 35, 36, 40.

#### Acceptance criteria

- [ ] Recover each durable request/manifest phase through fresh owning-service startup. Continue the same service through FileManager–ReaderUI transitions and zero subscribers; reject retired callbacks and old request revisions.
- [ ] Inject failure or interruption before and after checked admission, each approved sidecar/archive unlink, per-file progress saves, revocation, and final bookkeeping. Retry from retained exact targets and evidence; archive absence alone cannot erase residual owned-file obligations.
- [ ] Handle a crash after physical removal but before progress/bookkeeping commit idempotently. Preserve newer unread state, pending sync, replacement generation/path, later queue jobs, and reader-return context through conditional current-state transactions.
- [ ] Persist five-second exponential retry deadlines capped at five minutes with no retry-count abandonment. Use bounded fair processing and useful lifecycle/ownership wakeups; a blocked chapter cannot stall unrelated requests.
- [ ] Distinguish transient I/O/inspection/ownership waits from identity/unsupported-version blockers requiring evidence or action. Manual Retry bypasses neither identity proof nor ownership. Preserve unknown versions and failed migrations.
- [ ] Continue accepted requests after manual-delete or retention settings change; retain the original verified target and managed root across download-directory changes. Do not infer or discover new metadata targets after losing the original archive.
- [ ] Integrate with the existing total two-second service shutdown budget: no extra budget, final save, or future tick required. Preserve surviving workers' private ownership and pending manual work for the next owner.
- [ ] Run composed navigation/recovery tests and real temporary-file/process crash-boundary checks, including shared/recreated sidecars, partial removal then unread/new download/Cancel, and a surviving child. Assert committed state, files, ownership, and displayed outcomes together.

#### Blocked by

- [#16: Coordinate manual deletion with existing and replacement downloads](https://github.com/LK4D4/suwayomi.koplugin/issues/16)
- [#10: Stop download service within a bounded KOReader shutdown](https://github.com/LK4D4/suwayomi.koplugin/issues/10)

### M6 / #18: Apply durable manual deletion to selected and previous chapters

#### Parent

[Spec #12: durable manual deletion after mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/12)

#### What to build

Bulk mark-read produces one durable, honest outcome for exactly the selected or previous chapters, including mixtures of removed, pending, and blocked targets.

This is one unreleased slice of spec #12. Preserve accepted ADR-0003 and the navigation-safe ownership prerequisite contracts. Complete-feature acceptance requires final integration and device validation. Relevant user stories: 5, 6, 7, 8, 9, 22, 25, 34, 43.

#### Acceptance criteria

- [ ] Use the existing chapter read-actions coordination boundary for selected, supplied-list, and previous-chapter actions. Preserve visible target order, scanlator filtering, predecessor scope, and empty-input behavior.
- [ ] Capture independent target authority before refresh. Clear selection before the full rebuild and preserve non-target visible read reconciliation before the shared ledger is committed.
- [ ] Commit batch read-ledger changes, manual intents, and captured job cancellation dispositions through the checked boundary before any cancellation/removal. Do not allow an earlier target's filesystem work to outrun the batch's durable admission.
- [ ] Preserve completion order and pathless eligibility, schedule read-sync/refill through the established coordinator, and avoid leaking coordination through per-chapter compatibility flags or uncommitted supplied ledgers.
- [ ] Give one immediate aggregate summary separating marked-read chapters, pending/blocked deletion, removed archives, and retained metadata. Background retries stay quiet; unchanged targets coalesce without duplicate work.
- [ ] Exercise public selected and previous actions with mixed verified/legacy/missing/live/worker-owned/shared-metadata targets, retention off and three, repeated actions, failed/uncertain saves, and non-target menu reconciliation. Verify selection, worker fences, files, durable records, and rendered rows together.

#### Blocked by

- [#16: Coordinate manual deletion with existing and replacement downloads](https://github.com/LK4D4/suwayomi.koplugin/issues/16)

### M7 / #19: Preserve retention semantics while enforcing archive identity

#### Parent

[Spec #12: durable manual deletion after mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/12)

#### What to build

Manual requests and finish retention coexist without losing completion positions, inventing old deletion authorization, or deleting replacement archives.

This is one unreleased slice of spec #12. Preserve accepted ADR-0003 and the navigation-safe ownership prerequisite contracts. Complete-feature acceptance requires final integration and device validation. Relevant user stories: 2, 3, 20, 23, 25, 38, 39, 41.

#### Acceptance criteria

- [ ] Keep manual intent lifetime and eligibility separate from while-reading retention, including disabled retention and retained positions. Manual-setting disable stops new enrollment only.
- [ ] Retain finished-completion ordering and position when a captured generation is removed. A completion captured without an archive stays pathless and never gains authority over a later download.
- [ ] Preserve supported older retention records and their positions. Block deletion when their original archive generation cannot be proved; never bind an old record to a new publication merely because paths match.
- [ ] Do not convert historical read or retention records into manual intents based on current settings. A fresh authorized action may establish a new verified target; preserve unknown versions and old state when migration fails.
- [ ] Give fresh authorized completion/retention targets generation-aware bindings through the common ownership boundary. All retention removals revalidate their own authority and cannot erase newer read/path/job state.
- [ ] Cancel pending manual deletion grants no retention exemption. Demonstrate independent eligible retention proceeding only against its own proved generation; failure or cancellation of one mechanism must not silently erase the other's durable state.
- [ ] Use public manual actions plus the real retention processor, menus, queue, and persistence. Cover retention off/three, pathless and historical records, same-path replacement after completed manual removal, manual cancellation, setting changes, and fresh authorized records. Assert files, retained sequence/positions, durable state, and UI.

#### Blocked by

- [#15: Make single-chapter manual deletion durable and inspectable](https://github.com/LK4D4/suwayomi.koplugin/issues/15)

### M8 / #20: Verify durable manual deletion on a device

#### Parent

[Spec #12: durable manual deletion after mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/12)

#### What to build

The assembled feature satisfies spec #12 across public-action composition, real filesystem/process checks, and device navigation/restart workflows.

This is one unreleased slice of spec #12. Preserve accepted ADR-0003 and the navigation-safe ownership prerequisite contracts. Complete-feature acceptance requires final integration and device validation. Relevant user stories: 26, 27, 29, 30, 33, 35, 36, 41, 42, 43, 44, 45, 46.

#### Acceptance criteria

- [ ] Audit all 46 user stories and every acceptance row in spec #12 against the assembled implementation. Fill integration gaps without substituting refresh counts, per-UI queues, or mocked file removal for physical proof.
- [ ] Run the full LuaJIT suite, lint, localization checks, and real filesystem/process coverage for admission ambiguity, generation identity, live readers/workers, aliases/symlinks, shared/recreated metadata, partial removal, revocation, migration, and conditional bookkeeping.
- [ ] On a device with test data, exercise retention off and three, single and bulk manual actions, a live chapter, FileManager/ReaderUI and direct-reader transitions, zero-view progress, quit/relaunch, Cancel/Retry, and a later deliberate download.
- [ ] Check archive, managed metadata, read/pending-sync state, worker identity, durable records, and current UI together. Verify actual settings/download mounts and relevant KOReader metadata behavior. Never damage storage to provoke failures.
- [ ] Verify base ownership acceptance from issue #11 remains satisfied after the new generation and removal coordination. The manual feature's complete acceptance cannot substitute for an unverified prerequisite.
- [ ] Update the architecture reference and user-facing pending/blocked/cancellation/legacy guidance for implemented behavior. Explain retained metadata, non-restoration, separate retention policy, and supported external-writer limits without exposing internal details unnecessarily.
- [ ] Keep shared evidence redacted: no credentials, server URLs, local paths, device identifiers, manga/chapter titles, or unrelated personal data. Use generic device wording and preserve runtime packaging boundaries.
- [ ] Run required GitHub Actions before any separately authorized implementation merge. Record unresolved acceptance blockers accurately; leave parent specs/reports unchanged and do not claim completion when a required layer is missing.

#### Blocked by

- [#17: Recover partial manual deletion across navigation and restart](https://github.com/LK4D4/suwayomi.koplugin/issues/17)
- [#18: Apply durable manual deletion to selected and previous chapters](https://github.com/LK4D4/suwayomi.koplugin/issues/18)
- [#19: Preserve retention semantics while enforcing archive identity](https://github.com/LK4D4/suwayomi.koplugin/issues/19)
- [#11: Verify complete ownership behavior on a device](https://github.com/LK4D4/suwayomi.koplugin/issues/11)
