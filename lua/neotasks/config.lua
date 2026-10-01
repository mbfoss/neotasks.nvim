---@brief The plugin's options: the shipped defaults, and the live table
---`setup()` merges the user's `opts` into.
---
---Capture the live options once at a module's top
---(`local config = require("neotasks.config").current`) and read options off
---that. `apply()` refills the table rather than replacing it, so the capture
---stays current.
local M = {}

---@class neotasks.Config.Panel.Winbar
---@field separator string  drawn between adjacent group tabs
---@field unread    string  marker appended to a tab with unseen output
---@field numbers   boolean prefix each tab with its jump number

---@class neotasks.Config.Panel
---@field position   "bottom"|"top"|"left"|"right" where the panel splits
---@field size       number  fraction of editor lines/columns (0..1)
---@field min_size   integer floor in lines/columns
---@field empty_text string  shown when the panel has no page to show
---@field winbar     neotasks.Config.Panel.Winbar

---@class neotasks.Config
---@field tasks_filename     string
---@field storage_dir        string
---@field lsp_debug_commands boolean enable LSP debug dump requests (`:Neotasks lsp_dump`)
---@field debug_adapters     string[] ezdap adapters the `debug` task type may use
---@field panel              neotasks.Config.Panel  the task-output panel

---@type neotasks.Config
local defaults = {
    tasks_filename     = "neotasks.toml",
    storage_dir        = ".neotasks",
    lsp_debug_commands = false,
    -- Only the adapters named here (plus ezdap's built-in `remote`, always
    -- included) are loaded from ezdap (for performance)
    debug_adapters     = {},

    -- The task-output panel: a fixed split whose winbar lists one numbered tab
    -- per run. A run opens it on its own; the values here only place and size it.
    panel              = {
        position   = "bottom",
        size       = 0.22,
        min_size   = 6,
        empty_text = "No pages",
        winbar     = {
            separator = "❘",
            unread    = "•",
            numbers   = true,
        },
    },
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

---Split spec for the configured `panel.position`: which axis fixedwin pins and
---which placement modifier puts the split on that edge of the editor.
---@return "height"|"width" axis, string pos
function M.split_spec()
    local pos = M.current.panel.position
    if pos == "top" then return "height", "topleft" end
    if pos == "left" then return "width", "topleft" end
    if pos == "right" then return "width", "botright" end
    return "height", "botright"
end

return M
