# Android performance testing

This document records the repeatable Android checks for Suwayomi Downloader UI stalls.

## Setup

1. Start an Android emulator and wait for `adb devices` to show `device`.
2. Install KOReader from the official GitHub release APK that matches the emulator ABI.
   - The API 36 emulator in this test accepted `koreader-android-arm64-v2026.03.apk`.
   - GitHub release SHA256 used: `aa8c1f8330a2bddd65b8725dbb8dd9f86c6485eae4bfe17dc1160a31641a3ba8`.
3. Install the plugin:

```powershell
$stage = Join-Path $env:TEMP "suwayomi_dl.koplugin"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item _meta.lua, main.lua, README.md $stage
Copy-Item suwayomi $stage -Recurse

adb shell mkdir -p /sdcard/koreader/plugins/suwayomi_dl.koplugin
adb push "$stage/." /sdcard/koreader/plugins/suwayomi_dl.koplugin/
```

The staged directory contains only plugin runtime files: `_meta.lua`, `main.lua`,
`README.md`, and `suwayomi/`.

4. Optional test settings can be pushed to `/sdcard/koreader/settings/suwayomi_dl.lua`:

```lua
return {
    ["credentials"] = {
        ["server_url"] = "https://example.invalid/",
        ["username"] = "user",
        ["password"] = "password",
        ["auth_method"] = "basic_auth",
    },
    ["download_directory"] = "/storage/emulated/0/Books/Manga",
    ["source_languages"] = { "en" },
    ["max_parallel_chapter_downloads"] = 2,
}
```

## Capturing evidence

Debug instrumentation is off by default, including in release installs. Enable it for a QA run by pushing
`/sdcard/koreader/settings/suwayomi_dl_debug.lua` before launching KOReader:

```powershell
$debugConfig = "$env:TEMP\suwayomi_dl_debug.lua"
@'
return {
    enabled = true,
    log_to_file = true,
    log_to_koreader_log = true,
    slow_threshold_ms = 0,
}
'@ | Set-Content -NoNewline -Encoding ASCII $debugConfig
adb push $debugConfig /sdcard/koreader/settings/suwayomi_dl_debug.lua
```

`slow_threshold_ms` filters timing events below the configured duration. Use `0` for full traces, or a value
like `250` to keep only slower operations. The debug config is read at plugin startup, so restart KOReader
after changing it.

Disable QA instrumentation and remove captured logs with:

```powershell
adb shell rm -f /sdcard/koreader/settings/suwayomi_dl_debug.lua
adb shell rm -f /sdcard/koreader/settings/suwayomi_debug.log
```

Clear logs before each focused flow:

```powershell
adb logcat -c
adb shell rm -f /sdcard/koreader/settings/suwayomi_debug.log
adb shell am start -n org.koreader.launcher/.MainActivity
```

Capture KOReader/plugin logs:

```powershell
adb logcat -d | rg "SuwayomiDL|KOReader|ANR"
adb shell cat /sdcard/koreader/settings/suwayomi_debug.log
```

Capture a screenshot after each step:

```powershell
adb exec-out screencap -p > step-name.png
```

For quick frame evidence around a flow:

```powershell
adb shell dumpsys gfxinfo org.koreader.launcher reset
# perform one focused flow
adb shell dumpsys gfxinfo org.koreader.launcher > gfxinfo-flow.txt
adb shell dumpsys gfxinfo org.koreader.launcher framestats > gfxinfo-flow-framestats.txt
```

## Focused flows

### Local source stress flow

1. Open KOReader.
2. Open the top menu, then the Search tab.
3. Open Suwayomi.
4. Browse Suwayomi.
5. Select Local source.
6. Select a manga with many chapters from the test server.
7. Open the chapter list.
8. Long-press/select about 70 chapters.
9. Open the chapter-list menu and run Mark selected as read.
10. Stay on the chapter list for at least two minutes and collect `SuwayomiDL` timing logs while pending read syncs run.
11. Repeat with Mark selected as unread.
12. Queue a large batch download, then collect queue/process/poll logs.

