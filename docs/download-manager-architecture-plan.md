# Download Manager Architecture Plan

Date: 2026-05-03

Historical note: this plan predates the slash-style `suwayomi/` module refactor and uses old top-level module names such as `suwayomi_download_queue.lua`, `suwayomi_downloader.lua`, and `suwayomi_api.lua`. The implemented architecture now lives behind `suwayomi/downloads/queue.lua`, `suwayomi/downloads/active_jobs.lua`, `suwayomi/downloads/job_store.lua`, `suwayomi/downloads/progress_file.lua`, `suwayomi/downloads/downloader.lua`, and the `suwayomi/api.lua` facade. Treat the body below as historical design context, not the active module map.

## Goal

Improve Suwayomi chapter download speed without making download behavior hard to test or unsafe on KOReader devices.

The recommended path is:

1. Introduce a testable download manager architecture around the current queue.
2. Add bounded chapter-level parallelism.
3. Keep page downloading sequential inside each chapter to preserve simple, ordered CBZ assembly.

## Current Shape

The current implementation has useful boundaries already:

- `suwayomi_download_queue.lua` owns enqueueing, persisted queue state, subprocess launch, progress polling, timeout handling, and status formatting.
- `suwayomi_downloader.lua` owns target paths, fetching chapter pages, downloading each page, validating image responses, writing CBZ files, and cleanup.
- `suwayomi_api.lua` owns the blocking GraphQL and binary HTTP calls.
- `main.lua` calls the queue from chapter actions and bulk actions.

The main speed bottlenecks are:

- only one active chapter job is allowed at a time;
- each chapter downloads pages sequentially;
- page download and archive writing happen in the same loop.

This plan addresses only the first bottleneck. That is the best return for complexity: manga downloads commonly involve several small-to-medium chapters, and running multiple chapter subprocesses in parallel gives useful throughput without complicating archive assembly.

The archive writer should stay single-writer and ordered. Each chapter worker will continue to download and write pages sequentially inside its own subprocess.

## Architecture

Keep the public plugin-facing API close to the current queue API, but split responsibilities internally.

```text
main.lua
  |
  v
DownloadManager
  |-- JobStore
  |-- StatusStore
  |-- WorkerPool
  |-- ProgressCodec
  |
  v
ChapterWorker subprocess
  |-- existing ChapterDownloader
      |-- fetch page list
      |-- download pages sequentially
      |-- write CBZ sequentially
```

### DownloadManager

Owns the public API:

- `enqueue(manga, chapter, download_directory, options)`
- `enqueueBatch(manga, chapters, download_directory, options)`
- `cancelPending(manga, chapter)`
- `recover()`
- `process()`
- `poll()`
- `getStatus(manga, chapter)`
- `formatChapterMenuText(chapter, status)`

It should preserve existing behavior for callers in `main.lua`, but internally delegate persistence, worker management, and progress parsing.

Configuration:

- `max_active_chapters`, default `2`
- `poll_interval_seconds`, default current `0.5`
- `watchdog_timeout_seconds`, default current `30 * 60`

### JobStore

Owns persistent job records and duplicate handling.

Responsibilities:

- build stable job keys;
- normalize persisted jobs;
- upsert single or batch jobs;
- remove terminal jobs;
- recover interrupted `downloading` jobs back to `queued`;
- preserve failed jobs until explicitly retried or cleared.

This makes persistence testable without starting subprocesses.

Suggested module:

- `suwayomi_download_job_store.lua`
- tests: `spec/suwayomi_download_job_store_spec.lua`

### StatusStore

Owns in-memory user-visible chapter statuses.

Responsibilities:

- set, clear, and read status by job key;
- coalesce status-change callbacks;
- keep status rendering separate from worker state.

This can initially remain inside `suwayomi_download_queue.lua`; extract only if the file keeps growing.

### WorkerPool

Owns active subprocesses and scheduling.

Responsibilities:

- maintain `active_jobs` keyed by job key instead of a single `active` field;
- start jobs until `active_count < max_active_chapters`;
- assign each active job a unique progress path;
- poll all active jobs on each timer tick;
- finish each active job independently;
- start replacement jobs as soon as a worker finishes;
- keep one scheduled poll active while there are active jobs.

This is the first real speed improvement. With `max_active_chapters = 2`, two chapters can download at the same time while each chapter still uses the proven sequential page downloader.

Suggested module:

- `suwayomi_download_worker_pool.lua`, or keep inside `suwayomi_download_queue.lua` for the first phase if extraction feels too large.
- tests: `spec/suwayomi_download_worker_pool_spec.lua` or expanded `spec/suwayomi_download_queue_spec.lua`.

### ProgressCodec

Owns progress file read/write format.

Responsibilities:

- encode progress as key-value text or JSON;
- parse partial or missing files safely;
- write progress atomically by writing to a temporary path and renaming it;
- support fields needed by multiple active jobs:
  - `state`
  - `current`
  - `total`
  - `path`
  - `error`
  - `job_key`

The current progress file is simple and good for tests, but atomic writes will avoid the parent polling a half-written file.

Suggested module:

- `suwayomi_download_progress.lua`
- tests: `spec/suwayomi_download_progress_spec.lua`

### ChapterWorker

Runs in a subprocess for one chapter job.

Responsibilities:

- call the downloader;
- write progress through `ProgressCodec`;
- never mutate parent state directly;
- return success or failure only through progress file and subprocess completion.

The worker should accept injected dependencies in tests:

- downloader;
- progress writer;
- clock if needed;

### ChapterDownloader

