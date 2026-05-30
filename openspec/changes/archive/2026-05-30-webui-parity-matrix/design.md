## Context

The roadmap marks stability and recovery work complete, then calls for a WebUI parity matrix before implementation of additional parity features. The plugin already has a KOReader-first scope: use KOReader as the reader, prefer device-local CBZ downloads, and avoid hidden server-side side effects.

The matrix is a planning artifact, not a runtime feature. It should live with development documentation and connect future feature proposals to current evidence about WebUI/server capability, plugin support, API feasibility, e-ink/device risk, and recommended priority.

## Goals / Non-Goals

**Goals:**

- Create a maintained matrix document under `docs/` with the roadmap-required columns.
- Seed the matrix with the initial high-value capabilities from the roadmap.
- Include API feasibility and evidence notes so later feature proposals can cite the matrix instead of redoing broad discovery.
- Make unsupported or out-of-scope parity work explicit when it conflicts with KOReader-first product principles.

**Non-Goals:**

- Do not implement any matrix row as runtime behavior in this change.
- Do not add server download queue control, tracking, migration, or reader WebUI parity beyond documenting their status.
- Do not introduce new dependencies or generated API clients.
- Do not require a live Suwayomi server, KOReader install, or local manga library for verification.

## Decisions

1. Store the matrix as `docs/webui-parity-matrix.md`.

   Rationale: this is a durable planning reference for maintainers, not an OpenSpec-only artifact. Keeping it in `docs/` makes it available after the change is archived and keeps the roadmap concise.

   Alternative considered: keep the matrix only in the roadmap. That would make the roadmap too detailed and harder to maintain as evidence changes.

2. Use a Markdown table matching the roadmap columns, plus concise evidence notes.

   Rationale: Markdown is reviewable, portable, and enough for the small initial row set. Evidence notes keep the table actionable without creating a separate database or generated report.

   Alternative considered: create a structured JSON/YAML matrix. That would be useful only if automation exists, and no current workflow needs machine-readable output.

3. Treat API feasibility as documented evidence, not a guarantee.

   Rationale: Suwayomi server GraphQL capabilities may vary by version. The matrix should identify likely feasibility and cite where follow-up schema checks are needed before implementation.

   Alternative considered: block the matrix until every row is verified against a live server schema. That would delay prioritization and add integration requirements to a documentation-only change.

4. Keep priority recommendations KOReader-first.

   Rationale: parity is valuable only when it improves on-device browsing, library organization, downloads, or read-state workflows. WebUI reader modes and server-side download queue control should remain explicitly low or out of scope unless future requirements change.

   Alternative considered: rank by WebUI feature completeness. That would bias work toward parity volume instead of plugin value.

## Risks / Trade-offs

- Matrix becomes stale -> Add source/evidence notes and a maintenance expectation to re-check relevant rows before implementing a feature.
- API feasibility is incomplete without live schema validation -> Mark uncertain rows as requiring schema confirmation rather than overstating support.
- Table gets too wide for Markdown review -> Keep cells concise and move details into notes when needed.
- Documentation-only work is mistaken for implementation readiness -> Make tasks and docs state that each future row still needs its own proposal/design/tests before runtime work.

## Migration Plan

No runtime migration is needed. Add the docs and OpenSpec artifacts, then verify by reviewing the diff.

## Open Questions

- Which Suwayomi server version should be used as the baseline when future implementation work validates API feasibility?
- Should the matrix eventually link each implemented row to its completed OpenSpec change or release note?
