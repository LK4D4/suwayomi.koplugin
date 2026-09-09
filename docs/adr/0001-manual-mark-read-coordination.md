---
status: accepted
date: 2026-09-06
---

# Keep manual mark-read coordination in chapter read actions

Implemented in [read_actions.lua](../../suwayomi/chapters/read_actions.lua). This record preserves the ownership decision and incorporates [ADR-0003](0003-durable-manual-delete-intent.md)'s checked ordering. The original immediate-delete-before-save sequence is superseded, not an instruction for future changes.

## Decision

Single, selected, and previous-chapter mark-read actions share private per-chapter processing and batch finalization in the read-actions module. It owns each operation's ledger, captured completion records, and side-effect ordering. [actions.lua](../../suwayomi/chapters/actions.lua) retains dispatch/confirmation; [context.lua](../../suwayomi/chapters/context.lua) retains selection mechanics.

Keep `markChapterRead`, `markChapterListRead`, `markSelectedChaptersRead`, and `markChaptersBeforeRead` as the public interface, including empty-input behavior. Single-call options for supplied ledgers, completion buffers, and refresh/sync/keep-policy suppression remain supported; they do not bypass persistence or serve as the internal batch protocol.

## Ordering

1. Capture archive targets before metadata changes or menu refresh can change the observed context. Build independent completion snapshots from those captured observations.
2. Update read state in the operation's ledger. For selected batches, clear selection before rebuilding the menu. Reconcile visible non-target chapters during the batch refresh before committing the shared ledger.
3. Commit read state and accepted manual-delete requests through the checked shared store before archive removal. Busy download work prevents deletion acceptance without preventing mark-read or canceling that work.
4. Publish captured completions in input order after the commit, then run manual processing, read-sync scheduling, and keep-next-unread policy. A caller-owned completion buffer defers manual processing until the caller can publish it.

Singles commit and publish before refresh; batches need pre-commit refresh to preserve non-target reconciliation. Do not flatten this distinction into one ordering. A failed or uncertain save makes no durable-success claim and starts no removal; KOReader metadata writes and server synchronization are not part of the shared-settings transaction.

Completion eligibility stays bound to its captured archive. Pathless records never acquire deletion authority from a later download. Removing an archive retires that authority without transferring it to a replacement or changing retention positions.

## Rationale and evidence

The existing read-actions module owns the shared protocol without another orchestration layer. Moving duplicated loops alone would leave callers coordinating persistence and destructive effects.

Relevant checks are [manual completion integration](../../spec/manual_read_completion_spec.lua), [chapter actions](../../spec/suwayomi_chapters_actions_spec.lua), [chapter menus](../../spec/suwayomi_chapters_menu_spec.lua), and [finished cleanup](../../spec/suwayomi_finished_cleanup_spec.lua). Preserve observable ordering, selection, non-target reconciliation, filesystem outcomes, and committed state—not merely callback counts. Simulated filesystem checks do not establish physical-device behavior. Current module boundaries and evidence references live in [ARCHITECTURE.md](../ARCHITECTURE.md).
