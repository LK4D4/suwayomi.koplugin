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
2. Enter your server URL and, if required, your Basic Auth username and password. Tap **Test connection**.
3. Continue and choose a folder for downloaded chapters.

You can repeat setup from **Suwayomi > Settings > Setup wizard**.

## Read

- **Library** opens manga in your Suwayomi library.
- **Browse** lets you search sources, explore Popular or Latest lists, and install or update source extensions.
- **Downloads** shows progress and lets you cancel or retry downloads.
- **Sync** sends pending read/unread changes to your server.

Choose a manga, open its chapters, then tap a chapter to download or read it. Use **Download next** for a batch, or **Download ahead** to keep a small reading buffer. Each download action adds at most 50 new chapters.

Downloads continue while you read. Network failures retry in the background, and unfinished downloads resume after a KOReader restart. Files are organized by source and manga in your chosen download folder.

## Need help?

- **Plugin missing?** Check that its folder is named `suwayomi.koplugin`, then restart KOReader.
- **Can't connect?** Check that the server is running and reachable from your device, and verify your URL and credentials.
- **Source missing?** Install or update its extension from **Browse**. Check **Show NSFW sources** in Browse settings if relevant.
- **Download failed?** Open **Downloads** and tap the failed entry for details or to retry. For an archive warning, use **Verify download**; use **Redownload** if it reports damage.

Still stuck? [Open an issue](https://github.com/LK4D4/suwayomi.koplugin/issues). Include your KOReader and Suwayomi versions and what happened, but leave out credentials and private library details.

## Contributing

Bug reports, pull requests, and translations are welcome. See the [architecture guide](docs/ARCHITECTURE.md) for development details and the [translation guide](docs/TRANSLATING.md) to help with your language.
