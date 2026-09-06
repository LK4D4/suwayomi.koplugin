# Domain docs

This repository uses a single-context layout:
- CONTEXT.md at the repository root holds domain terminology.
- docs/adr/ holds architectural decision records.
- docs/ARCHITECTURE.md holds the existing module map and boundary guidance.

## Before exploring

Read CONTEXT.md when present and ADRs relevant to the work.
Read docs/ARCHITECTURE.md for module ownership and architecture.

If CONTEXT.md or docs/adr/ is absent, proceed silently.
Create domain documentation lazily through domain-modeling when terminology
or decisions are resolved.

## Vocabulary and decisions

Use the terminology defined in CONTEXT.md in issues, proposals, and tests.
Identify genuine glossary gaps for domain-modeling.

If a proposal contradicts an ADR, cite the ADR and explain why the decision
should be reconsidered.
