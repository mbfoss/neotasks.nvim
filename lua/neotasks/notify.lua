---User-facing messages: one prefix, three levels. Every `vim.notify` in the
---plugin goes through here so messages are consistently tagged `[neotasks]`.
local M = {}

local _PREFIX = "[neotasks] "

---@param msg string
function M.info(msg)
    vim.notify(_PREFIX .. msg, vim.log.levels.INFO)
end

---@param msg string
function M.warn(msg)
    vim.notify(_PREFIX .. msg, vim.log.levels.WARN)
end

---@param msg string
function M.error(msg)
    vim.notify(_PREFIX .. msg, vim.log.levels.ERROR)
end

return M
