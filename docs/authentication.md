# Authentication

Read this when changing login, transport recovery, credential handling, or authentication tests. [transport.lua](../suwayomi/api/transport.lua) owns the protocols; setup and settings expose an explicit method selector. Basic Auth remains the default for existing configurations. Methods never fall back to one another.

## Credentials and sessions

Username and password remain in the existing settings. Each process owns its session in memory, scoped to server URL, username, password, and authentication method. Cookies and JWTs never enter persistent settings, worker results, or logs. Independent processes may log in separately; no shared session store is needed.

Restarting KOReader causes silent authentication using saved credentials. Editing credentials does not cancel running work: it retains its captured credentials. New attempts use current settings without reusing the old identity's session. Authentication failures leave downloads failed until explicit Retry; pending read sync retains its retry behavior. Queued jobs also obey the [recorded endpoint boundary](ARCHITECTURE.md#download-ownership).

## Recovery and replay

| Method | Session | After definite authentication rejection |
| --- | --- | --- |
| Basic Auth | Credentials sent with each protected request | Report failure; no session renewal |
| Simple Login | Cookie from the form login | One silent login, then at most one replay |
| UI Login | GraphQL access/refresh token pair | One refresh; only definite refresh-token rejection permits one saved-credential login; then at most one replay |

Renew reactively, without predicting expiry from the device clock. Refresh timeouts, network/server errors, or unrecognized responses do not permit login fallback. Login and refresh omit old access credentials; refresh replaces only the access token.

GraphQL may return authentication errors with HTTP 200. Replay requires proof that the pre-resolver guard rejected every unaliased root emitted by the request builder, including both manga-refresh roots. Partial execution, arbitrary errors, and ambiguous mutation failures must not cause replay. Connection tests use protected category access, not public introspection.

External image origins receive no credentials or sessions. Simple Login and UI Login requests do not follow redirects. HTTP remains supported, but HTTPS is recommended: HTTP exposes passwords and session tokens. Issued UI Login tokens can survive a server password change.

## Protocol references

These pinned Suwayomi v2.3.2243 sources explain the transport assumptions. Check them when changing server compatibility; source inspection alone does not establish runtime acceptance.

- [JavalinSetup.kt](https://github.com/Suwayomi/Suwayomi-Server/blob/v2.3.2243/server/src/main/kotlin/suwayomi/tachidesk/server/JavalinSetup.kt): Simple Login uses a session cookie and HTTP 303.
- [UserMutation.kt](https://github.com/Suwayomi/Suwayomi-Server/blob/v2.3.2243/server/src/main/kotlin/suwayomi/tachidesk/graphql/mutations/UserMutation.kt) and [Jwt.kt](https://github.com/Suwayomi/Suwayomi-Server/blob/v2.3.2243/server/src/main/kotlin/suwayomi/tachidesk/global/impl/util/Jwt.kt): login returns both tokens; refresh returns an access token without rotating or extending the refresh token. Token validation does not check current credentials.
- [UserType.kt](https://github.com/Suwayomi/Suwayomi-Server/blob/v2.3.2243/server/src/main/kotlin/suwayomi/tachidesk/server/user/UserType.kt) and [RequireAuthDirectiveWiring.kt](https://github.com/Suwayomi/Suwayomi-Server/blob/v2.3.2243/server/src/main/kotlin/suwayomi/tachidesk/graphql/directives/RequireAuthDirectiveWiring.kt): access uses Bearer authorization; GraphQL guards individual resolvers.
- [ServerConfig.kt](https://github.com/Suwayomi/Suwayomi-Server/blob/v2.3.2243/server/server-config/src/main/kotlin/suwayomi/tachidesk/server/ServerConfig.kt): token lifetimes are configurable, not client-side expiry rules.

## Verification

Use the [testing workflow](agents/testing.md) and [sandbox](sandbox.md) for protocol changes. Cover affected modes through real setup (wrong and corrected credentials), browsing/covers/pages, background transfers, read sync, restart, and independent worker sessions. Check identity isolation and captured-credential behavior. Exercise both renewal paths, persistent rejection, refresh failures, and ambiguous or partial mutation responses. Check that secrets stay out of results, logs, and session storage.

Identify whether expiry used elapsed time, shortened server lifetimes, or injected invalidation. [September 9 acceptance](evidence/authentication-2026-09-09.md) records historical desktop controls and their limits; it is not evidence for a new candidate or Android behavior.
