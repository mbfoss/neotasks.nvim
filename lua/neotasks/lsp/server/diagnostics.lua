local validator = require("neotasks.tomltools.validator")
local expr = require("neotasks.util.expr")
local M = {}

local SERVER_NAME = "neotasks-toml"

--local diagnostics_ns = require("neotasks.lsp").diagnostics_ns

---@return lsp.Range
local function to_lsp_range(range)
  return {
    start = { line = range[1], character = range[2] },
    ["end"] = { line = range[3], character = range[4] },
  }
end

---@param range integer[]?
---@return lsp.Range
local function fallback_range(range)
  if range then return to_lsp_range(range) end
  return { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }
end

-- Walk the decoded values and flag any `{{ … }}` slot whose expression fails to
-- parse. Parsing the *decoded* value matches what the runner evaluates, at the
-- cost of highlighting the whole value rather than the exact column.
---@param data        any
---@param dt          tomltools.DecodeTree
---@param dt_id       integer
---@param diagnostics lsp.Diagnostic[]
local function expr_diagnostics(data, dt, dt_id, diagnostics)
  if type(data) ~= "table" then return end
  for key, value in pairs(data) do
    local child = dt:get_child_id(dt_id, tostring(key))
    if type(value) == "table" then
      if child then expr_diagnostics(value, dt, child, diagnostics) end
    elseif type(value) == "string" and child then
      for _, interior in ipairs(expr.slots(value)) do
        local _, perr = expr.parse(interior)
        if perr then
          local range = dt:get_value_range(child) or dt:range_of_id(child)
          diagnostics[#diagnostics + 1] = {
            range    = fallback_range(range),
            severity = vim.lsp.protocol.DiagnosticSeverity.Error,
            source   = SERVER_NAME,
            message  = "invalid expression: " .. (perr:gsub("%s*%(at col %d+%)$", "")),
          }
        end
      end
    end
  end
end

---@param bufnr integer?
---@param context neotasks.LspBufferContext
---@return lsp.Diagnostic[]
function M.build(bufnr, context)
  local diagnostics = {}
  local accumulated_errors = {}

  for _, err in ipairs(context.parse_errors or {}) do
    table.insert(accumulated_errors, err)
    diagnostics[#diagnostics + 1] = {
      range    = fallback_range(err.range),
      severity = vim.lsp.protocol.DiagnosticSeverity.Error,
      source   = SERVER_NAME,
      message  = err.message,
    }
  end

  if not context.cst then
    context.parse_results = { data = nil, errors = accumulated_errors }
    return diagnostics
  end

  for _, err in ipairs(context.decode_errors or {}) do
    table.insert(accumulated_errors, err)
    diagnostics[#diagnostics + 1] = {
      range    = fallback_range(err.range),
      severity = vim.lsp.protocol.DiagnosticSeverity.Error,
      source   = SERVER_NAME,
      message  = err.message,
    }
  end

  if not context.data then
    context.parse_results = { data = nil, errors = accumulated_errors }
    return diagnostics
  end

  if context.schema then
    local valid, errors = validator.validate(context.schema, context.data, context.decode_tree)
    if not valid then
      for _, err in ipairs(errors) do
        table.insert(accumulated_errors, err)
        local range = (context.decode_tree and err.node_id)
            and context.decode_tree:range_of_id(err.node_id) or nil
        diagnostics[#diagnostics + 1] = {
          range    = fallback_range(range),
          severity = vim.lsp.protocol.DiagnosticSeverity.Error,
          source   = SERVER_NAME,
          message  = err.err_msg,
        }
      end
    end
  end

  if context.decode_tree then
    expr_diagnostics(context.data, context.decode_tree, context.decode_tree:root_id(), diagnostics)
  end

  context.parse_results = { data = context.data, errors = accumulated_errors }
  return diagnostics
end

---@param bufnr integer
---@param diagnostics lsp.Diagnostic[]
---@param client_id integer?
function M.publish(bufnr, diagnostics, client_id)
  if client_id then
    vim.lsp.handlers[vim.lsp.protocol.Methods.textDocument_publishDiagnostics](
      nil,
      { uri = vim.uri_from_bufnr(bufnr), diagnostics = diagnostics },
      { client_id = client_id, method = vim.lsp.protocol.Methods.textDocument_publishDiagnostics }
    )
    return
  end

  local items = {}
  for _, diag in ipairs(diagnostics) do
    items[#items + 1] = {
      lnum     = diag.range.start.line,
      col      = diag.range.start.character,
      end_lnum = diag.range["end"].line,
      end_col  = diag.range["end"].character,
      severity = vim.diagnostic.severity.ERROR,
      message  = diag.message,
      source   = diag.source,
    }
  end
  --assert(diagnostics_ns)
  --vim.diagnostic.set(diagnostics_ns, bufnr, items)
end

---@param bufnr integer
---@param context neotasks.LspBufferContext
---@param client_id integer?
function M.update(bufnr, context, client_id)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local diagnostics = M.build(bufnr, context)
  M.publish(bufnr, diagnostics, client_id)
end

return M
