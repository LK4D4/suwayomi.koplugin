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
        index = math.floor(tonumber(state.index) or 0),
        ascending = state.ascending == true,
    }
end

local normalizeDraftEntry

local function normalizeState(state_type, state)
    if state_type == "sortState" then
        return copySortState(state)
    elseif state_type == "checkBoxState" then
        return state == true
    elseif state_type == "selectState" then
        return math.floor(tonumber(state) or 0)
    end
    return state ~= nil and tostring(state) or ""
end

local function statesEqual(state_type, state, default)
    if state_type == "sortState" then
        default = copySortState(default)
        return type(state) == "table"
            and type(default) == "table"
            and state.index == default.index
            and state.ascending == default.ascending
    end
    return state == default
end

normalizeDraftEntry = function(entry)
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
    if normalized.position < 1 then
        return nil
    end

    if type(entry.group_change) == "table" then
        normalized.group_change = normalizeDraftEntry(entry.group_change)
        return normalized.group_change and normalized or nil
    end

    local state_type = tostring(entry.type or "")
    if state_type == "" then
        return nil
    end

    normalized.type = state_type
    normalized.state = normalizeState(state_type, entry.state)
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

function SourceFilters.normalizeSavedSearches(saved_searches)
    local normalized = {}
    if type(saved_searches) ~= "table" then
        return normalized
    end

    for name, raw_entry in pairs(saved_searches) do
        name = tostring(name or "")
        if name ~= "" and type(raw_entry) == "table" then
            local draft = SourceFilters.normalizeDraft(raw_entry)
            draft.name = name
            table.insert(normalized, draft)
        end
    end

    table.sort(normalized, function(left, right)
        return left.name < right.name
    end)
    return normalized
end

function SourceFilters.savedSearchesToMap(entries)
    local saved_searches = {}
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
        if type(entry) == "table" and entry.name ~= nil and tostring(entry.name) ~= "" then
            local draft = SourceFilters.normalizeDraft(entry)
            saved_searches[tostring(entry.name)] = {
                query = draft.query,
                filters = draft.filters,
            }
        end
    end
    return saved_searches
end

local function buildOneChange(schema, draft)
    if type(schema) ~= "table" or type(draft) ~= "table" then
        return nil
    end

    if schema.type == "GroupFilter" then
        local child = draft.group_change
        local child_schema = child and type(schema.filters) == "table" and schema.filters[child.position]
        local child_change = buildOneChange(child_schema, child)
        if not child_change then
            return nil
        end
        return {
            position = draft.position - 1,
            groupChange = child_change,
        }
    end

    local expected_key = TYPE_TO_STATE_KEY[schema.type]
    if not expected_key or draft.type ~= expected_key then
        return nil
    end
    if statesEqual(expected_key, draft.state, schema.default) then
        return nil
    end

    local change = {
        position = draft.position - 1,
    }
    change[expected_key] = draft.state
    return change
end

function SourceFilters.buildFilterChanges(schema, draft_filters)
    local changes = {}
    for _, raw_draft in ipairs(type(draft_filters) == "table" and draft_filters or {}) do
        local draft = normalizeDraftEntry(raw_draft)
        local filter_schema = draft and type(schema) == "table" and schema[draft.position]
        local change = buildOneChange(filter_schema, draft)
        if change then
            table.insert(changes, change)
        end
    end
    return changes
end

return SourceFilters
