-- Polyfill for the bits of `vim.lsp` / `vim.api` that the TOML pipeline and
-- LSP handler modules touch at require-time or call directly, but that don't
-- exist inside a vim.uv.new_thread worker (no editor state there: vim.lsp is
-- nil, vim.api is an empty stub). Everything else those modules use
-- (vim.islist, vim.tbl_map, vim.deepcopy, vim.empty_dict, vim.mpack, vim.json,
-- vim.inspect, ...) is already present natively inside a uv thread.
--
-- Values below are copied verbatim from vim.lsp.protocol in a normal Neovim
-- instance so completion kinds / symbol kinds / severities render exactly as
-- the real LSP client expects.
local M = {}

M.CompletionItemKind = {
  Text = 1, Method = 2, Function = 3, Constructor = 4, Field = 5, Variable = 6,
  Class = 7, Interface = 8, Module = 9, Property = 10, Unit = 11, Value = 12,
  Enum = 13, Keyword = 14, Snippet = 15, Color = 16, File = 17, Reference = 18,
  Folder = 19, EnumMember = 20, Constant = 21, Struct = 22, Event = 23,
  Operator = 24, TypeParameter = 25,
}

M.InsertTextFormat = {
  PlainText = 1, Snippet = 2,
}

M.SymbolKind = {
  File = 1, Module = 2, Namespace = 3, Package = 4, Class = 5, Method = 6,
  Property = 7, Field = 8, Constructor = 9, Enum = 10, Interface = 11,
  Function = 12, Variable = 13, Constant = 14, String = 15, Number = 16,
  Boolean = 17, Array = 18, Object = 19, Key = 20, Null = 21, EnumMember = 22,
  Struct = 23, Event = 24, Operator = 25, TypeParameter = 26,
}

M.DiagnosticSeverity = {
  Error = 1, Warning = 2, Information = 3, Hint = 4,
}

M.ErrorCodes = {
  ParseError = -32700, InvalidRequest = -32600, MethodNotFound = -32601,
  InvalidParams = -32602, InternalError = -32603, ServerNotInitialized = -32002,
  UnknownErrorCode = -32001, RequestCancelled = -32800, ContentModified = -32801,
  ServerCancelled = -32802, RequestFailed = -32803,
}

-- Installs vim.lsp.protocol (needed at require-time by completion.lua and
-- symbols.lua) and a harmless vim.api.nvim_create_namespace stub for
-- diagnostics.lua, whose return value the worker never reads.
function M.install()
  vim.lsp = vim.lsp or {}
  vim.lsp.protocol = vim.lsp.protocol or {
    CompletionItemKind = M.CompletionItemKind,
    InsertTextFormat = M.InsertTextFormat,
    SymbolKind = M.SymbolKind,
    DiagnosticSeverity = M.DiagnosticSeverity,
    ErrorCodes = M.ErrorCodes,
  }
  vim.api = vim.api or {}
  vim.api.nvim_create_namespace = vim.api.nvim_create_namespace or function() return -1 end

  -- Defensive: vim.deprecate (used internally by e.g. the legacy
  -- vim.validate{<table>} form) doesn't exist inside a uv thread either.
  vim.deprecate = vim.deprecate or function() end
end

return M
