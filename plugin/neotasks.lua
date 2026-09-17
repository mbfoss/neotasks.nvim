if vim.fn.has("nvim-0.11") ~= 1 then
    error("neotasks.nvim requires Neovim >= 0.11")
end

-- Nothing else is registered at startup: `require("neotasks").setup()` is
-- mandatory and creates the command, filetype and LSP from the final config.
