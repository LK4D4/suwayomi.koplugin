# Source Manga Async Audit Design

## Goal

Ensure source manga browse/search/latest loading never performs a Suwayomi network request on the UI thread.

## Pre-change State

Source manga loading now has a subprocess worker, a loading menu, a cancel action, and a timeout. That covers the normal KOReader runtime path. The remaining gap is the fallback path in `SuwayomiClient:showMangaForSource`: if the subprocess runtime cannot be resolved, it calls `fetchMangaForSourceSync`, which wraps `api.fetchMangaForSource` in `withLoadingMessage`. That still performs GraphQL synchronously on the UI thread.

## Design

`showMangaForSource` should treat a missing source manga worker/runtime as a startup failure, not as permission to perform network IO synchronously. It should show a short user-facing error and return without calling `api.fetchMangaForSource`.

The source manga worker remains the only implementation path for remote source manga pages. Existing cancellation and timeout behavior stays intact: the loading menu close callback and title action cancel the active subprocess, and timeout updates the loading menu with a failure message.

## Scope

This pass only hardens source manga after the async merge. Library loading, chapter loading, manga refresh, library mutations, read sync, and active download cancellation remain separate ANR-hardening work.

## Tests

Add or update client specs so:

- Missing source manga runtime does not call `api.fetchMangaForSource`.
- Source manga subprocess startup failure does not call `api.fetchMangaForSource`.
- Source manga async tests continue to prove loading starts immediately with cancel callbacks.
- Existing browse behavior tests run through an immediate source manga worker fake rather than relying on synchronous fallback.
