# Suwayomi Client for KOReader

[![Test](https://github.com/LK4D4/suwayomi.koplugin/actions/workflows/test.yml/badge.svg)](https://github.com/LK4D4/suwayomi.koplugin/actions/workflows/test.yml)

Browse a self-hosted [Suwayomi](https://github.com/Suwayomi/Suwayomi-Server) server from KOReader, install or update source extensions, download manga chapters as local CBZ files, and read them with KOReader's normal reader.

This plugin is for readers who already use Suwayomi on another machine and want a comfortable e-ink workflow: choose manga on the device, keep a small local reading queue, and sync read/unread state back when possible.

## What You Need

- KOReader on your device.
- A Suwayomi server reachable from that device.
- Basic Auth credentials if your Suwayomi server uses login protection.

Sources do not have to be installed before first use. You can install and update Suwayomi source extensions from the plugin's **Browse** screen.

Downloaded chapters stay on the KOReader device. The plugin does not use or manage Suwayomi's server-side download queue.

## Installation

### Recommended: KOReader App Store

1. Install the [KOReader App Store plugin](https://github.com/omer-faruq/appstore.koplugin) if it is not already on your device.
2. In KOReader, open **Tools** > **App Store**.
3. Search for `suwayomi.koplugin` or `LK4D4/suwayomi.koplugin`.
4. Install the plugin.
5. Restart KOReader.

### Manual Install

1. Download the versioned `suwayomi.koplugin-vX.Y.Z.zip` asset from the [latest release](https://github.com/LK4D4/suwayomi.koplugin/releases/latest).
2. Extract the zip.
3. Copy the extracted `suwayomi.koplugin` folder into KOReader's plugin directory.
4. Confirm the final path is exactly one plugin folder deep. KOReader discovers the plugin from that folder name:

```text
<your-device-root>/koreader/plugins/suwayomi.koplugin/
```

On Android, `<your-device-root>` is usually `/sdcard`. On Kobo or Kindle, use the device storage root that contains `koreader/`. On Linux desktop, the full path is usually `~/.config/koreader/plugins/suwayomi.koplugin/`.

Do not leave the files in a nested path such as `koreader/plugins/suwayomi.koplugin/suwayomi.koplugin/`; KOReader will not discover the plugin there.

5. Confirm the folder contains `_meta.lua`, `main.lua`, `suwayomi/`, and compiled `l10n/` catalogs when the release includes translations.
6. Restart KOReader.

To update a manual install, replace the old `suwayomi.koplugin` folder with the new release folder, then restart KOReader.

## First Run

1. Open KOReader's top menu.
2. Go to **Search** and tap **Suwayomi**.
3. Enter your Suwayomi server URL, username, and password.
4. Tap **Test connection**.
5. Choose a download folder for local CBZ files.

You can rerun setup later from **Suwayomi** > **Settings** > **Setup wizard**. To edit only the saved login, use **Settings** > **Connection** > **Login information**.

## Daily Use

Open **Suwayomi** from KOReader's **Search** menu. The hub has the main actions:

- **Library** opens manga already in your Suwayomi library.
- **Browse** searches enabled sources, opens Popular or Latest lists where a source supports them, and installs or updates Suwayomi source extensions.
- **Downloads** shows active, queued, and failed local downloads.
- **Sync** sends pending read/unread changes to Suwayomi.
- **Settings** changes connection, library, browse, and download behavior.

Tap a manga to open actions, then open its chapters. Tap a chapter to open, download, delete the local file, or change read state. For a new device, use **Mark this and previous as read** on your current reading position, then queue a small **Download next** batch or enable a **Download ahead** buffer.

Each explicit download action adds at most **50 new downloads**. **Download all chapters (up to 50 new)** includes read and unread chapters; **Download all unread (up to 50 new)** includes only unread chapters. Both use the manga's loaded chapter list and scanlator restriction. Existing files and chapters already in the download queue do not use any of those 50 places. A saved scanlator restriction never falls back to other groups for these actions when no matching chapters are available.

The confirmation shows how many eligible chapters are captured for this batch, how many are already downloaded or in the queue, and how many eligible chapters are outside the limit. Acceptance rechecks only the captured chapters, so changes can reduce the number queued without filling the batch with different chapters. If the chapter view or filter changes, run the action again. Results report actual queued, skipped, and capped counts, with failed or unconfirmed saves reported separately. Canceled or rejected actions preserve selection.

Use another explicit action to reach the remaining eligible chapters; batches never continue automatically. **Download selected** asks for confirmation when its eligible selection exceeds 50. Small selected and next actions remain immediate. **Download next** continues to count additional eligible unread chapters; its confirmation also discloses the 50-new-download cap when applicable. The **Download ahead** buffer keeps its existing position-based behavior.

Downloads continue through FileManager–ReaderUI and reader-to-reader navigation, including when no Suwayomi screen is open. All screens share the configured parallel-download limit. Lowering the limit lets current workers finish.

Transient network failures are retried in the background with increasing delays. Retries resume after wake or KOReader restart; permanent failures remain visible under **Downloads** without interrupting reading. The home entry shows the terminal failure count when nonzero. Failed rows show a short summary; tap one to read the complete stored error with manga/chapter context in a scrollable viewer. **Retry** retries a current transfer failure, and **Close** returns to the same screen. The chapter action menu's **Download error** opens the same details.

Waiting retries show **Retry scheduled** and a fixed next retry date/time in device-local time. Tap the row and choose **Download error**, or use the chapter action menu, to inspect the last error during the running session. Queued actions still allow cancellation and opening the chapter list. **Retry** stays disabled while the automatic retry is queued. Times do not count down or cause extra screen refreshes.

Waiting retries do not reserve download slots or block new chapters. Retries whose scheduled time has arrived take priority, but use the same parallel-download limit as other work. During an outage, new chapters may therefore also attempt downloading and enter their own retry schedule.

After KOReader restarts, unfinished downloads automatically requeue with their retry counts and future retry times preserved. Existing final archives are validated before being adopted as complete. Canceled work is not requeued, and existing permanent failures keep their details. Canceling a download preserves any final archive; cleanup and replacement wait until a known stopping worker exits.

Chapters are validated before opening through the plugin, or on **Verify download**. Validation runs in the background and checks ZIP structure, complete entry reads/checksums, and the transfer's expected page count when available. There is no whole-library validation scan. **Could not verify download** means inspection was inconclusive; try **Verify download** again. Unsupported ZIP variants, including ZIP64, encrypted, and multi-volume archives, remain unverified and are not opened through the plugin. **Download damaged; redownload** offers explicit **Redownload**, which keeps the old archive until a validated replacement is ready and preserves reading metadata. Download ahead does not initiate repairs. Clearing transfer failures does not clear archive-integrity warnings.

Repair retains the existing supported archive name, including legacy names. Hash-based reading metadata is copied to document-path sidecars before replacement, with the originals retained. Conflicting metadata or failed preservation stops the repair and leaves the old archive in place.

A normal KOReader restart loads an upgrade; no device reboot or directory change is required. New workers use private temporary files and publish complete archives by atomic rename. Surviving old-process workers can duplicate transfers, temporarily exceed the current process's parallel-download limit, or publish after cancellation; an older complete attempt may replace a newer one. Workers started before this upgrade do not gain its safeguards. Unknown temporary leftovers are left alone indefinitely—no boot tracking or startup sweep. Hot reload and simultaneous writable KOReader processes remain unsupported. Validation cannot prove image content correctness or guarantee durability after abrupt device failure.

Downloaded files use this layout:

```text
<download folder>/<source>/<manga>/<chapter>.cbz
```

When Suwayomi provides stable chapter metadata, the plugin adds a suffix such as `[id-398]`, `[order-3]`, or `[chapter-1]` before `.cbz` so same-named chapters do not overwrite each other.

## Current Limits

This release focuses on KOReader-local reading. It does not edit source preferences, manage extension repositories, show completed download history, or control Suwayomi's server-side download queue. Some sources search quickly, some time out, and some expose incomplete metadata. Downloaded chapters open in KOReader's normal reader; the plugin is not a custom manga reader.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| Plugin does not appear | Folder must be named `suwayomi.koplugin`; restart KOReader after install. |
| Cannot connect | Check server URL from the device, Basic Auth credentials, and whether Suwayomi is running. |
| Source is missing | Install or update the source from **Browse**; also check **Show NSFW sources** in Browse settings. |
| Search times out | Try a source-specific Popular or Latest list, or retry with a narrower search term. |
| Chapter will not download | Wait for background network retries, then open **Downloads** to inspect, retry, or clear any failed entry. |
| Chapter reports damage or cannot be verified | Use **Verify download** to retry inspection, or **Redownload** for established damage. A generic KOReader reader error alone does not establish archive damage. |

## Development

Run commands from the plugin root:

```bash
luacheck --codes spec suwayomi main.lua _meta.lua
busted spec
```

Native archive regression checks use Linux/WSL LuaJIT and `libarchive` (`sudo apt-get install libarchive-dev` on Ubuntu). KOReader already supplies its archive library; no extra device dependency is required.

Translation catalog maintenance requires GNU gettext tools:

```bash
./scripts/update-l10n.sh
./scripts/check-l10n.sh
./scripts/compile-l10n.sh
```

See [docs/TRANSLATING.md](docs/TRANSLATING.md) for translator guidance and Weblate setup notes.

Pull requests are welcome. Please keep runtime code under `suwayomi/`, add focused specs for behavior changes, and update `docs/ARCHITECTURE.md` when module ownership or packaging boundaries change.
