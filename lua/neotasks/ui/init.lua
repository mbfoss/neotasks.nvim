local M = {}

local _PREFIX = "[neotasks] "

---@param msg string
function M.notify_info(msg)
    vim.notify(_PREFIX .. msg, vim.log.levels.INFO)
end

---@param msg string
function M.notify_warning(msg)
    vim.notify(_PREFIX .. msg, vim.log.levels.WARN)
end

---@param msg string
function M.notify_error(msg)
    vim.notify(_PREFIX .. msg, vim.log.levels.ERROR)
end

return M
