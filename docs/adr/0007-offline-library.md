---
status: accepted
---

# Offline Library is a cache of the server

Use the normal Library and chapter screens with or without Internet access. Cache server information so those screens and downloaded chapters remain usable when requests fail. The server is authoritative; the cache is not a second library to maintain or reconcile.

This revision was accepted on 2026-09-17 and replaces the design accepted on 2026-09-12. It incorporates the simplification requested on 2026-09-16, not the behavior of the `offline-library` implementation. Acceptance records the intended behavior, not device verification. The current runtime has checked Library and chapter-list caches and saved-first screens; [architecture](../ARCHITECTURE.md#library-and-chapter-cache) describes those owners. Consult the [testing recipes](../testing-recipes.md#chapter-cache-acceptance) and [evidence index](../evidence/README.md) before claiming an individual scenario passed.

## Behavior

1. **Load normally, keep a cache.** Opening Library or a chapter list shows saved information immediately and attempts the normal server load without blocking local use. A successful response replaces that list and its cache. There is no confirmation or separate set of results to apply.
2. **Use the cache when the request fails.** Keep the same screen, rows, and controls. Do not turn a failed request into an empty list or a connection dialog that blocks reading. The ordinary refresh action retries; no new reconnect watcher or retry timer is needed.
3. **The server wins.** A successful server listing replaces cached membership and order, even if it removes manga or chapters. An empty successful listing is also authoritative. Do not union in downloaded manga, retain extra chapter rows, repair membership, or upload reconstructed entries. Replacing listing metadata does not delete chapter files or reading progress.
4. **Keep the same presentation.** Categories, sorting, chapter rows, and thumbnails use the same screens and saved information. No On device filter, local/full views, offline-specific navigation, or expansion buttons are introduced by this feature. Cached content should look the same as it did with Internet access; a brief request-failure indication is sufficient.
5. **Keep reading behavior.** Open downloaded chapters from their files and preserve KOReader reading progress. Existing Sync, read/unread actions, downloads, and deletion settings keep their behavior. Server authority over listings does not replace the existing read-synchronization rules. This ADR adds no reconciliation or read-state policy.

## What is cached

Persist the library listing and the metadata its normal display needs, including categories and thumbnail references. Persist chapter listings when loaded. Reuse the existing thumbnail cache offline, including thumbnails cached before the upgrade; a thumbnail must not disappear merely because a server request failed. Use the normal placeholder only when its image is actually unavailable.

Successful online use builds and updates this cache automatically, not through a separate setup or “prepare for offline” action. The baseline caches lists and thumbnails obtained through normal use; it does not fetch every manga's chapters or download chapter contents in advance. Do not add cache-limit settings or eviction machinery without a demonstrated storage need.

A manga's chapter list that has never been loaded may be unavailable offline. Reconstruct it from existing chapter information where possible; otherwise explain that no chapter information is saved. Do not claim the server has no chapters. A downloaded file's availability is determined locally, not inferred from connectivity or server-library membership.

Keep the last usable cache if a load is incomplete or fails. Report a failed cache write rather than claiming the new information will survive restart. Cache entries belong to the configured server; do not substitute another server's cache.

## First use of the new version

**With Internet access:** load the server library and save its display information. Use existing cached thumbnails and fetch missing ones through the normal thumbnail path. Cache chapter lists as they are loaded. Existing files and reading state are preserved. The server result takes precedence over any reconstructed information.

**Without Internet access and without a usable cache:** make a best-effort library and chapter listing from existing downloaded chapters and their saved metadata. Reuse available titles, order, and cached thumbnails; missing information is not a reason to hide a readable chapter. Reconstruction is a fallback, not a migration or association workflow. Do not scan unrelated folders, invent server identities, or rewrite archives. If nothing can be recovered, show an empty screen explaining that no saved library information is available.

Once a server listing succeeds, it replaces the reconstructed listing. Do not add reconstructed rows back afterward. In particular, a successfully cached empty server library must remain empty rather than trigger reconstruction on the next offline opening.

## Acceptance boundaries

Exercise the normal UI in a connected → disconnected → reconnected reading sequence, including chapter Open, saved progress, return, cached thumbnails, and successful server replacement. Also exercise first use of the new version with existing downloads and no cache: offline reconstruction must expose only recorded files without inventing identities. A successful empty server list is a separate control; it remains empty on offline restart even when local files exist. Failed or incomplete requests must retain the previous usable list. Check a real cache-write failure separately from a failed server request. These are requirements, not claims that each desktop or physical-device case passed; follow the [testing workflow](../agents/testing.md).

## Scope

This feature adds cached browsing and best-effort reconstruction when no cache exists. It does not change what opening Suwayomi opens: automatically opening Library is a separate change and is not required here.

No second library, download-association UI, multi-server management, new synchronization rules, new download/retention policies, or new reading controls. Reuse the existing screens and behavior rather than redesigning them for offline use.

Acceptance means exercising the scenarios above in the normal UI, including a new-version start with existing downloads, reuse of already-cached thumbnails, and the connected → disconnected → reconnected reading sequence. Check actual chapter opening and saved progress, not just row labels. These are requirements, not claimed test results; follow the [testing workflow](../agents/testing.md).
