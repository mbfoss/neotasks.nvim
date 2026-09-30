---@brief The highlight groups the output panel's winbar uses.
---
---`NeotasksActiveTab` is derived (not linked) so it follows the colorscheme; the
---rest link to built-in diagnostic groups. Every group is defined `default =
---true`, so a colorscheme or an explicit `:highlight` always wins.

local M = {}

---@param name string
---@param attr "fg"|"bg"
---@return integer?
local function _get(name, attr)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    return ok and hl[attr] or nil
end

--- The NeotasksActiveTab attrs this module last derived.
local _derived ---@type table?

--- Whether NeotasksActiveTab still holds exactly what this module gave it. Its
--- colours are derived rather than linked, so a new theme has to be able to
--- replace them -- but not to replace a definition the user made.
---@param attrs table
---@return boolean
local function _is_ours(attrs)
    local cur = vim.api.nvim_get_hl(0, { name = "NeotasksActiveTab", link = false })
    for k, v in pairs(attrs) do
        if cur[k] ~= v then return false end
    end
    return true
end

--- Define the panel's highlight groups. Safe to call repeatedly; re-run on
--- ColorScheme so the derived (non-linked) group follows the new theme.
function M.setup()
    local active = {
        fg   = _get("Title", "fg"),
        bg   = _get("WinBar", "bg"),
        bold = true,
    }

    -- After the first call the group exists because we made it, and `default`
    -- defers to whatever is already there: derived colours would then be stuck on
    -- the theme that was set when the panel first opened. Defer only to a
    -- definition that is not ours.
    vim.api.nvim_set_hl(0, "NeotasksActiveTab", vim.tbl_extend("force", active, {
        default = not (_derived and _is_ours(_derived)),
    }))
    _derived = active
    vim.api.nvim_set_hl(0, "NeotasksBadgeOk", { link = "DiagnosticOk", default = true })
    vim.api.nvim_set_hl(0, "NeotasksBadgeErr", { link = "DiagnosticError", default = true })
    vim.api.nvim_set_hl(0, "NeotasksBadgeWarn", { link = "DiagnosticWarn", default = true })
    vim.api.nvim_set_hl(0, "NeotasksBadgeHint", { link = "DiagnosticHint", default = true })
    vim.api.nvim_set_hl(0, "NeotasksBadgeMuted", { link = "WinBar", default = true })
    vim.api.nvim_set_hl(0, "NeotasksUnread", { link = "DiagnosticHint", default = true })
end

return M
