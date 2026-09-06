# complete chapter retrieval for long series

Published as [GitHub issue #21](https://github.com/LK4D4/suwayomi.koplugin/issues/21), labeled ready-for-agent. Accepted for autonomous planning; implementation remains pending.

## Problem Statement

Ordinary manga reopening can load only the first 200 stored chapters even when the server reports more. Download next and Download ahead then inspect an incomplete list and can report no candidates while unread chapters exist beyond page one. Explicit source refresh can temporarily hide the defect. A short-series test does not expose it.

This specification addresses section 2 of [issue #2](https://github.com/LK4D4/suwayomi.koplugin/issues/2). It also establishes the complete chapter input needed by durable completion-triggered refills.

## Solution

Retrieve all stored pages before exposing a successful chapter list. Keep the existing asynchronous loading boundary and display a clear failure when a complete result cannot be established. Preserve the last successful context when a reload fails, but do not execute the failed request's dependent action from stale or partial results.

Use a deterministic source order and chapter-ID tie-break across ordinary stored loading and explicit source refresh. Preserve local read-state reconciliation and the saved scanlator restriction. Keep the existing empty-stored-list source fallback only after a verified empty result.

## User Stories

1. As a reader, I want ordinary reopening to load every stored chapter, so that a long series is not silently truncated at 200.
2. As a reader, I want unread chapters beyond the first page considered by Download next, so that additional downloads are discoverable.
3. As a reader, I want Download ahead to use the complete unread list, so that my buffer does not stop at a page boundary.
4. As a reader, I want ordinary reopening and source refresh to yield the same order for the same data, so that action results do not depend on entry route.
5. As a reader, I want chapters with equal source-order values to have stable ordering, so that next/previous actions remain predictable.
6. As a reader, I want the saved scanlator filter applied to the complete list, so that later matching chapters remain visible.
7. As a reader, I want unsynchronized local read and unread choices preserved after loading, so that stale server flags do not change selection.
8. As a reader, I want an incomplete load reported as a failure, so that “no unread chapters” never means “a later page was lost”.
9. As a reader, I want my prior successful view preserved after a failed reload, so that a network interruption does not replace it with partial data.
10. As a reader, I want cancellation to stop a pending load without admitting downloads, so that canceling remains effective on long series.
11. As a reader, I want old or closed-view callbacks ignored, so that delayed results cannot replace another manga's screen.
12. As a reader, I want empty series handled normally, so that a valid empty response is not mistaken for a transport error.
13. As a reader, I want a server's shorter page size handled correctly, so that loading continues when more records remain.
14. As a reader, I want changed or overlapping pages rejected visibly, so that missing chapters are not hidden through silent deduplication.
15. As a reader, I want explicit Refresh chapters to retain its source-refresh meaning, so that ordinary loading does not silently trigger source network work on failure.
16. As a reader, I want time and size limits to produce clear retryable/too-large outcomes, so that the UI remains responsive without claiming truncated success.
17. As a maintainer, I want the complete-result contract retained through API parsing and worker transport, so that no consumer accidentally discards completion evidence.
18. As a maintainer, I want page errors tested through public chapter actions, so that query-only tests cannot miss wrong queue behavior.
19. As a maintainer, I want exact-boundary, short-page, and tied-order cases covered, so that the repair works beyond one 205-chapter example.
20. As a maintainer, I want the limits of offset pagination stated explicitly, so that this repair is not mistaken for a transactional server snapshot.

## Implementation Decisions

### Existing boundary, complete success

Keep query construction, response parsing, API orchestration, asynchronous network execution, chapter-context publication, and selection in their current responsibilities. Extend the existing stored-chapter retrieval operation rather than adding a second chapter service, durable page cache, or persistent cursor. Consumers still receive one complete chapter result or a structured failure.

The page parser must retain nodes, total count, and continuation evidence until the API has validated completion. Preserve error details/categories through the worker result and controller. No caller may accept a nonempty first page as success merely because it contains chapters.

Load sequential pages inside the existing asynchronous request lifetime. Request 200 records per page, starting at offset zero, ordered by source order ascending and numeric chapter ID ascending. Advance offset by the number of nodes actually received. Do not assume the server returns the requested page length.

Each page must provide a valid nonnegative integer total count and a boolean next-page indicator. Require the total to remain stable during one load. Accumulate unique valid chapter IDs and validate source-order values and monotonic source-order/ID order across page boundaries.

Success requires the accumulated unique count to equal the reported total and the final page to say no next page. A zero-total empty page with no continuation is complete. A short nonempty page with continuation remains a page, not end-of-list. An exact multiple of the page size completes when count and continuation agree, without requiring a speculative extra empty request.

Reject malformed chapter identity/order, duplicate IDs, GraphQL/transport errors, missing completion metadata, changing totals, count overrun, empty non-progress pages before completion, backward ordering, or contradictory continuation. Report an incomplete load; do not hide overlaps by deduplicating and claiming success. Retrying starts a new request from the first page, not an automatically looping in-request restart.

### Context publication and refresh

No partial list may reach chapter context, read reconciliation, previous-chapter range selection, next/ahead selection, or queue admission. A request that fails after receiving 200 chapters has no such side effects. Keep the prior complete view if present, identify its reload failure, and do not execute callbacks waiting for the failed fresh load using that older view. A successful verified empty result is different: after any applicable empty-list source fallback also completes, replace or invalidate the previous nonempty context, display the empty state, and prevent its old chapter IDs from being selected or enqueued.

Canceled, timed-out, superseded, and retired-host requests cannot publish results or run dependent actions. Retain current request-token checks at the highest controller boundary and carry them through the complete result. Loading feedback remains cancellable; network work never moves onto the UI thread.

Ordinary nonempty stored loads do not refresh sources. Preserve existing explicitly requested source refresh and uninitialized/empty-series behavior. Only a successfully verified complete empty stored list may use the existing source-fetch fallback; a transport error or partial page cannot masquerade as empty.

Normalize every successful stored, initial-fetch, and explicit-refresh result to source order ascending then numeric chapter ID ascending before consumers use it. Do not reorder by chapter number, upload time, title, or the current reader position. Validate identity/order and reject duplicate identities on source-refresh results too. The refresh operation returns its full list through the existing mutation contract; it is not an excuse to accept a truncated stored result.

Keep current local-ledger reconciliation rules, including pending local read/unread precedence. Apply the saved scanlator filter consistently. A configured scanlator absent from the complete result yields no matching chapters with an explanation; it must not silently broaden to All. This tightens the current missing-filter fallback and applies to both UI selection and automatic consumers.

### Bounds and concurrency limits

Do not introduce a fixed total chapter cap. Retain existing request timeout and transport/result byte budgets, enforcing an aggregate result-size budget before serialization/worker handoff. If a large series exceeds those budgets, return a clear complete-load failure/too-large reason rather than truncating, spinning indefinitely, or presenting an opaque timeout for a known size violation. Cancellation and stale-result suppression still apply.

Completeness is guaranteed for a stable server dataset. Offset pagination cannot prove a single atomic snapshot during arbitrary same-count concurrent edits. Fail detected count/order/identity inconsistencies; do not claim stronger guarantees or add server snapshot negotiation, repeated automatic full reloads, or speculative cursor compatibility.

### Protocol evidence

The pinned upstream [chapter query](https://github.com/Suwayomi/Suwayomi-Server/blob/7537f301c92ebea28d6f35ce992cfe440d03eb58/server/src/main/kotlin/suwayomi/tachidesk/graphql/queries/ChapterQuery.kt#L202-L290) accepts first/offset, explicit ordering, a next-page indicator, and total count. Its [count/sort primitive](https://github.com/Suwayomi/Suwayomi-Server/blob/7537f301c92ebea28d6f35ce992cfe440d03eb58/server/src/main/kotlin/suwayomi/tachidesk/graphql/server/primitives/OrderBy.kt#L108-L134) counts filtered rows before pagination. Chapter ID and source order are integer fields.

The actual [GraphQL source-refresh mutation](https://github.com/Suwayomi/Suwayomi-Server/blob/7537f301c92ebea28d6f35ce992cfe440d03eb58/server/src/main/kotlin/suwayomi/tachidesk/graphql/mutations/ChapterMutation.kt#L173-L191) returns the refreshed manga's chapters in ascending source order. This plan does not claim a reversed-refresh defect; explicit normalization establishes deterministic ties and parity. Unsupported or malformed completion metadata produces a clear error instead of an unverified one-page compatibility fallback.

## Testing Decisions

Prefer the composed public chapter load/action boundary with real query, parser, API, worker-result contract, controller, selection, and queue behavior. Stub transport/host time where needed; assert chapter identities/order, committed read state, candidate/admitted job IDs, visible counts, and displayed failures together.

Prior art is the API/query/parser specifications, asynchronous manga-controller and request-worker fixtures, chapter-context/action specifications, and composed download UX tests. Preserve those seams. Narrow parser tests supplement the composition; request count alone does not establish correct selection.

Required cases:

- Totals 0, 1, 199, 200, 201, 205, 400, and 401; at least one short nonterminal page; 200 read records followed by five unread records.
- Equal source-order values across page boundaries with deterministic numeric-ID ties.
- Same data through ordinary reopen, source refresh, initial source fallback, and both next/ahead actions; include nonmatching/missing saved scanlator and pending local read/unread.
- Later-page transport/GraphQL failure, changing total, duplicate/overlapping IDs, missing metadata, empty non-progress page, malformed IDs/order, count overrun, contradictory continuation, and aggregate size limit.
- Cancellation, timeout, navigation to another manga, retired host, newer successful request before older completion, and failed reload with a prior complete context.
- No queue mutation, read reconciliation, or no-candidates success message from an incomplete result. A previous nonempty context followed by verified stored-empty/source-empty or empty explicit refresh instead becomes a complete empty context; obsolete chapter IDs cannot enqueue.
- A device long-series control compares complete count/order and next/ahead candidates after reopening and refresh. This belongs to the shared audit acceptance ticket; no private library content is required.

Run full LuaJIT tests, lint, localization checks for implementation changes, and repository-required GitHub Actions before an authorized merge. No implementation or device pass is claimed by this specification.

## Out of Scope

Changing download-next/ahead buffer sizes, adding new refill triggers, byte/page resume, server-side download mutations, a server snapshot protocol, a persistent chapter cache, per-page UI streaming, a fixed total chapter limit, or changing read-sync conflict policy.

## Further Notes

The user authorized autonomous design and publication without questions, favoring simplicity. The audit and local design branch remain unpublished. This public specification contains the actionable contract independently of those local documents. The existing ownership and manual-deletion specifications retain their scope and safety requirements.
