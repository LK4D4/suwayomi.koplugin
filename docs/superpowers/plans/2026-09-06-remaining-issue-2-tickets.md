# Remaining issue-2 audit: specs and implementation tickets

Original publication status (2026-09-06; dependency and scope amendments below supersede old manual-deletion routing): published and verified under the user's authorization to decide autonomously, favor simplicity, and ask no further questions. Three specifications and eight implementation tickets are ready-for-agent. Runtime implementation and device acceptance remain pending.

## Scope and decisions

The September 6 investigation separates four confirmed defects from established semantics, previous repairs, and unresolved crash evidence. Sections 1 and 4 already have specifications and tickets; this plan completes coverage without duplicating them or changing the original report.

| Audit material | Specification / decision | Implementation / acceptance |
| --- | --- | --- |
| §1: process-wide download ownership | [Spec #3](https://github.com/LK4D4/suwayomi.koplugin/issues/3), ADR-0002 | Existing #4–#11; unchanged. |
| §2: 200-chapter truncation | [Spec #21](https://github.com/LK4D4/suwayomi.koplugin/issues/21) | [#24](https://github.com/LK4D4/suwayomi.koplugin/issues/24)–[#25](https://github.com/LK4D4/suwayomi.koplugin/issues/25), with device control in C3. |
| §3: missing completed-close refill | [Spec #22](https://github.com/LK4D4/suwayomi.koplugin/issues/22), ADR-0004 | [#26](https://github.com/LK4D4/suwayomi.koplugin/issues/26)–[#28](https://github.com/LK4D4/suwayomi.koplugin/issues/28), with device control in C3. |
| §4: lost manual deletion | [Spec #12](https://github.com/LK4D4/suwayomi.koplugin/issues/12), ADR-0003 and ADR-0001 amendment | [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36) and [#37: Verify reduced manual deletion on a device](https://github.com/LK4D4/suwayomi.koplugin/issues/37) supersede #13–#20. Reduced ADR-0003 scope retains ADR-0001 checked ordering. |
| §5: next/ahead meaning and hidden 50 cap | [Spec #23](https://github.com/LK4D4/suwayomi.koplugin/issues/23) | [#29](https://github.com/LK4D4/suwayomi.koplugin/issues/29)–[#30](https://github.com/LK4D4/suwayomi.koplugin/issues/30). |
| §5: while-reading repair and retention meaning | Reduced #12 and replacement implementation plus controls specification | Preserve current retention policy, add clear labels; C2/C3 and [#37: Verify reduced manual deletion on a device](https://github.com/LK4D4/suwayomi.koplugin/issues/37). |
| §5: transient retries, HTTP 400/404 fallback, error UI repairs | Controls specification regression obligations | C3 preserves checks; no duplicate defect tickets for repaired work. |
| Remaining device controls, revision provenance, actual crash evidence | Controls specification evidence contract | C3 composes prior acceptance, records demonstrated/failed/unverified outcomes, leaves unproved crash unresolved. |

Only the durable coalesced-refill boundary warrants another ADR. Pagination stays in the existing API/request boundary; wording and cap disclosure are reversible product decisions. Added glossary terms are Download-ahead buffer and Refill request. Current architecture documentation remains a description of implemented runtime and is updated only during implementation.

Simple choices: sequential offset pages with explicit completeness evidence; no partial success or persistent page cache; existing 50-download cap with honest pre-action disclosure; one coalesced refill per manga and one helper; existing checked store, worker ownership, and shutdown budget; no perpetual queue watcher, extra settings, telemetry, or suppression journal. Explicit cancellation retires pending evaluation without disabling ahead. Terminal failures need explicit chapter Retry. Missing saved scanlator never broadens to All.

Successful empty loads replace obsolete context. Relevant read/pending-sync revision changes reject stale fetch results, including synchronization acknowledgments. Endpoint provenance prevents old or unknown archive IDs from silently creating work on a different server.

## Original execution contract (2026-09-06)

Published three self-contained specifications and eight vertical implementation tickets, all ready-for-agent. The user explicitly authorized publication and delegated the normal interview/seam/breakdown decisions; no further approval round is required. Every ticket inherits its parent specification, applicable accepted ADRs, repository checks, privacy requirements, and existing ownership/manual-delete prerequisites. Local-only source links are not required to understand the public issue.

Work tickets whose native blockers are complete. Parent specifications and original report stay open and unchanged; finishing planning does not establish implementation or device results. No runtime edit, branch switch, merge, push, deployment, reporter message, or issue closure is included.

## Published breakdown

| Slice / issue | Title | Native blocked by | Parent / story coverage |
| --- | --- | --- | --- |
| P1 / [#24](https://github.com/LK4D4/suwayomi.koplugin/issues/24) | Load every stored chapter before publishing chapter context | None | [#21](https://github.com/LK4D4/suwayomi.koplugin/issues/21): 1, 2, 3, 5, 8, 12, 13, 14, 15, 16, 17, 19, 20 |
| P2 / [#25](https://github.com/LK4D4/suwayomi.koplugin/issues/25) | Preserve complete chapter selection across reopening and refresh | [#24](https://github.com/LK4D4/suwayomi.koplugin/issues/24) | [#21](https://github.com/LK4D4/suwayomi.koplugin/issues/21): 4, 6, 7, 9, 10, 11, 15, 18, 19, 20 |
| R1 / [#26](https://github.com/LK4D4/suwayomi.koplugin/issues/26) | Refill download ahead after completed reader close | [#25](https://github.com/LK4D4/suwayomi.koplugin/issues/25), [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36), [#10](https://github.com/LK4D4/suwayomi.koplugin/issues/10) | [#22](https://github.com/LK4D4/suwayomi.koplugin/issues/22): 1, 2, 3, 6, 7, 8, 9, 10, 11, 12, 18, 20, 27, 28, 29, 30, 32, 33, 34 |
| R2 / [#27](https://github.com/LK4D4/suwayomi.koplugin/issues/27) | Recover pending refills through offline operation and restart | [#26](https://github.com/LK4D4/suwayomi.koplugin/issues/26) | [#22](https://github.com/LK4D4/suwayomi.koplugin/issues/22): 4, 5, 21, 22, 23, 27, 29, 30, 32, 33, 34 |
| R3 / [#28](https://github.com/LK4D4/suwayomi.koplugin/issues/28) | Unify refill triggers and honor current reading choices | [#27](https://github.com/LK4D4/suwayomi.koplugin/issues/27), [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36) | [#22](https://github.com/LK4D4/suwayomi.koplugin/issues/22): 10, 13, 14, 15, 16, 17, 18, 19, 20, 24, 25, 26, 27, 28, 29, 31, 34 |
| C1 / [#29](https://github.com/LK4D4/suwayomi.koplugin/issues/29) | Disclose bulk download limits before queue admission | [#4](https://github.com/LK4D4/suwayomi.koplugin/issues/4) | [#23](https://github.com/LK4D4/suwayomi.koplugin/issues/23): 1, 2, 3, 4, 5, 6, 7, 18 |
| C2 / [#30](https://github.com/LK4D4/suwayomi.koplugin/issues/30) | Explain ahead buffers and completion retention consistently | [#28](https://github.com/LK4D4/suwayomi.koplugin/issues/28), [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36) | [#23](https://github.com/LK4D4/suwayomi.koplugin/issues/23): 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 |
| C3 / [#31](https://github.com/LK4D4/suwayomi.koplugin/issues/31) | Verify remaining issue-2 workflows and record crash evidence limits | [#29](https://github.com/LK4D4/suwayomi.koplugin/issues/29), [#30](https://github.com/LK4D4/suwayomi.koplugin/issues/30), [#37: Verify reduced manual deletion on a device](https://github.com/LK4D4/suwayomi.koplugin/issues/37) | [#23](https://github.com/LK4D4/suwayomi.koplugin/issues/23): 19, 20, 21, 22, 23, 24 |

Original ticket routing is retained for unrelated work; consult live progress before starting. R1 (#26) keeps #25/#10 and waits for the replacement implementation's checked manual admission and automatic-work fences. R3 (#28) keeps #27 and waits for complete bulk coordination. C2 (#30) keeps #28 and waits for actual reduced outcomes plus necessary retention/identity coordination. C3 (#31) keeps #29/#30 and waits for replacement device acceptance, which also waits for #11. Busy manual deletion never cancels downloads; accepted archive-only deletion remains durable. These are genuine gates, not requirements to close parent specs.
## Specification coverage

All 20 complete-retrieval stories, 34 refill stories, and 24 controls/acceptance stories map to at least one ticket above. Acceptance includes public action/lifecycle composition, targeted real filesystem/process checks, and device workflow evidence. No tests are claimed run in this planning task.

## Original publication verification (2026-09-06)

All three specification and eight ticket titles, bodies, open states, and ready-for-agent labels were read back. All 13 native blocked-by relationships match the table, including no blockers for #24 and checked command admission #4 for #29. Original report #2 and existing specifications #3/#12 retained identical titles, bodies, comments, states, and labels. No parent issue was modified or closed.

All published content passed a personal-data/device-name scan before finalization. This record uses generic device wording. Local validation reviewed documentation content, story coverage, links, dependency graph, and whitespace. No runtime test or device execution is claimed.

## Published tickets

### P1 / #24: Load every stored chapter before publishing chapter context

#### Parent

[Spec: complete chapter retrieval for long series (#21)](https://github.com/LK4D4/suwayomi.koplugin/issues/21)

#### What to build

Ordinary chapter loading retrieves and validates every stored page before displaying a successful list or running a dependent download action. Long-series chapters beyond record 200 become selectable through the existing asynchronous API/controller path.

This ticket inherits its parent specification's complete behavior, safety, privacy, and verification contract. Parent user stories: 1, 2, 3, 5, 8, 12, 13, 14, 15, 16, 17, 19, 20.

#### Acceptance criteria

- [ ] Keep pagination inside the existing stored-load operation and asynchronous request lifetime. Query sequential pages of up to 200 with actual-node-count offsets and explicit source-order ascending/numeric-ID ascending order.
- [ ] Carry validated totalCount and hasNextPage through parsing. Complete only when unique accumulated count equals the stable total and continuation is false; handle zero total, exact page multiples, and short nonterminal pages without truncation.
- [ ] Reject duplicate/invalid chapter identities or order, changing totals, backward pages, empty non-progress pages, missing metadata, count overrun, contradictory continuation, and transport/GraphQL errors. No partial success or silent duplicate suppression.
- [ ] Retain bounded request and aggregate result-size limits with explicit incomplete/too-large failure; add no total chapter cap, persistent cursor, automatic whole-load restart loop, or synchronous UI-network path.
- [ ] Publish chapter context and run dependent actions only after complete validation. A failed fresh load cannot silently use a partial or older list for its deferred action.
- [ ] Retain source-fetch fallback only after a proven complete empty stored result; a page error is not empty and must not silently refresh the source.
- [ ] Through the real query/parser/API/result/controller path, verify totals 0, 1, 199, 200, 201, 205, 400, 401, short nonterminal pages, and tied source order across boundaries. For 200 read plus five unread chapters, display all 205 and admit the expected next-download IDs.
- [ ] Exercise incomplete/malformed/oversized responses through the public load/action seam and assert error display, unchanged committed read state, unchanged prior complete context, and no queue admission together.
- [ ] Run full LuaJIT tests, lint, and localization checks for the implementation. Update current architecture guidance only for ownership/interface changes actually made.

#### Blocked by

None (can start immediately).


### P2 / #25: Preserve complete chapter selection across reopening and refresh

#### Parent

[Spec: complete chapter retrieval for long series (#21)](https://github.com/LK4D4/suwayomi.koplugin/issues/21)

#### What to build

Normal reopening, initial source fetch, explicit Refresh chapters, and next/ahead actions agree on complete chapter identities and ordering. Failed or obsolete loads preserve the valid view and cannot enqueue from stale context.

This ticket inherits its parent specification's complete behavior, safety, privacy, and verification contract. Parent user stories: 4, 6, 7, 9, 10, 11, 15, 18, 19, 20.

#### Acceptance criteria

- [ ] Normalize every successful stored/source-fetch/refresh result to source-order ascending then numeric chapter-ID ascending, validating identity/order and duplicate IDs before use. Do not sort by chapter number/title or reader position.
- [ ] Apply the exact saved scanlator restriction after complete loading. If the configured scanlator is absent, show no matches and an explanation instead of silently broadening to All; keep this behavior shared with automatic consumers.
- [ ] Merge current ledger state using existing conflict precedence, preserving pending local read/unread choices and unrelated archive-generation/manual-intent fields.
- [ ] Use current request tokens and host lifecycle guards through complete-result publication. Cancel, timeout, newer request, different manga, and retired host invalidate old completion and dependent actions.
- [ ] Keep the last successful context visible on reload failure with an honest error, while preventing the failed request's action from using it as a successful fresh result.
- [ ] Compose public reopening/refresh/first-unread/previous-range/next/ahead entry points with real query/parser/API and queue selection. Assert identical chapter order/candidate IDs for the same dataset, including more than 200 chapters, tied order, and saved filters.
- [ ] Cover later-page errors, duplicate/changing pages, cancel/timeout, old completion after newer success, absent filter, and stale server flags against local read/unread. Assert visible state, read ledger, and queue outcomes together.
- [ ] Preserve explicit source-refresh semantics and verified-empty fallback; document stable-dataset completeness without promising an atomic snapshot during undetectable same-count server edits.
- [ ] Run the full LuaJIT suite, lint, and localization checks. The combined audit acceptance ticket owns the device long-series comparison; do not claim this automated slice establishes it.
- [ ] Distinguish successful empty from failure: verified stored-empty/source-empty or empty explicit refresh replaces/invalidate a previous nonempty context, displays empty state, and cannot enqueue its obsolete chapter IDs. Add that composed transition test.

#### Blocked by

- [Load every stored chapter before publishing chapter context (#24)](https://github.com/LK4D4/suwayomi.koplugin/issues/24)


### R1 / #26: Refill download ahead after completed reader close

#### Parent

[Spec: durable completion-triggered download ahead (#22)](https://github.com/LK4D4/suwayomi.koplugin/issues/22)

#### What to build

With ahead enabled, a known chapter's completed close durably requests buffer evaluation and queues its next missing unread position after teardown, even across native reader-to-reader navigation and with zero plugin screens.

This ticket inherits its parent specification's complete behavior, safety, privacy, and verification contract. Parent user stories: 1, 2, 3, 6, 7, 8, 9, 10, 11, 12, 18, 20, 27, 28, 29, 30, 32, 33, 34.

#### Acceptance criteria

- [ ] Add the separately versioned coalesced per-manga refill request within the existing checked shared store/service. Persist resolvable manga context, endpoint scope, revision, status/reason, and retry metadata; never credentials, UI objects, or full chapter lists.
- [ ] Enroll qualifying completed closes including already-read chapters; ignore final-page-only, unfinished-close, and unlinked-file controls. Commit read/pending-sync changes and refill enrollment together; acknowledge neither on failed or uncertain persistence.
- [ ] Schedule after durable admission and teardown, never perform network work inline in CloseDocument. Keep one service-owned read-only context helper across manga, separate from chapter-download concurrency.
- [ ] Reuse complete stored retrieval and required manga/source lookup; merge current ledger read/unread precedence and revalidate request/service revision, endpoint, policy/filter, destination, queue/archive ownership, and manual-delete fences before admission.
- [ ] Use unique helper attempt/result artifacts and the existing durable launch/writer-release protocol, with parent-only shared writes and proven child exit before cleanup. Include this helper in the existing total two-second shutdown budget and process ownership restrictions.
- [ ] Select only the earliest N filtered unread positions for existing 5/10/50 limits. Owned queue/archive positions and terminal failed positions consume slots. Automatic admission neither resets terminal failure/retry history nor supersedes manual-delete intent.
- [ ] Commit newly admitted jobs and consumption of only the matching request revision atomically. A later trigger survives older output; chapter workers start only after checked admission. Known failure or uncertain outcome must not duplicate jobs or erase requests.
- [ ] Expose honest current pending/blocked versus evaluated status through service snapshots; no subscriber is required for durable work. Rendering snapshots itself must not enroll another request.
- [ ] Compose FileManager to Reader A to native Reader B without plugin chapters: ahead five admits the sixth chapter after completed close. Assert request/read state, candidate/job IDs, worker/file ownership, and returned UI state together; include duplicate events, zero views, save failure, terminal failure, and deletion fence.
- [ ] Run full LuaJIT tests, lint, and localization checks. Keep startup requests preserved safely until recovery support is verified in the next slice; no unsafe fallback, extra quit wrapper, or new independent service.
- [ ] Retain verified endpoint provenance for background enrollment; old/unknown-origin legacy associations cannot be stamped with current endpoint merely by closing a file. Require a fresh current-endpoint context plus explicit plugin Open/Download or ahead-setting association. Reject/refetch results when relevant read/pending-sync revision changes during fetch, including synchronization acknowledgment clearing pending state.

Manual-deletion dependency supplies checked admission, command provenance, and automatic-work fences under reduced #12. Owning downloads produce busy/not-accepted deletion without cancellation; accepted archive-only requests still fence refill. This ticket owns new completion-triggered refill scheduling.

#### Blocked by

- [Preserve complete chapter selection across reopening and refresh (#25)](https://github.com/LK4D4/suwayomi.koplugin/issues/25)
- [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36)
- [Stop download service within a bounded KOReader shutdown (#10)](https://github.com/LK4D4/suwayomi.koplugin/issues/10)


### R2 / #27: Recover pending refills through offline operation and restart

#### Parent

[Spec: durable completion-triggered download ahead (#22)](https://github.com/LK4D4/suwayomi.koplugin/issues/22)

#### What to build

Pending refill survives offline operation, process restart, helper interruption, and reported storage errors. A blocked manga yields to other work, and current views expose quiet Retry/Stop controls and useful reasons.

This ticket inherits its parent specification's complete behavior, safety, privacy, and verification contract. Parent user stories: 4, 5, 21, 22, 23, 27, 29, 30, 32, 33, 34.

#### Acceptance criteria

- [ ] Persist transient retry count/deadline with five-second exponential backoff capped at five minutes and no count abandonment. Recover recorded requests only after exclusive ownership; navigation/sleep never starts a second recovery or resets deadlines.
- [ ] Process due manga fairly with one context helper and bounded passes. Transient fetch/inspection failure retries; unsupported schema, identity/configuration, or unproved ownership remains blocked until relevant evidence/change or explicit Retry.
- [ ] Provide pending/waiting/blocked reason and fixed next retry time through Downloads and relevant chapter snapshots, with Retry and Stop download ahead. Refill Retry never acts as chapter Retry or revokes deletion intent; no background popup loop.
- [ ] Stop commits policy Off plus outstanding-request retirement and invalidates in-flight results, leaving already admitted chapter jobs. Hidden/retired UI callbacks stay inert and fresh views show current state.
- [ ] Preserve/reconcile requests at crashes around enrollment, helper allocation/authorization, result delivery, and atomic queue-admission/consumption. Never restore an old ledger/cache over uncertain replacement or clear a newer request revision.
- [ ] Prove helper isolation with actual temporary files and subprocesses: surviving old writer, inherited attempt locks, parent descriptor closure, unique replacement result paths, no stale shared write, proven reaping/release, and cleanup after safe release. No terminal-result-file or timeout guess establishes exit.
- [ ] Share the existing one total two-second service shutdown deadline across helper and chapter workers; preserve durable work and ownership if shutdown cannot confirm exit. No required final transaction or future UI tick.
- [ ] Compose offline then reconnect, restart while pending, two manga fairness, repeated transient failure, missing configuration, unknown versions, stale results, and failed/uncertain saves. Assert durable state, actual test files/workers, queue admissions, and rendered status together.
- [ ] Run full LuaJIT tests, lint, localization checks, and the real-process adapter checks. Device offline/relaunch comparison belongs to the final audit acceptance ticket.

#### Blocked by

- [Refill download ahead after completed reader close (#26)](https://github.com/LK4D4/suwayomi.koplugin/issues/26)


### R3 / #28: Unify refill triggers and honor current reading choices

#### Parent

[Spec: durable completion-triggered download ahead (#22)](https://github.com/LK4D4/suwayomi.koplugin/issues/22)

#### What to build

Existing plugin-return, manual read, reconciliation, unread, and policy/filter flows all request the same durable evaluation. Current user choices govern admission without accidental job cancellation, failure reset, or deletion supersession.

This ticket inherits its parent specification's complete behavior, safety, privacy, and verification contract. Parent user stories: 10, 13, 14, 15, 16, 17, 18, 19, 20, 24, 25, 26, 27, 28, 29, 31, 34.

#### Acceptance criteria

- [ ] Route completed close, single/selected/previous manual read, actual newly reconciled read transitions for every affected manga, accepted unread, successful chapter load/return/explicit refresh, and policy/filter changes through one service command.
- [ ] Coalesce manual batches per manga. Join refill enrollment to the checked read/manual-intent transaction while preserving visible completion order, pathless retention eligibility, selection clearing, non-target reconciliation, and post-commit scheduling from ADR-0001/ADR-0003.
- [ ] Do not create requests from subscriber repaint, queue progress/cancellation, or a startup scan of every enabled manga. A current queue event may wake an already recorded blocker without inventing work; no perpetual refill monitor.
- [ ] Use exact saved scanlator restriction and current ledger over stale server read flags. A vanished filter must not become All. Revalidate limits/filter/read revisions changed while fetching rather than admitting stale candidates.
- [ ] Keep 5/10/50 choices. Lowering or stopping ahead does not cancel admitted jobs; Off retires pending evaluation. Directory changes affect future admissions and wake configuration waits while preserving earlier job destinations.
- [ ] Scope outstanding work/results to their endpoint. An endpoint change blocks old work rather than retargeting reused IDs; a fresh action can establish a new scope. Same-endpoint authentication changes may retry, without storing/logging credentials in requests.
- [ ] Automatic refill cannot reset terminal failed jobs, select beyond N to compensate for blocked positions, or supersede manual-delete intent. Explicit chapter Download/Retry alone retains accepted supersession semantics; failed/no-op admission does not.
- [ ] Accepted explicit job cancellation atomically retires its manga's pending/in-flight/delayed/blocked refill evaluation and invalidates callbacks while keeping ahead enabled. Cancel all retires every outstanding evaluation, including one with no admitted job. Failed/uncertain commands cannot claim retirement; only a later independent qualifying event may enroll new work. Test both cancellation routes during helper execution and delayed retry.
- [ ] Compose all public triggers, mixed manual batches, nonvisible-manga reconciliation, local unread versus stale server, settings/endpoint change mid-fetch, terminal failure, pending manual deletion, and stale result races. Assert durable read/intent/request/job state and UI outcomes together.
- [ ] Run full LuaJIT tests, lint, localization, and relevant real-process checks. Update the architecture map for implemented service/trigger ownership. The final audit acceptance ticket verifies combined device behavior.
- [ ] Preserve verified origin through archive/policy association and reject unknown-origin completion after endpoint change. Exercise the close → fetch stale remote unread → read-sync acknowledgment → result sequence; revision invalidation must prevent re-downloading the completed chapter.

Manual-deletion dependency supplies complete bulk checked read/intent coordination and unread revocation under reduced #12. Include busy/not-accepted members without canceling work or promising deletion; only accepted intents join the transaction. This ticket owns new refill enrollment across those existing actions.

#### Blocked by

- [Recover pending refills through offline operation and restart (#27)](https://github.com/LK4D4/suwayomi.koplugin/issues/27)
- [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36)


### C1 / #29: Disclose bulk download limits before queue admission

#### Parent

[Spec: clear download controls and issue-2 acceptance (#23)](https://github.com/LK4D4/suwayomi.koplugin/issues/23)

#### What to build

All-chapter/all-unread and capped bulk actions state the 50-new-download limit before acceptance, and confirmations/results reflect actual eligible and admitted chapters rather than the uncapped selection or configured maximum.

This ticket inherits its parent specification's complete behavior, safety, privacy, and verification contract. Parent user stories: 1, 2, 3, 4, 5, 6, 7, 18.

#### Acceptance criteria

- [ ] Keep the existing 50-new-download cap and explicit action model. Label all-chapter and all-unread scopes with their up-to-50-new limit; no automatic continuation, background whole-series plan, or new setting.
- [ ] Count eligibility before the cap using shared admission/download checks, so existing files and owned queued/running/stopping/finalizing work do not consume new-download capacity. Preserve each action's read/scanlator/selected scope.
- [ ] Confirmation names the bounded captured candidates/count, already unavailable count, and eligible remainder beyond the cap. Zero eligible candidates get an honest reason; disclose the limit for selected/next actions when applicable without adding confirmation to every small action.
- [ ] At acceptance revalidate captured candidate identities against current state; never broaden to a changed filter, unrelated chapter, or different manga. Accept fewer if eligibility changed and leave further candidates for a new explicit action.
- [ ] Report actual admitted, skipped, capped, and failed/unconfirmed counts. Never say Queued 50 merely because 50 is configured, and never report a rejected/uncertain save as acceptance.
- [ ] Preserve explicit download/retry provenance and selection/menu behavior, including accepted-command manual-delete supersession when that integration is present; avoid introducing another queue eligibility definition.
- [ ] Compose public confirmations/actions with real selection and admission for 0, 1, 49, 50, 51, and larger batches; mixed read/downloaded/queued/failed items, stale dialog, cancel, duplicate race, and failed admission. Assert displayed promise/result and resulting jobs together.
- [ ] Use existing i18n/plural boundaries, update applicable source catalogs/template and user help, and run full LuaJIT tests, lint, and localization checks. Keep the cap unchanged.

#### Blocked by

- [Make plugin state writes atomic and report failed commands (#4)](https://github.com/LK4D4/suwayomi.koplugin/issues/4)


### C2 / #30: Explain ahead buffers and completion retention consistently

#### Parent

[Spec: clear download controls and issue-2 acceptance (#23)](https://github.com/LK4D4/suwayomi.koplugin/issues/23)

#### What to build

Settings, chapter/manga actions, and help consistently explain additional next downloads, earliest-unread ahead positions, durable manual deletion, and per-manga completion retention with concrete examples.

This ticket inherits its parent specification's complete behavior, safety, privacy, and verification contract. Parent user stories: 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18.

#### Acceptance criteria

- [ ] Explain next N as additional eligible unread downloads and ahead N as missing positions among the earliest N filtered unread chapters in normalized source order. Existing owned positions count; reader page is not an anchor.
- [ ] Describe completed-close/native-next, manual read/unread, read reconciliation, successful context load/return, and policy/filter triggers exactly as implemented. Snapshot repaint, queue progress, and cancellation are not new triggers.
- [ ] Explain Stop download ahead versus existing jobs, and download Cancel retiring current refill evaluation while permitting a later independent event. Cancel all retires all evaluations without disabling policies. Explain terminal chapter Retry separately from pending-refill Retry.
- [ ] Keep retention persisted values 0–5 compatible: 0 disabled; 1–5 keep newest 0–4 recorded completions per manga. Use a shared label mapping in settings summary and picker, such as Keep 2 newest completions, replacing misleading ordinal list-position wording.
- [ ] Explain completed status plus close, live-reader protection, manual completion enrollment, pathless positions, and no retroactive deletion authorization from historical/server read state.
- [ ] Explain reduced #12: owning queued/running/stopping/finalizing work makes deletion busy/not accepted, preserves work, and requires another action after it finishes. Mark-read may succeed independently. Accepted archive-only requests survive setting Off and are revoked by unread or later accepted deliberate download; failed/uncertain/duplicate/automatic admission does not revoke them. Sidecars/backups/metadata remain, not unfinished deletion work. Use existing chapter status and immediate summaries, with no dedicated manual Downloads screen or new deletion Retry/Cancel controls.
- [ ] Include ahead-five with two existing positions versus next-five additional downloads, and retention-three A/B/C with A eligible after C. Mention exact saved scanlator and no silent All fallback when missing.
- [ ] Keep UI explanations short and user-facing; put fuller examples in help. Use existing localization/plural boundaries and accurate source catalogs/template, without fabricating translations.
- [ ] Exercise public settings summary/picker/actions for all persisted values and repeated navigation, compare help to actual service/selection/retention behavior, and verify missing-filter/terminal-failure/pending-deletion wording. Run full suite, lint, and localization checks.

The implementation dependency includes necessary publication/ordinary Delete/retention identity coordination and unchanged completion positions/pathless eligibility. Verify explanations against those implemented outcomes; this ticket does not redesign retention eligibility.

#### Blocked by

- [Unify refill triggers and honor current reading choices (#28)](https://github.com/LK4D4/suwayomi.koplugin/issues/28)
- [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36)


### C3 / #31: Verify remaining issue-2 workflows and record crash evidence limits

#### Parent

[Spec: clear download controls and issue-2 acceptance (#23)](https://github.com/LK4D4/suwayomi.koplugin/issues/23)

#### What to build

One reproducible acceptance record covers the audit's remaining contrasting device workflows and links existing ownership/manual-delete evidence. It distinguishes verified fixes, failed/unverified checks, and the original unproved application-crash claim.

This ticket inherits its parent specification's complete behavior, safety, privacy, and verification contract. Parent user stories: 19, 20, 21, 22, 23, 24.

#### Acceptance criteria

- [ ] Run the device long-series control with more than 200 stored chapters and unread chapters beyond page one. Compare complete identities/count/order and next/ahead candidates after ordinary reopening versus explicit Refresh, including saved filter and tied order.
- [ ] From equivalent ahead-five state, compare plugin-list return against native Open next file/direct reader transitions without plugin screens. Both admit the sixth chapter after completed close; repeat offline/reconnect and pending-work quit/relaunch, with no duplicate workers or jobs.
- [ ] Reuse and link ownership and manual-delete acceptance evidence: Downloads-only versus navigation, concurrency two then one, zero-view completion, bounded shutdown, reduced archive-only manual deletion with retention off/three, live reader, navigation/restart, transient retry, busy downloads requiring another action, retained metadata, honest chapter summaries, and later deliberate replacement. Record any gaps instead of assuming dependencies establish new combinations.
- [ ] Exercise independent retention-three A/B/C with restart between B/C, retention-one live then close, and final-page-without-completed-status negative control. Observe archives, retained/owned metadata, read state, and displayed status together.
- [ ] Preserve automated controls for durable transient retries, quiet failures, full terminal-error inspection, and HTTP 400/404 archive-to-page fallback. Do not reopen already repaired regressions as new defects or attribute the later HTTP 400 bug to the original report.
- [ ] On a device compare bulk confirmation versus actual admissions for more than 50 eligible chapters, a changing queue, compact layouts, and relevant localized strings. Use synthetic/controlled data; do not damage storage to force failures.
- [ ] Record tested plugin revision and runtime-payload verification extent separately from displayed version, KOReader version, generic environment, timestamps, batch/concurrency, navigation, storage availability category, and sleep/network controls. Mark each result demonstrated, failed, or unverified.
- [ ] Provide a minimal redacted crash-evidence checklist distinguishing application disappearance/restart, child failure, and row failure. Remove credentials/endpoints/paths/library titles/source names and identifying device details before sharing any artifact; use anonymous aliases and generic device wording, no raw logs or user content in commits.
- [ ] Absence of an observed exit means only no application exit under these controls. Leave original crash cause unresolved without reproduction; do not close/modify parent reports or contact the reporter. If device execution is unavailable, leave that acceptance pending rather than claiming a pass.
- [ ] Run full LuaJIT tests, lint, localization checks and, before any separately authorized implementation merge, the repository-required GitHub Actions. This ticket records actual implementation evidence; the current planning task must not claim these checks were executed.

#### Blocked by

- [Disclose bulk download limits before queue admission (#29)](https://github.com/LK4D4/suwayomi.koplugin/issues/29)
- [Explain ahead buffers and completion retention consistently (#30)](https://github.com/LK4D4/suwayomi.koplugin/issues/30)
- [#37: Verify reduced manual deletion on a device](https://github.com/LK4D4/suwayomi.koplugin/issues/37)
