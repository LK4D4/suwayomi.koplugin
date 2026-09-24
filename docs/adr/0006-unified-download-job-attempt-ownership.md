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

## Evidence and boundaries

The structural acceptance criterion is that callers use queue commands and snapshots instead of inspecting attempt maps. Preserve composed evidence for:

- Stopping reservations, spare-slot scheduling, zero-view execution, and the shared quit budget.
- Matching late publication after cancellation; a rejected cancellation must neither report success nor release ownership.
- Rejected or uncertain completion without repeated transfer or overwritten read choices.
- Inert unsupported startup records, preserved unknown worker files, and atomic refill admission.

Inspection cannot publish an archive generation; manual deletion retains exact-generation checks. These are behavioral contracts of [ADR-0002](0002-navigation-safe-download-ownership.md), [ADR-0003](0003-durable-manual-delete-intent.md), [ADR-0004](0004-durable-download-ahead-refill.md), and [ADR-0005](0005-automatic-download-restart.md), not new state owned by this ADR. Persistence, archive policy, and one-shot scheduling stay separate. This refactor adds no cross-process lock, ownership registry, recovery journal, or user-visible behavior.

A Linux/LuaJIT smoke used two real child processes and synthetic ZIP archives. A canceled attempt retained its slot while another used spare capacity; rejected completion writes retained both attempts; later saves committed both validated archives without another transfer and with zero views. A read-only completion-input control failed before the change and passed afterward. This process and filesystem evidence does not establish physical-device behavior or live-server compatibility. The current [evidence index](../evidence/README.md) routes later observations.
