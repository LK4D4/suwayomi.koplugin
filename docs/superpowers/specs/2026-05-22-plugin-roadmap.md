# Suwayomi KOReader Plugin Roadmap

## Purpose

This roadmap keeps the plugin focused on its strongest role: a KOReader-first
client for a self-hosted Suwayomi server. The plugin should make e-ink reading
comfortable, keep local CBZ downloads reliable, and sync useful read state back
to Suwayomi without trying to become a full WebUI replacement.

The roadmap is intentionally ordered. Stability work comes before broad feature
parity because most future features will reuse the same async request, navigation,
download, and settings boundaries.

## Product Principles

- Keep KOReader as the reader. Do not rebuild WebUI reader modes, page scaling,
  themes, or keybindings inside the plugin.
- Prefer device-local CBZ downloads for offline reading. Treat Suwayomi server
  downloads as a separate system unless a future feature has a clear UX split.
- Add WebUI parity where it improves KOReader workflows: source setup, library
  organization, chapter state, and browse triage.
- Avoid hidden side effects. Actions that change server state should be explicit
  and visible in the current menu or dialog.
- Keep device constraints first: slow screens, weak CPUs, flaky network, limited
  storage, and modal-vs-screen clarity matter more than WebUI density.

## Current Baseline

The plugin already supports the core e-ink loop:

- first-run connection setup
- Library browsing
- source browse/search with source extension install/update/uninstall
- source filters
- manga actions and chapter lists
- KOReader-local CBZ downloads with retry/cancel/failure state
- read/unread sync through local ledger and KOReader metadata/history helpers
- reader-return routing back to the originating Suwayomi chapter list
- grouped settings and setup wizard

The current README names these missing areas:

- persistent source preferences, distinct from per-search source filters
- extension repository management
- completed download history
- Suwayomi server-side download queue control

## Priority 1: Stability And Recovery

Goal: make the existing plugin hard to wedge before adding larger parity work.

Candidate work:

- Add a manual golden-flow QA checklist for:
  - setup and connection test
  - Library load, category switch, manga open, chapter refresh
  - Browse source list refresh, extension install/update/uninstall, source cache
    refresh
  - source search, source filters, Popular/Latest unsupported flows, timeout and
    retry paths
  - enqueue, active progress, cancel, retry failed, clear failed, KOReader reopen
    after queue recovery
  - open downloaded CBZ, return to chapter list, close plugin stack
  - mark read/unread, sync, sync retry after failure
- Review stale async result handling across source manga, global search, library,
  manga actions, reader return, read sync, source fetch, extension mutations, and
  thumbnail workers.
- Add tests for any stale-result or route-close gaps found by the audit.
- Make timeout messages more action-aware where a generic failure leaves the user
  with no useful next step.
- Keep release payload smoke check in the normal pre-release path.

Success criteria:

- No known route-close, focus-reset, stale-worker, or queue-recovery regressions
  in the golden flows.
- Local gates remain `rtk luacheck --codes spec suwayomi main.lua _meta.lua`,
  `rtk busted spec`, `rtk git diff --check`, and release payload staging.
- Device QA notes identify any behavior that cannot be fully covered by specs.

## Priority 2: WebUI Parity Matrix

Goal: choose parity work deliberately instead of copying WebUI surface area.

Create and maintain a matrix with these columns:

- WebUI or Server capability
- Current plugin support
- KOReader value
- API feasibility
- device risk
- recommended priority
- notes or evidence

Initial high-value rows:

| Capability | Plugin status | KOReader value | Priority |
| --- | --- | --- | --- |
| Persistent source preferences | Missing; per-search source filters already exist | High: many sources need server-side settings | High |
| Extension repositories | Missing | High: sources may require custom repos | High |
| Completed download history | Missing | High: helps storage cleanup and retry confidence | High |
| Save source searches | Missing | Medium-high: good for repeated e-ink browsing | High |
| Hide in-library manga while browsing | Missing | Medium-high: reduces noise on slow screens | High |
| Duplicate warning when adding manga | Missing | Medium-high: prevents library clutter | High |
| Category change management | Library category browsing supported; changing manga categories missing | Medium: useful for library organization | Medium |
| Chapter bookmarks | Missing | Medium: common Suwayomi/WebUI chapter state | Medium |
| Library latest updates | Missing | Medium: useful but may be noisy on e-ink | Medium |
| Tracking integrations | Missing | Medium for some users, high API and UX scope | Later |
| Manga migration | Missing | Medium, but risky and uncommon on device | Later |
| Server-side download queue | Missing by design | Low-medium; conflicts with local CBZ model | Later |
| WebUI reader modes/settings | Not applicable | Low; KOReader owns reading | No |

