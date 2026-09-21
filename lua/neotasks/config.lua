---@brief The plugin's options: the shipped defaults, and the live table
---`setup()` merges the user's `opts` into.
---
---Capture the live options once at a module's top
---(`local config = require("neotasks.config").current`) and read options off
---that. `apply()` refills the table rather than replacing it, so the capture
---stays current.
local M = {}

---@class neotasks.Config
---@field command            string
---@field tasks_filename     string
---@field storage_dir        string
---@field lsp_debug_commands boolean enable LSP debug dump requests (`:Neotasks lsp_dump`)
---@field debug_adapters     string[] ezdap adapters the `debug` task type may use

---@type neotasks.Config
local defaults = {
    command            = "Neotasks",
    tasks_filename     = "neotasks.toml",
    storage_dir        = ".neotasks",
    lsp_debug_commands = false,
    -- Only the adapters named here (plus ezdap's built-in `remote`, always
    -- included) are loaded from ezdap (for performance)
    debug_adapters     = {},
}

---The live options, at the defaults until `setup()` applies the user's. Always
---this same table: `apply()` refills it in place, so a captured reference --
---this table or any table under it -- never goes stale.
---@type neotasks.Config
M.current = vim.deepcopy(defaults)

---The configuration as it shipped. A fresh deep copy every call, so the caller
---may keep or mutate it; the health check diffs the live config against it.
---@return neotasks.Config
function M.defaults()
    return vim.deepcopy(defaults)
end

---Overwrite `dst` from `src` key by key: a key `src` lacks is dropped, and a
---table on both sides recurses instead of being swapped in. Nothing reachable
---from `current` is ever replaced, and nothing stale is left behind.
local function _refill(dst, src)
    for k in pairs(dst) do
        if src[k] == nil then dst[k] = nil end
    end
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            _refill(dst[k], v)
        else
            dst[k] = v
        end
    end
end

---Merge `opts` over the defaults to make the live config. Called once, by
---`setup()`: merging into a copy of the defaults rather than into `current`
---means no key of an earlier call can survive into a later one.
---@param opts neotasks.Config?
function M.apply(opts)
    _refill(M.current, vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {}))
end

return M