### Remote source release flow

This flow records the May 2026 Phase 8 device verification shape. It uses
sources that are already installed and enabled on the Suwayomi server.

1. Open KOReader.
2. Open the top menu, then the Search tab.
3. Open Suwayomi.
4. Open **Settings** > **Browse** and enable **Show NSFW sources** if MangaDex or Comick are missing. The tested Suwayomi server marks those extensions as NSFW.
5. Return to the Suwayomi hub and open **Browse**.
6. Confirm the source list includes **Local source**, **MangaDex (EN)**, and **Comick (Unoriginal) (EN)**.
7. Open **MangaDex (EN)** > **Search**, use a query that testers know should return results on the configured server, and confirm results load. In the May 2026 run, the tested query returned multiple results in about 0.7 seconds through the plugin.
8. Open a MangaDex result and confirm library add/remove updates the row marker. One tested result returned `No chapters found` from Suwayomi for refresh/chapter listing.
9. Open **Comick (Unoriginal) (EN)** > **Latest**.
10. Open a manga from the Latest results that has multiple chapters.
11. Open the chapter-list menu and confirm **Scanlator filter** shows duplicate translation groups when the source returns them.
12. Filter to one scanlator, mark a chapter read, then mark it unread again.
13. Download one chapter and confirm the final file lands under the source-scoped path:

```text
/sdcard/Books/Manga/<source label>/<manga title>/<chapter title>.cbz
```

14. Use the chapter action **Open** and confirm KOReader opens the downloaded CBZ in the normal reader.

Direct GraphQL probing against the same Suwayomi server is useful when a live source looks suspicious. In the May 2026 run, direct probing confirmed:

- MangaDex text search returned multiple results quickly.
- Comick text search returned HTTP 504 after about 60 seconds for the tested query.
- Comick Latest returned 54 results over 4 pages.
- A manga selected from Comick Latest returned chapters with duplicate scanlator groups.
- One MangaDex search result returned `No chapters found` for chapter fetch, matching the device behavior.

## Known weak spots from the first investigation

- Browse source fetching now uses `source_fetch_worker`; keep validating cache-hit, silent-refresh, timeout, cancellation, stale-credential, and immediate-result behavior on Android.
- Source-specific manga pages use `source_manga_worker`, and chapter loading uses `network/request_job`/`request_worker`; keep validating worker startup, polling, timeout, stale-result ignore, and loading-message cleanup.
- Global search is now partial and cancellable; keep validating that slow-source failures stay isolated.
- Pending read sync now starts a subprocess worker from `schedulePendingReadSync`; verify that worker startup, polling, timeout, and retry handling remain non-blocking on Android.
- Against the provided Suwayomi test instance, 10 sequential read-state mutations took 16.6 to 22.5 seconds total in direct GraphQL probing, with single requests ranging roughly 0.6 to 4.5 seconds.
- A 70-chapter local batch is still useful as a stress case because it exercises the read-sync worker, result polling, and retry scheduling.
- `buildChapterMenuItems` does synchronous file checks for every visible chapter and may read or write KOReader sidecar metadata for downloaded chapters during full menu refreshes.
- Batch delete performs synchronous `os.remove` and metadata cleanup for each selected/read downloaded chapter.

## Instrumentation

When `/sdcard/koreader/settings/suwayomi_dl_debug.lua` sets `enabled = true`, the plugin emits redacted timing
events with the prefix `SuwayomiDL`. Without that file, instrumentation call sites are no-ops.

Important operations:

- `browseSuwayomi`
- `showMangaForSource`
- `showChaptersForManga`
- `buildChapterMenuItems`
- `refreshChapterMenu`
- `markSelectedChaptersRead`
- `markSelectedChaptersUnread`
- `schedulePendingReadSync`
- `downloadQueue.enqueueBatch`
- `downloadQueue.process`
- `downloadQueue.poll`
- `fetchSources`, `fetchMangaForSource`, `queryChaptersForManga`, `markChapterRead`, `markChapterUnread`, `markChaptersReadState`
- `downloadBinary`
