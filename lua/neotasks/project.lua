local M = {}

local config = require("neotasks.config").current

--- Find the project root by checking for the tasks file in cwd.
---@return string|nil root
---@return string|nil err
function M.find_root()
    local cwd = vim.fn.getcwd() --[[@as string]]
    local tasks_path = vim.fs.normalize(vim.fs.joinpath(cwd, config.tasks_filename))
    if not vim.uv.fs_stat(tasks_path) then
        return nil, ("tasks file (%s) not found — not in a project root"):format(config.tasks_filename)
    end
    return cwd, nil
end

return M
