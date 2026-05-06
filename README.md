# Suwayomi Downloader for KOReader

A KOReader plugin that allows you to browse your self-hosted [Suwayomi (Tachidesk)](https://github.com/Suwayomi/Suwayomi-Server) server and download chapters directly to your e-ink device.

## Development Status

This plugin is experimental and still under active development.

- Expect rough edges and incomplete features.
- The login flow, Suwayomi hub, Library entry point, source browsing, manga browsing, chapter browsing, chapter actions menu, single-chapter downloads, source-scoped download paths, cached source refresh, and read-state syncing are currently implemented and being tested.
- At the moment, the plugin is only considered usable with the Suwayomi **Local Source**.
- The top-level Downloads screen is not implemented yet, although the local download queue and chapter-level bulk actions exist.

## Features
- Native KOReader UI integration
- Native Suwayomi hub with Library, Browse, Downloads, Sync, Settings, and Close actions
- Library entry point with category picker behavior settings
- Browse sources, manga, and chapters directly from the server
- Cached source list with silent background refresh
- Basic auth login against a self-hosted Suwayomi server
- Filter sources by language
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
- The practical, tested flow currently targets the Suwayomi **Local Source**. Other Suwayomi sources may browse correctly, but downloading and reading workflows outside Local Source are not yet considered supported.
- `Downloads` is currently a placeholder hub action. Queue inspection and retry/clear actions are the next planned surface.

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
5. Optionally tap **Settings** > **Browse** > **Source languages** to filter the source list.
6. Tap **Settings** > **Downloads** > **Download directory** to choose where manga will be downloaded.
7. Tap **Library** to open manga already in your Suwayomi library, or **Browse** to explore sources.
8. Use the title-bar home button on Suwayomi Library/Browse screens to return to the hub.
9. Tap a chapter to open the chapter actions dialog.
10. Use the chapter actions dialog to open, download, delete, or toggle read state for that chapter.
11. For a clean device with existing reading progress, tap the first unread chapter and use **Mark previous as read**, or tap the last read chapter and use **Mark this and previous as read**. Then use the chapter-list menu to download or keep the next unread chapters.

## Testing Locally

This plugin uses Busted for unit testing. To run tests locally:

```bash
# Install busted via luarocks
luarocks install busted

# Run tests
busted spec/
```

## Contributing

Pull requests are welcome! Please ensure any new features have accompanying unit tests in the `spec/` directory.
