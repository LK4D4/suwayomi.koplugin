# Suwayomi Client for KOReader

[![Test](https://github.com/LK4D4/suwayomi.koplugin/actions/workflows/test.yml/badge.svg)](https://github.com/LK4D4/suwayomi.koplugin/actions/workflows/test.yml)

Browse manga on your [Suwayomi](https://github.com/Suwayomi/Suwayomi-Server) server, download chapters to your device, and read them offline in KOReader. You can search sources, install extensions, and sync your read/unread state without leaving KOReader.

You'll need KOReader and a Suwayomi server that your device can reach. Downloads are local CBZ files; the plugin does not manage the server's download queue.

## Install

### KOReader App Store

1. Install the [KOReader App Store plugin](https://github.com/omer-faruq/appstore.koplugin) if you don't have it.
2. Open **Tools > App Store**, search for `suwayomi.koplugin`, and install it.
3. Restart KOReader.

### Manual installation

1. Download `suwayomi.koplugin-vX.Y.Z.zip` from the [latest release](https://github.com/LK4D4/suwayomi.koplugin/releases/latest).
2. Extract the `suwayomi.koplugin` folder into `koreader/plugins/`. Avoid nesting it inside another folder with the same name.
3. Restart KOReader.

On Android, the destination is usually `/sdcard/koreader/plugins/`; on Kobo and Kindle, use the device storage containing `koreader/`. On Linux desktop, use `~/.config/koreader/plugins/`.

To update a manual install, quit KOReader, replace the plugin folder with the new release, then relaunch. Keep your KOReader settings and downloaded chapters.

## Connect

1. Open **Search > Suwayomi** in KOReader's top menu.
2. Enter your server URL and credentials. Select **Basic Auth**, **Simple Login**, or **UI Login** to match your server, then tap **Test connection**.
3. Continue and choose a folder for downloaded chapters.

You can repeat setup from **Suwayomi > Settings > Setup wizard**.

Simple Login and UI Login reconnect automatically using saved credentials; session cookies and JWT tokens are never saved. If authentication fails during a download, correct your login settings and retry it from **Downloads**.

Use HTTPS when connecting over a network. HTTP remains supported but exposes passwords and session tokens to network observers. Suwayomi UI Login tokens can remain valid after the server password changes; changing saved credentials does not cancel already-running downloads.

## Read

1. Open **Search > Suwayomi** to enter Library, using your category-picker preference.
2. Choose a manga, open its chapter list, then tap a chapter to download or read it.
3. Use **Go to Suwayomi** from the reader to return to the chapter list.

The title-bar menu offers **Library** and **Suwayomi home**. Home provides **Browse** for source search and extensions, **Downloads** for progress/cancel/retry, **Sync** for pending read/unread changes, and **Settings**. Back from the Library root exits the plugin.

Browse manga results default to List when no view preference is saved. Existing saved choices are preserved. Tap the small menu icon at the bottom left to choose **List**, **Cover only**, or **Cover with text** (titles below the covers). Your choice is saved, and switching views keeps your place. Tap a manga to open it. Grids adapt to the screen width; paging and status messages remain full-width rows.

### Read offline

Library and chapter lists save automatically as you browse. Saved lists appear immediately while the server refreshes. Failed loads keep them available; **Refresh** or **Refresh chapters** retries. Complete server results replace saved lists, including removals and empty results, without deleting downloaded chapters or reading progress. Failed saves are reported.

If no saved list exists, recorded downloads supply available rows. A manga whose chapters were never loaded may have no saved chapter information. Recovered files with no known server connection offer **Open** and **Verify download**; server sync, downloading, and deletion remain unavailable for those rows.

Downloaded chapters open without waiting for the server. KOReader saves and resumes progress normally, and **Go to Suwayomi** works offline. CBZs also remain accessible through KOReader's file browser.

### Keep chapters ready

Use **Download next** for a one-time batch or **Auto-download** to keep the first unread chapters available. Each action adds at most 50 new chapters. The checked Auto-download choice shows the saved limit; downloaded and queued chapters count toward it. This setting does not delete other downloads.

Selecting a limit may offer **Always mark as finished**. This optional KOReader setting applies to **all KOReader documents** at their end-of-document action. **Keep disabled** leaves Auto-download active and manual read marking available. Choose **Keep disabled** with **Don't ask again** checked, or **Enable**, to stop future reminders.

Change finish marking later under **Cogwheel > Document > End of document action > Always mark as finished** in an open document. Auto-download leaves your end action and removal settings unchanged; turning it off does not disable automatic finish marking.

Downloads continue while you read. Temporary network failures retry in the background; unfinished jobs recover after a KOReader restart. Files are organized by source and manga in your download folder.

### Remove finished chapters

Under **Settings > Downloads**, **Delete after reading** keeps the chapters finished most recently in each manga, not the highest chapter numbers. **Delete when marked read** separately requests file removal when you manually mark chapters read. See **Download help** for completion rules and deletion details.

### Faster downloads with server predownloads

Predownloading remote chapters on your Suwayomi server can speed up device transfers: the plugin tries to copy a complete archive before fetching individual pages. Saving server downloads as CBZs also avoids rebuilding archives for each transfer.

Queue chapters through Suwayomi's WebUI, or configure automatic downloads for future updates. Those depend on server category and unread-chapter settings and do not automatically fill an existing backlog.

A CBZ in Suwayomi's **Local source** is not the same as a server download. Local source chapters can still transfer page by page, so a predownloaded remote chapter can be faster.

Your device still needs to connect to copy chapters. Plugin **Auto-download** and removal settings affect only device-local copies.

## Need help?

- **Plugin missing?** Check that its folder is named `suwayomi.koplugin`, then restart KOReader.
- **Can't connect?** Check that the server is running and reachable from your device, and verify your URL and credentials.
- **Source missing?** Install or update its extension from **Browse**. Check **Show NSFW sources** in Browse settings if relevant.
- **Download failed?** Open **Downloads** and tap the failed entry for details or to retry. For an archive warning, use **Verify download**; use **Redownload** if it reports damage.

Still stuck? [Open an issue](https://github.com/LK4D4/suwayomi.koplugin/issues). Include your KOReader and Suwayomi versions and what happened, but leave out credentials and private library details.

## Contributing

Bug reports, pull requests, and translations are welcome. Start with the guide for your task:

| Task | Guide |
| --- | --- |
| Develop and test | [Repository rules and commands](AGENTS.md), then [choose verification](docs/agents/testing.md) |
| Change ownership or behavior | [Architecture](docs/ARCHITECTURE.md), with links to governing decisions |
| Change authentication | [Authentication contract](docs/authentication.md) |
| Translate | [Translation guide](docs/TRANSLATING.md) |
| Inspect past verification | [Acceptance evidence](docs/evidence/README.md) |
