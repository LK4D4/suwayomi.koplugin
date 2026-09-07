# durable completion-triggered download ahead

Published as [GitHub issue #22](https://github.com/LK4D4/suwayomi.koplugin/issues/22), labeled ready-for-agent. Accepted for autonomous planning; implementation remains pending.

## Problem Statement

Finishing a downloaded chapter updates read state but does not itself refill Download ahead. Returning to the plugin chapter list happens to run the policy; KOReader Open next file and direct reader transitions can drain the buffer without refilling it. Current policy evaluation also depends on a live UI's loaded chapter context, which cannot reliably own work across navigation, offline operation, or restart.

This specification addresses section 3 of [issue #2](https://github.com/LK4D4/suwayomi.koplugin/issues/2). It builds on [navigation-safe ownership #3](https://github.com/LK4D4/suwayomi.koplugin/issues/3), [durable manual deletion #12](https://github.com/LK4D4/suwayomi.koplugin/issues/12), and [complete chapter retrieval #21](https://github.com/LK4D4/suwayomi.koplugin/issues/21).

## Solution

Record one durable request per manga to reevaluate its Download-ahead buffer. Admit that request with the local read/completion change, then let the process-wide service obtain complete chapter context and queue missing eligible positions after document teardown. No plugin screen must remain open.

Coalesce repeated triggers, preserve pending work during transient failure, and always evaluate current policy/read/download state before admission. Keep the existing 5/10/50 buffer choices, local download semantics, and explicit controls. Use the existing service and shared checked store, not a background daemon or another queue.

## User Stories

1. As a reader, I want finishing and closing a chapter to request refill, so that native next-file reading maintains my buffer.
2. As a reader, I want refill without opening a plugin chapter screen, so that reader navigation does not determine reliability.
3. As a reader, I want pending refill to survive zero UI subscribers, so that closing menus does not abandon work.
4. As a reader, I want pending refill preserved while offline, so that reconnecting can finish the evaluation.
5. As a reader, I want pending refill preserved through KOReader restart, so that a restart does not lose a durable completion.
6. As a reader, I want no network work inside document teardown, so that closing or switching chapters stays responsive.
7. As a reader, I want completed status distinguished from reaching 100 percent, so that unfinished chapters do not trigger completion-only work.
8. As a reader, I want a known already-read chapter's completed close to reevaluate the buffer, so that rereading does not leave an empty buffer.
9. As a reader, I want unlinked local files ignored, so that unrelated documents cannot schedule manga downloads.
10. As a reader, I want repeated triggers coalesced, so that duplicate close/menu events do not multiply requests or jobs.
11. As a reader, I want long-series refill to load all chapters, so that the first 200 records do not limit continuous reading.
12. As a reader, I want pending local read/unread decisions to override stale server flags, so that refill follows my latest reading choices.
13. As a reader, I want my exact saved scanlator restriction respected, so that a missing filter never silently downloads another scanlator.
14. As a reader, I want current buffer settings used at admission, so that changing the limit during a fetch takes effect.
15. As a reader, I want Stop download ahead to stop pending automatic evaluations, so that stale callbacks cannot restart them.
16. As a reader, I want already admitted chapter jobs kept when I lower or stop ahead, so that policy changes do not unexpectedly cancel downloads.
17. As a reader, I want the latest download directory used for new jobs, so that previously queued jobs keep their own captured destination.
18. As a reader, I want terminal failures left visible for explicit Retry, so that automatic refill cannot erase error history.
19. As a reader, I want canceled downloads left canceled until another qualifying trigger, so that cancellation does not cause an immediate refill loop.
20. As a reader, I want manual-delete fences honored, so that automatic work never revokes an accepted deletion request.
21. As a reader, I want one manga's blocked refill not to stall another manga, so that unrelated reading can continue.
22. As a reader, I want waiting/error reasons inspectable without background popups, so that failures are understandable without interrupting reading.
23. As a reader, I want explicit Retry to reevaluate a pending refill using current settings, so that correcting a problem can resume work.
24. As a reader, I want chapter loading, manual mark-read, and read reconciliation to use the same refill operation, so that existing working paths remain reliable.
25. As a reader, I want bulk manual read actions to request one evaluation per affected manga, so that large batches do not start one load per chapter.
26. As a reader, I want another manga's reconciled read transition to request its own refill, so that the visible manga does not limit background work.
27. As a reader, I want an empty complete result distinguished from a failed load or blocked position, so that the UI never falsely claims the buffer is filled.
28. As a maintainer, I want read changes and refill enrollment committed together, so that a crash between them cannot lose work.
29. As a maintainer, I want queue admission and consumption of the matching request revision committed together, so that replay neither duplicates jobs nor clears newer work.
30. As a maintainer, I want context helpers fenced by service/request identity, so that late output cannot act for a retired service or changed policy.
31. As a reader, I want a changed server endpoint to block old scoped refill work, so that a reused manga ID cannot silently target a different server.
32. As a maintainer, I want one bounded helper and one shared shutdown deadline, so that durable refill does not create another source of uncontrolled workers.
33. As a maintainer, I want unknown state and uncertain saves preserved safely, so that normalization never erases pending work.
34. As a maintainer, I want reader, filesystem, durable-state, and visible-result evidence together, so that isolated callback tests do not stand in for lifecycle correctness.

## Implementation Decisions

### Durable admission and triggers

The process-wide download service owns a separately versioned collection of refill requests in the existing shared settings store. A request is a request to evaluate current policy, not a reserved list of chapters or a promise to download N additional chapters.

Store manga identity, minimal resolvable manga/source context or references, connection endpoint identity excluding secrets, a monotonically changing request revision, pending/waiting/blocked status, reason, and retry count/deadline. Preserve unknown versions and unrelated keys. Do not persist credentials, UI objects, live callbacks, complete chapter lists, or page cursors. Credentials are supplied afresh to each context attempt.

A completed document close for a positively identified managed chapter enrolls refill if that manga's policy is enabled, including an already-read completed chapter. Require the supported completed-document status and a close event; merely reaching the final page, ordinary unfinished close, or an unlinked file creates no completion-triggered request. Use existing archive lookup/ledger identity; missing manga/source metadata must be resolved through existing API/context facilities rather than fabricated from a title or path. Background enrollment inherits verified endpoint origin from the manga/archive/policy association, never the current endpoint stamped onto an old chapter ID. Preserve that minimal origin when queue completion or refill evaluation retires. Legacy or changed-endpoint associations with unknown origin stay blocked until a fresh current-endpoint chapter context and explicit plugin Open/Download or ahead-setting action establish the association; a bare matching ID/path or automatic close is insufficient.

When an action changes read state, commit local read/pending-sync changes and its refill revision together. Include same-action accepted archive-only manual-delete intents in that transaction under the reduced specification #12. Queued/running/stopping/finalizing work makes deletion busy/not accepted and remains intact; mark-read may still succeed. Do not cancel existing jobs or promise later deletion for that rejected request. Accepted deletion continues to fence automatic work. For completed-close actions that otherwise change nothing, a checked refill enrollment still occurs. This is not a distributed transaction with KOReader sidecars or the server. Known save failure permits no enqueue; uncertain replacement outcomes use the ownership specification's reconciliation rules.

Preserve manual-action visible ordering, selection clearing, non-target reconciliation, and captured finish-retention eligibility from accepted ADR-0001/ADR-0003. Refill enrollment joins the durable admission; helper scheduling and subscriber notifications follow that admission. Do not move network work into close or run it inline during teardown.

Route these triggers through the same service command: qualifying completed close; single/selected/previous manual read; actual newly reconciled local read transitions for every affected manga; accepted manual unread with its deletion revocation and refill enrollment in the same checked transaction; successful chapter display/return or explicit refresh; enabling/changing the ahead target; and saved scanlator changes for enabled manga. Read reconciliation does not thereby enroll historical chapters for deletion. Coalesce batches per manga and repeated outstanding requests by revision.

No global startup scan of every enabled manga and no perpetual queue-change refill monitor are introduced. Recover only recorded outstanding work; a normal successful context display or fresh action can request a new evaluation. Download cancellation itself, worker progress, subscriber attachment, and sleep/wake do not create new requests. Accepted explicit job cancellation atomically retires the affected manga's pending/in-flight refill evaluation and invalidates its callbacks while keeping ahead enabled; Cancel all downloads retires all currently outstanding evaluations as part of its checked command, including evaluations that have not admitted a chapter job. Failed/unconfirmed cancellation cannot claim retirement. Wake can process existing due work.

### Deferred context evaluation

At most one context-fetch helper runs across the service, distinct from the configured chapter-download concurrency. Service scheduling remains fair and bounded between manga requests. Reuse existing read-only API and subprocess operations with service ownership; never retain the first or retiring plugin UI as their owner.

Fetch a complete ordinary chapter result under the complete-retrieval specification. Ordinary nonempty stored reads do not trigger a source refresh; its existing verified-empty fallback remains available. Load required manga/source metadata when durable context cannot provide it. No fetched result mutates chapter state or schedules jobs in the helper.

Reuse the existing one-shot subprocess helper's result allocation, request tokens, and known-child termination/completion checks. Helpers write only their result files, never shared settings or archives. Reject obsolete results through the current request revision and defer known active helper-file cleanup until the existing helper reports completion. Revised #5 supplies no inherited locks or durable launch/publication protocol; do not add those as navigation prerequisites.

After a genuine restart, recover the durable refill request and fetch a fresh context through existing helper facilities; do not salvage an old helper result. Do not sweep untracked old helper files or claim isolation from surviving legacy workers. Include known helper workers in #5's single total two-second best-effort shutdown budget; no extra quit wrapper, required final save, or second deadline. Refill-request recovery does not automatically retry chapter jobs marked interrupted/failed by revised #3.

### Current policy and atomic queue admission

Before using a completed context result, revalidate service identity, request revision, endpoint scope, current policy/filter, current read ledger, destination availability, queue ownership, archive existence/generation, and manual-delete fences. Capture the relevant read/pending-sync revision when context fetching begins. Any relevant intervening change, including a read-sync acknowledgment that clears a pending flag, invalidates the result and requires a fresh evaluation before merging or admitting jobs. This may advance an already outstanding request revision; an acknowledgment alone does not create a new request. Merge fetched read flags using current ledger semantics: unsynchronized local read/unread wins. Preserve current pending-sync, generation, and deletion state rather than saving a captured ledger over them.

Endpoint changes invalidate in-flight results and block old endpoint-scoped requests with a visible explanation. They do not automatically target reused IDs on the new server. A fresh user/context action can establish work for the new endpoint; authentication updates for the same endpoint can retry its existing work. Do not log raw endpoint identities.

Evaluate the earliest N unread positions in normalized source order after the exact saved scanlator filter. N retains the existing values 5, 10, and 50. Downloaded files and queued/running/retrying/stopping/finalizing work occupy their positions and are not duplicated. A terminal failed job also occupies its position and remains failed until explicit chapter Retry; automatic enqueue must not reset its error or retry history. A deletion-fenced or otherwise blocked position is not replaced by looking beyond N.

A saved scanlator absent from the complete list yields no matches and an explanatory outcome, not an All fallback. This behavior is shared with normal chapter loading. Missing destination, metadata, ownership, or incomplete chapter data yields pending/blocked work, never “buffer filled”.

Automatic admission is an explicit internal command provenance. It cannot supersede a manual-delete intent or restart a terminal failed job. Only accepted deliberate chapter Download/Retry commands retain that supersession authority under specification #12. Revalidate immediately before admission even if candidate computation previously succeeded.

Commit newly admitted queue jobs and consumption of the matching refill revision together. Queue keys deduplicate existing work. A newer revision cannot be cleared by an older result; discard stale results and process the current request. If the transaction fails or is uncertain, acknowledge no admissions and launch no new chapter workers until reconciled. Newly accepted jobs capture the then-current destination; already queued jobs retain their original destination.

A fully evaluated request can retire when its positions are already owned/downloaded, no eligible unread chapters remain, or all positions have been admitted. The chapter jobs then own transfer/retry work. If terminal failures or manual-delete/ownership fences prevent a full buffer, preserve an inspectable blocked outcome. Do not report the buffer as filled or bypass N to compensate. An explicit retry or useful relevant ownership/configuration change may wake that blocked evaluation; ordinary queue completion does not create a new evaluation from nothing.

### Settings, retries, and user-visible state

Stopping ahead commits policy Off and retires its outstanding evaluations, invalidating in-flight callbacks. Already admitted jobs remain. Lowering the target or changing the filter reevaluates current choices without canceling jobs accepted earlier. Directory changes wake affected pending configuration waits; they only affect future admission. No automatic job restarts from a setting change may override deletion fences or terminal failure.

Transient context-fetch/inspection failures retain durable request and retry deadlines: five seconds initially, exponential backoff capped at five minutes, no retry-count abandonment. Each pass is bounded; a failed manga yields to other due manga. Terminal configuration, unsupported schema, or unproved ownership waits remain inspectable and resume only with relevant evidence/change or explicit Retry. Do not spin or show one popup per attempt.

Snapshots in Downloads and relevant chapter views show pending/waiting/blocked refill reason, fixed next retry time when scheduled, and Retry plus Stop download ahead. Retry requests a fresh evaluation; it is not chapter Retry and cannot override a terminal chapter failure or deletion fence. Background retries stay quiet. Detached or hidden views obey the existing subscriber lifecycle; returning views get current state.

Canceling a chapter download does not turn off ahead. Its checked cancellation retires the affected manga's already outstanding evaluation, including a delayed retry or running helper, so that existing work cannot immediately undo cancellation. A later independent completion/manual/context/policy event may select it again if eligible. Explain this behavior rather than adding a suppression journal or another cancellation setting.

Startup recovers outstanding refill requests once after the process service is initialized under revised #5. Navigation does not reset retry history or initiate another recovery. Do not infer lost historical requests by scanning existing read state; enroll new qualifying events and retain known versioned records only.

## Testing Decisions

Use the highest composed seam: real public close/manual/settings actions, service, checked shared state, complete chapter API/result handling, current-ledger selection, queue admission, and rendered snapshots. Use separate FileManager/ReaderUI objects and native reader-to-reader transitions without a plugin list. Keep process state through navigation and replace it only for simulated restart.

Prior art includes public manual-completion integration, read-sync controller/ledger, chapter-context/manga-controller, asynchronous request-worker, and download-failure UX fixtures. Stub server responses and host scheduling; assert durable request/read state, admitted chapter identities, live/terminating worker counts, files, and visible pending/completed/failed status together.

Required cases cover all stories, including: ahead five queues the sixth after completed close; already-read completed close; final-page/unfinished/unlinked negatives; zero views; duplicate events; two manga fairness; more than 200 chapters; local read/unread versus stale server; filter/limit/directory/endpoint changes mid-fetch; absent filter; terminal failure and manual-delete fence; mixed single/selected/previous actions; reconciliation outside visible manga; Off during a fetch; explicit download Cancel/Cancel all during an in-flight, delayed, or blocked evaluation without immediate reenrollment; read-sync acknowledgment between stale server fetch and result application; unknown-origin completion after endpoint change; offline/reconnect/restart with persisted deadlines; stale results; and failures/uncertainty at enrollment and queue-consumption commits.

Use focused real temporary-file and existing-helper checks for result lifetime, stale-result rejection, known-child cancellation, checked persistence, and the shared shutdown budget. Revised #5 does not establish inherited-lock or orphan-isolation guarantees; do not require its removed lock/publication matrix as refill evidence.

The shared device acceptance ticket contrasts plugin-list return and native Open next file from equivalent state, including offline recovery and quit/relaunch. Use generic device wording and synthetic test data. Run the full LuaJIT suite, lint, localization, and required GitHub Actions before a separately authorized implementation merge. No runtime acceptance is established by writing this specification.

## Out of Scope

New buffer sizes, automatic server library refresh, ongoing monitoring of every enabled manga, a persistent chapter cache, network work during teardown, a separate daemon/queue/settings database, immediate refill on every job cancellation or progress change, suppression journals, new read-sync conflict rules, device wake locks, server-side download mutations, or diagnosis of the original crash without evidence.

## Further Notes

ADR-0004 records the durable coalesced-request architecture and why UI-owned callbacks and persisted candidate lists were rejected. Its accepted planning status follows the user's explicit authorization to make simple decisions autonomously, not an additional interview. Implementation remains pending.

This public contract includes the relevant architectural obligations for future implementation through its linked dependency-aware tickets. The checked-in ADRs preserve decision history; publication does not establish runtime implementation or device acceptance.
