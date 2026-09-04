# Delete While Reading Reliability Design

## Goal

Make automatic local chapter deletion reliable across KOReader document transitions and restarts.

When the setting is **Third to last read chapter**, the plugin keeps the two most recently finished chapters for each manga. Finishing another chapter makes every older finished chapter eligible for deletion. Unread or skipped chapters do not count toward this retention window.

Deletion does not need to happen before the next document opens. Once a chapter becomes eligible, the plugin must preserve the deletion intent until one of these terminal conditions occurs:

- The local archive and managed sidecars are deleted.
- The archive is already absent.
- The user marks the chapter unread.
- The user disables delete-while-reading, which cancels all pending automatic cleanup.

Transient failures retry automatically. A safety rejection pauses automatic retries but keeps the intent visible and recoverable.

## Current Failure

`suwayomi/readsync/controller.lua` currently calls delete-while-reading once from `onCloseDocument()`. Offset selection in `suwayomi/chapters/delete_actions.lua` depends on `current_chapter_context.chapters`.

KOReader creates separate plugin instances for FileManager and ReaderUI and creates another ReaderUI instance when switching documents. The reader-side instance therefore normally has no in-memory chapter list. Without that list, the current implementation supports only offset `1`; offsets `2` through `5` return no candidate and silently stop.

The current path also has no durable retry state. Active downloads, transient filesystem failures, missing context, or interruption during shutdown permanently lose the cleanup attempt.

## User-Facing Semantics

The existing values remain:

- `0`: Disabled.
- `1`: Delete each finished chapter after its document closes.
- `2`: Keep the most recently finished chapter.
- `3`: Keep the two most recently finished chapters.
- `4`: Keep the three most recently finished chapters.
- `5`: Keep the four most recently finished chapters.

The retention order is completion order, not source-list position. A finished chapter receives a monotonically increasing local sequence number. Finishing an already-finished chapter again moves it to the newest position for that manga. This treats a reread as recent activity.

Unread chapters never enter the finished sequence. Marking a recorded chapter unread removes its automatic cleanup intent and its place in the retention sequence. Skipped unread gaps do not affect candidate selection.

Changing the setting applies immediately to retained journal entries:

- Decreasing the value makes additional old entries eligible.
- Increasing the value protects more entries from future deletion but cannot restore files already deleted.
- Setting the value to `0` clears the journal and cancels scheduled automatic cleanup.
- Re-enabling starts a new completion history.

Manual **Delete after manual mark-read** behavior remains separate and unchanged.

## Architecture

Add `suwayomi/chapters/finished_cleanup.lua` as the owner of finished-chapter retention, durable cleanup state, candidate selection, and retries. The module exposes plugin-bound methods through the existing controller composition pattern.

Keep responsibilities separated:

- `suwayomi/readsync/controller.lua` detects a finished document, updates read state, and records a finished-chapter event. It does not select or delete an offset candidate.
- `suwayomi/chapters/finished_cleanup.lua` owns journal normalization, retention ordering, eligibility checks, retry scheduling, and terminal-state handling.
- `suwayomi/chapters/delete_actions.lua` remains the device-delete boundary. It removes the archive and managed KOReader sidecars, updates the ledger, and clears queue status.
- `suwayomi/settings.lua` persists and normalizes the journal.
- `main.lua` composes the new controller and starts recovery during plugin initialization.

Update `docs/ARCHITECTURE.md` when implementing this boundary.

## Persistent Journal

Store a versioned journal in KOReader plugin settings under a dedicated key such as `finished_chapter_cleanup`.

Conceptual shape:

```lua
{
    version = 1,
    next_sequence = 17,
    mangas = {
        ["manga-id"] = {
            records = {
                {
                    chapter_id = "chapter-id",
                    path = "/managed/path/chapter.cbz",
                    sequence = 14,
                    retry_count = 0,
                    retry_after = 0,
                },
            },
        },
    },
}
```

Persist only fields required for cleanup. Do not store manga titles, chapter titles, source names, credentials, or server URLs.

Normalize all loaded data before use:

- Preserve an unknown journal version unchanged, pause processing, and expose a non-sensitive compatibility error. Never overwrite unknown-version data with an empty journal.
- Require non-empty manga ID, chapter ID, and path strings.
- Require finite non-negative numeric sequence, retry count, and retry time values.
- Deduplicate records by manga ID and chapter ID, keeping the newest valid sequence.
- Do not discard otherwise valid records because the journal is large. Bound work per processing pass, continue remaining work later, and report abnormal size through redacted diagnostics.
- Advance `next_sequence` above every accepted record sequence.

The journal keeps the newest `N - 1` finished records even when their files are already missing. These entries still define the retention window. Missing entries are removed only after they age beyond the retained window and become deletion candidates.

## Data Flow

### Recording completion

On `CloseDocument`:

1. Read the current document path and KOReader finished status.
2. Find the matching ledger entry by exact path.
3. Mark the ledger entry read and schedule existing server read-sync behavior.
4. If delete-while-reading is enabled and the ledger path is valid, upsert a journal record.
5. Assign a new sequence and flush the journal before returning from the event.
6. Do not delete the current document from this callback.

The durable write occurs before KOReader tears down the reader instance. A crash or shutdown after this write cannot lose cleanup intent.

### Processing cleanup

Process due journal work from these triggers:

- Plugin initialization in ReaderUI or FileManager.
- Return to Suwayomi after reading.
- Download queue transition from active or queued to idle.
- A bounded retry timer while the plugin instance remains active.
- A settings change that enables cleanup, reduces the retention value, or changes the download directory.

Only one processor runs per plugin instance. Every run reloads the journal before selecting work and saves each terminal state before continuing.

For each manga:

1. Sort valid records by sequence, oldest first.
2. Keep the newest `setting - 1` records.
3. Treat every older record as a deletion candidate.
4. Revalidate each candidate immediately before deletion.
5. Process candidates oldest first so repeated failures cannot reorder retention.

Processing must not require a network request or `current_chapter_context`. Server availability and chapter-list sorting therefore cannot block local cleanup.

### Revalidation

Before deletion, require all of these conditions:

- Delete-while-reading remains enabled.
- The ledger still identifies the chapter as read.
- The journal path matches the ledger path when both exist.
- The resolved path remains inside the configured plugin-managed download directory.
- The path is not the document currently open in ReaderUI.
- No queued or active download owns the chapter.

An unread chapter is a cancellation: remove its journal record without deleting anything. A path outside the managed download directory is a permanent safety rejection: retain the record for visibility, do not retry automatically, and never pass the path to filesystem deletion.

### Successful and missing deletion

Use the existing device-delete boundary so archive removal, sidecar removal, ledger cleanup, and queue cleanup remain consistent with manual deletion.

A successful deletion removes the candidate record from the journal. An archive already absent is also successful convergence; remove the candidate record and clear a stale ledger path when safe.

Deleting one candidate must not remove newer retained records.

## Retry Policy

Treat active downloads and filesystem failures as transient.

- Keep the candidate in the journal.
- Increment `retry_count` and persist `retry_after`.
- Use bounded exponential backoff, starting at 5 seconds and capped at 5 minutes.
- Reset retry metadata after a deferred condition changes; remove the record after successful convergence.
- Resume due retries after plugin restart.
- Do not impose a retry-count limit.

The processor stops its current pass after a transient failure for one manga. This avoids repeatedly attacking the same path and preserves oldest-first ordering. Other manga may continue processing.

Permanent safety rejection does not use the retry timer. The entry remains visible until the path becomes valid, the chapter becomes unread, cleanup is disabled, or the user removes the file manually.

## Failure Visibility and Privacy

Automatic cleanup must not fail silently.

- Show at most one summary notification per processing pass when newly reportable files remain pending, such as `Automatic chapter cleanup will retry 2 files.`
- Show a distinct summary for permanent safety rejections.
- Do not show raw paths, manga titles, chapter titles, or source names.
- Route diagnostics through `suwayomi/debug.lua` redaction helpers.
- Record only non-sensitive counts, retry state, reason codes, and redacted identifiers.
- Avoid success notifications during normal reading.

Repeated timer retries must not create repeated notifications in one plugin session. Notify again only when the failure reason changes or the pending count increases.

## Concurrency and Crash Safety

Journal updates run on KOReader's UI event loop and use read-modify-write-flush operations. A per-instance processing flag prevents reentrant processing from queue callbacks and retry timers.

Persist these transitions before starting later work:

- New completion record.
- Retry metadata update.
- Successful candidate removal.
- Unread cancellation.
- Journal clear after disabling cleanup.

Deletion is idempotent. If KOReader stops after removing a file but before removing its journal record, the next processor observes the missing file and completes cleanup safely.

## Test Strategy

Add focused specs for the new module and update integration boundaries.

### Finished cleanup module

- Values `1` through `5` retain exactly `0` through `4` most recently finished chapters.
- Third-to-last ignores unread gaps and deletes only older finished entries.
- Finishing the same chapter again moves it to the newest position without creating a duplicate.
- Manga histories remain independent.
- Decreasing and increasing retention behave as specified.
- Disabling cleanup clears journal state and cancels retry work.
- Marking a recorded chapter unread cancels deletion.
- Current document and active downloads defer deletion.
- Missing files converge successfully.
- Filesystem failure persists retry state and obeys bounded backoff.
- Restart recovery resumes due work.
- Successful retry removes only the completed candidate.
- Managed-path rejection never calls deletion.
- Unknown journal versions remain unchanged and stop processing with a compatibility error.
- Corrupt journal data normalizes safely, while oversized valid data remains intact and processes in bounded batches.

### Reader lifecycle

- `onCloseDocument()` records completion using a fresh reader plugin instance with no chapter context.
- Completion is flushed before the close callback returns.
- The next ReaderUI or FileManager plugin instance processes the prior document after it closes.
- Native **Open next file** follows the same path.
- Returning to Suwayomi triggers processing but does not duplicate records.
- Existing read-sync scheduling still occurs when automatic deletion is disabled or deferred.

### Existing delete boundary

- Journal processing uses ledger paths and removes the archive plus managed sidecars.
- Active, missing, failed, and successful delete states map to the correct journal transitions.
- Manual deletion and manual mark-read deletion retain their existing behavior.

No test may require a live Suwayomi server, KOReader installation, or local manga library.

## Migration

No migration is required for existing settings. Absence of the new journal key means an empty journal.

Existing users keep their configured delete-while-reading value. Cleanup begins with finished events recorded after the new version starts; the plugin does not infer historical completion order or retroactively delete older files.

## Out of Scope

- Server-side chapter deletion or Suwayomi download mutations.
- Reconstructing completion history from existing KOReader metadata.
- Restoring files deleted before a retention setting increase.
- Changing manual mark-read deletion semantics.
- Adding network calls to the document-close path.
- Deleting files outside plugin-managed download paths.

## Acceptance Criteria

- The reported flow works with a fresh reader plugin instance: finish a chapter, choose **Open next file**, then return to Suwayomi.
- With **Third to last read chapter**, two most recently finished chapters remain and every older finished download is eventually removed.
- Unread or skipped chapters do not count toward retention and are never deleted by this feature.
- Transient deletion failures survive document switches and application restarts until they succeed.
- Disabling cleanup cancels pending automatic deletion.
- Automatic cleanup never deletes the currently open document or any path outside the configured plugin-managed download directory.
- Failures remain visible without exposing user data.
