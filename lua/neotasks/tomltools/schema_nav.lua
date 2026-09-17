-- tomltools/toml/schema_nav.lua
-- Shared schema navigation: flatten, schema_at, and cursor resolution via DecodeTree.
local M         = {}

local validator = require("neotasks.tomltools.validator")
local std       = require("neotasks.tomltools.std")

local function _deep_merge_tables(dest, src)
  std.validate("dest", dest, "table")
  std.validate("src", src, "table")

  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dest[k]) == "table" and not std.islist(v) then
        _deep_merge_tables(dest[k], v)
      else
        dest[k] = std.deepcopy(v)
      end
    else
      dest[k] = v
    end
  end
  return dest
end

-- Merge allOf, anyOf, oneOf, dependentSchemas; resolve if/then/else against data.
-- Returns a new flat schema table with conditional keys removed.
---@param s table
---@param d any
---@return table
function M.flatten(s, d)
  local out = {}
  _deep_merge_tables(out, s)

  if s.allOf then
    for _, sub in ipairs(s.allOf) do
      _deep_merge_tables(out, M.flatten(sub, d))
    end
  end

  if s["if"] then
    local ok = validator.validate(s["if"], d)
    if ok and s["then"] then
      _deep_merge_tables(out, M.flatten(s["then"], d))
    elseif not ok and s["else"] then
      _deep_merge_tables(out, M.flatten(s["else"], d))
    end
  end

  if s.oneOf then
    local best, best_n = nil, math.huge
    for _, sub in ipairs(s.oneOf) do
      local _, errs = validator.validate(sub, d)
      if #errs < best_n then
        best_n = #errs; best = sub
      end
      if best_n == 0 then break end
    end
    if best then _deep_merge_tables(out, M.flatten(best, d)) end
  end

  if s.anyOf then
    local any_passed = false
    local best, best_n = nil, math.huge
    for _, sub in ipairs(s.anyOf) do
      local ok, errs = validator.validate(sub, d)
      if ok then
        any_passed = true
        _deep_merge_tables(out, M.flatten(sub, d))
      elseif #errs < best_n then
        best_n = #errs; best = sub
      end
    end
    if not any_passed and best then
      _deep_merge_tables(out, M.flatten(best, d))
    end
  end

  if s.dependentSchemas and type(d) == "table" and not std.islist(d) then
    for prop, subschema in pairs(s.dependentSchemas) do
      if d[prop] ~= nil then
        _deep_merge_tables(out, M.flatten(subschema, d))
      end
    end
  end

  out["if"] = nil; out["then"] = nil; out["else"] = nil
  out.allOf = nil; out.oneOf = nil; out.anyOf = nil
  out.dependentSchemas = nil
  return out
end

-- Walk the key segments from root to `id`, navigating schema and data in
-- parallel. Handles arrays (numeric segments → prefixItems then items),
-- objects (→ properties, patternProperties, additionalProperties), and
-- conditional keywords via flatten. Returns the target schema (not flattened)
-- and its data, or nil if the path is not navigable.
---@param root_schema table
---@param root_data   any
---@param dt          tomltools.DecodeTree
---@param id          integer
---@return table? schema
---@return any     data
local function _navigate(root_schema, root_data, dt, id)
  local parts = dt:key_parts_of(id)
  local s, d  = root_schema, root_data

  for _, seg in ipairs(parts) do
    local flat = M.flatten(s, d)
    local idx  = tonumber(seg)

    if idx then
      if flat.prefixItems and flat.prefixItems[idx] then
        d = type(d) == "table" and d[idx] or nil
        s = flat.prefixItems[idx]
      elseif flat.items then
        d = type(d) == "table" and d[idx] or nil
        s = flat.items
      else
        return nil
      end
    elseif flat.properties and flat.properties[seg] then
      d = type(d) == "table" and d[seg] or nil
      s = flat.properties[seg]
    else
      local matched = false
      if flat.patternProperties then
        for pattern, subschema in pairs(flat.patternProperties) do
          if type(seg) == "string" and seg:match(pattern) then
            d = type(d) == "table" and d[seg] or nil
            s = subschema
            matched = true
            break
          end
        end
      end
      if not matched then
        if type(flat.additionalProperties) == "table" then
          d = type(d) == "table" and d[seg] or nil
          s = flat.additionalProperties
        else
          return nil
        end
      end
    end
  end

  return s, d
end

-- Navigate root_schema+root_data to the schema owned by a DecodeTree node.
-- Returns a flattened schema table, or nil if the path is not navigable.
---@param root_schema table
---@param root_data   any
---@param dt          tomltools.DecodeTree
---@param id          integer
---@return table?
function M.schema_at(root_schema, root_data, dt, id)
  local s, d = _navigate(root_schema, root_data, dt, id)
  if s == nil then return nil end
  return M.flatten(s, d)
end

-- Like schema_at but returns the field's schema without the final flatten,
-- preserving oneOf/allOf on the target node. Used by completion to offer
-- completions from all oneOf branches rather than just the best-matching one.
---@param root_schema table
---@param root_data   any
---@param dt          tomltools.DecodeTree
---@param id          integer
---@return table?
function M.raw_schema_at(root_schema, root_data, dt, id)
  return (_navigate(root_schema, root_data, dt, id)) -- intentionally not flattened
end

-- True if `schema.type` is, or includes, `name`.
---@param schema table?
---@param name   string
---@return boolean
local function has_type(schema, name)
  local t = schema and schema.type
  return t == name or (type(t) == "table" and std.tbl_contains(t, name))
end