Sources to re-check before implementing any row:

- Suwayomi-WebUI README feature list
- Suwayomi-WebUI release notes for recent parity changes
- Suwayomi-Server README feature list
- Suwayomi-Server wiki pages for extension repositories and server settings
- Current server GraphQL schema or generated client code, if available

## Priority 3: Source Setup Parity

Goal: make Browse useful on a fresh or changed Suwayomi server.

Candidate work:

- Add extension repository list viewing.
- Add, edit, and remove extension repository URLs if the server API supports it.
- Add persistent source preferences viewer/editor for source-specific settings.
  Keep this distinct from existing per-search source filters, which are already
  supported in source search.
- Keep dangerous or unclear settings behind confirmation dialogs.
- Show source setup problems in Browse without dumping raw server config text.

Risks:

- Source preference schemas may be dynamic and inconsistent.
- Extension repo changes can affect all sources, so validation and confirmation
  matter.
- Some server settings may require restart or source cache refresh.

Suggested first slice:

- Read-only extension repository and source preference display, plus clear
  "managed in WebUI/server settings" fallback when mutation support is absent.

## Priority 4: Browse Triage UX

Goal: reduce repeated taps and noisy results in source browsing.

Candidate work:

- Saved source searches per source.
- Toggle to hide manga already in library while browsing source results.
- Duplicate warning before adding manga to library.
- Quick library add/remove from browse action menu, not long-press-only.
- Better search-empty vs filter-empty messaging where current schema or query
  state matters.

Risks:

- Source browse already has async paging, filter drafts, chapter-count workers,
  and thumbnail workers. New filters must not restart stale jobs incorrectly.
- Duplicate checks can be expensive if done eagerly.

Suggested first slice:

- Saved searches stored in plugin settings and surfaced from source search menu.
  No server mutation required.

## Priority 5: Download Visibility And Storage

Goal: make local downloads easier to trust and clean up.

Candidate work:

- Completed downloads/history view based on local queue records and, later,
  source-scoped filesystem scans under the plugin-managed download directory.
- Storage summary by source/manga when cheap to compute.
- Bulk cleanup for completed/read chapters, with clear confirmation.
- Better distinction between queued, active, failed, completed, deleted, and
  remote-only states in chapter rows.

Risks:

- Filesystem scans can be slow on some devices and must stay inside the
  plugin-managed source-scoped layout built by `suwayomi/paths.lua`.
- Paths and titles are user data; debug output must stay redacted.
- Cleanup must never delete outside plugin-managed download paths.

Suggested first slice:

- Downloads hub "Completed" section from known queue/download records only,
  before adding broad filesystem scanning.

## Priority 6: Library Organization

Goal: improve library maintenance without making KOReader feel like desktop WebUI.

Candidate work:

- Change categories for one manga.
- Bulk category actions only after single-manga category UX is stable.
- Library filters for unread, downloaded, bookmarked, tracked, or duplicate
  chapter states where API support is clear.
- Latest updates view if it can be compact and timeout-safe.

Risks:

- Bulk action UI can become awkward on e-ink.
- Some filters may need extra fields or heavier requests.

Suggested first slice:

- Single-manga category picker from manga action menu.

## Priority 7: Chapter State Parity

Goal: support small chapter-level state that helps reading flow.

Candidate work:

- Bookmark/unbookmark chapter.
- Filter/sort chapter list improvements if current source/order handling leaves
  real user friction.
- Open chapter source URL only if KOReader/device browser behavior is sane and
  privacy expectations are clear.

Risks:

- Bookmark state must stay distinct from read state, local download state, and
  KOReader metadata-derived read detection.

Suggested first slice:

- Bookmark action and visible bookmark marker in chapter rows.

## Later Or Explicit-Request Work

These are valid features, but should not lead near-term work:

- Server-side download queue control.
- Tracking provider setup and updates.
- Manga migration.
- Backup/restore management.
- OPDS administration.
- WebUI reader settings, themes, keybinds, and web-reader behavior.

## Proposed Roadmap Order

1. Stability audit and golden-flow checklist.
2. WebUI parity matrix with current API feasibility notes.
3. Saved source searches.
4. Extension repository and source preference discovery.
5. Completed downloads/history view.
6. Hide in-library browse results and duplicate add warning.
7. Single-manga category picker.
8. Chapter bookmark support.

## Verification Strategy

Roadmap-only changes require diff review. Runtime work should follow existing
project gates:

```bash
rtk luacheck --codes spec suwayomi main.lua _meta.lua
rtk busted spec
rtk git diff --check
bash .github/scripts/stage-release-payload.sh
```

Before merging or pushing `master`, run GitHub Actions `Test` against the work
branch, then rerun local gates on the merged tree.
