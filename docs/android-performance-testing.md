# Android performance testing

This document records the repeatable Android checks for Suwayomi Downloader UI stalls.

## Setup

1. Start an Android emulator and wait for `adb devices` to show `device`.
2. Install KOReader from the official GitHub release APK that matches the emulator ABI.
   - The API 36 emulator in this test accepted `koreader-android-arm64-v2026.03.apk`.
   - GitHub release SHA256 used: `aa8c1f8330a2bddd65b8725dbb8dd9f86c6485eae4bfe17dc1160a31641a3ba8`.
3. Install the plugin:

```powershell
adb shell mkdir -p /sdcard/koreader/plugins/suwayomi_dl.koplugin
adb push . /sdcard/koreader/plugins/suwayomi_dl.koplugin/
```

When pushing from a git checkout, stage a clean temporary directory containing only the plugin runtime files, not `.git`, `spec`, or CI files.

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

1. Open KOReader.
2. Open the top menu, then the Search tab.
3. Open Suwayomi.
4. Browse Suwayomi.
5. Select Local source.
6. Select a manga with many chapters, e.g. Sousou no Frieren.
7. Open the chapter list.
8. Long-press/select about 70 chapters.
9. Open the chapter-list menu and run Mark selected as read.
10. Stay on the chapter list for at least two minutes and collect `SuwayomiDL` timing logs while pending read syncs run.
11. Repeat with Mark selected as unread.
12. Queue a large batch download, then collect queue/process/poll logs.

## Known weak spots from the first investigation

- `browseSuwayomi`, `showMangaForSource`, and `showChaptersForManga` perform synchronous GraphQL requests on the UI path.
- `schedulePendingReadSync` runs `syncPendingReadMarks` from `UIManager:scheduleIn`; that function performs synchronous `markChapterRead` / `markChapterUnread` HTTP mutations on the UI scheduler.
- With the current batch size of 2, one scheduled read-sync tick can block for the combined latency of two Suwayomi mutations.
- Against the provided Suwayomi test instance, 10 sequential read-state mutations took 16.6 to 22.5 seconds total in direct GraphQL probing, with single requests ranging roughly 0.6 to 4.5 seconds.
- A 70-chapter local batch creates about 35 scheduled sync batches, so the user-visible symptom is expected to be repeated multi-second stalls after the immediate mark action.
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
- `syncPendingReadMarks`
- `downloadQueue.enqueueBatch`
- `downloadQueue.process`
- `downloadQueue.poll`
- `fetchSources`, `fetchMangaForSource`, `queryChaptersForManga`, `markChapterRead`, `markChapterUnread`
- `downloadBinary`
