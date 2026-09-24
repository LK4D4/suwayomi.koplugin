# Authentication acceptance — 2026-09-09

Historical desktop evidence for Simple Login and UI Login, consolidated from their original design notes. Environment: Suwayomi v2.3.2243, KOReader v2026.07.1, Ubuntu WSLg, isolated profiles, and generated three-page CBZs. The notes did not identify candidate commit hashes; exact-current-commit coverage cannot be inferred. UI Login acceptance reported all 98 deployed payload files matching its candidate. Raw manifests, logs, and screenshots remained private sandbox data.

| Control | Recorded result |
| --- | --- |
| Setup and normal reading | Basic Auth, Simple Login, and UI Login passed real field entry, method selection, wrong-password rejection, disabled continuation, correction, download, exact source-page comparison, visible rendering, and Go to Suwayomi return. Wrong-method probes failed without fallback. |
| Restart and independent sessions | KOReader restart loaded Library without another credential prompt. Simple Login recovered an old session after server restart with one login. UI Login retained a JWT across server restart; two independent plugin processes remained usable. |
| Simple Login recovery | Invalid-session cookies triggered recovery for read-state mutation, two-root manga refresh, and binary pages. Both refresh roots were rejected before one login and one successful replay. Wall-clock 30-minute idle expiry was not exercised. |
| UI Login recovery | Invalid access tokens caused refresh; rejected refresh tokens caused one login; persistent rejection stopped after one replay. Injected refresh timeout and HTTP 503 did not cause login fallback. |
| UI Login elapsed expiry | Disposable two-second access and six-second refresh lifetimes exercised elapsed expiry: refresh alone, then refresh followed by login. Defaults were restored. |
| Mutation uncertainty | A real mutation followed by an injected lost response was not replayed. Partial execution, malformed refresh responses, origin isolation, and replacement of rejected archive bytes had isolated-spec coverage. |
| Credential changes during work | Two held download workers finished with captured credentials. A queued third job failed with edited credentials, stayed failed after correction, then completed through Retry. All nine pages matched source bytes. |
| Read sync | Native Mark as read updated the server. Mark as unread during outage persisted pending sync; automatic sync applied it and cleared the entry after reconnect. |
| Inspector and privacy | Missing/wrong inspector tokens, arbitrary controls, stale fields, and oversized input were rejected. Live listeners blocked startup; stopped-service TIME_WAIT sockets did not. Logs contained no saved passwords, inspector secrets, cookies, or JWTs; plugin settings contained no session tokens. |

An exploratory UI Login fixture download returned `Chapter page not found`; explicit Retry succeeded without authentication fallback. Disposable probes were removed and owned services stopped.

These controls do not establish Android permissions, sleep/wake, or e-ink usability. The current [authentication contract](../authentication.md) and [testing workflow](../agents/testing.md) govern new work. Original detailed reports remain in Git history under `docs/simple-login-design.md` and `docs/ui-login-design.md` at `0d5b8a4`.
