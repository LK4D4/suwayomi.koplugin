# Source Manga Continuous Scroll Design

## Goal

Make source manga Browse, Latest, and Search results feel like one continuous list instead of exposing Suwayomi API pages as rows inside KOReader's own paged menu.

## Problem

Current source manga results use two different page concepts at once:

- Suwayomi API pages, loaded through `fetchSourceManga`.
- KOReader menu pages, calculated from the loaded rows by `Menu`.

The plugin renders `Next page` and `Previous page` rows for the Suwayomi API page. On devices this feels broken: a result set may span three KOReader pages, the final row says `Next page`, and tapping it replaces the list with the next API page while KOReader's local page counter starts again at page 1.

Suwayomi WebUI avoids this by presenting source results as an endless scroll. KOReader cannot clone that UI exactly, but it can match the behavior: keep one growing result list and load more results when the user reaches the end.

## External Plugin Patterns

Zlibrary uses a KOReader menu with remote pagination hidden behind local menu navigation. Its search dialog tracks `current_page_loaded` and `has_more_api_results`, appends fetched batches to the same `books` table, and triggers the next remote fetch when `onGotoPage` reaches the last local menu page.

Webbrowser keeps search pagination as `has_more` and offset state, appending more result rows into the same menu state instead of replacing the user's current list.

Rakuyomi presents manga search results as one flat KOReader menu. It does not expose remote page rows to the user.

These patterns point to one rule for this plugin: source/API pagination should be internal state, while KOReader menu pages should be the only visible pagination.

## Recommended Design

Replace explicit `Next page` and `Previous page` source rows with a growing source result session.

When a user opens source Popular, Latest, or Search:

1. Fetch API page 1 through the existing source manga worker.
2. Render loaded manga rows in the normal `ListMenu`.
3. Store browse session state on the client or menu state:
   - source record
   - browse type and query
   - loaded API page count
   - whether the source has more pages
   - accumulated raw manga rows
   - active load token
   - loading/error state for the next API page
4. When KOReader menu navigation lands on the last local page and the session still has `has_next_page`, start loading the next API page.
5. While loading, append a non-selectable `Loading more...` row at the bottom and keep all already loaded manga visible.
6. When the worker returns, append new manga rows to the existing session, remove the loading row, update the same menu, and keep the user's current item/page stable.
7. If the next-page load fails, keep loaded manga visible and replace the loading row with a selectable `Retry loading more` row plus a short failure line.

The result: user pages through KOReader pages normally. When they reach the end, more source results appear in the same list. No visible "remote page 2" screen, no reset to KOReader page 1.

## User Experience Details

Screen titles should stop emphasizing API pages. Use:

- `Popular`
- `Latest`
- `Search: <query>`

The full title-bar menu detail can still include the source name, for example `MangaDex (EN) - Search: frieren`, but should not show `Page 1` / `Page 2`.

If the first API page has no manga and no next page, show the existing empty state: `This source has no manga.`

If a later API page returns no visible manga because `hide_in_library_results` filtered everything but `has_next_page` is still true, continue auto-loading until one of these happens:

- visible rows are appended,
- source reports no next page,
- load fails.

To avoid runaway loops on a source that returns many filtered pages, cap chained auto-loads to a small number per user navigation event, then show a selectable `Load more` row. Recommended cap: 3 API pages.

## Architecture

Keep the worker boundary unchanged. `suwayomi/browse/source_manga_worker.lua` should still fetch one API page and return `{ manga, has_next_page }`.

Change `suwayomi/client/source_manga.lua` from page replacement to session append:

- Build initial session state before page 1 load.
- Render results from accumulated session rows.
- Add a next-page load path that reuses `startSourceMangaLoad` semantics but marks the load as an append instead of a full-screen replacement.
- Preserve active-load token checks so stale worker results cannot append into a newer source/search session.
- Cancel any active append load when menu closes or a different source/search starts.

Add a small callback hook to `suwayomi/ui/list_menu.lua`:

- `on_page_changed(menu, new_page)` or `on_last_page(menu)` called after KOReader page changes and `updateItems()` has recalculated visible rows.
- The source manga flow supplies this callback to trigger append loading.

Prefer the generic `on_page_changed` shape if it is easy to wire; it may help future library/search flows. Keep it optional so existing menus do not change behavior.

## Data Flow

Initial flow:

```text
showMangaForSource
  -> create session
  -> source_manga_worker fetch page 1
  -> render accumulated rows into ListMenu
```

Append flow:

```text
ListMenu page changes to last local page
  -> source_manga session sees has_next_page
  -> source_manga_worker fetch page N + 1
  -> append rows
  -> update same ListMenu
```

Failure flow:

```text
append worker fails or times out
  -> keep accumulated rows
  -> show bottom retry row
  -> retry row starts same append request again
```

## Error Handling

First-page failures should keep current behavior: loading menu becomes a failure status, with search-specific retry and edit actions.

Append failures should not replace the whole menu. They should keep all successfully loaded rows on screen, show a toast only for timeout/network errors, and add a bottom retry row. Retrying should preserve source, mode, query, and next API page number.

Append cancellation should silently remove the loading row when the menu closes or another source/search supersedes the session.

Stale append results must be ignored when:

- active session token changed,
- source/mode/query changed,
- menu was closed,
- another append load already advanced the API page.

## Testing

Update `spec/suwayomi_client_source_manga_spec.lua` to cover:

- Initial source results no longer expose `on_next_page` or `on_previous_page`.
- Source result title does not include API page number.
- Reaching the last KOReader menu page starts fetch for API page 2.
- Page 2 rows append to page 1 rows in the same menu.
- Selection remains on the user's current item/page after append update.
- Append failures keep existing rows and add retry.
- Retry fetches the same next API page and appends on success.
- Closing the menu cancels pending append load.
- Stale append results are ignored after a new search/source session starts.
- Hide-in-library filtering can skip empty API pages without replacing loaded rows, with the chained auto-load cap respected.

Keep worker specs focused on one-page fetch behavior. No live Suwayomi server is required.

## Scope

In scope:

- Source Popular, Latest, and Search result pagination.
- `ListMenu` optional page-change callback.
- Source result titles and README wording for the new flow.
- Focused specs for source manga paging behavior.

Out of scope:

- Global search summary pagination.
- Library category paging.
- WebUI-style smooth pixel scrolling.
- New API fields or server-side behavior.
- Android/device deployment unless implementation later needs manual QA.

## Open Decisions For Implementation Plan

- Callback name: `on_page_changed` is more general; `on_last_page` is narrower.
- Append loading row shape: non-selectable `Loading more...` row versus transient toast only.
- Auto-load cap exact value: recommended 3 filtered API pages per user navigation event.

