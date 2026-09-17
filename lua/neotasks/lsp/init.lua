-- In-process alternative to init.lua: the LSP "server" runs as a
-- vim.uv.new_thread worker (thread_server.lua) instead of a `nvim --headless`
-- subprocess. See thread_client.lua for the transport and thread_server.lua
-- for why debug_lua (LuaPanda) isn't supported here.
local thread_client = require("neotasks.lsp.client")

local M = {}

M.SERVER_NAME    = "neotasks-toml"
M.SERVER_VERSION = "0.1.0"

--M.diagnostics_ns = vim.api.nvim_create_namespace("neotasks-toml")

-- Public API
--
-- The server is registered as a `vim.lsp.Config` by `setup()` and
-- started by Neovim itself when a buffer gets the `neotasks` filetype; the
-- functions below are the pieces of that config, kept here so `setup()`
-- needs no `require` of this module.

--- `cmd`: spawn the worker thread that runs the server.
---@param dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.PublicClient
function M.cmd(dispatchers)
    return thread_client.start(dispatchers)
end

--- `init_options`: read at client-start time, so a `tasks_filename` or
--- `lsp_debug_commands` changed by `setup()` is honoured.
---@return table
function M.init_options()
    return { debug_commands = require("neotasks.config").current.lsp_debug_commands }
end

--- `root_dir`: doubles as the attach guard -- `on_dir` is called only for the
--- real project tasks file, so a scratch/preview buffer that merely borrows the
--- `neotasks` filetype for its highlighting never gets a client.
---@param buf    integer
---@param on_dir fun(dir: string)
function M.root_dir(buf, on_dir)
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and vim.fs.basename(name) == require("neotasks.config").current.tasks_filename then
        on_dir(vim.fn.getcwd())
    end
end

--- `on_attach`: push the schema and expression list to the server.
---@param client vim.lsp.Client
---@param buf    integer
function M.on_attach(client, buf)
    local uri = vim.uri_from_bufnr(buf)
    -- Server extension method: cast past the built-in method-name type, as the
    -- dump requests below do.
    client:notify("neotasks/setSchema" --[[@as any]], {
        uri         = uri,
        schema      = vim.json.encode(require("neotasks.types").build_resolved_schema()),
        expressions = vim.json.encode(require("neotasks.expressions").list()),
    })
end

-- Debug dump API
-- Only works when opts.debug_commands = true was passed to M.start().

local _dump_methods = {
    cst         = "neotasks/dumpCst",
    decode_tree = "neotasks/dumpDecodeTree",
    data        = "neotasks/dumpData",
    schema      = "neotasks/dumpSchema",
}

---@param buf  integer
---@param what "cst"|"decode_tree"|"data"|"schema"
function M.dump(buf, what)
    local client = vim.lsp.get_clients({ bufnr = buf, name = M.SERVER_NAME })[1]
    if not client then
        vim.notify("[neotasks] no LSP client attached to buffer " .. tostring(buf), vim.log.levels.WARN)
        return
    end
    if not (client.config.init_options or {}).debug_commands then
        vim.notify("[neotasks] debug_commands not enabled for this buffer", vim.log.levels.WARN)
        return
    end

    local method = _dump_methods[what]
    if not method then
        vim.notify("[neotasks] unknown dump target: " .. tostring(what), vim.log.levels.ERROR)
        return
    end

    local params = { textDocument = { uri = vim.uri_from_bufnr(buf) } }

    client:request(method --[[@as any]], params, function(err, result)
        if err then
            vim.notify("[neotasks] dump error: " .. tostring(err.message), vim.log.levels.ERROR)
            return
        end
        local text = (result and result.text) or "(empty)"

        local scratch = vim.api.nvim_create_buf(false, true)
        vim.bo[scratch].buftype   = "nofile"
        vim.bo[scratch].bufhidden = "wipe"
        vim.api.nvim_buf_set_name(scratch, "[neotasks:" .. what .. "]")
        vim.api.nvim_buf_set_lines(scratch, 0, -1, false, vim.split(text, "\n", { plain = true }))
        vim.cmd("split")
        vim.api.nvim_win_set_buf(0, scratch)
    end, buf)
end

return M
