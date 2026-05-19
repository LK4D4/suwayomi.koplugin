# Manga Information Dialog Design

## Goal

Add a read-only manga information view that is easy to open from both manga rows and the chapter list.

## Entry Points

- Add a `Manga information` action to the manga action menu shown after selecting a manga row.
- Add the same action to the chapter-list title-bar menu when the chapter list has a current manga context.
- The first version closes with one `Close` button only.

## Dialog

Use a KOReader-native modal similar in shape to the referenced assistant dialog:

- bordered window
- title row with the manga title
- scrollable body
- bottom button row with `Close`

The body is read-only. It starts with compact metadata, then shows the description or a fallback message.

## Data

Use only manga data already available in memory. Do not add a network fetch in this pass.

Show available fields in this order:

1. Source
2. Status
3. Author
4. Artist
5. Chapters
6. Library state
7. Genres
8. Description

Skip empty metadata fields. If description is absent, show `No description available.`

## Architecture

Add a focused UI helper for formatting and showing manga information. Wire it through the existing manga action controller so both entry points reuse the same action ID and callback path.

Keep manga action definitions in the existing shared action module. Keep KOReader widget construction in UI code. Keep controller behavior in manga/chapter controller methods.

## Tests

Add focused specs for:

- metadata formatting skips empty fields and includes fallback description
- manga action menu exposes `Manga information`
- selected manga action opens the information dialog
- chapter-list title menu exposes the same action

Run local lint and specs before commit.
