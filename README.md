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

To update a manual install, replace the plugin folder with the new release and restart KOReader.

## Connect

1. Open **Search > Suwayomi** in KOReader's top menu.
2. Enter your server URL and credentials. Select **Basic Auth**, **Simple Login**, or **UI Login** to match your server, then tap **Test connection**.
3. Continue and choose a folder for downloaded chapters.

You can repeat setup from **Suwayomi > Settings > Setup wizard**.

Simple Login and UI Login reconnect automatically using saved credentials; session cookies and JWT tokens are never saved. UI Login refreshes rejected access tokens silently and logs in again if the refresh token is rejected. If authentication fails during a download, correct your login settings and retry it from **Downloads**.

Use HTTPS when connecting over a network. HTTP remains supported but exposes passwords and session tokens to network observers. Suwayomi UI Login tokens can remain valid after the server password changes; changing saved credentials does not cancel already-running downloads.

## Read

- **Library** opens manga in your Suwayomi library.
- **Browse** lets you search sources, explore Popular or Latest lists, and install or update source extensions.
- **Downloads** shows progress and lets you cancel or retry downloads.
- **Sync** sends pending read/unread changes to your server.

Choose a manga, open its chapters, then tap a chapter to download or read it. Use **Download next** for a batch, or **Download ahead** to keep a small reading buffer. Each download action adds at most 50 new chapters.

The **Download ahead** menu shows **Off** or the saved buffer size for that manga. A checkmark identifies the current choice.

Selecting a Download-ahead buffer may offer KOReader's **Always mark as finished** setting. This optional setting applies to **all KOReader documents** at their end-of-document action. Download ahead also works with manual read marking. **Keep disabled** leaves Download ahead active; check **Don't ask again** to stop reminders. **Enable** also stops future reminders.

To change automatic finish marking later, open a document and use **Cogwheel > Document > End of document action > Always mark as finished**. The plugin leaves your end action and automatic removal settings unchanged; finished chapters remain subject to those removal settings. Stopping Download ahead does not turn automatic finish marking off.

Downloads continue while you read. Network failures retry in the background, and unfinished downloads resume after a KOReader restart. Files are organized by source and manga in your chosen download folder.

### Faster downloads with server predownloads

Downloading chapters on your Suwayomi server first can make transfers to KOReader much faster, especially for remote sources. The plugin automatically tries to copy a complete archive instead of fetching pages one at a time and building a CBZ on your device. Saving server downloads as CBZ files also avoids rebuilding the archive on the server for each transfer.

Use Suwayomi's WebUI to queue chapters in advance, or configure its automatic downloads for future chapter updates. The server can do the slow source fetching while your device is asleep or off. Automatic downloads depend on your server's category and unread-chapter settings; they do not automatically fill an existing backlog.

A CBZ in Suwayomi's **Local source** is not the same as a server download. Local source chapters can still transfer page by page, so a predownloaded remote chapter can be faster.

Your device still needs to connect to copy chapters for offline reading. The plugin does not queue or delete server downloads; its **Download ahead** and removal settings affect only device-local copies.

## Need help?

- **Plugin missing?** Check that its folder is named `suwayomi.koplugin`, then restart KOReader.
- **Can't connect?** Check that the server is running and reachable from your device, and verify your URL and credentials.
- **Source missing?** Install or update its extension from **Browse**. Check **Show NSFW sources** in Browse settings if relevant.
- **Download failed?** Open **Downloads** and tap the failed entry for details or to retry. For an archive warning, use **Verify download**; use **Redownload** if it reports damage.

Still stuck? [Open an issue](https://github.com/LK4D4/suwayomi.koplugin/issues). Include your KOReader and Suwayomi versions and what happened, but leave out credentials and private library details.

## Contributing

Bug reports, pull requests, and translations are welcome. See the [architecture guide](docs/ARCHITECTURE.md) for development details and the [translation guide](docs/TRANSLATING.md) to help with your language.
