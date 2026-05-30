## 1. Evidence Review

- [x] 1.1 Review the roadmap Priority 2 row list and required matrix columns.
- [x] 1.2 Review current README and architecture docs for existing plugin support notes relevant to each matrix row.
- [x] 1.3 Check available Suwayomi WebUI/server documentation or schema references for API feasibility notes, marking uncertain rows as requiring follow-up when not directly verified.

## 2. Matrix Documentation

- [x] 2.1 Create `docs/webui-parity-matrix.md` with a short purpose statement and maintenance guidance.
- [x] 2.2 Add a Markdown matrix with columns for capability, plugin support, KOReader value, API feasibility, device risk, recommended priority, and notes or evidence.
- [x] 2.3 Seed the matrix with every initial Priority 2 roadmap row.
- [x] 2.4 Mark out-of-scope or low-value parity work explicitly, including WebUI reader behavior and hidden server-side download queue control.

## 3. Verification

- [x] 3.1 Review the diff to confirm the implementation is documentation-only and does not alter runtime Lua, settings, downloads, localization, or release payload behavior.
- [x] 3.2 Verify the matrix covers every requirement in `openspec/changes/webui-parity-matrix/specs/webui-parity-matrix/spec.md`.
- [x] 3.3 Run or record the appropriate docs-only verification, with Lua lint/tests skipped unless runtime or command behavior changes.
