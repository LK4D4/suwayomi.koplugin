# Suwayomi local chapter lifecycle

This context describes reading and managing chapter downloads on a KOReader device. Local download removal is distinct from Suwayomi server download state.

## Language

**Manual-delete intent**:
An outstanding request created by a plugin manual mark-read action to remove the chapter's captured local archive and cancel download work already present at that action. Its eligibility is independent of while-reading retention; it never grants authority over a later deliberate download.
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
