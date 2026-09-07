# Issue #2: download, reader lifecycle, and cleanup investigation

## Scope and conclusion

[Issue #2](https://github.com/LK4D4/suwayomi.koplugin/issues/2) reports that Download next, Download ahead, deletion after manual mark-read, and deletion while reading do not work, plus occasional crashes during multiple downloads. It was opened on September 1, 2026, without versions, settings, a source, reproduction steps, or logs. The September 3 maintainer comment reports successful daily download-ahead use and asks about sleep, network conditions, and sources.

The complaints are credible under specific conditions. Research found **four current defects**, including a download ownership defect that could contribute to instability. A subsequent maintainer test on the device reproduced progress resetting or returning to queued when navigating back from a chapter. All downloads eventually finished, with no observed failures or app exits. This supports the lifecycle diagnosis without establishing the original reporter's crash cause. Ordinary bulk downloads and download-ahead through the plugin chapter list have working, tested paths.

The investigated revision is [`dbe4f8d171092a864ed68ef22aa116335fb497b3`](https://github.com/LK4D4/suwayomi.koplugin/commit/dbe4f8d171092a864ed68ef22aa116335fb497b3), also the live GitHub `master` during this investigation. The latest published release is [v1.0.6](https://github.com/LK4D4/suwayomi.koplugin/releases/tag/v1.0.6), released May 31 at `f715996`; current `_meta.lua` still says 1.0.6. A version label alone therefore cannot distinguish these revisions.

Read-only inspection of the test device confirmed KOReader package version `v2026.03` on Android. Installed `main.lua`, `suwayomi/downloads/downloader.lua`, and `suwayomi/chapters/read_actions.lua` match the current Git blobs. Only those three files were checked; this is not full payload validation. The maintainer opens chapters through the plugin, which explains why the working refill path is commonly exercised.

## 1. Download queues compete across reader instances

**Confirmed current defect; highest repair priority. Actual crash remains unproved.**

Each plugin instance creates its own queue, and every initialization calls recovery. KOReader creates plugin instances for its reader and file manager. The previous queue's scheduled polling callbacks can remain alive after a reader transition. Meanwhile, the new queue treats persisted `downloading` jobs as interrupted, removes their partial/progress files, and starts replacements. Multiple queues then operate on the same jobs and paths.

Evidence: [queue ownership and callbacks](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/main.lua#L60-L107), [unconditional recovery](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/main.lua#L229-L242), [interrupted-file removal and recovery](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/downloads/queue.lua#L428-L577), and [retained polling closure](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/downloads/active_jobs.lua#L76-L86). KOReader v2026.03 [creates reader plugins](https://github.com/koreader/koreader/blob/v2026.03/frontend/apps/reader/readerui.lua#L430-L445), [instantiates each plugin](https://github.com/koreader/koreader/blob/v2026.03/frontend/pluginloader.lua#L293-L300), and [finalizes by clearing its instance list](https://github.com/koreader/koreader/blob/v2026.03/frontend/pluginloader.lua#L327-L330).

A temporary probe composed the real queue, scheduler, and persistence modules with mocked subprocesses and file removal. Three queue instances sharing three persisted jobs, with concurrency set to two, produced **six mocked live workers**. Recovery called file removal on earlier active workers' partial/progress paths. Duplicate workers shared those paths. This architecture also exists in release `f715996`.

The probe demonstrates duplicate scheduling, destructive recovery calls against active jobs, and a concurrency limit enforced only within each queue. Competing writes and failed archive publication remain possible runtime consequences without device confirmation. Additional resource pressure is a plausible crash contributor, not a diagnosis. A failed worker also does not necessarily mean the KOReader process crashed: [active-job polling](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/downloads/active_jobs.lua#L541-L574) handles child completion without terminal progress as a download failure.

**Device follow-up, September 6 (maintainer-reported):** returning from a chapter to Suwayomi consistently reset one download's displayed progress to zero or moved it back to queued. No failed downloads or app exits were observed, and all downloads eventually completed. This confirms the navigation-linked progress symptom and strongly supports the recovery diagnosis. No worker-count or file trace was provided, so this observation alone does not prove duplicate workers on the device, how much transfer work was repeated, or an exclusive cause. Eventual completion does not make navigation-triggered resets correct. The repair must preserve each active download's worker and attempt across reader transitions; navigation alone must not reset or requeue it.

**Proposed repair:** establish one process-wide download service, with lifecycle-aware UI subscribers. Recover interrupted jobs once after a genuine process restart. Give workers explicit ownership of their files. Add a composed FileManager–ReaderUI–FileManager regression that checks worker count, files, persisted jobs, and displayed state together. Local entry points: [main.lua](../../../main.lua), [queue.lua](../../../suwayomi/downloads/queue.lua).

## 2. Stored chapter retrieval stops at 200

**Confirmed current defect affecting both next-download and ahead selection.**

The [stored query requests `first = 200`](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/api/queries.lua#L299-L315). The [parser discards `totalCount`](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/api/parsers.lua#L753-L779), and [any nonempty stored result is accepted](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/api.lua#L579-L602), without retrieving another page. Both download selectors inspect only the loaded chapter context.

The synthetic transport returned 200 read chapters while advertising 205 total chapters, with five unread chapters beyond the returned page. Real API/query/parser/selection functions made **one request, loaded 200 chapters, and found zero next-download or ahead candidates**. Supplying the full 205-chapter source response produced five candidates for each action. These are the first 200 returned records, not necessarily chronological chapters 1–200: the query does not specify a sort direction.

This explains a long-series failure that a short-series test misses. Explicit source refresh can temporarily provide the full list; ordinary reopening can return to the truncated stored list. The cap predates v1.0.6.

**Proposed repair:** paginate stored chapter retrieval to completion, retain total-count information, and preserve deterministic order. Test unread chapters beyond the first page and the ordinary-reopen versus source-refresh paths. Local entry points: [queries.lua](../../../suwayomi/api/queries.lua), [parsers.lua](../../../suwayomi/api/parsers.lua), [API facade](../../../suwayomi/api.lua).

## 3. Finishing a document does not itself refill Download ahead

**Confirmed current trigger gap; explains workflow-dependent results.**

[Document close](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/readsync/controller.lua#L276-L300) calls [`markLedgerEntryRead`](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/readsync/ledger.lua#L182-L201). That method updates read state and schedules synchronization, but never applies the ahead policy. A probe with an already loaded chapter context confirmed **read ledger updated, chapter marked read, one synchronization scheduled, zero refills**.

Refill happens when [the plugin displays returned/loaded chapters](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/manga/controller.lua#L334-L371), through manual mark-read, or through downloaded-ledger reconciliation when it discovers a new read transition in the current manga. The policy [requires current chapter context](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/downloads/controller.lua#L448-L476). Continuing through KOReader's next-file workflow does not display the plugin chapter list; the buffer can drain until the user returns to that list.

Commit [`8676a68`](https://github.com/LK4D4/suwayomi.koplugin/commit/8676a68) repaired refill after returning to the chapter list and includes a composed regression for that route. It is already in v1.0.6. It does not cover continuous reader transitions.

**Proposed repair:** record per-manga refill work when completion becomes durable and process it after document teardown. Reload chapter context when necessary. Integrate this with the shared download service rather than keeping work on a retiring reader instance. Preserve offline/restart retry intent. Local entry points: [read-sync controller](../../../suwayomi/readsync/controller.lua), [download controller](../../../suwayomi/downloads/controller.lua).

## 4. Manual mark-read can silently abandon a failed deletion

**Confirmed current defect; explicit deletion intent needs independent recovery.**

When deletion after manual mark-read is enabled, [immediate deletion suppresses active/missing/failure messages](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/chapters/delete_actions.lua#L124-L144). The public mark-read operation still succeeds. Its fallback completion is governed by the separate while-reading setting: [recording is disabled when that setting is off](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/chapters/finished_cleanup.lua#L206-L208), and [retention keeps the newest setting-minus-one completions](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/chapters/finished_cleanup.lua#L479-L489).

Two temporary tests extended the existing public-action fixture with simulated deletion failure:

- Manual deletion enabled, while-reading off: mark-read returned success without a message, journal record, or retry timer. Removing the failure and recreating the plugin did not delete the archive; its path and Downloaded state remained.
- Manual deletion enabled, while-reading set to three: the failed deletion acquired a completion record, but retention kept it. Processing after the failure cleared did not delete it or schedule another retry.

Both passed as reproductions. The existing [manual cleanup suite](../../../spec/manual_read_completion_spec.lua) covers retry with while-reading set to one, where retention does not expose this distinction.

**Approved repair, amended September 7:** persist accepted archive-only manual deletion independently of finish retention, with checked read/request persistence before removal. Owning queued/running/stopping/finalizing work makes deletion busy/not accepted and remains intact; request deletion again after work finishes. Bind accepted intent to the exact original archive/root, protect live readers and replacements, preserve all metadata, and report marked-read/removed/pending/busy/blocked through chapter status and immediate summaries. Local entry points: [delete actions](../../../suwayomi/chapters/delete_actions.lua), [read actions](../../../suwayomi/chapters/read_actions.lua), [finished cleanup](../../../suwayomi/chapters/finished_cleanup.lua).

## 5. Working semantics and previous repairs matter

The original while-reading implementation could fail across reader instances: [release code](https://github.com/LK4D4/suwayomi.koplugin/blob/f715996/suwayomi/chapters/delete_actions.lua#L170-L219) selected a previous loaded-list position and silently stopped when the required context was absent. It attempted deletion inline during document close.

Current code uses durable completion records and deferred cleanup. The main repair chain includes [`7d9ed43`](https://github.com/LK4D4/suwayomi.koplugin/commit/7d9ed43) for the journal, [`00e98a9`](https://github.com/LK4D4/suwayomi.koplugin/commit/00e98a9) and [`bed5c45`](https://github.com/LK4D4/suwayomi.koplugin/commit/bed5c45) for lifecycle recovery, [`dc1928b`](https://github.com/LK4D4/suwayomi.koplugin/commit/dc1928b) for retention/filesystem retries, and [`b461665`](https://github.com/LK4D4/suwayomi.koplugin/commit/b461665) for stale download indicators. No general current failure of while-reading cleanup was reproduced.

The settings and labels still permit misunderstandings:

- **Download next N** queues N additional eligible unread chapters. **Download ahead N** fills missing downloads among the earliest N unread chapters; downloaded/queued chapters consume buffer positions. Neither uses the current reader page as its starting point.
- Both use the loaded list and saved scanlator filter. “All chapters” still queues at most **50 new downloads** per action, despite an all-N confirmation; the cap is only explained afterward. See [selection](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/chapters/context.lua#L454-L500), [buffer selection](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/downloads/controller.lua#L365-L381), and [batch cap](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/chapters/actions.lua#L141-L171).
- Manual deletion applies to the plugin's mark-read action. Reader completion requires a completed document status and close, not merely reaching 100%. Values 1–5 retain 0–4 newest completions per manga. Plugin manual completions also count. Previously read/server-synced chapters are not retroactively enrolled. See [completion status](https://github.com/LK4D4/suwayomi.koplugin/blob/dbe4f8d171092a864ed68ef22aa116335fb497b3/suwayomi/readsync/koreader_metadata.lua#L322-L330) and [completion tests](../../../spec/manual_read_completion_spec.lua).

Download failures also received separate repairs: [`c34b1c5`](https://github.com/LK4D4/suwayomi.koplugin/commit/c34b1c5) adds durable transient retries; [`c9e0666`](https://github.com/LK4D4/suwayomi.koplugin/commit/c9e0666) restores HTTP 400/404 archive-to-page fallback and error inspection; [`71daead`](https://github.com/LK4D4/suwayomi.koplugin/commit/71daead) improves terminal rows. The HTTP 400 regression in the [earlier audit](2026-09-06-download-failure-regression.md) was introduced on September 4, after this issue opened, and subsequently repaired. It cannot explain the original report and is not a current finding.

## Focused device tests and remaining evidence

The initial investigation used read-only device inspection and synthetic probes. The maintainer subsequently performed the navigation test and reported the result recorded in section 1; the remaining device controls are unverified. No runtime fix was applied. The unchanged full suite passed under LuaJIT: **1,084 successes, zero failures, errors, or pending tests**, in 9.25 seconds. Temporary probes used real runtime boundaries with simulated network, storage, and subprocess behavior; they do not establish physical filesystem or Android timing behavior.

Run these controls with a small test manga and known settings:

1. **Queue ownership:** queue 8–10 missing chapters at concurrency two and stay on Downloads. Repeat with another batch while opening an already downloaded chapter through the plugin, returning, and opening another. Record chapter-download worker count and progress around each transition. The expected invariant is at most two active chapter-download workers across the process; thumbnail/search/read-sync workers have separate limits. Duplicate chapter workers establish the ownership failure; reset/missing progress is a symptom to correlate with worker activity. Repeat at concurrency one if needed.
2. **Ahead trigger:** with at least six eligible unread chapters, enable ahead five and wait for five downloads. Finish the first and return through plugin chapters: the sixth should queue. Repeat from equivalent state using KOReader Open next file without visiting plugin chapters: the current code is expected not to refill. Confirm completed status and the same scanlator filter in both runs.
3. **Long series:** use a manga with more than 200 stored chapters and unread chapters beyond the returned page. Compare displayed chapter count and next/ahead candidates after ordinary reopening versus explicit Refresh chapters. No downloads are needed to establish the truncated-list condition.
4. **Cleanup controls:** with manual deletion enabled and while-reading off, mark a downloaded test chapter read through the plugin; under reduced #12, only the verified archive should disappear after checked acceptance, with matching chapter status; all sidecars, backups, and other metadata remain and are explained. Include busy downloads requiring another action, live-reader waits, transient retries, restart, and replacement downloads. Separately, use while-reading three and manual deletion off; finish and close A, B, then C from the same manga, restarting between B and C. A should disappear after C; B and C should remain. For while-reading one, explicitly mark finished while still open: retain the live archive, then remove it after close. Merely reaching the final page without completed status is a negative control. Do not deliberately damage device storage to reproduce the synthetic deletion-failure case.

For an actual crash, record its timestamp and whether KOReader vanished/restarted or only a download row failed. Preserve the relevant crash/logcat interval and download error details, with source represented consistently by an alias. Record batch size, concurrency, free storage, Wi-Fi/sleep transitions, and whether navigation occurred. Remove credentials, server URLs, local paths, and manga/chapter titles before sharing logs. This evidence can distinguish a Lua error, child failure, native signal, or Android process kill; source inspection alone cannot.

Repair order: **shared download ownership first**, then **independent manual-delete retries**, **complete chapter retrieval**, and **durable completion-triggered refills**. Clarify the buffer trigger, retention meaning, and 50-download cap alongside those changes. Keep device validation focused on the contrasting workflows above.

## Planning disposition, September 6 (manual and ownership scope amended September 7)

Every finding, preserved behavior, and remaining evidence obligation above now has a specification and implementation/acceptance ticket. These are planning outcomes, not runtime fixes or new device results; the investigation evidence and unresolved crash conclusion remain unchanged.

| Audit scope | Specification | Tickets |
| --- | --- | --- |
| §1: navigation-safe ownership | Revised [#3](https://github.com/LK4D4/suwayomi.koplugin/issues/3), ADR-0002 | #4 complete; #5 is the single implementation and #11 device acceptance. #6–#10 superseded/not planned. |
| §2: complete stored chapters | [#21](https://github.com/LK4D4/suwayomi.koplugin/issues/21) | #24–#25; device comparison in #31 |
| §3: completion-triggered refill | [#22](https://github.com/LK4D4/suwayomi.koplugin/issues/22), ADR-0004 | #26–#28; device comparison in #31 |
| §4: durable manual deletion | [#12](https://github.com/LK4D4/suwayomi.koplugin/issues/12), ADR-0003 and ADR-0001 amendment | [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36) and [#37: Verify reduced manual deletion on a device](https://github.com/LK4D4/suwayomi.koplugin/issues/37) supersede #13–#20 |
| §5: batch cap, selection, and retention explanations | [#23](https://github.com/LK4D4/suwayomi.koplugin/issues/23) | #29–#30, preserving retention policy with required coordination owned by [#36: Implement durable archive-only deletion after manual mark-read](https://github.com/LK4D4/suwayomi.koplugin/issues/36) |
| Previous repairs, remaining device controls, provenance, and unproved crash | [#23](https://github.com/LK4D4/suwayomi.koplugin/issues/23) | #31, composing prior acceptance and retaining explicit unresolved/unverified outcomes |

The [complete publication map](../plans/2026-09-06-remaining-issue-2-tickets.md) records the original eight new implementation tickets, 13 verified native blocking links, and every new specification story, with subsequent dependency corrections. Pagination can begin immediately; cap disclosure is independent of pagination but waits for checked admission (#4); refill waits for existing ownership/manual-delete foundations. Already repaired failures receive regression obligations rather than duplicate repair tickets. The original GitHub report remains open. The September 7 revisions update manual-deletion and navigation routing; original investigation evidence remains historical and unchanged. See the [manual-deletion replacement map](../plans/2026-09-06-durable-manual-delete-tickets.md) and [revised ownership map](../plans/2026-09-06-navigation-safe-download-ownership-tickets.md) for current scope and dependencies.
