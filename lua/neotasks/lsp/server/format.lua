local M = {}

local parser      = require("neotasks.tomltools.parser")
local toml_format = require("neotasks.tomltools.formatter")

---@param text string
---@return lsp.TextEdit? edit
---@return string? err
function M.build_edit(text)
  local lines  = vim.split(text, "\n", { plain = true })
  local parsed = parser.parse(text)

  if parsed.errors and #parsed.errors > 0 then
    return nil, parsed.errors[1].message
  end
  if not parsed.ok or not parsed.cst then
    return nil, "nothing to format or invalid document structure"
  end
  local new_text   = toml_format.format(parsed.cst)
  local line_count = #lines
  local last_line  = lines[line_count] or ""

  return {
    newText = new_text,
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = math.max(0, line_count - 1), character = #last_line },
    },
  }, nil
end

---@param context  neotasks.LspBufferContext
---@param params   table
---@param callback fun(err?: table, result?: table[]|nil)
function M.handler(context, params, callback)
  local text
  if context.text then
    text = context.text
  else
    local bufnr = context.bufnr or vim.uri_to_bufnr(params.textDocument.uri)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      callback(nil, nil)
      return
    end
    text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  end

  ---@cast text string
  local edit, err = M.build_edit(text)
  if not edit then
    callback({
      code    = vim.lsp.protocol.ErrorCodes.RequestFailed,
      message = err or "cannot format document",
    }, nil)
    return
  end

  callback(nil, { edit })
end

return M
