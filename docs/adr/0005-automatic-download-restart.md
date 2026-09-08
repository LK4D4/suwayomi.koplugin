---
status: accepted
date: 2026-09-08
---

# Restart unfinished downloads with isolated attempts

The maintainer confirmed this design on 2026-09-08; implementation remains pending. It supersedes the startup interruption policy and shared temporary-file handling in [ADR-0002](0002-navigation-safe-download-ownership.md); process-owned navigation-safe downloads remain unchanged. [ARCHITECTURE.md](../ARCHITECTURE.md#download-ownership) continues to describe the implemented behavior.

## Agreed direction

Automatically requeue unfinished downloads on KOReader startup, respecting configured concurrency. Preserve cancellations, permanent failures, and completed archives. Restart means another transfer attempt, not resuming partial archive bytes.

Preserve retry counts and future retry deadlines across startup. Overdue retries are eligible immediately, subject to concurrency; restart itself does not consume a retry. Interrupted active transfers become queued attempts.

Use unique random download-attempt IDs for temporary archive and progress files. Each worker writes, validates, renames, and cleans up only its own temporary files. Close and validate an archive before publishing it through same-filesystem atomic rename to the final chapter CBZ. Concurrent successful attempts may publish one complete archive or another; their temporary bytes must never mix.

Detect damaged downloads using ZIP structure, full entry reads/checksums, and expected page count where available. Chapters and Downloads show a quiet “Download damaged; redownload” status with an explicit recovery action.

Cleanup is best-effort and limited to a worker's own temporary files, or that attempt's files after the current process confirms worker exit. Unknown leftovers, including legacy files, may remain indefinitely. This deliberately drops the original goal of eventual cleanup for every abandoned file: rare leftovers do not justify boot tracking, a cleanup registry, or another ownership mechanism. Do not sweep on startup or infer abandonment from age, missing progress, or absence from the current queue.

## Accepted tradeoffs and rejected alternatives

- Configured concurrency bounds workers tracked by the current process, including its known stopping workers. Untracked surviving workers may temporarily exceed that total and duplicate transfers.
- An older successful attempt may replace a newer complete archive. A surviving canceled worker may publish later; preserving cancellation does not promise prevention of late publication.
- Validation reduces damage risk but cannot prove content correctness or guarantee durability after abrupt device failure.
- No stronger cross-process ownership protocol is required for this direction.
- Do not delete a shared `.part` on startup or infer worker exit from whether a file currently has a writable handle. Neither proves that the old worker has finished.
- No mandatory reboot or upgrade gate. Attempt isolation and validated publication apply to new-version workers, not surviving legacy workers using shared paths and old validation rules. A device reboot ends that legacy-worker risk; upgrading alone does not authorize deleting legacy temporary files.

## Explicit repair policy

Redownload retains the existing damaged archive until a validated replacement is ready for atomic publication. Preserve saved reading metadata and read/unread state; identical page-position meaning is not guaranteed if replacement content differs. A failed replacement leaves the damage status and explicit recovery action available.

Download ahead must not automatically repair a known-damaged archive. Once the user explicitly authorizes Redownload, the unfinished repair job follows ordinary retry and startup-requeue rules.

## Validation and reader boundary

Perform full validation off the UI thread after closing each new archive and before publication, before adopting an existing final archive to complete an unfinished startup job, before a plugin-mediated chapter open, and on an explicit Verify download action. Do not scan the library on startup or validate merely to render rows. Displayed status is the latest known result, not a guarantee that every archive has been checked. KOReader FileManager opens are outside this boundary.

Distinguish established archive damage from an inconclusive inspection, such as permission failure, an I/O failure, or validator failure. An inconclusive result offers verification retry, does not authorize deletion, and does not publish the candidate or automatically proceed with the requested open. Only established integrity failures receive the damaged-download status. Existing known-damaged archives follow the explicit repair policy, including during startup reconciliation.

Use a trustworthy expected page count captured for the particular transfer when available, retaining it with that archive's validation metadata. Do not fetch current server metadata merely to validate an offline archive. Without an associated expected count, perform the remaining integrity checks without claiming chapter completeness.

Validation describes the archive inspected, not a locked pathname. Associate expected-count and damage evidence with that archive rather than knowingly applying stale results to a replacement. Accept the remaining inspection-to-open race; do not add cross-process exclusion to prevent it.

If atomic replacement fails, report failure and preserve the existing final archive. Never delete the final archive to make rename succeed.

Do not intercept generic reader failures or patch KOReader's reader error handling. A reader error alone is not evidence of archive damage; pre-open validation and the explicit Verify download action provide the plugin's inspection boundary.

## Complexity limit

Keep the change within existing queue/downloader ownership and prefer the smallest coherent implementation. Do not add an ownership service, recovery journal, cross-process locking protocol, boot tracking, cleanup registry, reader patch, or library-wide validation scan. The future exact-generation deletion contract in [ADR-0003](0003-durable-manual-delete-intent.md) remains separate: this change does not implement it or supply proof that a pathname still denotes a captured generation. Preserve that contract's blocked outcome when proof is unavailable rather than expanding this work.

## Confirmation

Shared understanding is confirmed. Implement the agreed scope without expanding the recovery protocol. Validator API and supported-device atomic-replacement behavior still need implementation-time verification. Acceptance of this decision does not mean the runtime has changed.
