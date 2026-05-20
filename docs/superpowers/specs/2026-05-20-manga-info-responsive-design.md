# Manga Info Responsive Layout Design

## Goal

Make the manga information dialog usable across KOReader-supported screen shapes:
small landscape phones, phone portrait, Kindle/e-reader portrait, and larger
tablet or desktop-like displays.

The dialog should keep the poster-forward visual design where it fits, avoid
fixed-height overflow where it does not, and recompute geometry after
screen-size changes such as rotation.

## Current Problems

`suwayomi/ui/manga_info.lua` currently chooses one layout shape for every
screen. It builds a horizontal poster/metadata row, gives the poster a fixed
ratio of dialog width, gives metadata the poster height, and gives description
a forced minimum height. This can overflow on short landscape screens, clip
metadata when many fields are present, and waste space on larger screens.

The dialog also captures screen dimensions during construction. A later resize
or rotation can leave stale dialog width, height, region, and content layout.

Poster rendering must stay conservative. The safest runtime image boundary is
the existing worker-decoded `.bb` poster cache loaded into `ImageWidget`.

## Layout Model

Add a small layout solver inside `suwayomi/ui/manga_info.lua`. The solver takes:

- screen width and height
- scaled padding, gaps, and line sizes
- measured title-bar and button-row heights
- available body width and height

It returns a layout table used by content construction:

- `mode`: `split` or `stacked`
- dialog width and height
- body width and height
- poster width and height
- metadata width and height
- description width and height
- scroll mode: `description` or `body`

The solver must be deterministic and directly unit-testable through dialog
construction specs.

## Adaptive Sheet Behavior

Use split mode only when both dimensions can support it:

- poster and metadata can sit side by side with positive usable widths
- metadata gets enough height to avoid obvious clipping of normal field counts
- description still receives meaningful height

Use stacked mode when the text column would be too narrow, the screen is short,
or the available body height cannot safely fit the current split layout.

In split mode:

- top row: poster on the left, metadata on the right
- bottom: scrollable description
- dialog width remains capped by the shorter screen edge for normal e-reader
  modal behavior, with a maximum cap so large tablets do not get a comically
  wide dialog

In stacked mode:

- body content is ordered poster, metadata, description
- poster is compact and centered
- the whole body is scrollable when total content is taller than available
  height
- no child gets a forced minimum that can make the dialog exceed the screen

## Scrolling

Keep `ScrollHtmlWidget` for rich description text and link handling.

For constrained screens, wrap the whole body in KOReader's
`ScrollableContainer` so poster, metadata, and description remain reachable.
The body scroll should own overflow instead of allowing fixed widgets to exceed
the modal.

Metadata must not be silently clipped. If split mode cannot give metadata
enough height, the solver should choose stacked mode. If stacked content still
exceeds available height, body scrolling makes all fields reachable.

After replacing content on poster load or resize, continue rebinding dialog
references so `ScrollHtmlWidget` link callbacks and dirty-region refreshes keep
working.

## Poster Sizing

Keep remote image fetch and decode in the existing thumbnail worker. Keep
decoded `.bb` cache loading in the UI process.

Move poster target sizing from a single fixed `240x360` request to a
layout-derived size. To avoid cache churn, bucket requested poster sizes rather
than using every exact pixel size. Candidate buckets:

- compact: about `160x240`
- normal: current `240x360`
- large: about `320x480`

The displayed poster slot uses the solver dimensions. The worker receives the
matching bucket dimensions through existing thumbnail worker options and cache
variant options. The row thumbnail path remains out of scope and must not be
used as a fallback for manga info posters.

## Resize Handling

Add `Dialog:onSetDimensions()` on the custom dialog and route it through the
same rebuild path used by poster refresh.

On resize:

1. Read current screen width and height.
2. Recompute dialog width, height, region, and content layout.
3. Rebuild title, content, and button geometry or reset affected containers.
4. Rebind refreshed content to the dialog.
5. Mark the dialog dirty through `UIManager:setDirty`.

Poster jobs should not be restarted just because the screen resized. If a new
layout picks a different poster bucket and no matching cache entry exists, the
dialog can continue showing the current cached poster or placeholder until a
future explicit cache refresh pass. Avoid adding complex job cancellation or
multi-size poster fetching in the same resize callback unless tests prove it is
necessary.

## Implementation Boundaries

Primary implementation file:

- `suwayomi/ui/manga_info.lua`

Primary tests:

- `spec/suwayomi_ui_spec.lua`

Do not change API payloads, controller action routing, download behavior, or
chapter-list behavior for this task.

The runtime module boundary remains the same: manga information UI formats
already-loaded metadata and shows read-only KOReader dialog content.

## Test Plan

Add table-driven specs with screen stubs for:

- small landscape, for example `640x360`
- very small landscape, for example `480x320`
- phone portrait, for example `360x640`
- Kindle/e-reader portrait, for example `758x1024` or similar
- tablet/large display, for example `1200x1600`

Assertions should cover:

- dialog dimensions never exceed screen dimensions
- body/content dimensions are positive
- stacked mode is selected for short or narrow screens
- split mode is selected for e-reader/tablet shapes with enough space
- metadata remains in reachable body content on constrained screens
- description still uses rich HTML/link callback path
- poster display dimensions match chosen layout
- poster worker/cache options use the expected size bucket
- resize handler recomputes dialog and content dimensions after screen values
  change

Run the focused UI spec first, then the normal local gates:

```bash
rtk busted spec/suwayomi_ui_spec.lua
rtk luacheck --codes spec suwayomi main.lua _meta.lua
rtk busted spec
```

## Manual QA

After implementation, push only the runtime payload to a KOReader device when a
device is available:

- `_meta.lua`
- `main.lua`
- `README.md`
- `suwayomi/`

Use `adb.exe` for Android-like device access. For Kindle manual testing, use
the normal KOReader plugin install path for that device and avoid copying specs,
docs, CI files, worktrees, or git metadata.

Manual checks:

- phone/small landscape equivalent does not overflow
- Kindle portrait keeps useful poster/metadata balance
- long metadata remains reachable
- description scrolls and links still work
- poster loading state still distinguishes `Loading...` from `No poster`
- rotation or resize rebuilds the dialog instead of leaving stale geometry
