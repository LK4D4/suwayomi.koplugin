# UI Login

Status: implemented and laptop-verified. The maintainer confirmed Q1–Q6 on 2026-09-09.

## Scope

Design support for Suwayomi's `ui_login` authentication method alongside the existing Basic Auth and Simple Login methods. Native username/password login uses GraphQL and does not require a browser.

## Agreed behavior

- **Q1 — Persistence:** Save the username and password through the existing credentials settings. Keep access and refresh tokens in memory only. Authenticate silently after KOReader restarts or when an expired refresh token requires a new login. Do not require credential entry again unless the saved credentials fail.
- **Q2 — Transport policy:** Preserve HTTP support, with documented guidance to use HTTPS. Do not add mandatory HTTPS or a new warning dialog for this method. HTTP exposes passwords and bearer tokens to network observers; refresh tokens can remain usable after a server password change.
- **Q3 — Acceptance environment:** Require an isolated Suwayomi server and the actual KOReader UI on the laptop. Cover setup, browsing, covers and chapter pages, background downloads, read sync, restart, expiry, and concurrent workers. Android device acceptance is not required for this change; Android permissions, sleep/wake behavior, and e-ink usability remain unclaimed.
- **Q4 — Renewal and replay:** Renew reactively after a definite authentication rejection rather than predicting expiry from the device clock. Attempt one refresh; if the refresh token is definitively rejected, attempt one login with the saved credentials. Replay the original protected operation at most once, after recovery succeeds. A timeout, network failure, or server error during refresh is not permission to fall back to login. Never replay mutations after ambiguous network failures or partial GraphQL execution.
- **Q5 — Process ownership:** Give each process its own in-memory token pair, scoped to the server URL, username, password, and authentication method. Accept extra silent logins rather than introduce shared token storage or cross-process coordination. Verify that independent logins coexist on the supported server release.
- **Q6 — Existing interaction contract:** Add an explicit UI Login choice in setup and settings, preserving Basic Auth as the default and avoiding automatic method detection or fallback. Keep failed downloads failed until explicit Retry after credentials are corrected; retain the existing pending read-sync retry behavior. Running work uses captured credentials and finishes or fails without forced cancellation; new attempts use updated credentials without reusing tokens from the old connection identity.

## Protocol evidence

The following findings come from source inspection of Suwayomi v2.3.2243, the sandbox's pinned server release. They are not runtime acceptance evidence.