Keep `suwayomi_downloader.lua` focused on one chapter at a time.

Keep:

- path sanitization;
- skip existing CBZ;
- partial CBZ cleanup;
- image validation;
- ordered archive writing;
- final rename from `.part` to `.cbz`.

Avoid introducing page-fetch strategies, temporary page stores, or async page assembly. Those abstractions would be useful only if we planned page-level parallelism, and we do not need that complexity.

The downloader tests should remain centered on the current chapter-level contract:

- start a chapter download;
- step through pages sequentially;
- report progress after each page;
- cleanup partial CBZ files on failure;
- finalize only complete CBZ files.

## Approach Comparison

### Option A: Chapter-level parallelism

Pros:

- fastest safe improvement from current architecture;
- uses existing subprocess model;
- no shared CBZ writer;
- failures stay isolated per chapter;
- straightforward tests with fake process runner and fake progress files.

Cons:

- a single large chapter is still sequential internally;
- too many active chapters can stress the Suwayomi server or device storage.

Recommendation: implement with a conservative default of 2 active chapters.

### Option B: Larger sequential batches with no parallelism

Pros:

- no architecture change;
- lowest risk.

Cons:

- does not materially improve speed;
- the user still waits for one chapter to finish before another starts.

Recommendation: insufficient for the speed goal.

### Out of Scope

Page-level parallelism is intentionally excluded. The design should not introduce page-fetch strategies, page worker pools, temporary page stores, or async archive assembly.

## State Model

Use these job states:

- `queued`: persisted and waiting.
- `starting`: selected by the pool, subprocess not confirmed yet.
- `downloading`: subprocess is running and progress exists.
- `downloaded`: terminal success, removed from persistent queue.
- `skipped`: terminal success because CBZ already existed, removed from persistent queue.
- `failed`: terminal failure, persisted for retry visibility.

Optional later state:

- `cancel_requested`: only useful if active subprocess cancellation becomes available. Keep current behavior for now: pending jobs can be canceled, active jobs cannot.

## Test Strategy

The architecture should be test-first friendly. Avoid real network, real subprocess timing, and real KOReader UI in unit tests.

### JobStore tests

Cover:

- duplicate upsert by key;
- batch upsert writes once;
- failed jobs persist through recovery;
- interrupted downloading jobs become queued;
- malformed persisted entries are ignored or normalized predictably.

### ProgressCodec tests

Cover:

- writes and reads every supported field;
- missing file returns nil;
- partial file does not crash;
- failed progress includes error text;
- atomic write uses temp path then rename.

### WorkerPool tests

Use fake `ui_manager`, fake `ffi_util`, fake clock, and fake progress files.

Cover:

- starts up to `max_active_chapters`;
- does not start more when active pool is full;
- starts the next queued job when one active job completes;
- handles one success and one failure in the same poll;
- keeps failed jobs persisted;
- removes successful and skipped jobs from persistence;
- watchdog failure applies per active job;
- schedules only one next poll while active jobs remain;
- recovery requeues interrupted active jobs.

### Downloader tests

Use fake API and fake archive writer.

Cover:

- current sequential behavior remains unchanged;
- archive entries are written in page order;
- page validation rejects empty or non-image responses;
- partial CBZ files are cleaned on failure;
- finalization fails if written page count does not match expected page count.

### Plugin integration tests

In `spec/main_spec.lua`, cover:

- bulk enqueue still schedules one processing cycle;
- multiple chapters can show `downloading` status at once;
- refresh coalescing still prevents excessive chapter menu refreshes;
- duplicate and downloaded chapters are still skipped.

## Implementation Phases

### Phase 1: Extract testable infrastructure without changing behavior

- Add `ProgressCodec`.
- Add `JobStore`, or isolate equivalent methods in the queue behind a small interface.
- Update existing queue tests to use those boundaries.
- Keep one active job.

### Phase 2: Add bounded chapter-level worker pool

- Replace `self.active` with `self.active_jobs`.
- Add `max_active_chapters`.
- Change `process()` to fill available worker slots.
- Change `poll()` to poll all active jobs.
- Preserve existing public queue API.
- Keep page downloads sequential.

This should deliver the first download speed improvement.

### Phase 3: Add settings and guardrails

- Add a setting for max parallel chapter downloads.
- Default to 2.
- Clamp allowed values, for example 1 to 4.
- Keep the UI text simple and warn only if a high value is selected.

## Acceptance Criteria

- Existing tests continue to pass.
- New unit tests cover queue recovery, worker pool scheduling, progress parsing, and downloader page ordering.
- With `max_active_chapters = 2`, two chapter jobs can be active at once.
- A failure in one active chapter does not block or corrupt another active chapter.
- Successful and skipped jobs are removed from persistent queue state.
- Failed jobs remain visible and retryable.
- CBZ files are always complete, ordered, and finalized with the existing `.part` to `.cbz` rename.
- Page downloads remain sequential within each chapter worker.

## Open Decisions

1. Whether the first implementation should keep the `suwayomi_download_queue.lua` filename and public module name for compatibility, or introduce `suwayomi_download_manager.lua` and leave a thin compatibility wrapper.
2. Whether max parallel chapters should be user-configurable immediately or start as an internal constant.

## Recommendation

Implement bounded chapter-level parallelism. It matches the current subprocess design, avoids shared archive writers, and gives a meaningful speedup for bulk downloads with the least risk.

Keep the downloader sequential within each chapter. The manager architecture should make multiple active chapter jobs reliable, observable, recoverable, and easy to unit test.
