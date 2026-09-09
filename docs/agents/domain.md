# Domain docs

Consult only the references relevant to the change:

- [CONTEXT.md](../../CONTEXT.md): domain vocabulary for code, issues, and tests. Keep it a glossary, not an implementation plan.
- [ARCHITECTURE.md](../ARCHITECTURE.md): current module ownership and runtime boundaries; check source/specs when behavior matters.
- [ADRs](../adr/): accepted decisions and their rationale. Read the governing record and its amendments for ownership, persistence, or lifecycle changes.
- GitHub Issues: requested scope, current work status, maintainer clarifications, and acceptance evidence. Read comments as well as the original body.

An accepted ADR records a decision, not proof of implementation or device acceptance. Explicit later amendments supersede the affected older clauses, not unrelated safeguards. If source and the current contract disagree, report the discrepancy rather than rewriting the contract to bless existing behavior.

Retired plans, audits, and feature specs remain in Git history. Consult them only for relevant historical context; old checkboxes, branch instructions, and mirrored issue statuses are not current authority. Reconcile them with later decisions and issue comments before acting.

Ordinary fixes need no new domain document. Update a glossary term or ADR only when terminology or an architectural decision actually changes; explain any proposed departure from an accepted decision.
