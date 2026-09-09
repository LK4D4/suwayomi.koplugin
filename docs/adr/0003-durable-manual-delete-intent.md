---
status: accepted
date: 2026-09-06
---

# Preserve manual-delete intent independently of finish retention

The implemented contract incorporates the 2026-09-07 archive-only amendment. It replaces the original cancellation, sidecar-removal, manifest, legacy-adoption, and dedicated-management-screen proposals. Those proposals remain in Git history, not as competing instructions below. Current UI behavior follows the quiet-success policy in [ARCHITECTURE.md](../ARCHITECTURE.md#ui-localization-and-diagnostics).

## Problem and decision

Deletion after manual mark-read must not disappear because finish retention is disabled or its positions change. The original investigation for [#2](https://github.com/LK4D4/suwayomi.koplugin/issues/2), preserved in Git history, records that failure. Keep an accepted manual request independent of retention and bind it to one captured archive generation.

The process service from [ADR-0002](0002-navigation-safe-download-ownership.md) owns scheduling/recovery with zero views. [read_actions.lua](../../suwayomi/chapters/read_actions.lua) preserves single/selected/previous selection, scanlator filtering, completion order, and read-sync coordination under [ADR-0001](0001-manual-mark-read-coordination.md). [manual_deletion.lua](../../suwayomi/chapters/manual_deletion.lua) owns checked admission and archive-only removal.

## Admission and removal

- Capture the exact target before refresh or metadata changes. Commit read-ledger changes, accepted manual requests, and refill enrollment through the checked shared store before archive removal. A failed or uncertain save starts no removal and makes no durable-success claim. KOReader metadata and server synchronization are outside that transaction.
- If queued, running, stopping, or finalizing download work owns the chapter, deletion is busy/not accepted. Preserve that work; mark-read may still succeed. The user must request deletion again after ownership ends. There is no automatic cancellation or eventual-deletion promise for an unaccepted request.
- An accepted request removes only its verified CBZ. Preserve all KOReader sidecars, backups, and other metadata; retained metadata is not unfinished deletion. Ordinary Delete and independent retention keep their separate removal boundaries.
- Revalidate request revision, exact generation, original root, resolved containment/aliases, filesystem identity/change evidence, current reader, and download ownership before unlink. Preserve files whenever proof or persistence is uncertain. Pathname, timestamp, or content hash alone cannot identify a replacement generation.
- Establish identity only for a fresh authorized target or publication. Do not scan the library, infer historical manual authorization, or bind an old unproved record to a later file. A fresh action can authorize a currently proved target; an unproved original request stays blocked.

## Lifetime and revocation

| Event | Effect |
| --- | --- |
| Disable manual deletion | Stop new enrollment; accepted requests continue. |
| Change or disable finish retention | No change to manual-request eligibility or lifetime. |
| Durably mark unread | Revoke remaining manual removal; restore no deleted files. |
| Accept a deliberate download | Supersede the old intent in the same checked admission transaction. Explicit Retry counts only when it accepts new work. |
| Failed, uncertain, duplicate/no-op, or automatic admission | Cannot revoke or retarget manual intent. Automatic work cannot race accepted removal. |
| Change download directory | Keep the original target/root. |
| Repeat manual mark-read | Coalesce an unchanged target, or authorize a fresh proved generation. |
| Confirm the captured archive is absent | Complete only that obligation; grant no authority over future downloads. |

Archive verification observes identity without publishing a generation or granting deletion authority. [ADR-0005](0005-automatic-download-restart.md)'s attempt validation is not a substitute for the generation proof here.

## Persistence, recovery, and retention

Keep separately versioned manual/archive state in the existing shared settings document: generations/revisions, captured evidence/root, progress, and retry deadlines. Every publication is a distinct generation, even with identical bytes at the same path. Writers preserve unrelated fields and unknown versions.

Filesystem unlink and settings replacement are not atomic together. Persist authorization first, then observed progress and conditional bookkeeping. Recovery after unlink must preserve newer read/pending-sync state, replacement paths/generations, queue work, and reader-return context. Download finalization likewise merges into current state rather than restoring a captured ledger.

Retry transient failures quietly across navigation, zero views, and process restart. Persist five-second exponential deadlines capped at five minutes, with no retry-count abandonment. Use bounded fair passes so one blocked target cannot stall others. Identity/unsupported-version blockers require new evidence or action. Reuse the service's total two-second quit budget; no second deadline, final save, or future tick is required.

Retention records keep completion positions and pathless eligibility. Old records never gain authority over new publications. A generation with pending/blocked manual intent yields to the archive-only processor; competing retention must not remove metadata after a manual unlink failure. Disabling retention does not disable manual retries.

## User-visible behavior

Show normal read/download results in existing menus. Pending and blocked manual work remain inspectable; failed saves and busy/blocked admission produce actionable errors. Completed removal needs no receipt or retained-metadata popup. Keep background retries quiet. Do not add a manual-deletion screen or pending-deletion Retry/Cancel controls; unread and accepted deliberate downloads provide revocation.

## Tradeoffs and evidence

Busy deletion requires another action, metadata consumes storage, and unproved targets may stay blocked. These limits favor preservation without abandoning accepted durable requests. Coordination covers plugin mutations, not universal protection against uncoordinated external writers; a pathname check followed by unlink is not a filesystem lock.

[#12](https://github.com/LK4D4/suwayomi.koplugin/issues/12) and [#36](https://github.com/LK4D4/suwayomi.koplugin/issues/36) preserve implementation scope/history. [#37](https://github.com/LK4D4/suwayomi.koplugin/issues/37) records maintainer acceptance of exercised workflows and remaining verification gaps; its later comments supersede the original keep-open checklist. [#31](https://github.com/LK4D4/suwayomi.koplugin/issues/31) owns combined workflow evidence. No unexercised case becomes a pass through documentation cleanup.

Current composed/filesystem checks are mapped in [ARCHITECTURE.md](../ARCHITECTURE.md#test-strategy). Preserve the distinction between stubbed removal, real temporary files, and device observations. Earlier sidecar-ownership analysis explains the archive-only choice; it does not require implementing the rejected sidecar-deletion protocol.
