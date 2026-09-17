-- tomltools/schema_util.lua
local std = require("neotasks.tomltools.std")

local M = {}

-- True when `target` starts with `prefix` (case-insensitive); empty/nil prefix matches all.
---@param prefix string?
---@param target string
---@return boolean
function M.matches_filter(prefix, target)
  if not prefix or prefix == "" then return true end
  return target:lower():sub(1, #prefix) == prefix:lower()
end

-- Schema `description`, or "" when absent.
---@param node table?
---@return string
function M.get_description(node)
  return node and node.description or ""
end

-- First non-null entry of node.type (or the type itself when it's a string).
---@param node table?
---@return string?
local function first_type(node)
  local t = node and node.type
  if type(t) == "string" then return t end
  if type(t) == "table" then
    for _, v in ipairs(t) do if v ~= "null" then return v end end
  end
  return nil
end

-- Human-readable type label, e.g. "string", "string|integer", or "any".
---@param node table?
---@return string
function M.get_type_label(node)
  if not node or not node.type then return "any" end
  if type(node.type) == "table" then
    local clean = {}
    for _, t in ipairs(node.type) do
      if t ~= "null" then table.insert(clean, t) end
    end
    return table.concat(clean, "|")
  end
  return tostring(node.type)
end

-- TOML literal for a schema's `default`, or a type-appropriate empty value
-- (`""`, `0`, `false`, `[]`, `{}`, …) when no default is declared.
---@param node table?
---@return string
function M.get_default_toml(node)
  if not node then return "" end
  if node.default ~= nil then
    if type(node.default) == "string" then
      return string.format("%q", node.default)
    elseif type(node.default) == "table" then
      return (std.inspect(node.default):gsub("%s+", ""))
    end
    return tostring(node.default)
  end
  local t = first_type(node)
  if t == "string" then
    return '""'
  elseif t == "integer" then
    return "0"
  elseif t == "number" then
    return "0.0"
  elseif t == "boolean" then
    return "false"
  elseif t == "array" then
    return "[]"
  elseif t == "object" then
    return "{}"
  end
  return ""
end

-- True when `key` is listed in the parent schema's `required` array.
---@param parent_node table?
---@param key         string
---@return boolean
function M.is_required(parent_node, key)
  if not parent_node or not parent_node.required then return false end
  for _, req in ipairs(parent_node.required) do
    if req == key then return true end
  end
  return false
end

-- Schema's properties as an ordered list, following `x-order` when present,
-- otherwise sorted alphabetically by key.
---@param node table?
---@return { key: string, schema: table }[]
function M.get_ordered_properties(node)
  if not node or not node.properties then return {} end
  local result = {}

  if node["x-order"] then
    for _, key in ipairs(node["x-order"]) do
      if node.properties[key] then
        table.insert(result, { key = key, schema = node.properties[key] })
      end
    end
  else
    for key, prop in pairs(node.properties) do
      table.insert(result, { key = key, schema = prop })
    end
    table.sort(result, function(a, b) return a.key < b.key end)
  end
  return result
end


return M
