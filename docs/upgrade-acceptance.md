# Upgrade acceptance before release

Run this after the candidate passes ordinary offline checks. This is opt-in desktop runtime acceptance; it does not run in unit CI or establish hardware acceptance.

## Disposable desktop run

Follow [sandbox setup](sandbox.md) with Linux x86_64/WSLg, Python 3, LuaJIT, and `xdotool`. Use the pinned releases, a graphical session, an English profile, and a fresh private root. Native entry and paging input activate and target only the window whose process owns this sandbox profile. Keep other reading sessions untouched.

From the candidate checkout, with sandbox services stopped:

```sh
export SOURCE="$PWD"
export ROOT="$HOME/suwayomi-sandboxes/upgrade-candidate"
python3 scripts/sandbox.py --root "$ROOT" setup
python3 scripts/sandbox.py --root "$ROOT" deploy --source "$SOURCE" --revision "$(git rev-parse HEAD)"
python3 scripts/sandbox.py --root "$ROOT" upgrade-acceptance --prepare
python3 scripts/sandbox.py --root "$ROOT" upgrade-acceptance --source "$SOURCE"
```

Preparation creates 35 additional synthetic manga and installs a profile-only fault/observation patch. The runner starts and stops its own server/reader. It never installs that patch in the release payload. Basic Auth is required for disposable category mutation controls. Keep the root private: reports include raw settings, paths, observations, and first-attempt diagnostics.

Each attempt gets a new `evidence/upgrade-*/results.json`. Required assertions are fixed per scenario; empty discovery, missing assertions, swallowed failed checks, missing controls, and exceptions cannot pass. Failed retries remain failed within a run. Missing prerequisites remain unverified with a blocker. `--only SCENARIO` runs a diagnostic selection plus native baseline; omitted scenarios remain unverified and exit status cannot establish full acceptance. Preserve earlier attempt directories and explain their disposition when recording a later pass.

The report records Git candidate/dirty state, runtime versions, canonical deployed hashes, instrumentation hash, scenario assertions, and cleanup. A dirty candidate cannot pass the final gate. Source discovery or hash mismatch blocks testing. Freeze the payload before acceptance; after runtime changes, redeploy and repeat affected checks. The launcher uses bounded longer discovery timeouts for the synthetic source.

## Required controls

| Scenario | Independent outcomes |
| --- | --- |
| Native entry and reader return | Search > Suwayomi opens Library; real server membership; downloaded fixture pages match; exact archive opens, page-two progress survives native return/reopen; archive preserved. |
| Mixed authority | Unknown-origin archive exposes safe local actions; unrelated current listing controls remain available; known foreign bytes gain no Open/delete authority; saved uncertain record and files preserved. |
| Pending unread | Normal manual read and Refresh establish server/cache Read; offline manual unread followed by labeled absent-old-path/changed-destination preconditions stays Unread in rows/context and admits the correct first unread; original bytes preserved. |
| Verification faults | Injected rename rejection and directory-sync uncertainty produce feedback, release inspection, retain fence and bytes/progress, and permit explicit recovery. These are not storage-exhaustion tests. |
| Stale controls | A real background response invalidates an open ordinary action; rejection feedback appears without replay, then fresh Off succeeds. |
| Publication stages | Separately injected checked-write faults retain response membership, stage-specific cache/read-choice state, and files. A labeled three-to-two response subset distinguishes cache persistence from visible membership; background read sync is held during these cases to isolate publication acknowledgment. Directory-sync uncertainty records disk contents without claiming confirmed persistence. Labeled empty/stale response controls exercise existing publication guards. |
| Deleted category | Delete synthetic selected category on real server; ordinary Refresh restores All manga. |
| Browse layouts | Synthetic source discovery, List/Cover with text/Cover only switching, visible-item preservation, and pagination to final fixture. |

Inspect framebuffer evidence for clipping and wrong destinations. Successful callbacks or matching titles alone are insufficient. Capture UI, saved state, events, and process state before restarting a stalled reader. A harness mistake is a retained failed attempt with a diagnosed cause, not a product pass.

## Palma and final readiness

One owner operates all live resources. Before takeover, inspect reader/session ownership, authorized attachment, package state, and ADB mappings. Back up the original profile/plugin/progress, hash every file, and preserve the original profile intact. Deploy the same frozen canonical payload into an isolated test profile; compare every deployed file hash. Use disposable server fixtures only.

Repeat native Search entry, mixed/pathless/foreign and relocated pending unread controls, normal display/Refresh/action preload/manual read-unread, publication faults, Open/Verify persistence feedback, stale controls/fresh Off, native return with progress, deleted-category Refresh, and Browse layouts/pagination. Record actual installed runtime versions and route. USB reverse/forward proves USB, not Wi-Fi. Physical sleep/wake, power loss, storage exhaustion, and e-ink usability require their own evidence.

Afterward stop owned readers/services/relays, restore original profile/plugin and package state, restore original ADB mappings, and rehash every original file. Retain private failure evidence separately. Unavailable hardware leaves these controls **unverified**, never demonstrated by desktop or offline tests.

Release readiness requires a clean exact candidate, required automated checks, every required desktop scenario demonstrated, explained first-attempt failures, matching deployed hashes, relevant Palma evidence/restoration, and separately authorized GitHub CI/finalization. This command never pushes, merges, publishes, closes issues, or grants release authority.
