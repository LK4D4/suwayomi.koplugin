# Checked read persistence design

Status: design confirmed by the maintainer on 2026-09-11, including Q1–Q4 and the complete design handoff. The subsequent implementation request authorizes implementation, review, and a commit on the task branch, but not publication or integration.

Based on local `master` at `d73e7a2`, following candidate 2 of the 2026-09-10 architecture review. Worktree: `.worktrees/checked-read-design`; branch: `docs/checked-read-design`.

## Agreed scope

**Q1 — Preserve behavior.** Change ownership and caller knowledge, not the persistence schema, UI, triggers, recovery policy, or observable operation ordering. Preserve busy-download admission rules, unread revocation, already-read completed-close enrollment, failed/uncertain-save safety, and existing per-call suppression options.

**Q2 — Keep transaction composition in the ledger module.** `suwayomi/readsync/ledger.lua` will own read merging and composition of the checked read transaction. `read_actions.lua` will retain operation ordering; `manual_deletion.lua` will retain admission/revocation rules and archive removal; `refill.lua` will retain enrollment policy and scheduling. Callers will no longer route read persistence through refill and manual deletion.

**Q3 — Limit the move to read-driven transactions.** Manual read/unread, reconciliation, synchronization acknowledgments, and completed close use the ledger's checked read interface. Download completion and archive-removal bookkeeping remain with their existing owners and retain their existing atomic transactions. This is not universal ownership of every `chapter_ledger` write.

**Q4 — Return committed targets explicitly.** The checked read interface returns the committed archive targets with admission outcomes after a confirmed save; it leaves supplied captures unchanged. Read actions use those results to build independent completion snapshots in input order. Deferred publication retains the exact committed generation even if a later download replaces the archive. Existing fallback completion eligibility for captures without an accepted target remains unchanged.

The existing contracts remain authoritative: [manual action ordering](adr/0001-manual-mark-read-coordination.md), [manual-delete admission and lifetime](adr/0003-durable-manual-delete-intent.md), and [atomic read/refill enrollment](adr/0004-durable-download-ahead-refill.md). The [architecture map](ARCHITECTURE.md) describes the implemented ownership.

## Source constraints at the design baseline

- `ledger.saveChapterLedger` forwards through `refill.commitLedger` to `manual_deletion.commitRead`. Completed close also calls refill directly.
- The current read transaction enrolls refill against the previous ledger before merging. Its merge preserves current archive associations when supplied archive generations differ.
- Selected batches reconcile visible non-target chapters before committing; singles commit and publish before refresh. Metadata writes and server synchronization remain outside the shared-settings transaction.
- Successful manual admission currently updates supplied capture targets after persistence. Read actions use those updated targets when publishing completion snapshots. Any interface change must preserve the exact committed generation and caller-owned completion-buffer ordering.

## Implementation consequences

These follow from Q1–Q4 rather than introducing new behavior:

1. Move the read-ledger merge and checked transaction composition into the existing ledger module. Retain current snapshot-versus-merge semantics, pending-sync precedence, preservation of unrelated fields, and protection against restoring stale archive associations.
2. Keep refill enrollment and manual admission/revocation as contributions to the same staged settings document. Enrollment must still compare against the previous ledger; manual revocation/admission must see the merged read state. Contributors do not perform nested saves.
3. Preserve the existing store fence, error classification, and reconciliation scheduling. A rejected or uncertain save returns no committed admission result and causes no completion publication, archive removal, or durable-success claim from that operation. Existing metadata writes are not rolled back.
4. After a confirmed save, return committed outcomes and independent target snapshots. Preserve refill wake/notification behavior after persistence. Read actions retain completion publication, manual processing, refresh, and sync ordering, including caller-owned completion buffers.
5. Route the read callers through the ledger interface and remove the obsolete refill forwarding method and manual-deletion read-transaction entrypoint. Retain manual-deletion policy methods and refill enrollment methods; do not introduce another forwarding module, scheduler, or persistent state owner.
6. Keep existing public read-action entrypoints and their supported options. Concrete internal method names and parameter packaging remain implementation details; callers must not coordinate the shared save or inspect contributor state.

## Verification and handoff

Implementation must exercise committed read state, pending synchronization, manual intent revocation/admission, and refill enrollment together through the ledger interface. Preserve composed action coverage for selection, non-target reconciliation, single/batch ordering, and deferred completion publication.

Focused controls must cover:

- Accepted remote unread revokes pending manual intent without requiring a later menu refresh.
- An already-read completed close still enrolls refill with the existing origin rules.
- Busy download work remains owned while mark-read succeeds without accepting deletion.
- Rejected and uncertain saves expose no committed targets and start no destructive processing; existing reconciliation behavior remains intact.
- A committed target survives deferred publication without acquiring a replacement generation. Supplied captures remain unchanged.
- Single-call refill suppression and preservation of unrelated ledger/archive fields retain their existing behavior.

Use the existing ledger, manual-read completion, durable-refill, settings-failure, and relevant regression specs rather than tests of forwarding or internal field wiring. Run full lint, LuaJIT specs, and l10n checks on the completed runtime candidate under the repository gates. Report automated evidence separately from device observations.

The implementation updates module headers and the architecture ownership/test map with the runtime cutover. Reconcile these notes against any intervening source changes before integration. Publication and integration require separate authorization and the repository CI gates.

No domain term has changed. No glossary entry or new ADR is needed for this design: terminology and the existing architectural contracts are preserved. Runtime evidence belongs to the implementation handoff; this note is not device acceptance.
