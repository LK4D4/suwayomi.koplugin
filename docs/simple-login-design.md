# Simple Login

Status: the maintainer confirmed Q1–Q6 and authorized implementation and laptop verification on 2026-09-09.

## Agreed behavior

- **Q1 — Selection:** Offer an explicit Basic Auth / Simple Login selector in setup and settings. Existing configurations remain on Basic Auth. Do not detect or fall back between authentication methods automatically.
- **Q2 — Persistence:** Save the username and password through the existing credentials settings. Never persist the session cookie. After KOReader restarts, authenticate silently when a server request needs a session; do not ask for credentials again unless the saved credentials fail.
- **Q3 — Session rejection:** After a definite authentication rejection, attempt one silent login and retry the rejected request once. Report further failure through the existing operation UI. Do not replay mutations after ambiguous network failures.
- **Q4 — Process ownership:** Each process may maintain and reuse its own in-memory cookie. Extra silent logins are acceptable. Do not introduce a shared cookie file or cross-process session coordinator. Verify that independent logins coexist on the supported server release.
- **Q5 — Failed downloads:** Authentication failures leave downloads failed. Correcting saved credentials does not automatically restart failed downloads; the user uses the existing Retry action. Pending read sync retains its existing retry behavior.
- **Q6 — Connection edits during active work:** Running work finishes or fails using its captured credentials when the username, password, or authentication method changes. New attempts use the updated settings and must not reuse cookies from the old credentials. Do not add cancellation machinery for these edits. Cookies must also remain scoped to the server.

## Verification requirements

Follow [the testing workflow](agents/testing.md). Acceptance requirements:

- Preserve the existing Basic Auth workflow and saved configuration behavior.
- Exercise Simple Login through the actual setup UI, browsing, covers, chapter pages, background downloads, and read sync against the isolated sandbox.
- Verify silent login after KOReader restart, rejected credentials, session expiry, server restart, and independent concurrent sessions.
- Verify the agreed retry bound and that ambiguous mutation failures do not trigger authentication replay.
- Verify server and credential changes cannot reuse a cookie from a different connection identity.
- Verify failed downloads require Retry after credentials are corrected and pending read sync is preserved.
- Verify credential edits do not interrupt already-running work, while new attempts use the updated credentials.
- Keep passwords and cookies out of logs, result files, and persistent session storage. Existing saved credential settings remain intentional.

## Documentation scope

No new glossary entry is needed: the agreed terms are general authentication concepts rather than new project-specific domain concepts. These reversible choices do not justify an ADR. The implemented ownership and boundaries are recorded in [the architecture reference](ARCHITECTURE.md).

## Protocol evidence

The [Suwayomi v2.3.2243 login handler](https://github.com/Suwayomi/Suwayomi-Server/blob/v2.3.2243/server/src/main/kotlin/suwayomi/tachidesk/server/JavalinSetup.kt) uses a per-session `logged-in` attribute and returns a cookie with HTTP 303. GraphQL reports resolver authentication errors with HTTP 200; transport recovery recognizes the pre-resolver guard only for the plugin's single-root operations and refuses ambiguous or partial replay.

## Laptop acceptance

Exercised with Suwayomi v2.3.2243 and KOReader v2026.07.1 under Ubuntu WSLg, using isolated Basic Auth and Simple Login profiles and generated three-page CBZs. Deployment manifests and raw evidence remain private sandbox data.

- Both authentication modes passed actual setup field entry, method selection, wrong-password rejection, disabled continuation after rejection, corrected credentials, and successful continuation.
- Both modes passed UI download, exact source-page byte comparison, Open, visible page rendering, and Go to Suwayomi return.
- Simple Login loaded the library after a KOReader restart without a credential prompt. A separate live plugin process retained an old session across an actual server restart and recovered with exactly one new login.
- Live plugin API calls recovered from controlled invalid-session cookies for GraphQL read-state mutation and binary pages. This exercises real server rejection and recovery; a wall-clock 30-minute idle expiry was not waited out.
- A temporary loopback timing proxy held two real download workers while a third chapter remained queued. Editing the saved password did not interrupt the two captured-credential workers. The newly launched third job failed authentication. Correcting the saved password left that job failed until the user-facing Retry action completed it. All nine downloaded pages matched their generated fixtures.
- The user-facing Mark as read action updated the server. Mark as unread during a controlled server outage persisted one pending sync entry. After the server restarted, automatic sync updated the server and cleared that entry without another user action.
- Inspector probes rejected missing/wrong tokens, arbitrary controls, stale fields, and oversized input. The port check rejected an active listener and accepted stopped-service TIME_WAIT sockets. Actual confirmation buttons were observed and activated through the inspector.
- Private server/reader logs contained no saved password, inspector token, or session cookie; plugin settings contained no session cookie.

Desktop evidence does not establish Android permissions, sleep/wake behavior, or e-ink usability. These platform checks are not claimed.
