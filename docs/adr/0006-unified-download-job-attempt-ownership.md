---
status: accepted
date: 2026-09-10
---

# Concentrate download job and attempt ownership behind the queue interface

The queue and active-attempt modules previously shared transition knowledge: queue reconstruction and cancellation inspected attempt state, while completion changed pending queue items. Keep one internal owner for pending download jobs, running and stopping download attempts, and completion awaiting persistence. Preserve the existing host-facing queue commands and snapshots; migrate callers that reach into attempt state instead of preserving those internal access paths.

The maintainer confirmed this combined design on 2026-09-10 and subsequently requested implementation. Implemented by the queue owner with private lifecycle methods on the same receiver. The current runtime map remains in [ARCHITECTURE.md](../ARCHITECTURE.md).

## Rationale

Separating pending-job and attempt ownership behind stricter interfaces was considered. It would still require coordination when reconstruction, stopping attempts, and checked completion affect the same chapter. Concentrating that knowledge offers locality without making callers coordinate the transition protocol. Internal files may remain separate; reducing file count is not the goal.

Redesigning the host-facing queue interface was also considered. The demonstrated friction concerns internal state ownership, so changing download controls and other ordinary callers would expand the work without an established benefit. Internal fields and helper methods are not compatibility promises, but observable command and snapshot behavior remains unchanged.

## Completion and inspection

Keep composition of the checked completion transaction in the existing process-owned module. It continues to save queue completion, ledger path, reader-return context, and archive generation together. The download owner requests completion and receives its outcome; only that owner updates download-attempt state. The transaction callback no longer mutates attempt fields, without moving unrelated document knowledge into the download owner. Rejected and uncertain saves preserve the existing ownership and reconciliation behavior.

Keep explicit archive inspection on its separate lifecycle. Inspection observes an existing archive and must not publish a new archive generation. Route shared download ownership and status changes through the download owner, while preserving inspection cancellation, request freshness, and confirmed-exit cleanup. Explicit Redownload remains a download job and is included in the unified owner.

Moving all completion bookkeeping or inspection worker management into the download owner was considered. Both would reduce crossings by broadening its responsibilities, rather than concentrating the download transition protocol that motivated this change.

## Transition execution

Use direct orchestration inside the download owner. It holds pending-job and attempt state, invokes the existing process and persistence adapters, and applies their outcomes. Keep transition logic explicit and private. Preserve the existing persisted representation; this refactor requires neither a migration nor a generic state-machine framework.

A pure transition module with a separate effect executor was considered. It would introduce another instruction protocol and execution-order contract for persistence, worker actions, and notifications. Existing controlled adapters already support failure testing without distributing that coordination across another seam.

## Required behavioral evidence

Exercise the existing queue commands and process-owned download flows with controlled process, clock, and persistence adapters. Preserve composed behavioral tests rather than tests of internal maps or helper identities. The implementation must retain these outcomes:

- Stopping attempts reserve their chapter and concurrency slot until exit is confirmed; unrelated jobs can use spare slots.
- Accepted cancellation preserves a matching late publication and completes checked bookkeeping without another transfer. A rejected cancellation save does not report success or release ownership.
- Rejected or uncertain completion saves retain ownership and archive evidence; reconciliation and completion retry do not repeat the transfer or overwrite newer reading choices.
- Startup and reconciliation preserve retry counts and deadlines, keep unsupported records inert, and do not sweep unknown files.
- Automatic admission and refill consumption remain atomic. Inspection never publishes a new archive generation, and manual deletion retains exact-generation checks.
- Navigation and zero-view execution preserve downloads, and shutdown retains the shared bounded quit behavior.

Locality is the structural acceptance criterion: callers no longer inspect or mutate attempt tables to coordinate cancellation, reconstruction, completion, or archive authority. Internal source files may remain separate. Implementation verification must distinguish composed checks and runtime smoke evidence from unexercised device behavior.

A Linux/LuaJIT smoke exercised two real child processes with synthetic ZIP archives: one canceled attempt retained its slot while the other used spare capacity; rejected completion writes retained both attempts; later saves committed both validated archives without another transfer and with zero views. The original completion implementation failed a read-only-input control; the new implementation passed. Process and filesystem evidence does not establish physical-device behavior or live-server compatibility.

## Constraints

- Preserve [ADR-0002](0002-navigation-safe-download-ownership.md): process-owned downloads, execution without views, completion before notification, and one shared two-second quit budget.
- Preserve [ADR-0003](0003-durable-manual-delete-intent.md): exact archive-generation authority and independent manual-delete intent. Existing download ownership still prevents manual-delete acceptance.
- Preserve [ADR-0004](0004-durable-download-ahead-refill.md): automatic job admission and consumption of the matching refill request remain one checked transaction.
- Preserve [ADR-0005](0005-automatic-download-restart.md): isolated attempts, retry-preserving reconstruction, known stopping reservations, validated publication, and preservation of unknown files. Cancellation does not prove worker exit or prevent every late publication.
- Keep persistence, archive policy, and one-shot request scheduling distinct. Do not add a cross-process lock, ownership registry, recovery journal, or new user-visible behavior.
- Preserve composed behavioral evidence. Tests must not make raw internal maps or helper identities part of the host-facing interface.
