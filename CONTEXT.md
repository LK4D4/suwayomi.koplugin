# Suwayomi local chapter lifecycle

This context describes reading and managing chapter downloads on a KOReader device. Local download removal is distinct from Suwayomi server download state.

## Language

**Manual-delete intent**:
An accepted request from a plugin manual mark-read action to remove only the chapter's captured local archive, preserving metadata; download work owning the chapter prevents acceptance. Its lifetime is independent of finish retention, and its authority never transfers to a replacement archive.
_Avoid_: Finished-chapter record, retention candidate.

**Archive generation**:
A particular published or explicitly adopted local chapter archive. A later publication is a different generation even when its chapter, pathname, and contents are identical.
_Avoid_: Chapter ID, archive path, content hash when referring to archive identity.

**Download-ahead buffer**:
The earliest configured number of unread chapters for a manga after its saved scanlator filter, in source order. Existing downloaded or queued chapters occupy positions in this buffer.
_Avoid_: Next N additional downloads, chapters after the current reader page.

**Refill request**:
Outstanding work to reevaluate a manga's Download-ahead buffer using current reading and download choices. Repeated triggers can refer to the same outstanding evaluation; they do not reserve additional chapters.
_Avoid_: Download job, reserved batch.

**Download job**:
An accepted request to obtain a chapter archive on the KOReader device. A job may require multiple download attempts before completion.
_Avoid_: Download attempt when referring to the continuing request.

**Download attempt**:
One execution of a download job that tries to produce a complete local chapter archive. Attempts for the same chapter can overlap without being the same attempt.
_Avoid_: Download job, archive generation.

**Damaged download**:
A local chapter archive that fails an integrity check, such as archive structure, entry checksums, or a known expected page count. Passing those checks does not establish that its content is correct.
_Avoid_: Reader error when no archive damage has been established.