- [UserMutation.kt](https://github.com/Suwayomi/Suwayomi-Server/blob/v2.3.2243/server/src/main/kotlin/suwayomi/tachidesk/graphql/mutations/UserMutation.kt): GraphQL `login` returns `accessToken` and `refreshToken`; `refreshToken` returns a new access token only. Login must not carry an existing valid access token.
- [Jwt.kt](https://github.com/Suwayomi/Suwayomi-Server/blob/v2.3.2243/server/src/main/kotlin/suwayomi/tachidesk/global/impl/util/Jwt.kt): refresh does not rotate or extend the refresh token. Validation does not check the current username or password, so changing credentials does not invalidate issued tokens. No per-session revocation mechanism was found in the inspected authentication implementation.
- [ServerConfig.kt](https://github.com/Suwayomi/Suwayomi-Server/blob/v2.3.2243/server/server-config/src/main/kotlin/suwayomi/tachidesk/server/ServerConfig.kt): access and refresh lifetimes default to five minutes and sixty days, respectively, but are configurable. These defaults are not client-side expiry rules.
- [UserType.kt](https://github.com/Suwayomi/Suwayomi-Server/blob/v2.3.2243/server/src/main/kotlin/suwayomi/tachidesk/server/user/UserType.kt): protected HTTP requests accept `Authorization: Bearer <accessToken>`. Refresh tokens are not access credentials.
- [RequireAuthDirectiveWiring.kt](https://github.com/Suwayomi/Suwayomi-Server/blob/v2.3.2243/server/src/main/kotlin/suwayomi/tachidesk/graphql/directives/RequireAuthDirectiveWiring.kt): GraphQL authorization checks individual resolvers. Authentication errors can arrive in an HTTP-200 GraphQL response; an arbitrary error or one rejected field cannot establish that replaying the entire operation is safe.

## Verification requirements

Follow [the testing workflow](agents/testing.md). The acceptance requirements are:

- Preserve the existing Basic Auth and Simple Login workflows and saved configurations. Exercise explicit UI Login selection, incorrect credentials, corrected credentials, and successful setup through the actual UI.
- Exercise browsing, covers, chapter pages, background downloads, and read sync against the isolated server.
- Verify silent login after KOReader restart. Exercise server restart separately; surviving JWTs need not trigger login.
- Verify a rejected access token triggers one refresh and at most one replay. Verify a definitively rejected refresh token triggers one saved-credential login before that replay. Further rejection must stop recovery.
- Verify refresh timeouts, network failures, and server errors do not trigger login fallback. Verify ambiguous mutation failures and partial GraphQL execution do not trigger replay.
- Verify independent concurrent process sessions coexist and tokens cannot cross server, credential, or authentication-method boundaries.
- Verify credential edits do not cancel running work, while new attempts use updated settings. Verify failed downloads require explicit Retry after correction and pending read sync remains recoverable.
- Keep passwords and tokens out of logs, worker results, and persistent session storage. Existing saved credential settings remain intentional.
- Record whether expiry is exercised through elapsed time, short configured lifetimes, or injected invalidation. Do not report injected invalidation as elapsed-time expiry.

## Laptop acceptance

Exercised on 2026-09-09 with Suwayomi v2.3.2243 and KOReader v2026.07.1 under Ubuntu WSLg. Three isolated profiles used Basic Auth, Simple Login, and UI Login with generated fixtures. All 98 deployed payload files matched the candidate after the checks; deployment manifests and raw screenshots remain private sandbox evidence.

- All three modes passed actual setup field entry, selection through all three methods, wrong-password rejection, disabled Continue after rejection, corrected credentials, and successful continuation. Each downloaded a chapter with all three PNG pages byte-identical to its source, opened the exact archive, visibly rendered the pages, and returned through Go to Suwayomi.
- UI Login displayed the checked selector without clipping, loaded the library with its cover, and browsed Local source's Popular results. An actual KOReader restart loaded the library without a credential prompt.
- A live plugin process retained its JWT across an actual server restart without another login. Two independent plugin processes logged in concurrently and continued using their sessions.
- Live plugin API calls recovered from controlled invalid access tokens for a read-state mutation, two-root manga refresh, and binary page fetch. Controlled refresh-token rejection triggered one silent login. A persistent rejection stopped after one protected-request replay. Injected refresh timeout and HTTP 503 did not trigger login fallback.
- A real mutation executed before an injected lost response was not replayed. Isolated transport specs cover partial GraphQL execution, malformed refresh responses, identity/origin isolation, and replacement of rejected archive bytes.
- With the disposable server configured for a two-second access lifetime and six-second refresh lifetime, elapsed access expiry caused one refresh without login; elapsed refresh expiry caused one refresh attempt followed by one login. Default lifetimes were restored afterward.
- A loopback timing proxy held two real download workers while a third chapter remained queued. Editing the saved password left both captured-credential workers able to finish. The third job failed authentication with the new settings, remained failed after correction, and completed only after the explicit Retry action. All nine pages matched the generated source bytes.
- Native Mark as read updated the server. Native Mark as unread during a server outage persisted pending sync; after restart, automatic sync updated the server and cleared the pending entry.
- Private server/reader logs contained no saved password, inspector secret, or JWT. Plugin settings contained no JWT or token fields. Disposable probe scripts were removed and all owned services were stopped.

An earlier exploratory fixture download returned the server's `Chapter page not found` error; explicit Retry succeeded. No authentication fallback or code change was used to hide that source error.

Desktop evidence does not establish Android permissions, sleep/wake behavior, or e-ink usability. These platform checks are not claimed.

## Documentation boundaries

The [Simple Login design](simple-login-design.md) records the existing interaction contract; Q5–Q6 explicitly extend its process ownership and interaction rules to UI Login. The glossary remains unchanged because the terms discussed are general authentication concepts, not new project-specific domain terms. No ADR is needed: these choices do not introduce a hard-to-reverse architectural commitment.
