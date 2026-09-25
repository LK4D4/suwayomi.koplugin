# Issue #58: reader Next chapter acceptance, 2026-09-25

Implementation is complete on `codex/next-chapter-58`; focused desktop and physical Palma acceptance passed under the controls below. This record does not authorize publication or permanent device deployment.

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

After explicit user approval, a physical Palma running Android 11 and KOReader v2026.03 used a disposable profile and the same `bcfcb73` runtime candidate. All 98 deployed payload files were hash-verified before and after acceptance. The real Suwayomi sandbox server was reached through a USB ADB reverse route and a host relay; the authenticated inspector used a separate USB forward route. This does not establish Wi-Fi behavior.

| Control | Observed result | Status |
| --- | --- | --- |
| Native reader menu | **Next chapter** appeared immediately beside **Go to Suwayomi**. | Demonstrated |
| Download and saved-position navigation | Chapters 001 and 002 were downloaded through the UI. Chapter 002 was put into native page view, advanced to page 2, and closed through Go to Suwayomi. Opening Chapter 001 and invoking its native Next action displayed the verification notice, then rendered Chapter 002 at saved page 2; the framebuffer showed fixture label `00202`. | Demonstrated |
| Independent archive and saved-state inspection | All three PNG pages in each downloaded CBZ matched the corresponding source fixture bytes. Chapter 002's native sidecar recorded `last_page=2`, matching the rendered successor. | Demonstrated |
| Missing Chapter 003 | Next from Chapter 002 named Chapter 003 and said to download it first. **Stay here** retained Chapter 002 at page 2; **Go to Suwayomi** returned to the correct three-chapter list. | Demonstrated |
| Repeated touch input | Two taps at the Next row followed by a top touch settled on Chapter 002 at page 2 without double advance or a Chapter 003 dialog. The timing does not prove that both taps reached an active Next callback; deterministic pending-duplicate behavior remains established by specs. | Demonstrated with timing limit |
| Verification notice touch | Touching the observed verification notice allowed the transition to settle on Chapter 002 at page 2. | Demonstrated |

The inspector's initial token file had Windows line endings and was corrected to LF before acceptance; candidate plugin bytes were unchanged. Device framebuffer images establish rendered content and dialog layout. Human judgments of physical e-ink readability, ghosting, and touch responsiveness remain **unverified**. The device run did not repeat the desktop completion/retention matrix or inject every stale-state and inspection failure. GitHub CI, push, merge, release, and issue closure were not performed by this implementation task.

## Cleanup and retained resources

The original Palma profile was isolated only after all 1,217 file hashes were captured and verified. After acceptance, the original profile was restored and every hash matched. An independent second audit confirmed the same 1,217 files with zero mismatches, the original disabled/stopped app state, no USB routes, and removal of the task's backup, disposable profile, and generated download directories.

The disposable desktop server and reader both reported stopped after final acceptance. The task relay exited successfully and its listener was absent. The private sandbox root, task scratch helpers/screenshots and synthetic archive evidence, and clean implementation/selection worktrees remain for handoff. No personal archives, credentials, settings, raw logs, or generated CBZs are committed.
