local exec = require("neotasks.runner.exec")

---@class neotasks.Runner
local M = {}

---A read-only, display-ready view of a run: no signals, closures or buffers.
---@class neotasks.RunInfo
---@field run_id      integer              monotonically increasing run number
---@field task_name   string
---@field task_type   string?              absent on a queued `if_running = "wait"` entry
---@field state       neotasks.TaskState
---@field result      neotasks.TaskResult? set only once `state` is "complete"
---@field status      neotasks.TaskStatus  result when complete, otherwise state
---@field active      boolean              state is running or waiting
---@field primary     boolean              user-launched (not a dependency); never nil
---@field waiting_for string[]?            dependency names while state is "waiting"

---@type neotasks.RunInfo[]?  nil when a run changed since it was built
local _runs_cache = nil

---Drop the cached snapshot and announce that `list_runs()` has changed.
local function _on_runs_changed()
    _runs_cache = nil
    -- Deferred: updates can arrive from libuv callbacks, where autocmds cannot run.
    vim.schedule(function()
        vim.api.nvim_exec_autocmds("User", { pattern = "NeotasksRunsChanged" })
    end)
end

-- Loaded before any run starts, so every change is announced.
exec.on_update(_on_runs_changed)
exec.on_dispose(_on_runs_changed)

--- Run a named task from a TOML config file.
--- Non-blocking: execution is driven by coroutines and libuv callbacks.
---@param task_name string
---@param toml_path string
function M.run(task_name, toml_path)
    exec.run(task_name, toml_path)
end

--- Stop a running task.
---@param task_name string
function M.stop(task_name)
    exec.stop(task_name)
end

--- Dispose a completed run: delete its buffers and drop it from the registry.
--- Returns false + error string if the run is still active.
---@param run_id integer
---@return boolean ok, string? err
function M.dispose(run_id)
    return exec.dispose(run_id)
end

--- Whether a run may be disposed, and why not when it may not.
---@param run_id integer
---@return boolean ok, string? err
function M.can_dispose(run_id)
    return exec.can_dispose(run_id)
end

--- Every run that can be disposed right now, labelled for a picker.
---@return neotasks.DisposableRun[]
function M.disposable()
    return exec.disposable()
end

--- Return a task's current status: its state while it runs, else its result.
---@param task_name string
---@return neotasks.TaskStatus
function M.status(task_name)
    return exec.status(task_name)
end

---Sanitized snapshots of every live run, oldest first. Cached until a run
---changes; the returned outer array is safe to mutate.
---@return neotasks.RunInfo[]
function M.list_runs()
    if not _runs_cache then
        local list = {}
        for run_id, entry in pairs(exec.get_all()) do
            list[#list + 1] = {
                run_id      = run_id,
                task_name   = entry.task_name,
                task_type   = entry.task_type,
                state       = entry.state,
                result      = entry.result,
                status      = entry.result or entry.state,
                active      = entry.state == "running" or entry.state == "waiting",
                primary     = entry.primary == true,
                waiting_for = entry.waiting_for and vim.list_slice(entry.waiting_for) or nil,
            }
        end
        table.sort(list, function(a, b) return a.run_id < b.run_id end)
        _runs_cache = list
    end
    return vim.list_slice(_runs_cache)
end

--- Return the sorted list of task names and a by-name lookup from a TOML file.
---@param toml_path string
---@return string[]? ordered
---@return table<string,neotasks.TaskBase>? by_name
---@return string? err
function M.list_tasks(toml_path)
    return exec.list(toml_path)
end

--- Return the sorted names of every expression usable against a tasks file:
--- registered expressions plus the file's inline `[expressions]`.
---@param toml_path string
---@return string[]
function M.list_expression_names(toml_path)
    return exec.list_expression_names(toml_path)
end

--- Evaluate an expression template string against a tasks file, resolving both
--- built-in and inline `[expressions]`. The result is delivered to `callback`.
---@param expr      string
---@param toml_path string
---@param callback  fun(ok: boolean, result: any, err: string?)
function M.eval_expression(expr, toml_path, callback)
    exec.eval(toml_path, expr, callback)
end

return M
