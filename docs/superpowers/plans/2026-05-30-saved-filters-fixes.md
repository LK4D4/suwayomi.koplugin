# Saved Filters Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix saved-filter save/load behavior, expose useful saved-filter failure details, and complete saved-filter translations for Russian, Ukrainian, and Simplified Chinese.

**Architecture:** Keep saved filters in Suwayomi source metadata and keep the UI flow already added on `codex/saved-filters-spec`. Align the metadata key with WebUI (`webUI_savedSearches`), preserve the existing draft/filter normalizer, and only add user-facing error detail after sanitizing the server error into a short message. Do not touch Traditional Chinese in this pass.

**Tech Stack:** LuaJIT / Lua 5.1, dkjson, Suwayomi GraphQL, KOReader gettext catalogs, `busted`, `luacheck`, gettext tools.

---

## Investigation Findings

- Worktree: `C:\Users\lk4d4\projects\suwayomi.koplugin\.worktrees\saved-filters-spec` on `codex/saved-filters-spec`.
- Current branch tests pass for saved-filter files, so failures are behavioral gaps, not syntax failures:
  - `busted spec\suwayomi_api_spec.lua spec\suwayomi_api_queries_spec.lua spec\suwayomi_api_parsers_spec.lua spec\suwayomi_source_filters_spec.lua spec\suwayomi_client_source_manga_spec.lua spec\suwayomi_ui_browse_spec.lua`
  - `bash ./scripts/check-l10n.sh`
- Suwayomi Server current master has `source.meta` and `setSourceMetas`; `Long` maps to `LongString`, so string source IDs in GraphQL variables are valid.
- Suwayomi WebUI stores saved source searches under metadata key `webUI_savedSearches`, not bare `savedSearches`. Current branch reads and writes bare `savedSearches`, so it is not WebUI-compatible and can appear empty even when WebUI has saved entries.
- Saved-filter failure UI discards non-unsupported errors in `SuwayomiClient:showSavedFilterFailure`. That is why users see only `Could not save saved filter.` or `Could not load saved filters.` with no reason.
- `Save filter` and `Saved filters` are fuzzy in `ru`, `uk`, and `zh_CN`; `msgfmt` omits fuzzy strings from `.mo` catalogs, so runtime falls back to English. `zh_TW` is intentionally skipped for now.
- Russian source filter title uses `msgid "%1 filters"` -> `msgstr "%1 фильтров"`, producing `Atsumaru фильтров`. It should be `Фильтры Atsumaru`. Ukrainian should use the same source-name-after-noun pattern.

## File Structure

- `suwayomi/client/source_manga.lua`: saved-filter metadata key, saved-filter load/save/delete failure formatting, saved-filter UI orchestration.
- `suwayomi/api/queries.lua`: GraphQL metadata write key.
- `spec/suwayomi_api_queries_spec.lua`: verifies saved-filter metadata mutation uses WebUI-compatible key.
- `spec/suwayomi_api_spec.lua`: verifies facade fetch/update flow with WebUI-compatible metadata.
- `spec/suwayomi_client_source_manga_spec.lua`: verifies saved-filter load/save/delete uses the WebUI metadata key and reports detailed failures.
- `docs/superpowers/specs/2026-05-30-saved-filters-design.md`: correct design notes from `savedSearches` to `webUI_savedSearches`.
- `l10n/ru/suwayomi.po`, `l10n/uk/suwayomi.po`, `l10n/zh_CN/suwayomi.po`: saved-filter translations and fuzzy-flag removal.
- `l10n/ru/suwayomi.mo`, `l10n/uk/suwayomi.mo`, `l10n/zh_CN/suwayomi.mo`: compiled runtime catalogs.

---

### Task 1: Use WebUI Saved-Search Metadata Key

**Files:**
- Modify: `suwayomi/client/source_manga.lua`
- Modify: `suwayomi/api/queries.lua`
- Modify: `spec/suwayomi_api_queries_spec.lua`
- Modify: `spec/suwayomi_api_spec.lua`
- Modify: `spec/suwayomi_client_source_manga_spec.lua`
- Modify: `docs/superpowers/specs/2026-05-30-saved-filters-design.md`

- [ ] **Step 1: Write failing API query test**

In `spec/suwayomi_api_queries_spec.lua`, update the saved-search mutation expectation so it fails while code still writes bare `savedSearches`:

```lua
assert.are.same({
    input = {
        items = {
            {
                sourceIds = { "2499283573021220255" },
                metas = {
                    { key = "webUI_savedSearches", value = '{"One":{}}' },
                },
            },
        },
    },
}, mutation_payload.variables)
```

Run:

```powershell
busted spec\suwayomi_api_queries_spec.lua
```

Expected: FAIL showing expected key `webUI_savedSearches` but actual key `savedSearches`.

- [ ] **Step 2: Write failing facade and client tests**

In `spec/suwayomi_api_spec.lua`, change saved-filter response fixtures and assertions:

```lua
body = [[{"data":{"source":{"id":"s1","meta":[{"key":"webUI_savedSearches","value":"{\"One\":{\"query\":\"frieren\",\"filters\":[]}}"}]}}}]],
```

```lua
body = [[{"data":{"setSourceMetas":{"metas":[{"key":"webUI_savedSearches","value":"{\"Two\":{}}","sourceId":"s1"}]}}}]],
```

```lua
assert.are.equal("webUI_savedSearches", fetched.meta[1].key)
assert.truthy(request.bodies[2]:match("webUI_savedSearches"))
```

In `spec/suwayomi_client_source_manga_spec.lua`, update saved-filter metadata fixtures:

```lua
meta = {
    {
        key = "webUI_savedSearches",
        value = [[{"Favorite":{"query":"old","filters":[]}}]],
    },
}
```

Apply the same key to fixtures for apply and delete tests.

Run:

```powershell
busted spec\suwayomi_api_spec.lua spec\suwayomi_client_source_manga_spec.lua
```

Expected: FAIL while production code still searches for bare `savedSearches`.

- [ ] **Step 3: Change production metadata key**

In `suwayomi/client/source_manga.lua`, change:

```lua
local SAVED_SEARCHES_META_KEY = "savedSearches"
```

to:

```lua
local SAVED_SEARCHES_META_KEY = "webUI_savedSearches"
```

In `suwayomi/api/queries.lua`, add near the top:

```lua
local SAVED_SEARCHES_META_KEY = "webUI_savedSearches"
```

Then change `_buildSetSourceSavedSearchesMutation`:

```lua
key = SAVED_SEARCHES_META_KEY,
```

- [ ] **Step 4: Correct design doc**

In `docs/superpowers/specs/2026-05-30-saved-filters-design.md`, replace statements saying WebUI stores `savedSearches` directly with `webUI_savedSearches`.

Use this wording in the context section:

```markdown
- `webUI_savedSearches` on source metadata. WebUI derives this from app metadata key `savedSearches` plus the `webUI_` metadata prefix.
```

Use this wording in the data model section:

```markdown
Use WebUI-compatible source metadata key `webUI_savedSearches`; the JSON value still has the saved-search map shape:
```

- [ ] **Step 5: Run focused tests**

Run:

```powershell
busted spec\suwayomi_api_queries_spec.lua spec\suwayomi_api_spec.lua spec\suwayomi_client_source_manga_spec.lua
```

Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add suwayomi\client\source_manga.lua suwayomi\api\queries.lua spec\suwayomi_api_queries_spec.lua spec\suwayomi_api_spec.lua spec\suwayomi_client_source_manga_spec.lua docs\superpowers\specs\2026-05-30-saved-filters-design.md
git commit -m "fix(saved-filters): use WebUI metadata key"
```

---

### Task 2: Show Saved-Filter Failure Details

**Files:**
- Modify: `suwayomi/client/source_manga.lua`
- Modify: `spec/suwayomi_client_source_manga_spec.lua`

- [ ] **Step 1: Write failing load-detail test**

In `spec/suwayomi_client_source_manga_spec.lua`, add a test near the existing unsupported saved-filter test:

```lua
it("shows saved-filter load failure details", function()
    local client, state = newClient({
        api = {
            fetchSourceMetadata = function()
                return {
                    ok = false,
                    error = "Cannot query field \"meta\" on type \"SourceType\".",
                }
            end,
        },
        ui = {
            showSavedFiltersMenu = function()
                return { name = "saved-filters" }
            end,
        },
    })

    client:showSavedSourceFilters({ server_url = "https://suwayomi.example" }, {
        id = "s1",
        name = "MangaDex",
    }, {})

    assert.are.same({
        'Could not load saved filters: Cannot query field "meta" on type "SourceType".',
    }, state.shown_messages)
end)
```

Run:

```powershell
busted spec\suwayomi_client_source_manga_spec.lua
```

Expected: FAIL, actual remains `Could not load saved filters.`.

- [ ] **Step 2: Write failing save/delete detail tests**

Add save failure coverage:

```lua
it("shows saved-filter save failure details", function()
    local name_prompt
    local client, state = newClient({
        api = {
            fetchSourceMetadata = function()
                return { ok = true, meta = {} }
            end,
            setSourceSavedSearches = function()
                return { ok = false, error = "Authentication failed." }
            end,
        },
        ui = {
            showSavedFilterNamePrompt = function(_, onSave)
                name_prompt = onSave
            end,
        },
    })

    client:showSaveSourceFilterPrompt({ server_url = "https://suwayomi.example" }, {
        id = "s1",
        name = "MangaDex",
    }, { query = "one", filters = {} })

    name_prompt("Mine")

    assert.are.same({
        "Could not save saved filter: Authentication failed.",
    }, state.shown_messages)
end)
```

Add delete failure coverage:

```lua
it("shows saved-filter delete failure details", function()
    local client, state = newClient({
        api = {
            fetchSourceMetadata = function()
                return { ok = true, meta = {} }
            end,
            setSourceSavedSearches = function()
                return { ok = false, error = "Source metadata write failed." }
            end,
        },
        ui = {
            showSavedFiltersMenu = function()
                return { name = "saved-filters" }
            end,
        },
    })

    client:deleteSourceSavedFilter({ server_url = "https://suwayomi.example" }, {
        id = "s1",
        name = "MangaDex",
    }, {}, { name = "Mine" })

    assert.are.same({
        "Could not delete saved filter: Source metadata write failed.",
    }, state.shown_messages)
end)
```

Run:

```powershell
busted spec\suwayomi_client_source_manga_spec.lua
```

Expected: FAIL for both new tests.

- [ ] **Step 3: Implement detailed saved-filter failure helper**

In `suwayomi/client/source_manga.lua`, add:

```lua
local function normalizeSavedFilterErrorDetail(error_text)
    local detail = trim(error_text)
    if detail == "" then
        return nil
    end
    detail = detail:gsub("%s+", " ")
    if #detail > 180 then
        detail = detail:sub(1, 177) .. "..."
    end
    return detail
end

local function appendSavedFilterErrorDetail(fallback, error_text)
    local detail = normalizeSavedFilterErrorDetail(error_text)
    if not detail then
        return fallback
    end
    local prefix = tostring(fallback or ""):gsub("[%.。]$", "")
    if prefix == "" then
        return detail
    end
    return prefix .. ": " .. detail
end
```

Change `showSavedFilterFailure`:

```lua
function SuwayomiClient:showSavedFilterFailure(error_text, fallback)
    if sourceSavedFiltersUnsupported(error_text) then
        self.plugin:showMessage(I18n.t("Saved filters are not supported by this server."))
        return
    end
    self.plugin:showMessage(appendSavedFilterErrorDetail(fallback, error_text))
end
```

This reuses already translated fallback strings instead of adding three new
detail-only msgids that would churn every locale. In translated locales, the
message becomes localized fallback text plus raw server detail, for example
`Не удалось сохранить фильтр: Authentication failed.`

- [ ] **Step 4: Run focused tests**

Run:

```powershell
busted spec\suwayomi_client_source_manga_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add suwayomi\client\source_manga.lua spec\suwayomi_client_source_manga_spec.lua
git commit -m "fix(saved-filters): show failure details"
```

---

### Task 3: Polish Saved-Filter Translations

**Files:**
- Modify: `l10n/ru/suwayomi.po`
- Modify: `l10n/uk/suwayomi.po`
- Modify: `l10n/zh_CN/suwayomi.po`
- Modify: `l10n/ru/suwayomi.mo`
- Modify: `l10n/uk/suwayomi.mo`
- Modify: `l10n/zh_CN/suwayomi.mo`

- [ ] **Step 1: Replace Russian fuzzy and untranslated saved-filter entries**

In `l10n/ru/suwayomi.po`, remove `#, fuzzy` from these saved-filter entries and set:

```po
msgid "%1 filters"
msgstr "Фильтры %1"

msgid "Apply saved filter"
msgstr "Применить сохранённый фильтр"

msgid "Could not delete saved filter."
msgstr "Не удалось удалить сохранённый фильтр."

msgid "Could not load saved filters."
msgstr "Не удалось загрузить сохранённые фильтры."

msgid "Could not save saved filter."
msgstr "Не удалось сохранить фильтр."

msgid "Delete saved filter"
msgstr "Удалить сохранённый фильтр"

msgid "Delete saved filter \"%1\"?"
msgstr "Удалить сохранённый фильтр \"%1\"?"

msgid "Filter name"
msgstr "Название фильтра"

msgid "No saved filters."
msgstr "Нет сохранённых фильтров."

msgid "Overwrite saved filter \"%1\"?"
msgstr "Перезаписать сохранённый фильтр \"%1\"?"

msgid "Save current filter"
msgstr "Сохранить текущий фильтр"

msgid "Save filter"
msgstr "Сохранить фильтр"

msgid "Saved filter deleted."
msgstr "Фильтр удалён."

msgid "Saved filter saved."
msgstr "Фильтр сохранён."

msgid "Saved filters"
msgstr "Сохранённые фильтры"

msgid "Saved filters are not supported by this server."
msgstr "Сервер не поддерживает сохранённые фильтры."
```

Do not change the unrelated `Suwayomi Client v1.0.5` fuzzy entry in this task unless it is part of a separate release/l10n cleanup.

- [ ] **Step 2: Replace Ukrainian fuzzy and untranslated saved-filter entries**

In `l10n/uk/suwayomi.po`, remove `#, fuzzy` from these saved-filter entries and set:

```po
msgid "%1 filters"
msgstr "Фільтри %1"

msgid "Apply saved filter"
msgstr "Застосувати збережений фільтр"

msgid "Could not delete saved filter."
msgstr "Не вдалося видалити збережений фільтр."

msgid "Could not load saved filters."
msgstr "Не вдалося завантажити збережені фільтри."

msgid "Could not save saved filter."
msgstr "Не вдалося зберегти фільтр."

msgid "Delete saved filter"
msgstr "Видалити збережений фільтр"

msgid "Delete saved filter \"%1\"?"
msgstr "Видалити збережений фільтр \"%1\"?"

msgid "Filter name"
msgstr "Назва фільтра"

msgid "No saved filters."
msgstr "Немає збережених фільтрів."

msgid "Overwrite saved filter \"%1\"?"
msgstr "Перезаписати збережений фільтр \"%1\"?"

msgid "Save current filter"
msgstr "Зберегти поточний фільтр"

msgid "Save filter"
msgstr "Зберегти фільтр"

msgid "Saved filter deleted."
msgstr "Фільтр видалено."

msgid "Saved filter saved."
msgstr "Фільтр збережено."

msgid "Saved filters"
msgstr "Збережені фільтри"

msgid "Saved filters are not supported by this server."
msgstr "Сервер не підтримує збережені фільтри."
```

- [ ] **Step 3: Replace Simplified Chinese fuzzy and untranslated saved-filter entries**

In `l10n/zh_CN/suwayomi.po`, remove `#, fuzzy` from saved-filter entries and set:

```po
msgid "Apply saved filter"
msgstr "应用已保存的筛选器"

msgid "Could not delete saved filter."
msgstr "无法删除已保存的筛选器。"

msgid "Could not load saved filters."
msgstr "无法加载已保存的筛选器。"

msgid "Could not save saved filter."
msgstr "无法保存筛选器。"

msgid "Delete saved filter"
msgstr "删除已保存的筛选器"

msgid "Delete saved filter \"%1\"?"
msgstr "要删除已保存的筛选器“%1”吗？"

msgid "Filter name"
msgstr "筛选器名称"

msgid "No saved filters."
msgstr "没有已保存的筛选器。"

msgid "Overwrite saved filter \"%1\"?"
msgstr "要覆盖已保存的筛选器“%1”吗？"

msgid "Save current filter"
msgstr "保存当前筛选器"

msgid "Save filter"
msgstr "保存筛选器"

msgid "Saved filter deleted."
msgstr "筛选器已删除。"

msgid "Saved filter saved."
msgstr "筛选器已保存。"

msgid "Saved filters"
msgstr "已保存的筛选器"

msgid "Saved filters are not supported by this server."
msgstr "此服务器不支持已保存的筛选器。"
```

Leave existing `msgid "%1 filters"` as-is for Simplified Chinese unless a native review requests a different source-title style.

- [ ] **Step 4: Verify fuzzy/untranslated saved-filter entries are gone**

Run:

```powershell
bash -lc 'for locale in ru uk zh_CN; do echo "== $locale fuzzy =="; msgattrib --only-fuzzy l10n/$locale/suwayomi.po | grep -E "saved filter|Saved filter|Saved filters|Save filter|Filter name|%1 filters" || true; echo "== $locale untranslated =="; msgattrib --untranslated l10n/$locale/suwayomi.po | grep -E "saved filter|Saved filter|Saved filters|Save filter|Filter name|%1 filters" || true; done'
```

Expected: no saved-filter or `%1 filters` lines for `ru`, `uk`, or `zh_CN`. Unrelated `Suwayomi Client v1.0.5` may still appear as fuzzy.

- [ ] **Step 5: Compile catalogs**

Run:

```powershell
bash ./scripts/compile-l10n.sh
```

Expected: `l10n/ru/suwayomi.mo`, `l10n/uk/suwayomi.mo`, and `l10n/zh_CN/suwayomi.mo` update.

- [ ] **Step 6: Confirm compiled runtime strings**

Run:

```powershell
bash -lc 'for locale in ru uk zh_CN; do echo "== $locale =="; msgunfmt l10n/$locale/suwayomi.mo | grep -A1 -E "msgid \"Save filter\"|msgid \"Saved filters\"|msgid \"%1 filters\""; done'
```

Expected includes:

```text
== ru ==
msgid "%1 filters"
msgstr "Фильтры %1"
msgid "Save filter"
msgstr "Сохранить фильтр"
msgid "Saved filters"
msgstr "Сохранённые фильтры"

== uk ==
msgid "%1 filters"
msgstr "Фільтри %1"
msgid "Save filter"
msgstr "Зберегти фільтр"
msgid "Saved filters"
msgstr "Збережені фільтри"

== zh_CN ==
msgid "Save filter"
msgstr "保存筛选器"
msgid "Saved filters"
msgstr "已保存的筛选器"
```

- [ ] **Step 7: Run l10n gate**

Run:

```powershell
bash ./scripts/check-l10n.sh
```

Expected: PASS.

- [ ] **Step 8: Commit**

```powershell
git add l10n\ru\suwayomi.po l10n\uk\suwayomi.po l10n\zh_CN\suwayomi.po l10n\ru\suwayomi.mo l10n\uk\suwayomi.mo l10n\zh_CN\suwayomi.mo
git commit -m "fix(l10n): translate saved filter strings"
```

---

### Task 4: Final Verification

**Files:**
- No code changes expected.

- [ ] **Step 1: Run focused saved-filter tests**

Run:

```powershell
busted spec\suwayomi_api_queries_spec.lua spec\suwayomi_api_spec.lua spec\suwayomi_client_source_manga_spec.lua spec\suwayomi_ui_browse_spec.lua spec\suwayomi_source_filters_spec.lua
```

Expected: PASS.

- [ ] **Step 2: Run full local gates**

Run:

```powershell
luacheck --codes spec suwayomi main.lua _meta.lua
busted spec
bash ./scripts/check-l10n.sh
```

Expected: PASS for all three commands.

- [ ] **Step 3: Review diff and commit boundaries**

Run:

```powershell
git log --oneline --max-count=4
git diff --check
git status --short
```

Expected:

- recent commits include:
  - `fix(saved-filters): use WebUI metadata key`
  - `fix(saved-filters): show failure details`
  - `fix(l10n): translate saved filter strings`
- `git diff --check` has no whitespace errors.
- `git status --short` is clean.

- [ ] **Step 4: Push branch and watch CI before finalize**

Run:

```powershell
git push origin codex/saved-filters-spec
gh workflow run test.yml --ref codex/saved-filters-spec
```

Then watch with repo-preferred RTK wrapper:

```powershell
rtk gh run watch <run-id> --exit-status
```

Expected: GitHub Actions `Test` passes on `codex/saved-filters-spec`.

Only after user says `finalize`, follow repo finalization workflow: fast-forward merge to `master`, rerun local gates on merged tree, push `master`, watch `Test` on `master`, and clean up own worktree/branch.

---

## Self-Review

- Spec coverage: save/load failure messages, WebUI metadata compatibility, Russian title grammar, and RU/UK/ZH_CN saved-filter translations all have tasks. ZH_TW is explicitly out of scope per user instruction.
- Placeholder scan: no `TBD`, `TODO`, or "implement later" placeholders.
- Type consistency: metadata key is a string constant; saved-search JSON shape remains `Record<string, { query?: string; filters?: IPos[] }>`; source IDs remain strings at plugin boundaries and GraphQL `LongString` variables.
- Risk: actual live Atsumaru/server failure was not reproduced locally. Task 2 intentionally makes hidden server/API errors visible so any remaining server-specific problem is diagnosable instead of silent.
