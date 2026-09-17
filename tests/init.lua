-- Busted helper: loaded once, inside Neovim, before any spec runs. It replaces
-- the old two-file bootstrap (an entry point plus a `minimal_init.lua` re-used
-- by the child nvim plenary spawned per spec) -- busted runs every spec in this
-- one Neovim, so a single setup file is enough.
--
-- busted runs under `tests/nvim-lua` (see `.busted`), so the specs get a real
-- Neovim (and with it the `vim` API) rather than a bare Lua interpreter.

-- Absolute paths throughout: a spec that `chdir`s into a temporary directory
-- would otherwise stop resolving a relative runtimepath or `package.path`.
local root = vim.uv.cwd()

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
    root .. "/lua/?.lua",
    root .. "/lua/?/init.lua",
    package.path,
}, ";")

-- The shim starts Neovim with `-u NONE`, which also means "no plugin scripts and
-- no filetype detection". Put back the parts of an ordinary session the specs
-- assume: this plugin's own commands and autocmds, and `:filetype on` (the
-- specs open TOML task files and expect the ftplugin and syntax to apply).
-- `setup()` then registers the command, filetype and LSP.
vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")
for _, file in ipairs(vim.fn.glob(root .. "/plugin/**/*.{lua,vim}", false, true)) do
    vim.cmd.source(file)
end

require("neotasks").setup()
