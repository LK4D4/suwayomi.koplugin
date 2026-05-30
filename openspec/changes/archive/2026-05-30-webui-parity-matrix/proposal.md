## Why

The roadmap calls for a WebUI parity matrix before adding more feature-parity work so future features are chosen deliberately rather than copied wholesale from WebUI. Capturing current plugin support, KOReader value, API feasibility, device risk, and evidence will make the next implementation slices easier to prioritize and review.

## What Changes

- Add a maintained WebUI parity matrix document for Suwayomi WebUI and server capabilities relevant to KOReader workflows.
- Seed the matrix with the roadmap's high-value rows and evidence-oriented fields.
- Record API feasibility notes and source references for each row where available.
- Keep non-KOReader or risky WebUI parity work explicitly deprioritized.
- No runtime behavior changes.

## Capabilities

### New Capabilities

- `webui-parity-matrix`: Documents and maintains a decision matrix for WebUI/server parity candidates, including plugin support, KOReader value, API feasibility, device risk, priority, and evidence.

### Modified Capabilities

None.

## Impact

- Adds OpenSpec documentation for the matrix capability.
- Adds or updates development documentation under `docs/` for the maintained parity matrix.
- Uses existing roadmap context in `docs/superpowers/specs/2026-05-22-plugin-roadmap.md`.
- Does not affect runtime Lua modules, plugin packaging, settings, downloads, or Suwayomi server state.
