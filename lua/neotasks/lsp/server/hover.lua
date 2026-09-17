local M          = {}

local s_util     = require("neotasks.tomltools.schema_util")
local schema_nav = require("neotasks.tomltools.schema_nav")
local Cst        = require("neotasks.tomltools.Cst")

local K          = Cst.Kind

---@param node table?
---@return string|nil
local function hover_text(node)
  if not node then return nil end

  local lines = {}
  if node.title       then lines[#lines + 1] = "**" .. node.title .. "**" end
  if node.description then lines[#lines + 1] = node.description end

  local type_label = s_util.get_type_label(node)
  if type_label ~= "any" then
    lines[#lines + 1] = ("Type: `%s`"):format(type_label)
  end

  if node.required and #node.required > 0 then
    lines[#lines + 1] = "Required keys: " .. table.concat(node.required, ", ")
  end

  if #lines == 0 then return nil end
  return table.concat(lines, "\n\n")
end

---@param context  neotasks.LspBufferContext
---@param params   lsp.HoverParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.Hover)
function M.handler(context, params, callback)
  if not context.cst then
    callback(nil, nil)
    return
  end

  local row    = params.position.line
  local col    = params.position.character
  local cst    = context.cst
  local dt     = context.decode_tree
  local schema = context.schema
  local data   = context.data

  if not schema then
    callback(nil, nil)
    return
  end

  local tok_id = cst:token_at(row, col)

  local dt_id
  local cur = tok_id ---@type integer?
  while cur do
    local d = cst:data(cur)
    if d and d.tag then dt_id = d.tag; break end
    local k = d and d.kind
    if k == K.Document or k == K.KeyValuePair
            or k == K.TableSection or k == K.AotSection
            or k == K.InlineTable then
      break
    end
    cur = cst:parent_id(cur)
  end

  local schema_node
  if dt_id and dt then
    schema_node = schema_nav.schema_at(schema, data, dt, dt_id)
  end

  local contents = hover_text(schema_node)
  if not contents then
    callback(nil, nil)
    return
  end

  callback(nil, {
    contents = { kind = "markdown", value = contents },
  })
end

return M
