local M = {}

local ui = require("neotasks.util.ui")

---@class neotasks.util.TermHandle
---@field bufnr number
---@field pid   integer
---@field stop  fun()  stop the spawned command

---@class neotasks.util.SpawnOpts
---@field bufname?   string
---@field cwd?       string
---@field env?       table<string,string>
---@field clear_env? boolean don't inherid the current process env
---@field on_stdout?      fun(id: integer, data: string[], name: string)
---@field on_stderr?      fun(id: integer, data: string[], name: string)
---@field on_exit?        fun(code: integer)
---@field line_buffered?  boolean  only emit complete lines to on_stdout/on_stderr

---Neovim splits on newlines but the last element of each on_stdout/on_stderr
---call is always a partial fragment joined to the first element of the next call.
---This wraps the callback so it only fires with complete lines.
---@param cb fun(id: integer, data: string[], name: string)
---@return fun(id: integer, data: string[], name: string)
local function _wrap_line_buffered(cb)
    local partial = ""
    return function(id, data, name)
        if #data == 0 then return end
        local first = partial .. data[1]
        if #data == 1 then
            partial = first
            return
        end
        local lines = { first }
        for i = 2, #data - 1 do
            lines[#lines + 1] = data[i]
        end
        partial = data[#data]
        cb(id, lines, name)
    end
end


--- Spawn a command in a terminal buffer.
--- Returns immediately with a handle, or nil if jobstart failed.
--- termopen handles all output rendering including ANSI colours.
---@param cmd   string|string[]
---@param opts  neotasks.util.SpawnOpts
---@return number? job_id,number? pid, string? error
local function _start_job(cmd, opts)
    local job_id

    local exited
    local env = nil
    if opts.env and next(opts.env) then env = opts.env end
    if opts.cwd and vim.fn.has("win32") == 0 then
        env = env and vim.deepcopy(env) or {}
        env["PWD"] = opts.cwd
    end
    local start_ok, job_id_or_err = pcall(function()
        return vim.fn.jobstart(cmd, {
            term      = true,
            cwd       = opts.cwd,
            env       = env,
            clear_env = opts.clear_env,
            on_stdout = opts.on_stdout and (opts.line_buffered and _wrap_line_buffered(opts.on_stdout) or opts.on_stdout),
            on_stderr = opts.on_stderr and (opts.line_buffered and _wrap_line_buffered(opts.on_stderr) or opts.on_stderr),
            on_exit   = function(_, code)
                job_id = -1
                exited = true
                vim.schedule(function()
                    if opts.on_exit then opts.on_exit(code) end
                end)
            end,
        })
    end)

    if not start_ok then
        return nil, nil, tostring(job_id_or_err)
    end

    job_id = job_id_or_err
    if job_id < 0 then
        local program = type(cmd) == "table" and tostring(cmd[0]) or tostring(cmd)
        return nil, nil, (start_ok and "Invalid command:" .. program)
    end

    if job_id == 0 then
        return nil, nil, (start_ok and "Invalid arguments")
    end
    local pid = 0
    if not exited then
        pid = vim.fn.jobpid(job_id)
    end
    return job_id, pid
end

--- Give a terminal buffer a name. No-op for an empty/absent name.
--- Renaming off `term://…` spins the old name into an unlisted alternate buffer;
--- that alternate is `#` in this buffer's context, so we delete exactly it.
--- Best-effort: on a name clash the rename no-ops and term:// is kept.
---@param bufnr   integer
---@param bufname string?
---@return nil
function M.rename(bufnr, bufname)
    if type(bufname) ~= "string" or bufname == "" then return end
    if not pcall(vim.api.nvim_buf_set_name, bufnr, bufname) then return end
    vim.api.nvim_buf_call(bufnr, function()
        local alt = vim.fn.bufnr("#")
        if alt > 0 and alt ~= bufnr and not vim.api.nvim_buf_is_loaded(alt) then
            pcall(vim.api.nvim_buf_delete, alt, { force = false })
        end
    end)
end

--- Spawn a command in a terminal buffer.
--- Returns immediately with a handle, or nil if jobstart failed.
--- termopen handles all output rendering including ANSI colours.
---@param cmd   string|string[]
---@param opts  neotasks.util.SpawnOpts
---@param bufnr? integer buffer to own the terminal (auto created if nil)
---@return neotasks.util.TermHandle?,string?
function M.spawn(cmd, opts, bufnr)
    -- A terminal buffer must be in a window for jobstart {term=true}.
    local own_buf
    if not bufnr then
        own_buf = true
        bufnr = vim.api.nvim_create_buf(false, true)
    end

    local spawn_win = ui.create_window(bufnr, false, {
        relative  = "editor",
        row       = 0,
        col       = 0,
        width     = vim.o.columns,
        height    = vim.o.lines,
        style     = "minimal",
        hide      = true,
        focusable = false,
        zindex    = 1,
    }, function() end)

    local saved_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(spawn_win)

    local job_id, job_pid, job_err = _start_job(cmd, opts)

    vim.api.nvim_set_current_win(saved_win)
    vim.api.nvim_win_close(spawn_win, true)

    if not job_id then
        if own_buf then
            vim.api.nvim_buf_delete(bufnr, { force = true })
            own_buf = nil
        end
        return nil, job_err
    end

    if own_buf then
        vim.bo[bufnr].buflisted = true
    end

    vim.api.nvim_create_autocmd("TermClose", {
        buffer   = bufnr,
        once     = true,
        callback = function()
            for _, key in ipairs({ 'i', 'a', 'o', 'I', 'A', 'O', 'c', 'cc', 'C', 's', 'S', 'R', '.' }) do
                vim.keymap.set("n", key, "<Nop>", { buffer = bufnr, nowait = true })
            end
        end,
    })

    if opts.bufname then M.rename(bufnr, opts.bufname) end

    return { ---@type neotasks.util.TermHandle
        bufnr = bufnr,
        pid   = job_pid or 0,
        stop  = function()
            vim.fn.jobstop(job_id)
        end,
    }
end

return M
