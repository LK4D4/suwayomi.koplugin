# Immediate download failure investigation

## Finding

Commit `c34b1c548c828180b92f0ffbf149a65562a390c8` (`fix(downloads): retry transient failures`) introduces a reproducible regression for chapters that are not downloaded on the Suwayomi server. The same commit removes failure dialogs without adding a way to inspect the full error in Downloads.

The plugin's local and GitHub `master` both pointed to this commit during the investigation. This report records source inspection and synthetic LuaJIT reproduction. No device logs, server credentials, library state, or live chapter downloads were accessed. The exact response from the user's server remains unverified.

## Why downloads fail before fetching pages

1. `suwayomi/api/transport.lua:210` builds `GET /api/v1/chapter/<id>/download?markAsRead=false`.
2. This endpoint exports an existing server download. In the inspected Suwayomi server source, both archive and folder providers throw `IllegalArgumentException` when the corresponding download is absent. The server maps that exception to HTTP 400.
3. `suwayomi/api/transport.lua:551` maps HTTP 400 to `{ ok = false, error = "Could not download chapter archive.", retryable = false, status_code = 400 }`. The response body is discarded.
4. Previously, an unsuccessful archive request returned `nil` from `downloadDirectChapterArchive`, allowing the plugin to fetch source pages and build a device-local CBZ.
5. `suwayomi/downloads/downloader.lua:480` now permits that fallback only for HTTP 404 or the matching not-found error string. HTTP 400 returns a terminal failure instead.
6. `suwayomi/downloads/downloader.lua:743` writes failed progress and returns before `startChapterDownload`. No page list is fetched. Because `retryable` is false, the queue does not schedule a transient retry.

This explains immediate failure across chapters that are absent from the server's download storage. It does not imply that every possible download fails: an existing server archive or an HTTP 404 response takes a different path.

### Upstream evidence

Inspected upstream revision: `7537f301c92ebea28d6f35ce992cfe440d03eb58`.

- [MangaController.downloadChapter](https://github.com/Suwayomi/Suwayomi-Server/blob/7537f301c92ebea28d6f35ce992cfe440d03eb58/server/src/main/kotlin/suwayomi/tachidesk/manga/controller/MangaController.kt) calls `ChapterDownloadHelper.getCbzForDownload`.
- [ChapterDownloadHelper](https://github.com/Suwayomi/Suwayomi-Server/blob/7537f301c92ebea28d6f35ce992cfe440d03eb58/server/src/main/kotlin/suwayomi/tachidesk/manga/impl/ChapterDownloadHelper.kt) selects the archive or folder provider and requests its archive stream.
- [ArchiveProvider.getAsArchiveStream](https://github.com/Suwayomi/Suwayomi-Server/blob/7537f301c92ebea28d6f35ce992cfe440d03eb58/server/src/main/kotlin/suwayomi/tachidesk/manga/impl/download/fileProvider/impl/ArchiveProvider.kt) throws when the CBZ is absent.
- [FolderProvider.getAsArchiveStream](https://github.com/Suwayomi/Suwayomi-Server/blob/7537f301c92ebea28d6f35ce992cfe440d03eb58/server/src/main/kotlin/suwayomi/tachidesk/manga/impl/download/fileProvider/impl/FolderProvider.kt) throws when the chapter folder is missing, invalid, or empty.
- [JavalinSetup exception handling](https://github.com/Suwayomi/Suwayomi-Server/blob/7537f301c92ebea28d6f35ce992cfe440d03eb58/server/src/main/kotlin/suwayomi/tachidesk/server/JavalinSetup.kt) maps `IllegalArgumentException` to HTTP 400.

## Reproduction and test gap

The existing focused suite passed unchanged:

```text
busted spec/suwayomi_downloader_spec.lua spec/suwayomi_downloads_active_jobs_spec.lua spec/suwayomi_api_transport_spec.lua
91 successes / 0 failures / 0 errors / 0 pending
```

For the reproduction, a temporary copy of the downloader spec changed the archive response in `falls back to page downloads when the direct archive endpoint is unavailable` to:

```lua
return {
    ok = false,
    error = "Could not download chapter archive.",
    status_code = 400,
    retryable = false,
}
```

All filesystem, archive-writer, and network stubs remained in place. The expected behavior remained a successful page download. The same case ran against the current downloader and the file extracted from `c34b1c5^`. It also ran through `downloadChapterWithProgress`, the worker entry point, with the same outcome:

| Downloader revision | Result | Page fetch called | Retryable | Test |
| --- | --- | --- | --- | --- |
| `c34b1c5` | `ok=false`, `Could not download chapter archive.` | No | No | 1 failure |
| `c34b1c5^` | `ok=true` | Yes | Not applicable | 1 success |

The existing fallback spec uses only `Chapter archive not found.`, which takes the surviving HTTP 404-compatible path. The transport spec covers HTTP 400 as non-retryable but does not connect that result to the downloader's page fallback. The focused suite therefore misses this boundary.

## Why the full error cannot be opened

- `c34b1c5` replaces `queue.onMessage(...)` with `queue:notifyDownloadFailure(...)` throughout `suwayomi/downloads/active_jobs.lua`.
- `suwayomi/downloads/queue.lua:219` only logs the failure. It does not display a dialog.
- The complete plugin error remains in `download_queue[*].progress.error`; `suwayomi/downloads/job_store.lua:97` preserves it.
- `suwayomi/ui/downloads.lua:141` places the error in the row subtitle. `suwayomi/ui/list_menu.lua:402` reserves approximately one line, and line 427 enables ellipsis.
- `suwayomi/downloads/controller.lua:127` offers only Retry and Close for failed jobs. There is no error-details action.
- Normal debug output also does not expose this text: the debug sanitizer redacts the `error` field. Separately, the original HTTP response body has already been discarded by the archive transport.

## Recommended repair scope

Restore page fallback for HTTP 400 from the optional archive export request while preserving transient retries and explicit authentication or local filesystem failures. Add a regression case that proves both successful page fallback and terminal progress through `downloadChapterWithProgress`.

Add an explicit error-details action for failed jobs that displays the complete stored error in a scrollable viewer. Preserve quiet background failure handling. Include useful HTTP status and bounded server error details in archive failures if needed for diagnosis; keep raw external data out of debug logs.

Do not enqueue Suwayomi server downloads as a workaround. The plugin must continue to download pages and build CBZ files on the KOReader device.

This investigation changes documentation only. No runtime fix is included.
