# Suwayomi Downloader for KOReader

[![Test](https://github.com/LK4D4/suwayomi_dl.koplugin/actions/workflows/test.yml/badge.svg)](https://github.com/LK4D4/suwayomi_dl.koplugin/actions/workflows/test.yml)

A KOReader plugin that allows you to browse your self-hosted [Suwayomi (Tachidesk)](https://github.com/Suwayomi/Suwayomi-Server) server and download chapters directly to your e-ink device.

## Development Status

This plugin is experimental and still under active development.

- Expect rough edges and incomplete features.
- The login flow, Suwayomi hub, Library entry point, source browsing/search, extension install/update/uninstall, global search, manga browsing, manga actions, chapter browsing, chapter actions menu, single-chapter downloads, source-scoped download paths, cached source refresh, local queue inspection, and read-state syncing are currently implemented and being tested.
- The practical flow has been verified on device with the Suwayomi **Local Source** and a live Comick remote-source browse/latest workflow. Remote source search still depends heavily on source/server behavior; global search is partial and cancellable, while individual source requests can still time out.
- The top-level Downloads screen can inspect active, queued, and failed local downloads, although completed history is not implemented yet.

## Features
- Native KOReader UI integration
- Native Suwayomi hub with Library, Browse, Downloads, Sync, Settings, and Close actions
- Library entry point with category picker behavior settings
- Browse sources, search across visible sources, search within a source, page source results, and open manga/chapter actions directly from the server
- Browse available Suwayomi extensions from KOReader and install, update, or uninstall extensions on the server
- Cached source list with silent background refresh
- Basic auth login against a self-hosted Suwayomi server
- Filter sources by language
- Browse title-menu settings for source languages, NSFW source visibility, and optionally hiding in-library source results
- Select a custom download directory
- Source-scoped download layout: `<download directory>/<source>/<manga>/<chapter>.cbz`, with duplicate-safe chapter suffixes when stable chapter metadata is available
- Download individual chapters as `.cbz`
- Chapter actions menu with `Open`, `Download`, `Delete from device`, and `Mark as read` / `Mark as unread`
- Bulk chapter menu actions for selected chapters, one-shot `Download next 5/10/50` commands, per-manga `Keep next 5/10/50 downloaded` auto-refill buffers, and deleting read chapters
- Downloads settings can delete local chapter files after manual mark-read actions or after finishing chapters while reading
- Chapter action to mark the selected chapter and all previous chapters as read, useful for setting up a clean device from an existing reading position
- Batch downloads queue chapters in the visible chapter-list order
- Queued chapter downloads run in parallel with a conservative default of 2 active chapters
- Bulk queueing is capped at 50 new downloads per action to avoid accidental huge queues
- Chapter rows show lightweight read/download status symbols, including queued and in-progress downloads
- Read-state tracking from Suwayomi, the local plugin ledger, and KOReader sidecar metadata
- Background retry of pending read/unread syncs when Suwayomi is temporarily unavailable
- Manual `Sync` action for flushing pending read/unread changes immediately

Current limitations:
- Remote source browse/latest workflows can be usable. Global search now keeps per-source failures isolated and can be cancelled, and source-specific result loading is cancellable, but source-specific search still depends on the selected source and may end in a timeout or source error instead of results.
- Some Suwayomi extensions mark broadly used sources, including MangaDex and Comick in the tested server setup, as NSFW. Enable **Settings** > **Browse** > **Show NSFW sources** if expected sources are missing.
- Source-specific quirks are expected. In the May 2026 live test, MangaDex search returned results quickly, but one tested result had no chapters from Suwayomi; Comick Latest returned manga and chapters, while Comick text search timed out at the server.
- Full source filter editing is still deferred; source-specific search currently uses text search without dynamic source filters.
- `Downloads` currently shows KOReader-local active, queued, and failed downloads. Completed history and server-side Suwayomi download queue management are not implemented.
- Downloaded files are KOReader-device-local CBZ files under the configured download directory. The plugin does not manage Suwayomi's server-side download queue.

## Installation

Recommended:

1. Open KOReader.
2. Go to **Tools** > **App Store**.
3. Find `LK4D4/suwayomi_dl.koplugin`.
4. Install the plugin from the App Store.
5. Restart KOReader.

Manual installation:

1. Download the latest `suwayomi_dl.koplugin.zip` from the [Releases page](../../releases).
2. Extract the zip file.
3. Copy the `suwayomi_dl.koplugin` directory to the KOReader plugins directory on your device:
   - For Android/e-readers: usually `koreader/plugins/`
   - The final path should be `koreader/plugins/suwayomi_dl.koplugin`
4. Restart KOReader.

## Usage

1. Open the **Search** tab in KOReader's top menu.
2. Tap **Suwayomi** to open the hub.
3. First time use opens **Suwayomi setup**. Enter your server URL, username, and password, tap **Test connection**, then choose the download folder used for KOReader-local CBZ files.
4. To re-run setup later, tap **Settings** > **Setup wizard**. To edit only the saved login, tap **Settings** > **Connection** > **Login information**.
5. Optionally tap **Sync** to flush any pending local read/unread changes.
6. Optionally tap **Browse**, then open the title-bar menu to filter source languages, show/hide NSFW sources, or hide in-library source results.
7. Tap **Settings** > **Downloads** > **Download directory** to change where manga will be downloaded. The same Downloads settings section also controls optional local-file deletion after mark-read or finished-reading events.
8. Tap **Library** to open manga already in your Suwayomi library, or **Browse** to explore sources.
9. In **Browse**, use **Global search** or choose a source, then pick **Popular**, **Latest** when supported, or **Search**.
10. Use **Next page** and **Previous page** on source result pages when available.
11. Use the title-bar burger menu on Suwayomi Library/Browse/Search screens to return to the hub.
12. Tap a manga result to open manga actions, or tap a chapter to open the chapter actions dialog.
13. Use the chapter actions dialog to open, download, delete, or toggle read state for that chapter.
14. Tap **Downloads** from the hub to inspect active, queued, and failed KOReader-local jobs.
14. For a clean device with existing reading progress, tap the first unread chapter and use **Mark previous as read**, or tap the last read chapter and use **Mark this and previous as read**. Then use the chapter-list menu to queue a one-shot **Download next** batch or enable a **Download ahead** buffer.

## Remote Source Notes

Remote sources must already be installed and enabled on your Suwayomi server. KOReader only sees the sources Suwayomi exposes through GraphQL and the plugin's Browse settings.

The May 2026 Boox Palma verification used a live Suwayomi server with MangaDex and Comick enabled. The strongest verified remote-source path was:

```text
Suwayomi -> Browse -> Comick (Unoriginal) (EN) -> Latest -> choose a manga -> Open chapters -> Scanlator filter -> Download -> Open
```

That flow opened duplicate scanlator choices, marked chapters read/unread, and downloaded a chapter to:

```text
<download directory>/<source label>/<manga title>/<chapter title>.cbz
```

When Suwayomi provides stable chapter metadata, the filename adds a duplicate-safe suffix before `.cbz`, such as `<chapter title> [id-398].cbz`, `<chapter title> [order-3].cbz`, or `<chapter title> [chapter-1].cbz`. This keeps same-titled chapters from colliding on disk. The downloaded CBZ opens in KOReader's normal reader. MangaDex search and library add/remove were also verified, but one tested result returned no chapters from Suwayomi. Comick text search timed out on the tested server; Comick Latest still worked.

## Unsupported / Deferred

The current client MVP intentionally does not implement:

- Full dynamic source filter editing
- Source preference editing
- Extension repository editing or source enable/disable management
- Server-side Suwayomi download queue, download settings, or completed history management
- Per-source download directory overrides
- A custom in-plugin manga reader; downloaded chapters open in KOReader's normal reader

## Testing Locally

This plugin targets KOReader's LuaJIT runtime. Local checks use Luacheck for
project Lua parsing/linting, avoiding generated dependency directories such as
`.lua` and `.luarocks`, and Busted for unit tests:

```bash
# Confirm LuaRocks is configured for LuaJIT
luarocks config lua_interpreter

# Install test and lint dependencies via LuaJIT-backed LuaRocks
luarocks install --local busted
luarocks install --local dkjson
luarocks install --local luasocket
luarocks install --local luasec
luarocks install --local luacheck

# Run project Lua parsing/linting while avoiding generated dependency directories
PATH="$HOME/.luarocks/bin:$PATH" luacheck --codes spec suwayomi main.lua _meta.lua

# Run tests
PATH="$HOME/.luarocks/bin:$PATH" busted spec
```

## Contributing

Pull requests are welcome! Please ensure any new features have accompanying unit tests in the `spec/` directory.
