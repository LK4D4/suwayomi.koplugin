# Issue #58: reader Next chapter acceptance, 2026-09-25

Implementation is complete on `codex/next-chapter-58`; physical Palma acceptance remains unverified. This record does not authorize publication or permanent device deployment.

## Candidate and environment

- Base: `865a4b6`; final runtime candidate: `bcfcb73` (including the checked ledger-path repair and foreign-endpoint Library fallback).
- Final desktop deployment recorded and byte-verified all 98 canonical payload files against the candidate worktree. No runtime fault patch was installed. Later changes to this record do not change runtime bytes.
- Desktop: WSLg, KOReader v2026.07.1, Suwayomi v2.3.2243, disposable Basic Auth server and three generated three-page CBZs. Only synthetic fixture data was used.
- UI controls used the authenticated sandbox inspector, actual reader menu widgets, and native X11 page-turn/configuration input. Page mode was chosen from a current screenshot; completion used KOReader's visible **Mark as finished** action, never an injected completion flag.

## Automated evidence

Final candidate passed `busted --lua=luajit spec`: **1,684 successes, zero failures/errors**. Full `luacheck --codes spec suwayomi main.lua _meta.lua` passed with zero findings across 173 files. `scripts/check-l10n.sh` and diff whitespace checks passed. Canonical release-payload staging passed during implementation; final sandbox deployment independently verified the 98-file allowlist and exact bytes.

WSL used distro LuaSec paths and the task's explicit Git metadata/worktree paths. Earlier focused red tests reproduced the missing menu, duplicate verification, and foreign-endpoint navigation gaps before their implementation. The scoped-path/missing-ledger repair has a checked-store regression; local-only files retain their existing authority restrictions.

The specs cover source order rather than chapter numbers, ID tie-breaking, separate releases/specials, exact saved scanlator filtering including an excluded current chapter, read-independent selection, absent/empty/mismatched saved context, stale reader/document/context/filter/candidate, duplicate pending requests, unfinished ownership, terminal failure with an archive, inspection failures/busy state, and archive replacement. Existing network/completion boundaries remain in place.

## Desktop observations

| Control | Observed result | Status |
| --- | --- | --- |
| Reader menu for a linked fixture | Fixed **Next chapter** entry appeared immediately beside **Go to Suwayomi**. | Demonstrated |
| Successor opened previously at a saved native position | Next resumed Chapter 002 at page 2 during the initial integrated run; the final candidate resumed its later saved page 3. Rendered page-2 screenshot matched the ordinary Open screenshot exactly. | Demonstrated |
| Chapter 002 missing while Chapter 003 downloaded | Next from Chapter 001 kept the reader open, named Chapter 002, and said to download it first. It did not skip or enqueue. **Stay here** kept the document open; **Go to Suwayomi** opened the chapter list. This control was repeated on the final candidate after deleting only the disposable Chapter 002 through its normal action. | Demonstrated |
| Last saved chapter | Next reported **No next chapter in saved list.**, with explicit stay/navigation choices. | Demonstrated |
| Server stopped after a complete list was saved | Next switched locally; completed successors remained eligible. Final candidate also passed after a cold offline reader start: Chapter 002 resumed at page 3 and Next rendered Chapter 003, page 1. Screenshot independently shows fixture label `00301`. | Demonstrated |
| Explicit unread choice | Plugin **Mark as unread** cleared Chapter 002's read state. Next restored its saved page 3; subsequently leaving it with Next did not mark it read. Independent server inspection confirmed unread state. | Demonstrated |
| Native finish with ordinary close/Open baseline | With Auto-download 5 and Delete after reading Keep 1, Chapter 001 was finished through the native end dialog and closed through Go to Suwayomi. Ledger/native metadata/server showed completion; its archive remained. | Demonstrated |
| Native finish followed by Next | Under the same policy, finishing Chapter 002 and invoking Next rendered Chapter 003. Native metadata retained page 3, 100%, and `complete`; server read state became true, pending sync cleared, and refill requests settled. Keep 1 removed the older completed Chapter 001 while retaining Chapter 002 and the open Chapter 003. | Demonstrated |
| Completed reread | Reopening completed Chapter 002 restored page 3. Next to Chapter 003 preserved the same read, sync, refill, and retention outcome. | Demonstrated |
| Pending duplication, changed reader identity, changed file, busy/inconclusive/damaged inspection, and endpoint fallback | Deterministic specs and targeted review cover these boundaries. They were not all injected through the desktop UI. | Automated only |

Some ordinary Open/download clicks were invalidated while the existing saved-first list refreshed. Those harness steps were re-observed and retried after the list settled; they are not counted as successful opens. Early harness filename assumptions and clicks before async reader opening were likewise corrected before recording results.

Private local evidence retains deployment hashes, framebuffer images, and redacted structured ledger/native/server observations. The ordinary and Next finish controls used the same policies but different consecutive fixture chapters; this is a focused comparison, not an exhaustive lifecycle matrix. Refill settled with the remaining unread fixture already available, so this does not demonstrate a newly transferred refill archive after Next.

## Independent review

- **Standards:** one boundary-documentation finding, repaired in the module header and architecture routing map. No remaining actionable finding.
- **Spec:** a scoped archive without a ledger path could lose native close bookkeeping; the repaired path now shares checked ordinary Open bookkeeping without changing read choices or granting unrecorded files authority. A subsequent concrete endpoint-mismatch concern found that the blocked dialog's navigation button could do nothing; its guarded fallback now opens the configured Library without passing foreign IDs. Targeted repair review found no remaining concrete defect.

## Palma and remaining limits

Read-only Windows ADB inspection found one connected, unlocked Palma with KOReader v2026.03, currently disabled and stopped, and an existing profile. No device acceptance was performed.

Automatic approval review rejected the proposed temporary full-profile isolation and staged deployment because the implementation request did not explicitly authorize that device-state change or transfer of synthetic settings. The action never executed. The original profile remains in place, app state is unchanged, no task backup/replacement profile or USB routes exist, and the task relay was stopped. Explicit user approval is pending for temporary staging, native menu checks, and exact original-profile/app-state restoration.

Physical file handling, repeated taps, notice readability, touch responsiveness, and e-ink usability therefore remain **unverified**. Desktop observations do not establish them. GitHub CI, push, merge, release, and issue closure were not performed by this implementation task.

## Cleanup and retained resources

The disposable desktop server and reader both reported stopped after final acceptance. No live task relay or device routing remains. The private sandbox root, task scratch helpers/screenshots, and clean implementation/selection worktrees remain for handoff and possible approved Palma acceptance. No personal archives, credentials, settings, raw logs, or generated CBZs are committed.
