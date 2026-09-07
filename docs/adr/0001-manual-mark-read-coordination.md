---
status: accepted
date: 2026-09-06
---

# Keep manual mark-read coordination in chapter read actions

Single, selected, and previous-chapter mark-read actions will share private implementation in the existing [chapter read-actions module](../../suwayomi/chapters/read_actions.lua). The module will own the ledger, captured completion records, and side-effect ordering that bulk callers currently coordinate themselves. This increases locality without changing manual mark-read behavior; implementation is pending.

## Decision

- Keep `markChapterRead`, `markChapterListRead`, `markSelectedChaptersRead`, and `markChaptersBeforeRead` as the plugin-facing interface, with their existing return values and empty-input behavior.
- Move selected mark-read orchestration from [chapter actions](../../suwayomi/chapters/actions.lua) into the read-actions module. Action dispatch and confirmation remain in chapter actions; selection mechanics remain in [chapter context](../../suwayomi/chapters/context.lua).
- Share private per-chapter processing and batch finalization. Keep each operation's ledger and completion buffer local to that operation. Bulk callers must no longer coordinate these through `markChapterRead` options.
- Preserve tested single-call options as compatibility behavior, including refresh/sync/keep-policy suppression and a supplied ledger. A supplied ledger must be saved before a single completion is published. Compatibility handling must not become the mechanism for internal batching.

## Follow-up ordering decision

[Accepted ADR-0003](0003-durable-manual-delete-intent.md) revises the destructive-action ordering for deletion after manual mark-read. Under its 2026-09-07 scope amendment, capture the exact archive target and commit read-ledger changes plus accepted manual-delete intent before file removal. Existing queued/running/stopping/finalizing work makes deletion busy/not accepted; manual mark-read does not cancel it. Retain this ADR's module boundary, visible completion order, pathless eligibility, selected-menu clearing, and durable reconciliation of non-target visible chapters. The original sequence below records the behavior this coordination refactor preserved; its immediate-delete phase must not be carried into the durable manual-delete implementation.

## Original ordering constraints

For a non-empty selected or previous-chapter batch:

1. Process supplied chapters in list order (the visible order for selected and previous actions), updating metadata and the shared ledger and applying immediate manual deletion.
2. Capture an independent completion record after each chapter's immediate deletion attempt, before any menu refresh.
3. For a selected action, clear selection after processing and before rebuilding the menu.
4. Fully refresh the chapter menu using the shared ledger.
5. Save the shared ledger once, including changes made during refresh.
6. Publish the captured completions in list order, only after the entire ledger batch is durable.
7. Schedule pending read-sync and apply the keep-next-unread download policy once for the batch.

The refresh-before-save order is deliberate: [chapter menu construction](../../suwayomi/chapters/menu.lua) reconciles KOReader state into the supplied ledger, including visible chapters outside the batch. Moving refresh after the sole save would leave those reconciliation changes unpersisted.

Single-chapter actions retain their existing save-and-publish-before-refresh behavior. Sharing implementation must preserve this distinction instead of routing every action through an identical sequence.

## Scope and consequences

This decision covers manual mark-read actions only. Mark-unread actions, reader-close completion, server reconciliation, queue transitions, and physical deletion retain their current ownership and behavior. No settings or journal schema change is required.

Completion eligibility remains a snapshot of the manual action: include a path only when the chapter was downloaded and immediate deletion did not remove it. Successful immediate deletion and non-downloaded chapters still contribute pathless completion records. A later download must never acquire deletion eligibility from an older pathless record. Preserve reread ordering, durable retries, and the existing cleanup protections.

The existing read-actions module provides the seam. A new orchestration module would add another interface without removing caller knowledge. Merely moving duplicate loops into one file would also miss the decision: the private implementation must own the shared protocol. Existing settings, filesystem, metadata, and scheduling adapters remain usable by production and tests.

## Implementation verification

Use the existing public actions as the test surface:

- [Manual completion integration](../../spec/manual_read_completion_spec.lua): preserve visible completion order, one bulk ledger save before journal writes, immediate-deletion outcomes, pathless retention, restart recovery, and displayed download status together.
- [Chapter action specifications](../../spec/suwayomi_chapters_actions_spec.lua): preserve method returns, empty batches, single-call options, and one refresh/sync/keep-policy application per batch.
- [Chapter menu specifications](../../spec/suwayomi_chapters_menu_spec.lua): preserve reconciliation of backing chapter and ledger state.

Add composed coverage for selection being cleared in the rebuilt menu and for a visible non-target chapter's refresh reconciliation reaching the saved batch ledger. Preserve coverage of the real sidecar-removal implementation in [finished cleanup specifications](../../spec/suwayomi_finished_cleanup_spec.lua); existing filesystem simulations must not be described as physical filesystem tests. Assert filesystem outcomes, durable state, and displayed status together rather than relying only on refresh call counts.

Update [the architecture map](../ARCHITECTURE.md) when the ownership change is implemented, and run the repository verification required by [AGENTS.md](../../AGENTS.md). This record describes the intended refactor, not a completed runtime change.
