# Domain docs

This repository uses a single-context layout:
- CONTEXT.md at the repository root is a glossary of domain terminology.
- docs/adr/ holds architectural decision records.
- docs/ARCHITECTURE.md holds the existing module map and boundary guidance.

## When to consult

Consult relevant sections of CONTEXT.md and docs/ARCHITECTURE.md when the task
involves their terminology, ownership, persistence, lifecycle, or module boundaries.
Read relevant ADRs when their decisions govern the change. Small unrelated fixes
do not require reading every domain document.

If CONTEXT.md or docs/adr/ is absent, proceed silently.
Ordinary fixes do not require new domain documentation. Use domain-modeling when
the task calls for resolving terminology or recording architectural decisions.

## Vocabulary and decisions

Use the terminology defined in CONTEXT.md in issues, proposals, and tests.
Identify genuine glossary gaps for domain-modeling.

If a proposal contradicts an ADR, cite the ADR and explain why the decision
should be reconsidered.
