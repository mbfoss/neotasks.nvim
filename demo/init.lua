-- Minimal, self-contained init for the README recordings.
local demo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(demo .. "/..", ":p")

vim.opt.rtp:append(demo) -- demo/colors/pastelstone.lua
vim.opt.rtp:append(root) -- the plugin itself

-- nvim-demo launches Neovim with --clean, so enable the filetype machinery the
-- plugin's setup() relies on.
vim.cmd("filetype plugin indent on")
vim.cmd("syntax on")
if vim.env.LOCATOR_NVIM and vim.env.LOCATOR_NVIM ~= "" then
    vim.opt.rtp:append(vim.env.LOCATOR_NVIM)
end

vim.o.number = true
vim.o.cursorline = true
vim.o.signcolumn = "no"
vim.o.wrap = false
vim.o.scrolloff = 8
vim.o.showtabline = 2
vim.o.laststatus = 2
vim.o.cmdheight = 1
vim.o.termguicolors = true
vim.o.background = "dark"
vim.o.mouse = ""
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.undofile = false
vim.o.backup = false
vim.o.list = false
vim.o.completeopt = "menuone,noselect,popup"
vim.o.shortmess = vim.o.shortmess .. "I"
vim.o.winborder = "rounded"
vim.opt.clipboard = ""
vim.g.mapleader = " "

vim.cmd("colorscheme pastelstone")

-- Statusline: the plugin on the left, the open file on the right.
vim.api.nvim_set_hl(0, "DemoStatusLeft", { fg = "#2e2f33", bg = "#90b8e3", bold = true })
vim.api.nvim_set_hl(0, "DemoStatusRight", { fg = "#dcdce4", bg = "#46474f" })
vim.o.statusline = "%#DemoStatusLeft# neotasks.nvim %#DemoStatusRight#%= %f "

require("nvim_demo").setup({ fg = "#2e2f33", bg = "#90b8e3", fill = "#3a3b41" })

require("neotasks").setup()

-- Completion in the tasks file, from the plugin's own LSP. The scene opens the
-- menu with <C-Space>; an explicit trigger keeps the recording independent of
-- autotrigger timing.
vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(ev)
        if vim.lsp.completion then
            vim.lsp.completion.enable(true, ev.data.client_id, ev.buf)
            vim.keymap.set("i", "<C-Space>", function()
                vim.lsp.completion.get()
            end, { buffer = ev.buf, desc = "LSP completion" })
        end
    end,
})

-- The README uses locator.nvim as its picker. It is optional for users, but
-- the recording script puts a checkout on the runtimepath above.
local ok, select = pcall(require, "locator.select")
if ok then vim.ui.select = select end

-- Open the tasks file with the cursor after the empty assignment the scene
-- completes. Reset that line in the buffer so a previous recording's save does
-- not change the starting point; the fixture on disk stays valid TOML.
vim.cmd.edit(vim.fn.fnameescape(root .. "demo/project/neotasks.toml"))
vim.api.nvim_buf_set_lines(0, 12, 13, false, { "quickfix_matcher =" })
vim.api.nvim_win_set_cursor(0, { 13, 19 })
