# Testing workflow for agents

Use this guide before planning verification, running integration/UI/device checks, or handing off manual QA. [AGENTS.md](../../AGENTS.md) owns repository checks, worktrees, and data safety. The [test strategy](../ARCHITECTURE.md#test-strategy) maps isolated coverage. Use the [sandbox runbook](../sandbox.md) only for live server or KOReader work, and the [feature recipes](../testing-recipes.md) when their behavior is in scope. [Dated evidence](../evidence/README.md) records earlier candidates; it is context, not a pass for a new candidate.

## Select evidence

For each requirement, write down the precondition, user action or injected fault, independently observable outcome, and environment. Choose the narrowest layers that establish the changed behavior:

| Layer | Establishes | Limit |
| --- | --- | --- |
| Isolated LuaJIT specs | Deterministic selection, state transitions, and failure boundaries | No real server or KOReader lifecycle |
| Plugin with a real server | GraphQL, authentication, binary responses, parsing, and transfers | No menu wiring, reader transition, or device behavior |
| Desktop KOReader with a real server | Actual menus, workers, reading, persistence, navigation, and restart | No Android permissions, physical sleep/wake, or e-ink usability |
| Target device | Platform behavior under recorded controls | No claim about untested devices, routes, or crash causes |

Ordinary specs stay offline, without a server, KOReader install, or personal library. Run sandbox checks only when a real integration or UI question warrants them. Follow the LuaJIT command in [AGENTS.md](../../AGENTS.md#tests-and-commands); plain Lua 5.1 lacks `ffi` and misses native archive and durable-storage boundaries.

## Run the relevant path

Use the normal widget path for UI claims. A direct downloader call cannot establish that its button works; an injected completion flag cannot establish native completion and close. Label fixture edits and injected faults as preconditions, and distinguish them from the user action being tested. Compare the outcome with independent server, filesystem, saved-state, and process evidence. A matching title or successful tap is insufficient to prove a download or rendered page.

When navigation or entry behavior is in scope, open **KOReader Search > Suwayomi** natively and check the destination and return path. The sandbox's `ui home` and `auth-smoke` helpers enter the plugin directly, so neither proves the native Search entry. Use [sandbox UI controls](../sandbox.md#inspect-the-ui-safely) for the rest of the flow; use [feature recipes](../testing-recipes.md) for endpoint read sync, Library/chapter cache, and related controls.

Keep comparisons controlled: restore equivalent preconditions, change one factor, and record the precise response or fault. Do not count graceful shutdown as power loss, an owned-server stop as a physical network transition, or a fault patch as exhausted storage. Let asynchronous read synchronization settle within a bounded deadline before judging it. During sleep/standby checks, avoid polling that wakes the reader.

## Hardware and human gaps

Repeat device-sensitive requirements on hardware: permissions and file identity, OS lifecycle, sleep/wake, real network transitions, touch behavior, and e-ink rendering. ADB reverse forwarding can route a device to a disposable server; ADB forward can expose its loopback inspector. Record the actual USB, Wi-Fi, SSH, or other route. USB connectivity does not establish Wi-Fi behavior. Keep the inspector loopback-bound and authenticated; never publish it. Ask a human only for physical attachment, unlock/authorization, unavailable physical controls, or usability judgment. Provide exact preconditions, steps, expected results, and safe reporting instructions.

## Record and finish

Record the requirement and expected/actual result as **demonstrated**, **failed**, or **unverified**. Include candidate revision and dirty changes, deployed hash coverage, installed versions, evidence layer, timestamp, fixture aliases, relevant concurrency and fault controls, commands actually run, artifacts, and remaining gaps. Mark human-reported observations separately. Automated, desktop, and device evidence each retain their own scope; unrun cases are not passes. No observed crash under a control does not establish the cause of an earlier crash.

Keep credentials, tokens, endpoints, private paths, source names, titles, raw logs/settings, generated CBZs, and identifying device details out of committed evidence. Redact exported observations and screenshots. Stop owned services, verify their status, and restore temporary device/profile changes. Remove throwaway artifacts only from the identified disposable root, retaining failed evidence for diagnosis. Report retained roots and processes; the sandbox inspector patch remains outside release payloads.

For release upgrade workflows, use the opt-in [upgrade acceptance command](../upgrade-acceptance.md). Keep automated, desktop, and Palma results separate; preserve first-attempt failures.
