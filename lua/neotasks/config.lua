local M = {}

---@class neotasks.Config
---@field command            string
---@field tasks_filename     string
---@field storage_dir        string
---@field lsp_debug_commands boolean enable LSP debug dump requests (`:Neotasks lsp_dump`)
---@field debug_adapters     string[] ezdap adapters the `debug` task type may use

---@type neotasks.Config
local config = {
    command            = "Neotasks",
    tasks_filename     = "neotasks.toml",
    storage_dir        = ".neotasks",
    lsp_debug_commands = false,
    -- Mandatory for `debug` tasks: only the adapters named here are loaded from
    -- ezdap (for performance)
    debug_adapters     = {},
}

return config
