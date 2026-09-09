---
status: accepted
date: 2026-09-06
revised: 2026-09-07
---

# Keep one download queue through reader navigation

Implemented: this record owns process-level navigation and bounded quit. [ADR-0005](0005-automatic-download-restart.md) supersedes the original terminal-interruption startup policy and shared temporary files with automatic restart and isolated, validated attempts. Use [ARCHITECTURE.md](../ARCHITECTURE.md#download-ownership) for the current runtime map.

## Problem

At `01ed3e3`, each plugin instance cached and recovered its own queue. FileManager–ReaderUI navigation could recover persisted work while another host's workers still ran. The original investigation for [#2](https://github.com/LK4D4/suwayomi.koplugin/issues/2), preserved in Git history, records the maintainer's download-reset observation; it does not establish an application-crash cause.

## Decision

- One small process-owned service wraps the existing queue, scheduler, downloader, and KOReader `ffi/util` helper. FileManager and ReaderUI attach disposable view subscriptions. Navigation, screen/document close, and sleep/wake neither create nor recover another queue.
- Downloads and completion bookkeeping continue with zero plugin views while the main loop runs. Commit queue completion, ledger path, and reader-return context through the checked shared store before notifying views. Retry a failed completion save in-session without another transfer. Detached views receive no callbacks; reopened views read current state.
- Retain known stopping workers and their chapter/file associations until the helper confirms exit. They still count toward concurrency. A queue failure/removal does not prove child termination; defer temporary cleanup and replacement launch, preserving final CBZs.
- Use one idempotent `UIManager.quit` wrapper that preserves the previous method. Stop admission/timers and attempt to stop known children within one total two-second budget, with no final save or required future tick. Closing a screen is not quitting KOReader.
- Preserve retry classification/counts/deadlines, directory captured at admission, current credentials at each attempt, source-scoped local downloads, and the checked store's ambiguity fence/reconciliation. Navigation or wake spends no retry. Lowering concurrency lets current workers finish before replacement.

## Limits and superseded alternatives

This is current-process coordination, not cross-process exclusion. Abrupt death may leave an untracked child; a PID, queue state, or missing progress cannot establish its lifetime. Keep unknown files. Hot reload and simultaneous writable KOReader processes are unsupported. ADR-0005 owns the resulting late-publication and legacy-worker limits.

The earlier mandatory-reboot, storage-relocation, inherited-lock, and publication-journal approach was rejected. The old startup rule requiring explicit retry is also superseded; do not restore it from historical plans. Manual-delete identity and refill have their own decisions, not implied guarantees supplied by this service.

## Evidence and history

[#5](https://github.com/LK4D4/suwayomi.koplugin/issues/5) records implementation; [#11](https://github.com/LK4D4/suwayomi.koplugin/issues/11) records device acceptance. Read their comments and later acceptance records rather than treating this ADR as a checklist of unimplemented work. Superseded #6–#10 were not completed implementations.

The rejected `codex/ownership-5-10` implementation and original host/helper analysis remain historical references in Git and the investigation. They are not ready-to-apply patches or current lock/recovery requirements. Automated composition tests and device observations remain distinct evidence.
