# Testing workflow for agents

Use local KOReader and a disposable Suwayomi server for runtime verification. Use hardware for platform-sensitive behavior and explicit device acceptance. [AGENTS.md](../../AGENTS.md) owns repository gates, worktrees, packaging, and data safety; the [test strategy](../ARCHITECTURE.md#test-strategy) maps isolated coverage.

## Choose the evidence

Match each requirement to a precondition, action, observable outcome, and environment. Run only the layers the change needs:

| Layer | Establishes | Does not establish |
| --- | --- | --- |
| Isolated LuaJIT specs | Selection, state transitions, deterministic failure boundaries | Real server compatibility or KOReader lifecycle |
| Plugin code against a real server | GraphQL, authentication, binary responses, parsing and transfers | Menu wiring, reader transitions, device behavior |
| Local KOReader plus real server | Actual menus, workers, reading, persistence, navigation and restart | Android permissions, physical sleep/wake, e-ink usability |
| Target device | Required platform behavior under recorded controls | Other platforms or the cause of an unreproduced crash |

Reuse focused specs and prior evidence. A closed issue with accepted gaps does not establish its unchecked cases. Ordinary specs stay offline and independent of a server, KOReader installation, or personal library. Sandbox runs are opt-in.

Run isolated specs with `busted --lua=luajit spec` when the installed Busted launcher does not already select LuaJIT. A LuaRocks launcher can hardcode plain Lua 5.1, which lacks `ffi` and cannot exercise the native archive and durable-storage boundaries.

## Start a fresh sandbox

### Prerequisites

The shipped launcher supports **Linux x86_64**: native Linux, Windows with [WSLg](https://learn.microsoft.com/en-us/windows/wsl/tutorials/gui-apps), or a Linux VM with a desktop. It is not a native Windows or macOS runtime launcher. Docker is not required.

Provide these prerequisites in that Linux environment:

- [Python 3.9+](https://www.python.org/downloads/). The Python tooling uses only the standard library; no pip packages are required.
- A working graphical session and SDL2 runtime libraries for [KOReader desktop Linux](https://github.com/koreader/koreader/wiki/Installation-on-desktop-Linux). A shell alone is not a display. Use the distribution's documented dependencies when provisioning the environment.
- HTTPS access for setup to fetch the pinned [KOReader releases](https://github.com/koreader/koreader/releases) and [Suwayomi releases](https://github.com/Suwayomi/Suwayomi-Server/releases). See [Suwayomi installation guidance](https://github.com/Suwayomi/Suwayomi-Server#downloading-and-running-the-app) for upstream requirements.

[scripts/sandbox.py](../../scripts/sandbox.py) owns the release pins and download selection; `sandbox.json` records the installed versions. The scripts download application releases but do not install OS packages or change firewall, routing, DNS, or other network configuration. Provision missing prerequisites separately.

On Windows, run `wsl.exe -- bash`, then run the commands below from the plugin checkout inside Linux. Both `SOURCE` and `ROOT` must be Linux paths, and both services must run in that same environment. Windows paths and a successful Windows browser request do not establish connectivity from KOReader.

### Setup and deploy

Run these commands from the candidate plugin root. Choose an absolute, disposable `ROOT` outside the checkout. Use the same exported values in each terminal or supervised process:

```sh
export SOURCE="$PWD"
export ROOT="$HOME/suwayomi-sandboxes/chapter-check"
python3 scripts/sandbox.py --root "$ROOT" setup
python3 scripts/sandbox.py --root "$ROOT" deploy --source "$SOURCE" --revision "sandbox-candidate"
```

`setup` requires an absent or empty root. It refuses existing contents; there is no destructive reset. For another clean comparison, choose a new root. To select unused ports, add `--server-port 4569 --inspector-port 8083` to `setup` with your chosen values. An occupied service port is an error, not permission to kill an unrelated process.

Authentication is explicit. `setup --auth-mode basic_auth` is the default; use `setup --auth-mode simple_login` or `setup --auth-mode ui_login` in a different empty root for either login method. `sandbox.json` records `auth_mode`, and setup writes the matching server and plugin settings. Roots created before this field existed remain Basic Auth. The launcher does not switch or fall back between modes.

Setup creates isolated runtime trees, server data, a KOReader profile, and client downloads. It generates `server-data/local/Sandbox Alpha/Chapter 001.cbz` through `Chapter 003.cbz`, each containing three visibly labeled PNG pages. No personal server, settings, credentials, or library copy is needed.

Deployment copies only the canonical runtime payload into `profile/plugins/suwayomi.koplugin`. `deployment.json` records the caller-supplied revision label and SHA-256 for every deployed file. The script does not authenticate the label against Git; record dirty changes separately and compare the manifest with the intended candidate when reporting exact-hash coverage. The copy does not follow later source edits. Stop KOReader before redeploying. Deployment refuses changed or unrecorded files in an existing payload rather than overwriting uncertain data.

Deployment also refreshes the sandbox-only inspector patch and records its digest. Stop the reader and redeploy after changing the tooling; this leaves credentials and downloaded fixtures intact.

### Run and wait for readiness

Keep each command in a separate terminal or harness-supervised foreground process. Start the server first:

```sh
python3 scripts/sandbox.py --root "$ROOT" run server
```

Wait for **`server ready`**. This requires authenticated readiness and real API seeding of the Local source library, not just process creation. In the second terminal, start KOReader:

For Simple Login, readiness uses a launcher-owned, in-memory cookie jar and posts the generated credentials to `/login.html`. The pinned release must return `303` with `Location: /` and a session cookie; the launcher does not follow that redirect or any API redirect. Authenticated API calls then discover and seed the fixtures, and a separate cookie-free request must be rejected. No cookie is written to disk, printed, or shared with KOReader. This proves server readiness, not plugin authentication.

For UI Login, readiness uses a launcher-owned, in-memory access/refresh token pair obtained through GraphQL login. Protected API calls send the access token as a Bearer header. A rejected access token permits one refresh and one replay; only definite refresh-token rejection permits a new login. Login and refresh carry no old access credentials, and no API redirect is followed. A separate token-free request must be rejected. Tokens are never persisted, printed, or shared with KOReader; launcher readiness does not prove plugin authentication.

```sh
python3 scripts/sandbox.py --root "$ROOT" run reader
```

Wait for **`reader ready`**, which requires authenticated inspector access. In a third terminal, inspect owned-process state:

```sh
python3 scripts/sandbox.py --root "$ROOT" status
```

If SDL display selection is necessary, prefix the reader command with `SDL_VIDEODRIVER=x11` or `SDL_VIDEODRIVER=wayland`, only when that driver and display are available. Keep the existing `DISPLAY` or `WAYLAND_DISPLAY` from the graphical session. The launcher does not create a desktop or display server.

`status` reports running/stopped state, not readiness. A spawned PID, open TCP port, or HTTP acknowledgment alone is not readiness or a successful plugin request. Report startup failure directly. `stop` targets only sandbox-owned services; never stop another application to free a port.

An immediate restart after graceful shutdown can fail with `Requested sandbox port is already in use` while only old `TIME-WAIT` connections remain. Check the configured port with `ss -ltn` for a listener and `ss -tan` for connection state. If there is no listener and the owned service is stopped, wait for those connections to expire and retry the same launch. Do not kill another process or change an existing sandbox's recorded ports to bypass this transient preflight failure.

### Observe and run the single-chapter smoke

From the plugin root, with both services ready and the fresh English-language profile:

```sh
python3 scripts/sandbox.py --root "$ROOT" ui home
python3 scripts/sandbox.py --root "$ROOT" ui observe
python3 scripts/sandbox.py --root "$ROOT" ui tap "Library"
python3 scripts/sandbox.py --root "$ROOT" ui wait "Suwayomi Library"
python3 scripts/sandbox.py --root "$ROOT" ui screenshot "$ROOT/evidence/library.png"
python3 scripts/sandbox.py --root "$ROOT" smoke
```

Use returned labels and titles for further navigation. Smoke follows Library, Sandbox Alpha, Open chapters, and a not-yet-downloaded fixture chapter. It invokes Download, waits for Downloaded, checks exactly one new CBZ and unchanged existing archives, and compares all three PNG pages with the source fixture. It then opens that archive, captures a screenshot, and uses the reader menu's Go to Suwayomi action to return. Inspect the returned evidence and screenshot; invocation alone is not success. This does not cover bulk limits, retention, auth failures, or hardware behavior.

If a bundled fixture chapter remains open after manual checks, close it with:

```sh
python3 scripts/sandbox.py --root "$ROOT" ui close-reader
```

Then shut down the sandbox:

```sh
python3 scripts/sandbox.py --root "$ROOT" stop reader
python3 scripts/sandbox.py --root "$ROOT" stop server
python3 scripts/sandbox.py --root "$ROOT" status
```

`ui close-reader` is a reader transition, not process shutdown. It expects a return to the bundled `Chapter 001`–`003` list; it is not a general document-close helper. For custom fixtures, use observed reader-menu controls to return and verify the intended screen before `stop reader`, which also uses this helper if a document is open. Keep a failed sandbox for diagnosis; starting fresh does not require deleting it.

### Exercise authentication through the actual setup UI

Choose a fresh root with the authentication mode under test, deploy the candidate, and start both services as above. For UI Login, use `setup --auth-mode ui_login`. Then run:

```sh
python3 scripts/sandbox.py --root "$ROOT" auth-smoke
```

This English-profile scenario opens **Settings > Setup wizard**, fills all three visible inputs from the sandbox's private configuration, and visits all three authentication choices before selecting the configured method. It tests a deliberately wrong password, requires the failed setup title and disabled **Continue**, restores the correct password, and requires the real worker's success message and tested title with **Continue** enabled. It dismisses result messages through ordinary widget handlers, continues setup, selects the existing sandbox download directory with **Use this folder > Choose**, and runs the single-chapter smoke above. It saves credentials through the real setup callback, not by editing plugin settings. Run it once per fresh comparison root; like `smoke`, it needs an unused fixture chapter.

For deliberate failed credentials or individual controls, use the observed field hint or its 1-based index:

```sh
python3 scripts/sandbox.py --root "$ROOT" ui home
python3 scripts/sandbox.py --root "$ROOT" ui tap "Settings"
python3 scripts/sandbox.py --root "$ROOT" ui tap "Setup wizard"
python3 scripts/sandbox.py --root "$ROOT" ui fill "Server URL" --credential server_url
python3 scripts/sandbox.py --root "$ROOT" ui fill "Username" --credential username
python3 scripts/sandbox.py --root "$ROOT" ui fill "Password" --credential password --invalid
python3 scripts/sandbox.py --root "$ROOT" ui tap "Test connection"
python3 scripts/sandbox.py --root "$ROOT" ui observe
```

Wait for the final failure message, not the loading message. `ui tap "Dismiss message"` dismisses an ordinary informational popup; it does not dismiss a loading operation. Require the failed setup title and disabled **Continue**. Restore the password with `ui fill "Password" --credential password`, test again, dismiss the success message, and require the tested title before continuing. To change methods, tap the observed **Authentication: Basic Auth**, **Authentication: Simple Login**, or **Authentication: UI Login** button, then the desired method in **Authentication method**. Existing typed fields stay in the connection dialog.

For saved-credential controls, open **Settings > Connection > Login information**, fill the visible fields, choose the method, and tap **Save**. Dismiss its saved message, then use the existing **Test connection** action. Correcting settings does not retry failed downloads: navigate to the failed chapter and invoke its ordinary **Retry** action explicitly. Use `ui observe` between steps rather than assuming a previous dialog remains current.

`ui fill FIELD --stdin` accepts exact text from standard input for other visible single-line inputs, including numeric settings. Supply sensitive text through a private pipe or a Python caller, not command arguments or shell history; a trailing newline is rejected. Do not capture screenshots while any password is revealed. Field observations and fill results omit all input values. Screenshots are raw framebuffer evidence and can still contain visible usernames, endpoints, or revealed passwords.

`auth-smoke` does not establish restart, session expiry, independent concurrent sessions, concurrent download limits, read sync, credential changes during active work, ambiguous mutation failures, or bounded authentication recovery. Exercise those separately using the plugin's ordinary widgets and owned-service `stop`/`run` controls. Launcher sessions are intentionally independent of plugin sessions, so successful seeding cannot establish those contracts.

For a server-restart control, keep the plugin process alive while using `stop server` followed by `run server`, wait for authenticated readiness, then exercise another protected operation. Restart probes tolerate TIME_WAIT sockets but still refuse live listeners. A new plugin process alone cannot prove recovery of an existing cookie. For idle-session behavior without a 30-minute wait, a disposable transport control may send an invalid cookie to the real server; record that as injected session invalidation, not elapsed-time expiry.

For UI Login, a normal server restart can preserve JWT validity. Test access rejection and refresh-token rejection separately, including a refresh timeout/server error that must not trigger login fallback. Use short configured token lifetimes for elapsed-time expiry, or label injected invalid-token controls explicitly. Neither control establishes the other.

## Inspect the UI safely

The repository ships [sandbox_ui.py](../../scripts/sandbox_ui.py) and [sandbox-inspector.lua](../../scripts/sandbox-inspector.lua); machine-local inspector prototypes are no longer prerequisites. Setup installs the patch only into the sandbox profile as `patches/2-sandbox-inspector.lua`. It uses KOReader's bundled HTTP inspector, not a production plugin modification or a separate execution service.

The inspector binds to `127.0.0.1` and requires the private `profile/inspector.token`; its port comes from `profile/inspector.port`. Server credentials live in `secrets.json`. Helpers read these files internally. Do not pass secrets as command arguments, print them, or enable transport logging that records headers. Keep the root private and never expose the inspector to a LAN or the Internet. Verify rejected missing/wrong tokens when changing this boundary.

Prefer `observe` for titles, labels, enabled controls, field hints/indices, and page state. `tap` resolves a unique enabled label, waits for its first paint, then queues the existing widget handler on KOReader's next UI tick. `fill` sends a bounded, authenticated POST only to an observed editable input; it uses the widget's ordinary delete/insert methods and waits for the edit acknowledgment without exposing text. The inspector recognizes a dialog's own virtual keyboard, but never skips unrelated modal windows. Missing, stale, or ambiguous controls are failures. Re-observe after navigation or asynchronous updates. `wait` has a deadline and reports the last observation on failure; a matching title does not establish download completion. Use framebuffer screenshots for layout, clipping, covers, rendered pages, and unexpected dialogs, not after every tap. An empty or unsupported observation needs investigation, not a passing assertion.

The inspector also discovers button layouts nested in visual containers, including ordinary confirmation dialogs. Re-observe the confirmation and activate its exact visible label; do not bypass confirmation callbacks or traverse arbitrary object properties.

Reader transitions can briefly interrupt inspector access. The helper bounds connection-refused retries to a 15-second transition deadline. It also retries connection resets for read-only observations during that interval, but never replays a possibly executed control action. Other network errors are failures.

The inspector's Bearer token is unrelated to Suwayomi authentication and remains mandatory in all server modes. The allowlist does not expose arbitrary Lua evaluation, global-object browsing, settings assignment, or generic method invocation. When changing input controls, verify rejected missing/wrong tokens, stale fields, unsupported routes/methods, and oversized bodies as well as a real dialog edit. These instructions describe required checks, not checks already executed.

### Native reader controls and incomplete observations

The inspector does not expose every widget. Native configuration choices can have empty labels. If a visible control is still missing after re-observation, capture the framebuffer and use the actual visible control through desktop input. Nested confirmation buttons are now observed directly, so try their labels first. Do not bypass confirmation by calling the downloader, or widen the inspector's method allowlist.

For an X11/WSLg session, `xdotool` is an optional input tool. Identify the window by a process whose `/proc/<pid>/environ` contains the exact sandbox `KO_HOME`; matching only the title can select another KOReader session. Send keys to that window, and derive click coordinates from a current screenshot rather than reusing another dialog's coordinates. On the pinned desktop reader, **Return** opens the bottom configuration panel, **Escape** dismisses it, and **Right** advances the reader. Wait for reader initialization after opening, then verify the page change independently.

The generated three-page CBZ can fit entirely on one screen in the default cropped continuous view. Advancing can then show the end-of-document dialog while the reported top page and saved progress remain **1/3**, not 100%. That is not a valid final-page-only control.

For a final-page test:

1. Open the bottom configuration panel and select **View Mode: page** under the page-view icon. Use a screenshot if the choices have empty observed labels.
2. Advance through native input until observation reports `document_page == document_pages`; also inspect the rendered last-page label.
3. Leave the document unfinished and close through **Go to Suwayomi**. Check saved `percent_finished == 1`, non-completed status, plugin/server unread state, and archive presence.
4. For the positive control, reopen and use the native **Mark as finished** action. Check archive protection while open and the configured outcome after close. A completed document can remain downloaded when retention is Off.

Read synchronization is asynchronous. A pending local read entry immediately after close is not a failed server update; wait for the server result and cleared pending state within a bounded deadline.

## Extend the smoke only where needed

Use the actual user path for UI and lifecycle checks. Direct downloader calls cannot establish button wiring. Injected completion flags cannot establish completion-plus-close behavior. Label programmatic preconditions and faults separately from actions under test.

- **Fixtures:** follow [Suwayomi Local source layout](https://github.com/Suwayomi/Suwayomi-Server/blob/master/docs/Local-Source.md). Keep `Sandbox Alpha` and its three chapter names unchanged: every server start seeds and validates that baseline, and the bundled smoke expects it. Create separate fixture series for more than 200 chapters (pagination), at least six eligible chapters (ahead-five refill), more than 50 (bulk limits), or independent A/B/C completions (retention). Record expected identities/order and discover server-assigned IDs. Refresh and seed additional series through supported server operations; setup does not create them. Numbered CBZs alone do not cover scanlator restrictions, tied source order, extension failures, or archive-export fallback.
- **Auth:** check GraphQL and binary covers/pages, rejected credentials, expiry/relogin, workers, and server/credential changes. A passing connection check alone is insufficient.
- **Downloads:** compare admitted IDs with actual workers and jobs. Check CBZ entries/CRC and page bytes against fixtures, not just file existence or a “Downloaded” label. Include Open, visible page, and reader return when relevant.
- **Cleanup/read sync:** compare archives, sidecars/backups, committed state, server read state, and displayed status. Keep final-page-only and completed-plus-close controls distinct.
- **Recovery:** distinguish graceful quit, intentional process termination, worker failure, and network outage. Use controlled sandbox shutdown or scoped fault injection, not damaged storage or interrupted unrelated work.
- **UI:** compare confirmation with actual admissions; inspect stale dialogs, compact sizes, and relevant locales. Successful serialization does not establish readable layout.

Wait for the independent outcome itself. Restore equivalent preconditions and change one factor for comparisons. Stop polling during sleep/standby controls if observation keeps KOReader awake. A check is complete only when the expected UI result agrees with the relevant server, filesystem, and process evidence.

## Hardware and human gaps

Repeat device-sensitive cases on hardware: storage permissions/file identity, OS lifecycle, sleep/wake, real network transitions, touch interaction, and e-ink rendering. Explicit device requirements remain **unverified** until demonstrated or explicitly changed by the maintainer.

For Android, ADB reverse forwarding can connect the device to the sandbox server; ADB forward can expose the device's loopback inspector. Confirm the ADB server's environment and route to Suwayomi. WSL/VM USB attachment or wireless debugging is a separate prerequisite. Other targets can use supported SSH/tunnels or narrowly scoped LAN access to Suwayomi, never a publicly exposed inspector. Record the route actually exercised.

Automate what access permits. Ask a human only to attach/unlock/authorize hardware, perform unavailable physical controls, or judge usability. Supply exact preconditions, steps, expected results, and safe reporting instructions rather than requesting a full manual rerun.

## Record and finish

Use one concise acceptance record, or include the same fields in a routine handoff:

- Requirement/control, expected result, and actual outcome: **demonstrated**, **failed**, or **unverified**. Identify human-reported evidence separately.
- Candidate revision and dirty changes, deployed hash coverage, installed versions, and inspection patches.
- Evidence layer, generic environment, timestamp, fixture aliases, concurrency, navigation, storage availability category, and sleep/network/fault controls.
- Commands actually run, results, relevant artifacts, and remaining gaps. Runtime smoke does not replace repository gates.

Apply AGENTS.md privacy rules before exporting artifacts. Remove credentials, tokens, endpoints, private paths, personal titles, and identifying device details. Keep raw logs, settings, and generated CBZs out of commits. No observed exit means only no exit under the recorded controls; without reproduction, the original crash cause remains unresolved.

Stop owned services and confirm status before removing a sandbox or its access-control patch. Remove throwaway artifacts only from the identified disposable root; retain failed evidence as needed. Report retained roots/processes and restart/stop commands. The tools and profile patch stay outside every release payload.
