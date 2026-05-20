# Manga Info UI Fixes Design

## Goal

Fix the manga information dialog so poster placement is stable, description text gets useful space, and common manga description markup renders predictably without unsafe HTML.

## Layout

Poster placement is screen-class driven. Wide/tall dialogs use split mode with poster on the left and metadata on the right. Narrow or short dialogs use stacked mode with poster above metadata and description. Manga metadata length must not decide whether the poster moves from left to top; long metadata remains reachable through scrolling instead.

Stacked mode uses one scroll owner for the body. It must not put an independently scrolling `ScrollHtmlWidget` inside a `ScrollableContainer`. Description height should be based on available body height, not a fixed small cap.

## Description Markup

Description formatting stays local to `suwayomi/ui/manga_info.lua`. The formatter accepts plain text, common Markdown, and a small safe HTML subset:

- Markdown links and safe bare `http` or `https` URLs.
- Markdown bold and italic markers.
- Markdown headings and bullet lists.
- Safe HTML links, paragraphs, line breaks, bold, and italic tags.

Raw text is escaped first. Only allowlisted tokens are restored. Unsupported tags become escaped text instead of disappearing.

## Tests

Focused specs cover stable split-vs-stacked layout, larger stacked description space, single scroll owner in stacked mode, Markdown bold/list/bare URL rendering, and angle-bracket text preservation. Full verification uses the project Lua gates after the focused spec passes.

## Boundaries

Do not change API payloads, download behavior, chapter-list behavior, poster worker/cache boundaries, or device packaging. Keep poster image loading on the existing decoded `.bb` path.
