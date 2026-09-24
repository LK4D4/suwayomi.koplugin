# Feature testing recipes

Use the [sandbox runbook](sandbox.md) for setup, deployment, services, and UI controls. Apply only the scenarios relevant to the change; these are controls, not current test results. Select and report evidence with the [testing guide](agents/testing.md).

## Read-sync endpoint acceptance

Use two disposable servers, A and B, with separate credentials and ports but colliding fixture IDs. Discover IDs independently. Deploy one candidate profile and keep retention Off.

1. On A, mark an undownloaded chapter read through its chapter menu. Require a pathless ledger entry with A scope, a real server read transition, and cleared pending state. Mark unread and require the reverse.
2. Open a known A download, use native **Mark as finished**, then **Go to Suwayomi**. Wait for A's read state and cleared pending flag; preserve the archive. Continuous view can show a completion dialog at reported page 1, so this is explicit completion, not a final-page-only test.
3. Stop A, create an offline read choice in the UI, and confirm durable pending state. Save B through **Settings → Connection → Login information**, then invoke **Sync**. Require A's choice and scope to survive, B's matching chapter to remain unchanged, and association feedback.
4. With the reader stopped and settings backed up, inject separate A-scoped, unknown, and B-scoped pending entries. Restart under B and invoke **Sync**. Only B's entry should clear and change its server chapter. Repeated Sync must still report the retained unsendable choices.
5. For unknown recovery, back up settings and native sidecar. Remove the archive's origin evidence and cached association, retain IDs, clear pending flags, and set native status unfinished. Label this injected precondition. Reconstruct offline, Open through the UI, and require a rendered page with no new scope or pending sync. Restore the server, mark finished natively, and close. Require local completion, still-unknown origin, no pending enrollment, and unchanged matching server read state. Restore backed-up state.

## Library-cache acceptance

Use a disposable profile with a recorded download and cover. Preserve private settings, thumbnails, archive, and sidecar before altering fixtures.

1. For legacy image recovery, save a fixture's decoded `.bb` privately and put its source PNG at the same cache-key stem with a `.png` extension. Label this injected pre-upgrade fixture. With the server stopped, open Library: recorded downloads should supply rows and covers without setup or linking. Repeat after reader restart. A separate profile lacking both usable cache and download metadata should show missing-information feedback, not authoritative emptiness.
2. Add a second synthetic series and category through the Local source and supported server API. Keep the baseline fixture intact. Refresh Library and require complete rows/categories. Select **Default**, the new category, and **All manga**; account for the category picker preference.
3. Verify the owned server PID and start time, suspend it during a Library request, and choose a category/manga from cached rows. Resume it and require the selected manga to stay foreground. Separately stop the server and require cached rows/covers after failure and cold reader restart. Restore the owned process even when the control fails.
4. Remove only the second series from server Library and Refresh; its row should disappear while existing archives remain unchanged. For successful emptiness, remove all Library membership, Refresh to empty, then stop the server and cold-restart only the reader. Empty must survive despite downloads. The launcher reseeds its baseline on server start, so restore membership only after this assertion.
5. Navigate **Library → menu → Suwayomi home → Library**, then close the new branch. Require return to the underlying KOReader screen. Compare archive/sidecar hashes and preserved credentials/read/download state independently of screenshots. Restore injected cache files and server membership.

## Chapter-cache acceptance

Keep Library and chapter controls in one disposable profile, with separate fixtures for page progress, membership removal, and a manga never opened online. Record deployment, settings, archive, and sidecar evidence before faults.

1. Download a chapter through the UI, Open it, choose native **View Mode: page**, advance to page 2, and return through **Go to Suwayomi**. Stop the server, follow **Library → manga → Open chapters → downloaded chapter → Open**, and require a visible page and return. Cold-restart offline and require native page-2 resume. At the last page without marking finished, check unfinished status, read state, and retained archive.
2. Open the never-loaded manga offline and require missing-information feedback. For first-upgrade recovery, back up settings and remove only `chapter_cache` through the checked store. Separately inject recorded metadata lacking association/title fields. Test once with Library cache and once without. The file must remain reachable; Open/Verify and return must not invent endpoint scope or pending sync. Restore settings between cases.
3. Verify the owned server PID/start time and suspend only that process while opening cached Library, chapters, and archive. Require a visible reader before resuming the server. Always resume the owned process.
4. Move one source archive into private evidence and **Refresh chapters**. The real server and screen should omit that row while the local archive/sidecar hashes remain unchanged. Restore the source file. On Suwayomi v2.3.2243, removal of every source chapter returns **No chapters found**; this failure should retain the previous complete list.
5. Test successful empty response separately. With the real server stopped, an authenticated disposable responder at the same endpoint may return, for only the controlled manga, `GET_CHAPTERS_MANGA` → `{"data":{"chapters":{"nodes":[],"totalCount":0,"pageInfo":{"hasNextPage":false}}}}`, then `GET_MANGA_CHAPTERS_FETCH` → `{"data":{"fetchChapters":{"chapters":[]}}}`. Reject other requests and avoid header logs. The normal chapter UI should show explicit empty; it should survive offline cold restart despite downloads. Label this **injected successful response**. Stop the responder, restore the real server, and require ordinary refresh to replace it.
6. Mark a known chapter read offline; require durable pending state, then reconnect and **Sync** and inspect server read state. After refresh settles, mark unread and verify the reverse. Download and confirm deletion of a spare chapter; only its archive should disappear. Retry any stale action from the current menu after context replacement.

For further recovery, restore a private settings backup between controls: clear a saved scanlator restriction to reveal an unassociated file without changing the shared filter or enrolling a same-ID Auto-download association; reconstruct a current-endpoint file lacking IDs/descriptive fields without inventing IDs; and show that newer Library title/membership wins over stale chapter-cache metadata. Compare independent archive and sidecar hashes after each control.
