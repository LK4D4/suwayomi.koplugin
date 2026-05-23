# Stability And Recovery Golden-Flow QA

Use this checklist before large parity work and before release candidates. Keep entries factual and short. Redact server URLs, source names tied to private libraries, manga titles, chapter titles, credentials, local paths, and screenshots that expose user data.

## Environment

- [ ] KOReader device or emulator:
- [ ] Suwayomi server version:
- [ ] Plugin commit:
- [ ] Network condition: normal / slow / disconnected / reconnected
- [ ] Notes file contains no credentials, tokens, local paths, or private library names.

## Setup And Connection

- [ ] Open Suwayomi from KOReader menu.
- [ ] Complete first-run setup with valid server settings.
- [ ] Run connection test and confirm success message.
- [ ] Change server settings to an unreachable endpoint, run connection test, and confirm timeout or failure message names the connection action.
- [ ] Restore valid server settings and confirm Browse or Library can load again.

## Library Flow

- [ ] Open Library.
- [ ] Switch category when categories are present.
- [ ] Open a manga from Library.
- [ ] Refresh chapters.
- [ ] Close chapter screen with the title-bar close action.
- [ ] Reopen Library and confirm no stale chapter screen or loading result reopens.
- [ ] While Library is loading, close the plugin stack and confirm no Library result screen appears later.

## Browse And Extensions

- [ ] Open Browse with cached sources.
- [ ] Trigger source cache refresh.
- [ ] Install an extension and confirm extension list refresh plus source cache refresh result.
- [ ] Update an extension when an update is available.
- [ ] Uninstall an extension and confirm focus stays in the extension list.
- [ ] Search extensions and repeat one install or uninstall while search remains active.
- [ ] Close Browse during source loading and confirm no stale source list appears later.

## Source Search And Filters

- [ ] Open a source.
- [ ] Run source search.
- [ ] Open source filters, change one filter, and run filtered search.
- [ ] Trigger Popular and Latest for a source that supports them.
- [ ] Trigger Popular or Latest for a source that does not support the mode and confirm unsupported-flow message is specific.
- [ ] Simulate timeout or disconnected network during source search and confirm retry/edit actions are visible.
- [ ] Page through source results until chapter-count workers start and confirm stale count rows do not update after changing pages.

## Downloads And Queue Recovery

- [ ] Enqueue one chapter.
- [ ] Confirm active progress appears.
- [ ] Cancel queued download.
- [ ] Cancel active download and confirm no failed job is left for the canceled chapter.
- [ ] Enqueue a chapter, force a network failure, and confirm failed state appears.
- [ ] Retry failed download and confirm status updates.
- [ ] Clear failed downloads.
- [ ] Start a download, close KOReader or restart plugin before completion, reopen plugin, and confirm queue recovery leaves a queued/failed/recovered state instead of wedging.
- [ ] Confirm recovered archive opens when a completed CBZ exists on disk.

## Reader Return And Stack Close

- [ ] Open a downloaded CBZ from a chapter row.
- [ ] Use Suwayomi reader-return shortcut to return to the originating chapter list.
- [ ] Close the chapter list.
- [ ] Close the full plugin stack from title menu.
- [ ] Confirm no stale reader-return request reopens a chapter list after close.

## Read Sync

- [ ] Mark one chapter read.
- [ ] Mark one chapter unread.
- [ ] Trigger manual read sync.
- [ ] Disconnect network, mark a chapter read, trigger sync, and confirm pending retry remains.
- [ ] Reconnect network and confirm retry clears the pending sync state.
- [ ] Close a document and confirm document-close sync does not block KOReader.

## Pre-Release Local Gates

Run from repository root:

```bash
rtk luacheck --codes spec suwayomi main.lua _meta.lua
rtk busted spec
rtk git diff --check
bash .github/scripts/stage-release-payload.sh
```

Expected:

- Luacheck succeeds with no warnings.
- Busted suite succeeds.
- Diff check succeeds.
- Release payload contains only `_meta.lua`, `main.lua`, `README.md`, and `suwayomi/`.
- Remove generated `suwayomi.koplugin/` after staging before committing.

## Device QA Notes

Record only non-sensitive facts:

- [ ] Behavior that specs cannot cover:
- [ ] Device-only issue found:
- [ ] Follow-up issue or commit:
