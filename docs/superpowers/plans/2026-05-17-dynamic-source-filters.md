# Dynamic Source Filters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add search-only dynamic source filters for Suwayomi source browse while keeping scanlator chapter filtering independent.

**Architecture:** Add a pure source-filter normalizer, extend API facade with source filter schema fetch, persist per-source drafts by server/auth scope, carry filter changes through source search worker/client pagination, and render a KOReader-native filter editor. Popular and Latest never submit filters; scanlator filtering stays per-manga chapter state.

**Tech Stack:** LuaJIT/Lua 5.1, KOReader widget stubs in specs, dkjson, busted, luacheck.

---

## File Map

- Create: `suwayomi/source_filters.lua`
  Pure filter schema/draft normalization and Suwayomi `FilterChange` builder.
- Create: `suwayomi/browse/source_filter_worker.lua`
  Subprocess-safe worker for fetching one source filter schema.
- Modify: `suwayomi/api/queries.lua`
  Add source filter schema query builder.
- Modify: `suwayomi/api/parsers.lua`
  Parse source filter schema and detect unsupported `filters` field errors.
- Modify: `suwayomi/api.lua`
  Export query/parser helpers and add `fetchSourceFilters`.
- Modify: `suwayomi/settings.lua`
  Persist source filter drafts by server/auth scope and source ID.
- Modify: `suwayomi/client.lua`
  Accept optional injected `source_filter_worker`.
- Modify: `suwayomi/client/runtime.lua`
  Lazily load `suwayomi/browse/source_filter_worker`.
- Modify: `suwayomi/browse/source_manga_worker.lua`
  Preserve `browse_options.filters` for `SEARCH` only and pass them to API.
- Modify: `suwayomi/client/source_manga.lua`
  Add source filter flow, paging/retry/edit-filter preservation, and title labels.
- Modify: `suwayomi/ui/browse.lua`
  Add source filter editor menus/prompts.
- Modify: `docs/ARCHITECTURE.md`
  Document source filter module/worker ownership.
- Test: `spec/suwayomi_source_filters_spec.lua`
- Test: `spec/suwayomi_source_filter_worker_spec.lua`
- Modify tests: API, settings, worker, client, UI, and scanlator regression specs listed below.

---

### Task 1: API And Pure Source Filter Core

**Files:**
- Create: `suwayomi/source_filters.lua`
- Create: `spec/suwayomi_source_filters_spec.lua`
- Modify: `suwayomi/api/queries.lua`
- Modify: `suwayomi/api/parsers.lua`
- Modify: `suwayomi/api.lua`
- Modify: `spec/suwayomi_api_queries_spec.lua`
- Modify: `spec/suwayomi_api_parsers_spec.lua`
- Modify: `spec/suwayomi_api_spec.lua`

- [ ] **Step 1: Add failing query-builder specs**

In `spec/suwayomi_api_queries_spec.lua`, add a spec near source query coverage:

```lua
it("builds a source filter schema query", function()
    local payload = decode_request(queries._buildSourceFiltersQuery("2499283573021220255"))

    assert.truthy(payload.query:match("GET_SOURCE_FILTERS"))
    assert.truthy(payload.query:match("source%(id:%s*%$id%)"))
    assert.truthy(payload.query:match("%.%.%. on CheckBoxFilter"))
    assert.truthy(payload.query:match("%.%.%. on GroupFilter"))
    assert.truthy(payload.query:match("filters"))
    assert.are.equal(2499283573021220255, payload.variables.id)
end)
```

- [ ] **Step 2: Verify query spec fails**

Run: `busted spec/suwayomi_api_queries_spec.lua`

Expected: FAIL with `_buildSourceFiltersQuery` nil.

- [ ] **Step 3: Add source filter query builder**

In `suwayomi/api/queries.lua`, add:

```lua
local SOURCE_FILTER_FIELDS = table.concat({
    "... on HeaderFilter { name }",
    "... on SeparatorFilter { name }",
    "... on SelectFilter { name values default }",
    "... on TextFilter { name default }",
    "... on CheckBoxFilter { name default }",
    "... on TriStateFilter { name default }",
    "... on SortFilter { name values default { index ascending } }",
}, " ")

local GROUP_FILTER_FIELDS = SOURCE_FILTER_FIELDS
    .. " ... on GroupFilter { name filters { "
    .. SOURCE_FILTER_FIELDS
    .. " } }"

function Queries._buildSourceFiltersQuery(source_id)
    return json.encode({
        query = "query GET_SOURCE_FILTERS($id: Long!) { source(id: $id) { id displayName name filters { "
            .. GROUP_FILTER_FIELDS
            .. " } } }",
        variables = {
            id = tonumber(source_id) or source_id,
        },
    })
end
```

Add `"_buildSourceFiltersQuery"` to `query_exports` in `suwayomi/api.lua`.

- [ ] **Step 4: Verify query spec passes**

Run: `busted spec/suwayomi_api_queries_spec.lua`

Expected: PASS.

- [ ] **Step 5: Add failing parser specs**

In `spec/suwayomi_api_parsers_spec.lua`, add parser coverage:

```lua
it("parses source filter schema responses", function()
    local api = require("suwayomi/api")
    local body = [[{
      "data": {
        "source": {
          "id": "s1",
          "displayName": "MangaDex",
          "name": "mangadex",
          "filters": [
            { "__typename": "HeaderFilter", "name": "Tags" },
            { "__typename": "CheckBoxFilter", "name": "Completed", "default": false },
            { "__typename": "TriStateFilter", "name": "Official", "default": "IGNORE" },
            { "__typename": "SelectFilter", "name": "Demographic", "values": ["Any","Shounen"], "default": 0 },
            { "__typename": "TextFilter", "name": "Author", "default": "" },
            { "__typename": "SortFilter", "name": "Sort", "values": ["Relevance"], "default": { "index": 0, "ascending": false } },
            { "__typename": "GroupFilter", "name": "Genres", "filters": [
              { "__typename": "CheckBoxFilter", "name": "Fantasy", "default": false }
            ] }
          ]
        }
      }
    }]]

    local parsed = assert(api.parseSourceFiltersResponse(body))
    assert.are.equal("s1", parsed.source.id)
    assert.are.equal("MangaDex", parsed.source.display_name)
    assert.are.equal("CheckBoxFilter", parsed.filters[2].type)
    assert.are.equal(false, parsed.filters[2].default)
    assert.are.equal("GroupFilter", parsed.filters[7].type)
    assert.are.equal("Fantasy", parsed.filters[7].filters[1].name)
end)

it("reports unsupported source filter schema", function()
    local api = require("suwayomi/api")
    local body = [[{"errors":[{"message":"Cannot query field \"filters\" on type \"SourceType\""}]}]]

    assert.is_true(api.isSourceFiltersFieldError(body))
end)
```

- [ ] **Step 6: Verify parser specs fail**

Run: `busted spec/suwayomi_api_parsers_spec.lua`

Expected: FAIL with missing parser helpers.

- [ ] **Step 7: Add failing facade specs**

In `spec/suwayomi_api_spec.lua`, add facade fetch coverage with `install_graphql_stub`:

```lua
it("fetches source filters through the facade", function()
    local api = require("suwayomi/api")
    install_graphql_stub([[{"data":{"source":{"id":"s1","name":"MangaDex","filters":[]}}}]])

    local result = api.fetchSourceFilters(valid_credentials(), "s1")

    assert.is_true(result.ok)
    assert.are.equal("s1", result.source.id)
    assert.are.same({}, result.filters)
end)
```

- [ ] **Step 8: Verify facade specs fail**

Run: `busted spec/suwayomi_api_spec.lua`

Expected: FAIL with missing facade helpers.

- [ ] **Step 9: Implement parser/facade support**

In `suwayomi/api/parsers.lua`, add local helpers:

```lua
local function normalizeFilterType(filter)
    local typename = filter.__typename or filter.type
    if typename then
        return tostring(typename)
    end
    return nil
end

local function parseFilterNode(filter)
    if type(filter) ~= "table" then
        return nil
    end
    local filter_type = normalizeFilterType(filter)
    local name = filter.name ~= nil and tostring(filter.name) or ""
    local parsed = {
        type = filter_type,
        name = name,
    }
    if filter_type == "HeaderFilter" or filter_type == "SeparatorFilter" then
        return parsed
    elseif filter_type == "CheckBoxFilter" then
        parsed.default = filter.default == true
        return parsed
    elseif filter_type == "TriStateFilter" then
        parsed.default = filter.default or "IGNORE"
        return parsed
    elseif filter_type == "SelectFilter" then
        parsed.values = type(filter.values) == "table" and filter.values or {}
        parsed.default = tonumber(filter.default) or 0
        return parsed
    elseif filter_type == "TextFilter" then
        parsed.default = filter.default ~= nil and tostring(filter.default) or ""
        return parsed
    elseif filter_type == "SortFilter" then
        parsed.values = type(filter.values) == "table" and filter.values or {}
        if type(filter.default) == "table" then
            parsed.default = {
                index = tonumber(filter.default.index) or 0,
                ascending = filter.default.ascending == true,
            }
        end
        return parsed
    elseif filter_type == "GroupFilter" then
        parsed.filters = {}
        for _, child in ipairs(type(filter.filters) == "table" and filter.filters or {}) do
            local parsed_child = parseFilterNode(child)
            if parsed_child then
                table.insert(parsed.filters, parsed_child)
            end
        end
        return parsed
    end
    return nil
end
```

Then add:

```lua
function Parsers.parseSourceFiltersResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end
    local source = payload and payload.data and payload.data.source
    if type(source) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not return source filters."
    end
    local filters = {}
    for _, filter in ipairs(type(source.filters) == "table" and source.filters or {}) do
        local parsed = parseFilterNode(filter)
        if parsed then
            table.insert(filters, parsed)
        end
    end
    return {
        source = {
            id = source.id ~= nil and tostring(source.id) or nil,
            display_name = source.displayName,
            name = source.name,
        },
        filters = filters,
    }
end

function Parsers.isSourceFiltersFieldError(response_body)
    local payload = json.decode(response_body, 1, nil)
    if type(payload) ~= "table" or type(payload.errors) ~= "table" then
        return false
    end
    for _, graph_error in ipairs(payload.errors) do
        local message = tostring(graph_error and graph_error.message or "")
        if message:match("filters") and (message:match("Cannot query field") or message:match("Unknown field") or message:match("FieldUndefined")) then
            return true
        end
    end
    return false
end
```

In `suwayomi/api.lua`, export parser helpers and add:

```lua
function SuwayomiAPI.fetchSourceFilters(credentials, source_id)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildSourceFiltersQuery(source_id), "fetchSourceFilters")
    if not result.ok then
        return result
    end
    if parsers.isSourceFiltersFieldError(result.response_body) then
        return {
            ok = false,
            error = "Source filters are not supported by this server.",
        }
    end
    local parsed, parse_error = SuwayomiAPI.parseSourceFiltersResponse(result.response_body)
    if not parsed then
        logDebugEvent({ operation = "fetchSourceFilters", event = "parse_error", error = parse_error })
        return {
            ok = false,
            error = parse_error,
        }
    end
    return {
        ok = true,
        source = parsed.source,
        filters = parsed.filters,
    }
end
```

- [ ] **Step 10: Add failing pure source filter specs**

Create `spec/suwayomi_source_filters_spec.lua`:

```lua
package.path = "?.lua;" .. package.path

describe("suwayomi/source_filters", function()
    local SourceFilters

    before_each(function()
        package.loaded["suwayomi/source_filters"] = nil
        SourceFilters = require("suwayomi/source_filters")
    end)

    it("builds filter changes from valid drafts only", function()
        local schema = {
            { type = "CheckBoxFilter", name = "Completed", default = false },
            { type = "TriStateFilter", name = "Official", default = "IGNORE" },
            { type = "SelectFilter", name = "Demographic", values = { "Any", "Shounen" }, default = 0 },
            { type = "TextFilter", name = "Author", default = "" },
            { type = "SortFilter", name = "Sort", values = { "Relevance" }, default = { index = 0, ascending = false } },
        }
        local changes = SourceFilters.buildFilterChanges(schema, {
            { position = 1, type = "checkBoxState", state = true },
            { position = 2, type = "triState", state = "INCLUDE" },
            { position = 3, type = "selectState", state = 1 },
            { position = 4, type = "textState", state = "Abe" },
            { position = 5, type = "sortState", state = { index = 0, ascending = true } },
            { position = 99, type = "textState", state = "bad" },
        })

        assert.are.equal(5, #changes)
        assert.are.equal(true, changes[1].checkBoxState)
        assert.are.equal("INCLUDE", changes[2].triState)
        assert.are.equal(1, changes[3].selectState)
        assert.are.equal("Abe", changes[4].textState)
        assert.are.same({ index = 0, ascending = true }, changes[5].sortState)
    end)

    it("builds group filter changes", function()
        local schema = {
            {
                type = "GroupFilter",
                name = "Genres",
                filters = {
                    { type = "CheckBoxFilter", name = "Fantasy", default = false },
                },
            },
        }
        local changes = SourceFilters.buildFilterChanges(schema, {
            {
                position = 1,
                group_change = { position = 1, type = "checkBoxState", state = true },
            },
        })

        assert.are.equal(1, #changes)
        assert.are.equal(1, changes[1].position)
        assert.are.equal(1, changes[1].groupChange.position)
        assert.are.equal(true, changes[1].groupChange.checkBoxState)
    end)

    it("normalizes draft query and filter entries", function()
        local draft = SourceFilters.normalizeDraft({
            query = 123,
            filters = {
                { position = "2", type = "textState", state = 77 },
                "bad",
            },
        })

        assert.are.equal("123", draft.query)
        assert.are.equal(1, #draft.filters)
        assert.are.equal(2, draft.filters[1].position)
        assert.are.equal("77", draft.filters[1].state)
    end)
end)
```

- [ ] **Step 11: Verify pure source filter spec fails**

Run: `busted spec/suwayomi_source_filters_spec.lua`

Expected: FAIL with missing module.

- [ ] **Step 12: Implement pure source filter module**

Create `suwayomi/source_filters.lua`:

```lua
-- Boundary: pure source filter normalization.
--
-- Responsibility: normalize source filter drafts and build Suwayomi
-- FilterChange tables without touching network, settings, or UI.
-- Owned state: none.
-- Dependencies: none.
-- External data: source filter schemas and drafts are treated as untrusted.

local SourceFilters = {}

local TYPE_TO_STATE_KEY = {
    CheckBoxFilter = "checkBoxState",
    TriStateFilter = "triState",
    SelectFilter = "selectState",
    TextFilter = "textState",
    SortFilter = "sortState",
}

local function copySortState(state)
    if type(state) ~= "table" then
        return nil
    end
    return {
        index = tonumber(state.index) or 0,
        ascending = state.ascending == true,
    }
end

local function normalizeDraftEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local position = tonumber(entry.position)
    if not position then
        return nil
    end
    local normalized = {
        position = math.floor(position),
    }
    if type(entry.group_change) == "table" then
        normalized.group_change = normalizeDraftEntry(entry.group_change)
        return normalized.group_change and normalized or nil
    end
    local state_type = tostring(entry.type or "")
    if state_type == "" then
        return nil
    end
    normalized.type = state_type
    if state_type == "sortState" then
        normalized.state = copySortState(entry.state)
    elseif state_type == "checkBoxState" then
        normalized.state = entry.state == true
    elseif state_type == "selectState" then
        normalized.state = math.floor(tonumber(entry.state) or 0)
    else
        normalized.state = entry.state ~= nil and tostring(entry.state) or ""
    end
    if normalized.state == nil then
        return nil
    end
    return normalized
end

function SourceFilters.normalizeDraft(draft)
    draft = type(draft) == "table" and draft or {}
    local normalized = {
        query = draft.query ~= nil and tostring(draft.query) or "",
        filters = {},
    }
    for _, entry in ipairs(type(draft.filters) == "table" and draft.filters or {}) do
        local parsed = normalizeDraftEntry(entry)
        if parsed then
            table.insert(normalized.filters, parsed)
        end
    end
    return normalized
end

local function buildOneChange(schema, draft)
    if type(schema) ~= "table" or type(draft) ~= "table" then
        return nil
    end
    if schema.type == "GroupFilter" then
        local child = draft.group_change
        local child_schema = child and schema.filters and schema.filters[child.position]
        local child_change = buildOneChange(child_schema, child)
        if not child_change then
            return nil
        end
        return {
            position = draft.position,
            groupChange = child_change,
        }
    end
    local expected_key = TYPE_TO_STATE_KEY[schema.type]
    if not expected_key or draft.type ~= expected_key then
        return nil
    end
    local change = {
        position = draft.position,
    }
    change[expected_key] = draft.state
    return change
end

function SourceFilters.buildFilterChanges(schema, draft_filters)
    local changes = {}
    for _, raw_draft in ipairs(draft_filters or {}) do
        local draft = normalizeDraftEntry(raw_draft)
        local filter_schema = draft and schema and schema[draft.position]
        local change = buildOneChange(filter_schema, draft)
        if change then
            table.insert(changes, change)
        end
    end
    return changes
end

return SourceFilters
```

- [ ] **Step 13: Verify Task 1 focused specs pass**

Run:

```powershell
busted spec/suwayomi_api_queries_spec.lua spec/suwayomi_api_parsers_spec.lua spec/suwayomi_api_spec.lua spec/suwayomi_source_filters_spec.lua
```

Expected: PASS.

- [ ] **Step 14: Commit Task 1**

```powershell
rtk git add suwayomi/api/queries.lua suwayomi/api/parsers.lua suwayomi/api.lua suwayomi/source_filters.lua spec/suwayomi_api_queries_spec.lua spec/suwayomi_api_parsers_spec.lua spec/suwayomi_api_spec.lua spec/suwayomi_source_filters_spec.lua
rtk git commit -m "feat: add source filter API core"
```

---

### Task 2: Settings, Filter Worker, And Search Worker Plumbing

**Files:**
- Create: `suwayomi/browse/source_filter_worker.lua`
- Create: `spec/suwayomi_source_filter_worker_spec.lua`
- Modify: `suwayomi/settings.lua`
- Modify: `spec/suwayomi_settings_spec.lua`
- Modify: `suwayomi/client.lua`
- Modify: `suwayomi/client/runtime.lua`
- Modify: `suwayomi/browse/source_manga_worker.lua`
- Modify: `spec/suwayomi_source_manga_worker_spec.lua`

- [ ] **Step 1: Add failing settings specs**

In `spec/suwayomi_settings_spec.lua`, add:

```lua
it("loads and saves source filter drafts by source and credentials scope", function()
    local settings = require("suwayomi/settings")
    local alice = {
        server_url = "https://suwayomi.example",
        username = "alice",
        password = "secret",
        auth_method = "basic_auth",
    }
    local bob = {
        server_url = "https://suwayomi.example",
        username = "bob",
        password = "secret",
        auth_method = "basic_auth",
    }

    assert.are.same({ query = "", filters = {} }, settings:loadSourceFilterDraft(alice, "s1"))
    settings:saveSourceFilterDraft(alice, "s1", {
        query = "frieren",
        filters = { { position = "1", type = "textState", state = 12 } },
    })

    local draft = settings:loadSourceFilterDraft(alice, "s1")
    assert.are.equal("frieren", draft.query)
    assert.are.equal(1, draft.filters[1].position)
    assert.are.equal("12", draft.filters[1].state)
    assert.are.same({ query = "", filters = {} }, settings:loadSourceFilterDraft(bob, "s1"))
end)

it("clears one source filter draft without touching scanlator filters", function()
    local settings = require("suwayomi/settings")
    local credentials = { server_url = "https://suwayomi.example" }
    settings:saveSourceFilterDraft(credentials, "s1", { query = "one", filters = {} })
    settings:saveSourceFilterDraft(credentials, "s2", { query = "two", filters = {} })
    settings:saveMangaScanlatorFilter({ id = "m1" }, "Team A")

    settings:clearSourceFilterDraft(credentials, "s1")

    assert.are.same({ query = "", filters = {} }, settings:loadSourceFilterDraft(credentials, "s1"))
    assert.are.equal("two", settings:loadSourceFilterDraft(credentials, "s2").query)
    assert.are.equal("Team A", settings:loadMangaScanlatorFilter({ id = "m1" }))
end)
```

- [ ] **Step 2: Verify settings spec fails**

Run: `busted spec/suwayomi_settings_spec.lua`

Expected: FAIL with missing source filter draft methods.

- [ ] **Step 3: Implement settings draft persistence**

In `suwayomi/settings.lua`, require source filter module near top:

```lua
local SourceFilters = require("suwayomi/source_filters")
```

Add helpers:

```lua
function SuwayomiSettings:getSourceFilterDraftScope(credentials_or_url)
    local server_url, auth_identity = self:getSourceCacheScope(credentials_or_url)
    return table.concat({ server_url, auth_identity }, "\n")
end

function SuwayomiSettings:loadSourceFilterDraft(credentials_or_url, source_id)
    local scope = self:getSourceFilterDraftScope(credentials_or_url)
    local drafts = self:open():readSetting("source_filter_drafts", {})
    local draft = type(drafts) == "table"
        and type(drafts[scope]) == "table"
        and drafts[scope][tostring(source_id or "")]
        or nil
    return SourceFilters.normalizeDraft(draft)
end

function SuwayomiSettings:saveSourceFilterDraft(credentials_or_url, source_id, draft)
    local scope = self:getSourceFilterDraftScope(credentials_or_url)
    local drafts = self:open():readSetting("source_filter_drafts", {})
    if type(drafts) ~= "table" then
        drafts = {}
    end
    drafts[scope] = type(drafts[scope]) == "table" and drafts[scope] or {}
    drafts[scope][tostring(source_id or "")] = SourceFilters.normalizeDraft(draft)
    self:open():saveSetting("source_filter_drafts", drafts):flush()
    return drafts[scope][tostring(source_id or "")]
end

function SuwayomiSettings:clearSourceFilterDraft(credentials_or_url, source_id)
    local scope = self:getSourceFilterDraftScope(credentials_or_url)
    local drafts = self:open():readSetting("source_filter_drafts", {})
    if type(drafts) == "table" and type(drafts[scope]) == "table" then
        drafts[scope][tostring(source_id or "")] = nil
        self:open():saveSetting("source_filter_drafts", drafts):flush()
    end
    return { query = "", filters = {} }
end
```

- [ ] **Step 4: Add failing source filter worker spec**

Create `spec/suwayomi_source_filter_worker_spec.lua`:

```lua
package.path = "?.lua;" .. package.path

describe("suwayomi/browse/source_filter_worker", function()
    before_each(function()
        package.loaded["suwayomi/browse/source_filter_worker"] = nil
        package.loaded["suwayomi/api"] = nil
    end)

    after_each(function()
        package.loaded["suwayomi/browse/source_filter_worker"] = nil
        package.loaded["suwayomi/api"] = nil
        package.preload["suwayomi/api"] = nil
    end)

    it("fetches and normalizes source filters", function()
        package.preload["suwayomi/api"] = function()
            return {
                fetchSourceFilters = function(credentials, source_id)
                    return {
                        ok = true,
                        source = { id = source_id, name = "MangaDex" },
                        filters = { { type = "CheckBoxFilter", name = "Completed", default = false } },
                        credentials = credentials,
                    }
                end,
            }
        end

        local worker = require("suwayomi/browse/source_filter_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, { id = "s1" }, "/tmp/source_filters.json")

        assert.is_true(result.ok)
        assert.are.equal("s1", result.source.id)
        assert.are.equal("CheckBoxFilter", result.filters[1].type)
    end)
end)
```

- [ ] **Step 5: Verify source filter worker spec fails**

Run: `busted spec/suwayomi_source_filter_worker_spec.lua`

Expected: FAIL with missing worker module.

- [ ] **Step 6: Implement source filter worker**

Create `suwayomi/browse/source_filter_worker.lua` modeled after `source_manga_worker.lua`:

```lua
-- Boundary: Browse source filter worker process.
--
-- Responsibility: fetch one source's dynamic filter schema in a subprocess-
-- friendly module and write a compact JSON result for the UI process to poll.
-- Owned state: none.
-- Dependencies: Suwayomi API facade and shared subprocess result-file helper.
-- External data: credentials, source rows, and API responses are normalized.

local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")

local SourceFilterWorker = {}

function SourceFilterWorker:writeResult(result_path, result)
    return SubprocessJob.writeResult(result_path, result)
end

local function normalizeSource(source)
    source = type(source) == "table" and source or {}
    return {
        id = source.id ~= nil and tostring(source.id) or nil,
        name = source.name,
        display_name = source.display_name,
        displayName = source.displayName,
    }
end

function SourceFilterWorker:readResult(result_path)
    return SubprocessJob.readResult(result_path, function(parsed)
        parsed.ok = parsed.ok == true
        parsed.source = normalizeSource(parsed.source)
        parsed.filters = type(parsed.filters) == "table" and parsed.filters or {}
        if not parsed.ok then
            parsed.error = parsed.error or "Could not load source filters."
        end
        return parsed
    end)
end

function SourceFilterWorker:run(credentials, source, result_path)
    source = normalizeSource(source)
    local ok, api_result = pcall(function()
        return SuwayomiAPI.fetchSourceFilters(credentials, source.id)
    end)
    local result
    if not ok then
        result = { ok = false, source = source, filters = {}, error = tostring(api_result) }
    elseif not api_result or not api_result.ok then
        result = { ok = false, source = source, filters = {}, error = api_result and api_result.error or "Could not load source filters." }
    else
        result = {
            ok = true,
            source = api_result.source or source,
            filters = type(api_result.filters) == "table" and api_result.filters or {},
        }
    end
    self:writeResult(result_path, result)
    return result
end

return SourceFilterWorker
```

- [ ] **Step 7: Add failing source manga worker filter plumbing spec**

In `spec/suwayomi_source_manga_worker_spec.lua`, extend first test or add:

```lua
it("passes filters only for source search requests", function()
    local calls = {}
    package.preload["suwayomi/api"] = function()
        return {
            fetchMangaForSource = function(_, options)
                table.insert(calls, options)
                return { ok = true, manga = {}, has_next_page = false }
            end,
        }
    end

    local worker = require("suwayomi/browse/source_manga_worker")
    worker:run({}, { id = "s1" }, {
        type = "SEARCH",
        query = "",
        page = 1,
        filters = { { position = 1, checkBoxState = true } },
    }, "/settings/source_manga_filters.json")
    worker:run({}, { id = "s1" }, {
        type = "POPULAR",
        page = 1,
        filters = { { position = 1, checkBoxState = true } },
    }, "/settings/source_manga_popular.json")

    assert.are.same({ { position = 1, checkBoxState = true } }, calls[1].filters)
    assert.is_nil(calls[2].filters)
end)
```

- [ ] **Step 8: Verify worker plumbing spec fails**

Run: `busted spec/suwayomi_source_manga_worker_spec.lua`

Expected: FAIL because filters are not normalized/preserved or Popular still passes them.

- [ ] **Step 9: Implement runtime and source manga worker plumbing**

In `suwayomi/client.lua`, store injected worker:

```lua
source_filter_worker = options.source_filter_worker,
```

In `suwayomi/client/runtime.lua`, add:

```lua
function SuwayomiClient:getSourceFilterWorker()
    if not self.source_filter_worker then
        self.source_filter_worker = require("suwayomi/browse/source_filter_worker")
    end
    return self.source_filter_worker
end
```

In `suwayomi/browse/source_manga_worker.lua`, update `normalizeBrowseOptions`:

```lua
if browse_options.type == "SEARCH" then
    browse_options.query = tostring(options.query or "")
    browse_options.filters = type(options.filters) == "table" and options.filters or nil
end
```

Update `buildRequestOptions`:

```lua
if request_options.type == "SEARCH" then
    request_options.query = browse_options.query
    if type(browse_options.filters) == "table" then
        request_options.filters = browse_options.filters
    end
end
```

- [ ] **Step 10: Verify Task 2 focused specs pass**

Run:

```powershell
busted spec/suwayomi_settings_spec.lua spec/suwayomi_source_filter_worker_spec.lua spec/suwayomi_source_manga_worker_spec.lua
```

Expected: PASS.

- [ ] **Step 11: Commit Task 2**

```powershell
rtk git add suwayomi/settings.lua suwayomi/client.lua suwayomi/client/runtime.lua suwayomi/browse/source_filter_worker.lua suwayomi/browse/source_manga_worker.lua spec/suwayomi_settings_spec.lua spec/suwayomi_source_filter_worker_spec.lua spec/suwayomi_source_manga_worker_spec.lua
rtk git commit -m "feat: persist source filter drafts"
```

---

### Task 3: Client Flow, UI Editor, Scanlator Regression, Docs

**Files:**
- Modify: `suwayomi/client/source_manga.lua`
- Modify: `suwayomi/ui/browse.lua`
- Modify: `spec/suwayomi_client_source_manga_spec.lua`
- Modify: `spec/suwayomi_ui_browse_spec.lua`
- Modify: `spec/suwayomi_chapters_context_spec.lua`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `README.md`

- [ ] **Step 1: Add failing UI specs for source filter entry and editor**

In `spec/suwayomi_ui_browse_spec.lua`, update source mode menu expectations:

```lua
assert.are.equal("Source filters", shown_dialog.item_table[3].text)
shown_dialog.item_table[3].callback()
assert.are.same({ "POPULAR", "SEARCH_FILTERS" }, selected)
```

Add editor coverage:

```lua
it("shows source filter editor rows and submits actions", function()
    local browse = require("suwayomi/ui/browse")
    local actions = {}

    browse.showSourceFilterEditor({
        source = { id = "s1", name = "MangaDex" },
        filters = {
            { type = "HeaderFilter", name = "Tags" },
            { type = "CheckBoxFilter", name = "Completed", default = false },
            { type = "TriStateFilter", name = "Official", default = "IGNORE" },
            { type = "TextFilter", name = "Author", default = "" },
        },
        draft = { query = "", filters = {} },
        on_action = function(action)
            table.insert(actions, action)
        end,
    })

    assert.are.equal("Source filters", shown_dialog.title)
    assert.are.equal("Tags", shown_dialog.item_table[1].text)
    assert.is_false(shown_dialog.item_table[1].select_enabled)
    assert.are.equal("Completed", shown_dialog.item_table[2].text)
    assert.are.equal("Off", shown_dialog.item_table[2].mandatory)
    assert.are.equal("Official", shown_dialog.item_table[3].text)
    assert.are.equal("Ignore", shown_dialog.item_table[3].mandatory)
    assert.are.equal("Author", shown_dialog.item_table[4].text)

    shown_dialog.item_table[2].callback()
    assert.are.equal("toggle", actions[1].id)
    assert.are.equal(2, actions[1].position)
end)
```

