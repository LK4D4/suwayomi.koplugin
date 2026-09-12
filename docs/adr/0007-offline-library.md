---
status: accepted
---

# One Library with independent on-device availability

Offline reading will use the same Library entry point as server browsing, rather than a separate top-level shelf. On-device membership depends on plugin-known local chapters, not server-library membership: removing a manga from the server library must not make its retained local chapters inaccessible. The offline view is not a complete mirror of the server library.

The consolidated design was accepted on 2026-09-12 after the design interview. Acceptance records the intended behavior, not implementation or authorization to commit, push, or merge.

## Agreed behavior

- After first-run setup, opening the plugin goes directly to Library; Browse, Downloads, Sync, and Settings remain accessible from its menu.
- Library initially presents on-device content without waiting for the server. Server loading does not block local navigation. When the server result changes the ordered row identities, offer Show full library rather than replacing the list automatically; distinguish the current local and full views. Unchanged row identities and order update silently while preserving selection, scroll position, and row layout. An initially empty list may populate automatically.
- Preserve explicit chapter selection and the existing first/next-unread action rather than adding a new Continue reading selection system.
- First/next-unread must not silently skip a known unread chapter merely because its archive is not on device. Explain the unavailable chapter clearly; later downloaded chapters remain manually selectable.
- Full library includes both server-library manga and plugin-known downloaded manga, including manga not in the server library. Inclusion does not mutate server membership. An On device filter restricts the view to locally stored manga.
- Library opens the manga list directly instead of the category picker. Categories remain available as a filter when server data is available; offline category caching is outside this feature.
- Chapter lists follow the same local-first publication rule: show downloaded chapters immediately, load server information without blocking, and offer Show all chapters when it changes the rows. Unchanged rows update silently. Explicit refresh supports retries and newer information.
- Plugin reader return restores an existing manga chapter view without waiting for the server; without a retained view, it opens downloaded chapters first and follows the same nonblocking refresh rule. This includes plugin-known archives reopened through KOReader History or File browser; ordinary KOReader navigation is unchanged.
- Local open, verify, read/unread, delete, and applicable existing bulk actions remain usable offline. Existing pending read synchronization and deletion/retention policies still apply. Server mutations require connectivity; this feature adds no mutation queue. Existing download jobs retain their retry behavior.
- Existing plugin-known downloads remain manually browsable and readable when saved chapter information is incomplete. First/next-unread explains that a refresh is required if ordering or gap information is insufficient; filenames do not establish complete chapter order.
- Downloads from former or unknown server origins remain locally accessible. Different origins remain separate; no refresh, merge, or synchronization may target the wrong configured server. Unknown origins are not silently assigned to the current server. This is not multi-server account management.
- Back and reader-return navigation preserve an existing view's local/full choice, filters, selection, and scroll position. Failed background requests do not collapse a displayed full list. A fresh plugin opening or KOReader restart starts local-first; preserving navigation does not require persisting the full server library.
- Mark previous read targets all known preceding chapters under the saved scanlator filter, including undownloaded chapters hidden by the on-device view. Confirm the scope, explicitly including the undownloaded count. Incomplete chapter information requires a refresh rather than a guessed subset. Mark selected read affects only the explicit selection.

## Consequences

Server membership and device-local availability cannot share one inclusion rule. Rendering only downloaded chapters must not erase the information needed to recognize a known unread gap or to mark preceding chapters read. Origin isolation must cover local actions and reader lifecycle as well as background refresh. Persisting enough chapter information for these operations is distinct from persisting the entire server library; legacy records without that information retain manual access.

## Implementation constraints identified during design

- Existing completed-download records do not establish a complete ordered chapter list, including undownloaded gaps. Archive validation metadata does not supply that missing catalog.
- The current download queue key is only manga ID/title plus chapter ID/name (`suwayomi/downloads/queue.lua`, `getKey`); existing ledger identities likewise do not establish server separation. Retaining former-server downloads requires checking identity collisions and every action/reader/sync path, not merely filtering Library network requests. A UI-only origin check cannot satisfy this contract.
- Existing scanlator filtering precedes unread selection and bulk actions. Preserve that restriction independently of on-device visibility; the explicit Mark previous read scope above must not become a downloaded-only subset.
- Existing Refresh chapters performs a source refresh, while ordinary chapter loading reads stored server chapters first. Local-first background loading must not silently become an automatic source refresh.

## Scope exclusions

No new Continue reading selection system, full offline server-library mirror, offline category cache, arbitrary CBZ discovery, multi-server account manager, or new server-mutation queue. Existing archives, saved reading state, credentials, and download/retention contracts remain protected.

## Verification obligations

These are required implementation outcomes, not checks performed during this documentation-only interview:

| Scenario | Required observation |
| --- | --- |
| Download manga, partially read a chapter, restart with the server unavailable | Library and chapter navigation remain usable; manual opening resumes through KOReader's saved reading state. |
| Background server results arrive while a local list is open | Unchanged ordered identities update without moving selection; changed rows wait for expansion; an empty list may populate. |
| Expand Library and chapter views, read, and return with the server unavailable | View choice, filters, selection, and scroll position remain; a fresh opening still starts local-first. |
| A known next-unread chapter is not downloaded, or legacy chapter information is incomplete | No silent skip or guessed ordering; explain the gap or required refresh while retaining manual access. |
| Mark previous read with hidden undownloaded predecessors | Confirmation includes hidden scope; accepted changes include all known predecessors under the scanlator filter; explicit selection remains separate. |
| Perform local read/unread, verify, and delete actions offline | Existing local safety and persistence outcomes hold; no server success is claimed, and pending synchronization remains origin-bound. |
| Retain downloads absent from server-library membership | Local access survives full-library expansion without mutating server membership. |
| Switch between servers with colliding IDs, and include unknown-origin records | Local files remain accessible without merging identities, overwriting unrelated reading state, or sending requests/read updates to the wrong server. |

Use focused LuaJIT coverage for identity, ordering, and publication boundaries, and the local KOReader sandbox for real navigation, reader return, and restart evidence. Device-only observations must be reported separately, following [the testing workflow](../agents/testing.md).