---@class tomltools.HeaderPos
---@field dt  tomltools.DecodeTree
---@field row integer
---@field col integer

-- Pick the array element a header at the cursor binds to. Delegates to
-- DecodeTree:bound_element (see there for the binding rule); this wrapper just
-- guards against missing decode info.
---@param pos        tomltools.HeaderPos?
---@param array_node integer?
---@return integer? node_id
---@return string?  key
local function bound_element(pos, array_node)
  if not (pos and array_node) then return nil, nil end
  return pos.dt:bound_element(array_node, pos.row, pos.col)
end

-- Resolve the array element (data + decode node) to descend into for a header.
-- Uses the cursor-bound element when decode info is available, else falls back
-- to the array's most recent element (last in document order).
---@param array_data any
---@param pos        tomltools.HeaderPos?
---@param array_node integer?
---@return any element
---@return integer? element_node
local function descend_element(array_data, pos, array_node)
  local enode, ekey = bound_element(pos, array_node)
  if ekey then
    local elem = type(array_data) == "table" and array_data[tonumber(ekey)] or nil
    return elem, enode
  end
  local elem = (type(array_data) == "table" and #array_data > 0) and array_data[#array_data] or nil
  return elem, nil
end

-- Decode node for `key` under `dt_node`, or nil when there is no decode info.
---@param pos     tomltools.HeaderPos?
---@param dt_node integer?
---@param key     string
---@return integer?
local function child_node(pos, dt_node, key)
  return (pos and dt_node) and pos.dt:get_child_id(dt_node, key) or nil
end

-- Enumerate the [table] section paths reachable from (schema, data). Each level
-- is flattened against its own data, so conditional branches resolve to the one
-- the data selects rather than merging mutually-exclusive alternatives. Dotted
-- keys that cross an array-of-tables resolve against the element the cursor's
-- header binds to (see bound_element), so [tasks.x] sees the right [[tasks]].
---@param schema  table
---@param data    any
---@param prefix  string
---@param results { path: string, node: table }[]
---@param pos     tomltools.HeaderPos?
---@param dt_node integer?   decode node owning `data` (root id at the top call)
function M.gather_table_paths(schema, data, prefix, results, pos, dt_node)
  local flat = M.flatten(schema, data)
  if not has_type(flat, "object") then return end

  local function descend(key, prop)
    local cdata = type(data) == "table" and data[key] or nil
    local cnode = child_node(pos, dt_node, key)
    local fprop = M.flatten(prop, cdata)
    local path  = prefix == "" and key or (prefix .. "." .. key)
    if has_type(fprop, "object") then
      results[#results + 1] = { path = path, node = fprop }
      M.gather_table_paths(prop, cdata, path, results, pos, cnode)
    elseif has_type(fprop, "array") and fprop.items then
      -- Sub-tables of an array-of-tables element use a single [parent.child]
      -- header, so descend into the items against the bound element.
      local elem, enode = descend_element(cdata, pos, cnode)
      if has_type(M.flatten(fprop.items, elem), "object") then
        M.gather_table_paths(fprop.items, elem, path, results, pos, enode)
      end
    end
  end

  for key, prop in pairs(flat.properties or {}) do descend(key, prop) end

  -- Open-set maps (additionalProperties given as a schema, e.g. `tasks`): the
  -- keys are user-defined, so enumerate the ones that exist in the data. This
  -- surfaces [tasks.build] and its sub-tables ([tasks.build.env]) for completion.
  if type(flat.additionalProperties) == "table" and type(data) == "table" then
    for key in pairs(data) do
      if type(key) == "string" and not (flat.properties and flat.properties[key]) then
        descend(key, flat.additionalProperties)
      end
    end
  end
end

-- Enumerate the [[array-of-tables]] section paths reachable from (schema, data),
-- with the same data-aware, position-aware resolution as gather_table_paths.
---@param schema  table
---@param data    any
---@param prefix  string
---@param results { path: string, node: table }[]
---@param pos     tomltools.HeaderPos?
---@param dt_node integer?
function M.gather_array_table_paths(schema, data, prefix, results, pos, dt_node)
  local flat = M.flatten(schema, data)
  if not flat.properties and type(flat.additionalProperties) ~= "table" then return end

  local function descend(key, prop)
    local cdata = type(data) == "table" and data[key] or nil
    local cnode = child_node(pos, dt_node, key)
    local fprop = M.flatten(prop, cdata)
    local path  = prefix == "" and key or (prefix .. "." .. key)
    if has_type(fprop, "array") and fprop.items then
      local elem, enode = descend_element(cdata, pos, cnode)
      local fitem = M.flatten(fprop.items, elem)
      if has_type(fitem, "object") then
        results[#results + 1] = { path = path, node = fitem }
        M.gather_array_table_paths(fprop.items, elem, path, results, pos, enode)
      end
    elseif has_type(fprop, "object") then
      -- Descend through plain sub-tables so arrays nested under them
      -- (e.g. [[tasks.value.steps]]) are still discovered.
      M.gather_array_table_paths(prop, cdata, path, results, pos, cnode)
    end
  end

  for key, prop in pairs(flat.properties or {}) do descend(key, prop) end

  -- Descend through open-set map entries (additionalProperties, e.g. named
  -- tasks) so arrays-of-tables nested inside a task are still discovered.
  if type(flat.additionalProperties) == "table" and type(data) == "table" then
    for key in pairs(data) do
      if type(key) == "string" and not (flat.properties and flat.properties[key]) then
        descend(key, flat.additionalProperties)
      end
    end
  end
end

return M
