---
status: accepted
date: 2026-09-06
---

# Coalesce download-ahead work in the process-wide service

A completed chapter must request Download-ahead evaluation even when the reader never returns to a plugin chapter screen. Persist one coalesced refill request per manga in the existing checked shared store, owned by the process-wide service from [ADR-0002](0002-navigation-safe-download-ownership.md). Evaluate current policy after teardown using complete chapter data; do not persist a candidate list or keep the retiring reader alive.

This decision covers [section 3 of the investigation](../superpowers/audits/2026-09-06-issue-2-investigation.md#3-finishing-a-document-does-not-itself-refill-download-ahead). The user authorized autonomous decisions and spec/ticket publication, favoring simplicity and requesting no further interview. Accepted means a decided architecture; runtime implementation and acceptance remain pending.

## Durable boundary

Store a versioned per-manga request with resolvable manga context, endpoint scope without credentials, request revision, status/reason, and retry count/deadline. Read changes, pending synchronization, same-action accepted manual-delete admission, and refill enrollment share the checked transaction. For an already-read completed close, enroll without requiring a new read transition. Preserve [ADR-0001](0001-manual-mark-read-coordination.md) coordination and [ADR-0003](0003-durable-manual-delete-intent.md) checked admission and archive-only ordering under its 2026-09-07 amendment (busy download work is preserved, with no deletion acceptance); scheduling remains after commit and document teardown.

The service revalidates the current request revision, endpoint, policy, saved scanlator, ledger, queue, archive, destination, and manual-delete fences before admission. Commit newly accepted automatic jobs and consumption of that revision together. An old result cannot clear a newer trigger. Relevant read/pending-sync changes, including sync acknowledgments during fetch, invalidate that evaluation before merging stale remote flags. Unknown versions and uncertain commits follow existing preservation/reconciliation rules.

A changed endpoint cannot silently retarget outstanding work to reused manga IDs. Background enrollment must inherit verified origin from the manga/archive/policy association; unknown legacy origin requires a fresh current-endpoint context and explicit plugin association action, never stamping the current endpoint onto an old ID. Old scoped work becomes blocked; a fresh action can establish a new request. Authentication updates on the same endpoint may retry the original request. Ordinary directory changes affect new admissions only.

## Lifecycle and policy

Keep one read-only context helper across the service, with bounded fair work between manga. Reuse existing API/subprocess result allocation, request tokens, and known-child completion checks; defer cleanup while the known helper runs and reject stale results. Helpers do not write shared settings. Revised #5 supplies the service and one total two-second best-effort quit integration, not a durable launch, inherited-lock, or orphan-isolation protocol. Recover durable refill requests with a fresh fetch after restart without sweeping untracked helper files. Chapter jobs retain [ADR-0005](0005-automatic-download-restart.md)'s automatic restart policy, which supersedes revised #3's interruption policy. Refill never resets terminal chapter failures.

Use complete ordinary chapter retrieval, current ledger read precedence, source-order/ID ordering, and exact saved scanlator restriction. Missing scanlator matches never broaden to All. Keep existing 5/10/50 earliest-unread-position semantics. Existing owned downloads and terminal failures occupy positions; automatic evaluation cannot reset terminal failures, extend beyond N to compensate, or revoke manual-delete intent. Explicit chapter Download/Retry retains the authority already specified by ADR-0003.

Completion, manual read/unread, actual read reconciliation, successful chapter load/return, and policy/filter changes request evaluation. Rendering a snapshot is not a trigger. Do not add a perpetual queue-change watcher, startup library scan, suppression journal, or persistent chapter cache. Accepted explicit job cancellation atomically retires the affected manga's outstanding evaluation; Cancel all retires every outstanding evaluation. Neither disables ahead, but in-flight results cannot undo cancellation. A later independent qualifying event can select the canceled chapter again. Stop download ahead retires outstanding evaluation but leaves already admitted jobs intact.

Transient failures use persisted five-second exponential retries capped at five minutes without count abandonment. Configuration/identity/unsupported-state blockers remain inspectable and require relevant change or explicit Retry. Process outstanding work with zero UI subscribers; UI shows snapshots and submits commands only.

## Trade-offs and acceptance

A durable dirty revision is less state than persisting proposed chapter lists, which become stale whenever read state, filter, or queue changes. It requires fresh context retrieval after failures/restart, but existing asynchronous loading and complete stored pagination supply that input. Keeping work on a reader or relying only on the next menu visit is simpler locally and fails the continuous-reading requirement.

Event-driven reevaluation avoids a new always-on scheduler and cancellation-suppression policy. Automatic refill does not retry terminal failures implicitly. These two boundaries deliberately trade immediate self-healing of every missing slot for predictable explicit controls and existing queue retry behavior.

[The refill specification](../superpowers/specs/2026-09-06-durable-download-ahead-refill.md) defines the full command, settings, state, and acceptance contract. Require composed public lifecycle/actions, real filesystem/process helper checks, and the device next-file versus plugin-return control. Existing ownership and manual-delete tickets remain prerequisites. This ADR does not authorize runtime edits, deployment, branch switching, merging, or pushing.
