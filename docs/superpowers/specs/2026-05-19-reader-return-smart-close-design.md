# Reader Return Smart Close Design

## Goal

When a reader returns from a downloaded chapter to the plugin chapter screen, pressing the close cross should keep them inside the most useful plugin context instead of closing the plugin outright.

The routing rule is:

- If the returned title is known to be in the library, close the chapter screen and open Library.
- Otherwise, if the returned title has source metadata, close the chapter screen and open that Source flow.
- Otherwise, keep current close behavior.

Library membership wins over source origin because it reflects the title's current ownership state.

## Current Behavior

Reader-return state is persisted by `suwayomi/reader_return.lua` and is restored with `returnToSuwayomiChapters()`. That path closes the reader, reloads chapters, and calls `showChapterResultForManga(manga, result, { return_context = context })`.

The chapter screen is then tracked as a normal `"chapters"` route. Its close callback only clears `current_chapter_menu`. If the returned chapter screen is the only plugin screen, pressing the cross closes the plugin.

## Proposed Behavior

Reader-return contexts should carry non-sensitive routing hints:

- `manga_id`
- `manga_title`
- `chapter_id`
- `chapter_name`
- `source`
- `in_library`

When chapter archives finish downloading, the existing context save path should copy `manga.in_library` when present. Ledger and sibling inference fallbacks can keep working without `in_library`; missing membership means "unknown", not false.

When returning from reader mode, `ReaderReturn` should rebuild the manga table with `in_library = context.in_library`. The return call should pass a reader-return option to the chapter screen, for example:

```lua
self:showChapterResultForManga(manga, result, {
    return_context = context,
    reader_return_close_target = self:buildReaderReturnCloseTarget(context, manga),
})
```

The chapter controller should use that option to install a close callback for this screen only. Normal chapter menus opened from Library or Source stay unchanged.

## Routing

Add a plugin-bound helper that resolves the target:

1. If `manga.in_library == true`, return `{ kind = "library" }`.
2. Else if `manga.source.id` exists, return `{ kind = "source", source = manga.source }`.
3. Else return `nil`.

On close:

1. Clear `current_chapter_menu` as today.
2. If no target exists, return normally.
3. For Library target, call `showLibrary()`.
4. For Source target, call `getClient():showSourceModeMenu(source)`.

The close callback should avoid recursively closing the newly opened target. It should only react to the returned chapter menu close event and then launch the target after local chapter menu cleanup.

## Failure Behavior

If Library cannot load, existing Library error messages handle that.

If Source cannot open because source metadata is incomplete, keep current close behavior.

If source loading starts but fails later, existing Source failure UI handles that.

No new success toast is needed because the user sees the new screen directly.

## Privacy

Do not log filesystem paths, title names, source display names, or chapter names in new debug events. Existing persisted context fields remain settings data, not debug output.

## Tests

Add focused specs:

- Reader-return context saving preserves `in_library` when the downloaded manga has it.
- Reader-return chapter restore builds manga with `in_library`.
- Closing a reader-return chapter screen with `in_library = true` opens Library.
- Closing a reader-return chapter screen with `in_library` false or nil and valid source metadata opens the source flow.
- Closing a reader-return chapter screen with no close target keeps current close behavior.
- Normal chapter screens opened without reader-return options still only clear `current_chapter_menu`.

## Out Of Scope

- Remembering exact historical origin from before the reader opened.
- Prompting the user to choose between Library and Source.
- Changing normal in-plugin close behavior for Library, Source, manga actions, or non-reader-return chapter screens.
