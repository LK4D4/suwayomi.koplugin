# Suwayomi Downloader for KOReader

A KOReader plugin that allows you to browse your self-hosted [Suwayomi (Tachidesk)](https://github.com/Suwayomi/Suwayomi-Server) server and download chapters directly to your e-ink device.

## Development Status

This plugin is experimental and still under active development.

- Expect rough edges and incomplete features.
- The login flow, Suwayomi hub, Library entry point, source browsing/search, global search, manga browsing, manga actions, chapter browsing, chapter actions menu, single-chapter downloads, source-scoped download paths, cached source refresh, local queue inspection, and read-state syncing are currently implemented and being tested.
- At the moment, the plugin is only considered fully verified with the Suwayomi **Local Source**. Remote source verification remains planned for Phase 8.
- The top-level Downloads screen can inspect active, queued, and failed local downloads, although completed history is not implemented yet.

## Features
- Native KOReader UI integration
- Native Suwayomi hub with Library, Browse, Downloads, Sync, Settings, and Close actions
- Library entry point with category picker behavior settings
- Browse sources, search across visible sources, search within a source, page source results, and open manga/chapter actions directly from the server
- Cached source list with silent background refresh
- Basic auth login against a self-hosted Suwayomi server
- Filter sources by language
- Browse settings for source languages, NSFW source visibility, and optionally hiding in-library source results
- Select a custom download directory
- Source-scoped download layout: `<download directory>/<source>/<manga>/<chapter>.cbz`
- Download individual chapters as `.cbz`
- Chapter actions menu with `Open`, `Download`, `Delete from device`, and `Mark as read` / `Mark as unread`
- Bulk chapter menu actions for selected chapters, `Download next 5/10/50 unread`, `Keep next 5/10/50 unread downloaded`, and deleting read chapters
- Chapter action to mark the selected chapter and all previous chapters as read, useful for setting up a clean device from an existing reading position
- Batch downloads queue chapters in the visible chapter-list order
- Queued chapter downloads run in parallel with a conservative default of 2 active chapters
- Bulk queueing is capped at 50 new downloads per action to avoid accidental huge queues
- Chapter rows show lightweight read/download status symbols, including queued and in-progress downloads
- Read-state tracking from Suwayomi, the local plugin ledger, and KOReader sidecar metadata
- Background retry of pending read/unread syncs when Suwayomi is temporarily unavailable
- Manual `Sync` action for flushing pending read/unread changes immediately

Current limitation:
- The practical, verified flow currently targets the Suwayomi **Local Source**. Other Suwayomi sources may browse and search correctly, but full remote source download/read workflow verification remains Phase 8 work.
- Full source filter editing is still deferred; source-specific search currently uses text search without dynamic source filters.
- `Downloads` currently shows KOReader-local active, queued, and failed downloads. Completed history and server-side Suwayomi download queue management are not implemented.

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
3. First time use: Tap **Settings** > **Connection** > **Login information** to enter your Suwayomi server URL, username, and password.
4. Optionally tap **Sync** to flush any pending local read/unread changes.
5. Optionally tap **Settings** > **Browse** to filter source languages, show/hide NSFW sources, or hide in-library source results.
6. Tap **Settings** > **Downloads** > **Download directory** to choose where manga will be downloaded.
7. Tap **Library** to open manga already in your Suwayomi library, or **Browse** to explore sources.
8. In **Browse**, use **Global search** or choose a source, then pick **Popular**, **Latest** when supported, or **Search**.
9. Use **Next page** and **Previous page** on source result pages when available.
10. Use the title-bar home button on Suwayomi Library/Browse/Search screens to return to the hub.
11. Tap a manga result to open manga actions, or tap a chapter to open the chapter actions dialog.
12. Use the chapter actions dialog to open, download, delete, or toggle read state for that chapter.
13. For a clean device with existing reading progress, tap the first unread chapter and use **Mark previous as read**, or tap the last read chapter and use **Mark this and previous as read**. Then use the chapter-list menu to download or keep the next unread chapters.

## Testing Locally

This plugin targets KOReader's LuaJIT runtime. Local checks use Luacheck for
repo-wide parsing/linting and Busted for unit tests:

```bash
# Confirm LuaRocks is configured for LuaJIT
luarocks config lua_interpreter

# Install test and lint dependencies via LuaJIT-backed LuaRocks
luarocks install --local busted
luarocks install --local dkjson
luarocks install --local luacheck

# Run lint, including syntax parsing for all Lua files
PATH="$HOME/.luarocks/bin:$PATH" luacheck --codes .

# Run tests
PATH="$HOME/.luarocks/bin:$PATH" busted spec
```

## Contributing

Pull requests are welcome! Please ensure any new features have accompanying unit tests in the `spec/` directory.
