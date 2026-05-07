# Downloads Surface Small Slice Design

## Goal

Implement the smallest useful version of the top-level `Downloads` hub action. The screen should expose the existing KOReader-local download queue without changing the download architecture or adding Suwayomi server download behavior.

This slice should answer three questions:

- What is downloading now?
- What is queued next?
- What failed and can be retried or cleared?

Completed download history, pause/resume, and richer manga/chapter navigation remain out of scope for this slice.

## Approach

Add a narrow queue inspection API to `suwayomi_download_queue.lua` and a compact KOReader menu in `suwayomi_ui.lua`, then wire the existing `Downloads` hub action in `main.lua` to that menu.

The queue remains device-local. The implementation must not call Suwayomi server downloader mutations or treat server-side download state as KOReader-local availability.

## Queue API

Add small methods to `suwayomi_download_queue.lua`:

- `getSnapshot()` returns `{ active = {}, queued = {}, failed = {} }`.
- `retryFailed(key)` reuses the existing failed retry path by enqueueing the failed job's manga, chapter, and download directory.
- `clearFailed()` removes only failed persistent jobs and their local status entries.

Snapshot rows should preserve the metadata already stored by the queue: `key`, `state`, `manga`, `chapter`, `download_directory`, and `progress` where available. Active rows can be derived from `active_jobs`; queued rows from `items`; failed rows from persistent jobs and current statuses.

No completed history is added because completed jobs are currently removed from persistence.

## UI

Add a compact `Downloads` menu helper in `suwayomi_ui.lua`.

Rows should stay text-first and e-ink friendly:

```text
Downloading 03/24  Frieren / Ch. 144
Queued             Dandadan / Ch. 192
Failed             Chainsaw Man / Ch. 205
Clear failed
```

Failed rows should retry directly when selected. If a failed row has an error message, include a short version in the row text so the user can see the last failure without opening a second dialog.

If the snapshot is empty, the plugin should show a friendly message instead of an empty menu.

## Main Wiring

Replace the placeholder `showDownloads()` implementation with:

- Load `self:getDownloadQueue():getSnapshot()`.
- Show the downloads menu with the standard return-to-hub title-bar affordance.
- Retry failed items through the local queue and refresh the downloads menu.
- Clear failed items through the local queue and refresh or close to an empty message.

The existing Downloads settings remain under `Settings -> Downloads`; this slice does not duplicate those settings in the Downloads surface.

## Tests

Add or update unit tests for:

- Queue snapshot groups active, queued, and failed items where state exists.
- Failed rows can be retried through the local queue retry path.
- Clear failed removes failed queue records without touching queued or active work.
- The top-level `Downloads` hub action opens the new menu instead of the placeholder message.
- The menu stays local-only; no Suwayomi server downloader API helpers are involved.

## Scope Boundaries

This slice intentionally does not add:

- Completed download history.
- Server-side Suwayomi download queue inspection.
- Pause/resume controls.
- Rich open manga/chapter context from queue rows.
- New settings beyond the existing download directory and parallel download settings.
