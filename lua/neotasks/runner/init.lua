local exec = require("neotasks.runner.exec")

---@class neotasks.Runner
local M = {}

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

--- Dispose a finished run: delete its buffers and remove it from state.
--- Returns false + error string if the run is still active.
---@param run_id string
---@return boolean ok, string? err
function M.dispose(run_id)
    return exec.dispose(run_id)
end

--- Whether a run may be disposed, and why not when it may not.
---@param run_id string
---@return boolean ok, string? err
function M.can_dispose(run_id)
    return exec.can_dispose(run_id)
end

--- Every run that can be disposed right now, labelled for a picker.
---@return neotasks.DisposableRun[]
function M.disposable()
    return exec.disposable()
end

--- Return the current execution state of a task.
---@param task_name string
---@return neotasks.TaskState
function M.state(task_name)
    return exec.state(task_name)
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
