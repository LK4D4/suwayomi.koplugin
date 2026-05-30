## ADDED Requirements

### Requirement: Matrix Document Exists
The project SHALL provide a maintained WebUI parity matrix document under `docs/` for Suwayomi WebUI and server capabilities relevant to KOReader workflows.

#### Scenario: Matrix document is added
- **WHEN** the change is implemented
- **THEN** `docs/webui-parity-matrix.md` exists and describes its purpose as a planning reference for future parity work

### Requirement: Matrix Uses Required Columns
The matrix SHALL include columns for WebUI or server capability, current plugin support, KOReader value, API feasibility, device risk, recommended priority, and notes or evidence.

#### Scenario: Required columns are present
- **WHEN** a maintainer opens the matrix document
- **THEN** the matrix includes every required roadmap column with no omitted category

### Requirement: Matrix Is Seeded From Roadmap
The matrix SHALL include the initial high-value rows identified by the roadmap, including source preferences, extension repositories, completed download history, saved searches, in-library browse filtering, duplicate add warning, category changes, chapter bookmarks, library latest updates, tracking, manga migration, server-side download queue, and WebUI reader behavior.

#### Scenario: Initial roadmap rows are represented
- **WHEN** the matrix is reviewed against `docs/superpowers/specs/2026-05-22-plugin-roadmap.md`
- **THEN** each initial high-value row from Priority 2 is represented with a recommended priority

### Requirement: Feasibility Notes Are Evidence-Oriented
Each matrix row SHALL include concise notes or evidence that identify known plugin support, known API feasibility, or follow-up validation needed before implementation.

#### Scenario: Row feasibility is not implicit
- **WHEN** a row has uncertain API support or version-sensitive behavior
- **THEN** the notes identify the uncertainty or required follow-up instead of presenting implementation readiness as guaranteed

### Requirement: KOReader Scope Boundaries Are Explicit
The matrix SHALL explicitly deprioritize or reject parity work that conflicts with KOReader-first product principles, including WebUI reader modes and hidden server-side download side effects.

#### Scenario: Out-of-scope parity is visible
- **WHEN** a maintainer reviews capabilities with low KOReader value or conflicting ownership
- **THEN** the matrix marks them as later, low priority, or not recommended with a reason in the notes

### Requirement: Matrix Remains Documentation-Only
This change SHALL NOT alter runtime Lua behavior, plugin settings, download queue behavior, Suwayomi server state, release payload contents, or localization catalogs.

#### Scenario: Implementation is documentation-only
- **WHEN** the change diff is reviewed
- **THEN** changes are limited to documentation and OpenSpec artifacts