- [ ] **Step 2: Verify UI specs fail**

Run: `busted spec/suwayomi_ui_browse_spec.lua`

Expected: FAIL with missing `Source filters` entry/editor.

- [ ] **Step 3: Implement source filter UI**

In `suwayomi/ui/browse.lua`, add `Source filters` to `showSourceModeMenu`:

```lua
table.insert(menu_table, {
    text = _("Source filters"),
    callback = function()
        if onSelectCallback then onSelectCallback("SEARCH_FILTERS") end
    end,
})
```

Add simple editor renderer:

```lua
local function getDraftValue(draft, position)
    for _, entry in ipairs((draft and draft.filters) or {}) do
        if tonumber(entry.position) == position then
            return entry.state
        end
    end
    return nil
end

local function formatFilterState(filter, state)
    if filter.type == "CheckBoxFilter" then
        return state == true and _("On") or _("Off")
    end
    if filter.type == "TriStateFilter" then
        return tostring(state or filter.default or "IGNORE"):lower():gsub("^%l", string.upper)
    end
    if filter.type == "TextFilter" then
        return state and tostring(state) ~= "" and tostring(state) or nil
    end
    return nil
end

function BrowseUI.showSourceFilterEditor(options)
    options = options or {}
    local item_table = {}
    for index, filter in ipairs(options.filters or {}) do
        local state = getDraftValue(options.draft, index)
        local row = {
            text = filter.name or filter.type or _("Filter"),
            mandatory = formatFilterState(filter, state),
            callback = function()
                if options.on_action then
                    options.on_action({ id = "edit", position = index, filter = filter })
                end
            end,
        }
        if filter.type == "HeaderFilter" or filter.type == "SeparatorFilter" then
            row.select_enabled = false
            row.callback = nil
        elseif filter.type == "CheckBoxFilter" then
            row.callback = function()
                if options.on_action then
                    options.on_action({ id = "toggle", position = index, filter = filter })
                end
            end
        end
        table.insert(item_table, row)
    end
    local menu = newPluginMenu{
        title = _("Source filters"),
        item_table = item_table,
    }
    menu_utils.applyTitleBarOptions(menu, options)
    menu_utils.applyCloseCallback(menu, options)
    require("ui/uimanager"):show(menu)
    return menu
end
```

Keep first UI implementation menu-native. Later code can expand edit actions into choice/text prompts.

- [ ] **Step 4: Add failing client flow specs**

In `spec/suwayomi_client_source_manga_spec.lua`, add:

```lua
it("opens source filters from source mode without changing scanlator filter", function()
    local state = helper.new_state({
        ui = {
            showSourceModeMenu = function(_, onSelect)
                onSelect("SEARCH_FILTERS")
                return { name = "mode-menu" }
            end,
            showMangaMenu = function(rows, _, options)
                state.shown_manga_rows = rows
                state.shown_manga_options = options
                return { name = "loading-menu" }
            end,
            showSourceFilterEditor = function(options)
                state.filter_editor = options
                options.on_action({ id = "apply" })
                return { name = "filter-editor" }
            end,
        },
        source_filter_worker = {
            run = function(_, _, _, result_path)
                state.source_filter_worker_result_path = result_path
            end,
            readResult = function()
                return {
                    ok = true,
                    source = { id = "s1", name = "MangaDex" },
                    filters = { { type = "CheckBoxFilter", name = "Completed", default = false } },
                }
            end,
        },
    })
    state.client.current_scanlator_filter = "Team A"

    state.client:showMangaForSource({ id = "s1", name = "MangaDex" })

    assert.are.equal("Team A", state.client.current_scanlator_filter)
    assert.is_table(state.filter_editor)
end)
```

Add a worker request assertion where `source_manga_worker.run` receives `browse_options.filters` after applying draft.

- [ ] **Step 5: Verify client specs fail**

Run: `busted spec/suwayomi_client_source_manga_spec.lua`

Expected: FAIL with missing source filter flow.

- [ ] **Step 6: Implement minimal client source filter flow**

In `suwayomi/client/source_manga.lua`, require source filters:

```lua
local SourceFilters = require("suwayomi/source_filters")
```

Add methods:

