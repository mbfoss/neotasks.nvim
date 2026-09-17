local M      = {}

local config = require("neotasks.config")

-- The defaults, captured before `setup()` mutates the config in place — the
-- health check diffs the live config against them.
local _defaults = vim.deepcopy(config)

---@type boolean
local _setup_called = false

--- Register a task type. The schema is built when the tasks file is opened, so
--- register before that to have it included. `loader` may be a module path string, a zero-arg
--- factory function, or a fully-resolved TaskTypeDef table.
---@param name   string
---@param loader neotasks.TypeLoader
function M.register_task_type(name, loader)
    require("neotasks.types").register(name, loader)
end

--- Register a custom quickfix matcher for use in process tasks.
---@param name string
---@param fn   neotasks.QfMatcher
function M.register_qfmatcher(name, fn)
    require("neotasks.types.process").register_qfmatcher(name, fn)
end

--- Register a custom expression for use in task config values, written in TOML as
--- `{{ name }}` or `{{ name(arg1, arg2) }}`. Built-ins cannot be overridden; pass
--- `{ desc = … }` to have the name shown with that text in LSP completion.
---@param name string
---@param fn   neotasks.ExpressionFn
---@param opts? { desc?: string }
function M.register_expression(name, fn, opts)
    require("neotasks.expressions").register(name, fn, opts)
end

-- The tasks file gets its own `neotasks` filetype (not `toml`): it carries
-- vendored TOML + expression-slot highlighting via syntax/neotasks.vim and no
-- treesitter parser, and the LSP attaches by this filetype.
local FILETYPE = "neotasks"

--- True if `buf`'s file is the project tasks file, matched by filename. The LSP
--- has its own copy of this guard in its `root_dir`; this one is for finding
--- already-open tasks buffers.
---@param buf integer
---@return boolean
local function _is_tasks_buf(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    return name ~= "" and vim.fs.basename(name) == config.tasks_filename
end

--- The config as it was before any `setup()`, for comparison.
---@return neotasks.Config
function M.get_default_config()
    return vim.deepcopy(_defaults)
end

--- True once `setup()` has been called.
---@return boolean
function M.is_setup()
    return _setup_called
end

--- Create the user command. Its callbacks require the command plumbing and the
--- subcommands only on first use, so `setup()` stays cheap at startup.
local function _create_command()
    vim.api.nvim_create_user_command(config.command, function(opts)
        require("neotasks.util.usercmd").handle(opts, require("neotasks.commands").run)
    end, {
        nargs    = "*",
        desc     = "Run, stop and inspect project tasks",
        complete = function(arg_lead, cmd_line, _)
            return require("neotasks.util.usercmd").complete(arg_lead, cmd_line,
                require("neotasks.commands").complete)
        end,
    })
end

--- Declare the tasks-file language server and let Neovim start it when a
--- `neotasks` buffer appears. Every callback forwards to `neotasks.lsp`, so
--- nothing is required until a tasks file is actually opened.
local function _enable_lsp()
    -- Spelled out rather than read from `neotasks.lsp.SERVER_NAME`, which
    -- would require the module at startup.
    local server = "neotasks-toml"
    vim.lsp.config(server, {
        filetypes = { FILETYPE },

        cmd = function(dispatchers)
            return require("neotasks.lsp").cmd(dispatchers)
        end,

        -- Attach guard: only the real project tasks file gets a client.
        root_dir = function(buf, on_dir)
            require("neotasks.lsp").root_dir(buf, on_dir)
        end,

        before_init = function(params, client_config)
            -- Set on the client config too, so `:Neotasks lsp_dump` can see what
            -- the running client was started with.
            client_config.init_options   = require("neotasks.lsp").init_options()
            params.initializationOptions = client_config.init_options
        end,

        on_attach = function(client, buf)
            require("neotasks.lsp").on_attach(client, buf)
        end,
    })
    vim.lsp.enable(server)
end

--- Configure and start the plugin. Mandatory, and callable only once: the
--- command, filetype and LSP are all registered from the final config.
---@param opts neotasks.Config?
function M.setup(opts)
    if _setup_called then
        error("neotasks: setup() can only be called once")
    end
    _setup_called = true

    local tmp = vim.tbl_deep_extend("force", config, opts or {})
    for k, v in pairs(tmp) do
        config[k] = v
    end

    vim.filetype.add({
        filename = {
            [config.tasks_filename] = FILETYPE,
        },
    })

    _enable_lsp()

    -- Filetype detection only fires on future loads, so re-set the filetype on
    -- any tasks buffer that is already open. The assignment fires `FileType`
    -- even when unchanged, which makes Neovim start the server for it.
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and _is_tasks_buf(buf) then
            vim.bo[buf].filetype = FILETYPE
        end
    end

    _create_command()
end

---@return boolean
function M.in_project()
    return require("neotasks.project").find_root() ~= nil
end

return M