```lua
function SuwayomiClient:resolveSourceFilterRuntime()
    local ok_job, job = pcall(function() return self:getSubprocessJob() end)
    local ok_ffi, ffi_util = pcall(function() return self:getFFIUtil() end)
    local ok_ui, ui_manager = pcall(function() return self:getUIManager() end)
    local ok_worker, worker = pcall(function() return self:getSourceFilterWorker() end)
    if not ok_job or not ok_worker or not ok_ffi or not ok_ui then
        return nil
    end
    if type(job) ~= "table" or type(worker) ~= "table" then
        return nil
    end
    return { job = job, worker = worker, ffi_util = ffi_util, ui_manager = ui_manager }
end

function SuwayomiClient:showSourceFilters(source)
    if not self.ui.showMangaMenu then
        self.plugin:showMessage(self:translate("Could not load source filters."))
        return
    end
    local credentials = self.settings:load()
    local draft = self.settings.loadSourceFilterDraft
        and self.settings:loadSourceFilterDraft(credentials, source and source.id)
        or { query = "", filters = {} }
    local runtime = self:resolveSourceFilterRuntime()
    if not runtime then
        self.plugin:showMessage(self:translate("Could not load source filters."))
        return
    end
    local menu = self.ui.showMangaMenu({
        { title = self:translate("Loading source filters...") },
    }, nil, self:getTitleBarMenuOptions({ title = self:getSourceDisplayName(source) }))
    local active = runtime.job.start({
        active = { source = source, result_path = runtime.job.buildResultPath and runtime.job.buildResultPath("source_filters") or nil },
        ffi_util = runtime.ffi_util,
        ui_manager = runtime.ui_manager,
        poll_interval_seconds = self:getSourceMangaPollIntervalSeconds(),
        timeout_seconds = self:getSourceMangaTimeoutSeconds(),
        run = function(path) runtime.worker:run(credentials, source, path) end,
        read_result = function(path) return runtime.worker:readResult(path) end,
        on_finish = function(_, result)
            if not result or not result.ok then
                self:showSourceMangaStatus(menu, self:translate("Source filters"), result and result.error or self:translate("Could not load source filters."))
                return
            end
            self:showSourceFilterEditor(source, result.filters or {}, draft)
        end,
    })
    if not active then
        self:showSourceMangaStatus(menu, self:translate("Source filters"), self:translate("Could not load source filters."))
    end
end

function SuwayomiClient:showSourceFilterEditor(source, filters, draft)
    if not self.ui.showSourceFilterEditor then
        self.plugin:showMessage(self:translate("Source filters are not available."))
        return
    end
    return self.ui.showSourceFilterEditor({
        source = source,
        filters = filters,
        draft = draft,
        on_action = function(action)
            if action and action.id == "apply" then
                local normalized = SourceFilters.normalizeDraft(draft)
                if self.settings.saveSourceFilterDraft then
                    self.settings:saveSourceFilterDraft(self.settings:load(), source and source.id, normalized)
                end
                return self:showMangaForSource(source, {
                    type = "SEARCH",
                    query = normalized.query,
                    filters = SourceFilters.buildFilterChanges(filters, normalized.filters),
                    skip_mode_menu = true,
                })
            end
        end,
    })
end
```

In `showSourceModeMenu`, handle new mode:

```lua
if mode == "SEARCH_FILTERS" then
    return self:showSourceFilters(source)
end
```

In `buildSourceMangaRequestOptions`, `buildBrowseResultMenuOptions`, retry rows, and `showMangaForSource`, copy `options.filters` only for `SEARCH`.

In title helpers, show `Filter` when `type == "SEARCH"` and query is empty but filters exist.

- [ ] **Step 7: Add scanlator regression spec**

In `spec/suwayomi_chapters_context_spec.lua`, add a regression that source-filter draft state is unrelated to scanlator state. Do not change scanlator key semantics in this feature; same-title/source scoping is a separate follow-up because it can affect existing persisted settings. Add:

```lua
it("keeps source filter drafts separate from manga scanlator filters", function()
    local settings = require("suwayomi/settings")
    settings:saveMangaScanlatorFilter({ id = "m1" }, "Team A")
    if settings.saveSourceFilterDraft then
        settings:saveSourceFilterDraft({ server_url = "https://suwayomi.example" }, "s1", {
            query = "frieren",
            filters = { { position = 1, type = "checkBoxState", state = true } },
        })
    end

    assert.are.equal("Team A", settings:loadMangaScanlatorFilter({ id = "m1" }))
end)
```

- [ ] **Step 8: Update docs**

In `README.md`, move `Full dynamic source filter editing` out of deferred gaps and add source search filters to feature list.

In `docs/ARCHITECTURE.md`, add:

- `suwayomi/source_filters.lua` to shared support.
- `suwayomi/browse/source_filter_worker.lua` to Browse workers.
- Source filter schema/API ownership to API and Browse change map.

- [ ] **Step 9: Verify Task 3 focused specs pass**

Run:

```powershell
busted spec/suwayomi_ui_browse_spec.lua spec/suwayomi_client_source_manga_spec.lua spec/suwayomi_chapters_context_spec.lua
```

Expected: PASS.

- [ ] **Step 10: Run full verification**

Run:

```powershell
busted spec
luacheck --codes spec suwayomi main.lua _meta.lua
```

Expected: PASS.

- [ ] **Step 11: Commit Task 3**

```powershell
rtk git add suwayomi/client/source_manga.lua suwayomi/ui/browse.lua spec/suwayomi_client_source_manga_spec.lua spec/suwayomi_ui_browse_spec.lua spec/suwayomi_chapters_context_spec.lua docs/ARCHITECTURE.md README.md
rtk git commit -m "feat: add search source filters"
```

---

## Final Verification

- [ ] Run `busted spec`
- [ ] Run `luacheck --codes spec suwayomi main.lua _meta.lua`
- [ ] Run `rtk git log --oneline -5`
- [ ] Run `rtk git status --short --branch`
- [ ] Confirm commits are separated:
  - `docs: design source filters`
  - `docs: plan source filters`
  - `feat: add source filter API core`
  - `feat: persist source filter drafts`
  - `feat: add search source filters`
