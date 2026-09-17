--- Task execution engine.
--- Handles TOML loading, dependency resolution, coroutine scheduling,
--- and task state tracking.
local async        = require("neotasks.util.async")
local Signal       = require("neotasks.util.Signal")
local toml         = require("neotasks.tomltools")
local task_types   = require("neotasks.types")
local resolver     = require("neotasks.runner.resolver")
local notify       = require("neotasks.ui")
local save_buffers = require("neotasks.util.save_buffers")
local project      = require("neotasks.project")

---@class neotasks.TaskTemplate
---@field label string  shown in vim.ui.select
---@field task  table   the template data to encode and insert

---@alias neotasks.RunFn fun(task: neotasks.TaskBase, ctx: neotasks.RunCtx, on_done: fun(ok: boolean)): fun()
---@alias neotasks.DisposeFn fun(run_id: string, bufnrs: neotasks.BufEntry[])
---@
---@class neotasks.TaskTypeDef
---@field start      neotasks.RunFn
---@field dispose    neotasks.DisposeFn?  optional cleanup called when the run is disposed
---@field schema     (table|(fun(): table))?
---@field templates  (neotasks.TaskTemplate[]|(fun(): neotasks.TaskTemplate[]))?
---@field no_action  boolean?  type has no action of its own; behaviour is purely its dependencies

---@class neotasks.BufEntry
---@field bufnr    integer
---@field label    string
---@field priority integer  higher = shown preferentially when added (default 0)

---@class neotasks.ProgressEvent
---@field time    integer  unix timestamp
---@field message string

---Presentation options for a buffer registered with the run host.
---@class neotasks.AddBufOpts
---@field label?      string
---@field priority?   integer

---@class neotasks.RunCtx
---@field name       string   the task's name (the `[tasks.<name>]` key)
---@field run_id     string   this run's unique id (`<name>#<counter>`)
---@field add_bufnr  fun(bufnr: integer, opts?: neotasks.AddBufOpts)
---@field report     fun(message: string)

---@alias neotasks.TaskState "idle"|"running"|"waiting"|"ok"|"failed"|"stopped"

---@class neotasks.RunEntry
---@field task_name      string
---@field task_type      string?
---@field state          neotasks.TaskState
---@field waiting_for    string[]?
---@field reports        neotasks.ProgressEvent[]
---@field bufnrs         neotasks.BufEntry[]
---@field cancel         fun()?
---@field stop_requested boolean?
---@field done           neotasks.util.Signal<fun()>
---@field primary        boolean?  user-initiated launch (run/restart/parallel), not a dependency

---@class neotasks.exec
local M            = {}

---@type table<string, neotasks.RunEntry>
local _running     = {}
local _run_counter = 0


---@type neotasks.util.Signal<fun(run_id: string, entry: neotasks.RunEntry)>
local _on_state_change = Signal.new()

---@type neotasks.util.Signal<fun(run_id: string, event: neotasks.ProgressEvent)>
local _on_report = Signal.new()

---@type neotasks.util.Signal<fun(run_id: string)>
local _on_dispose = Signal.new()

local function _gen_run_id(task_name)
    _run_counter = _run_counter + 1
    return task_name .. "#" .. _run_counter
end


---@param fn fun(run_id: string, entry: neotasks.RunEntry)
---@return fun() cancel
function M.on_state_change(fn) return _on_state_change:subscribe(fn) end

---@param fn fun(run_id: string, event: neotasks.ProgressEvent)
---@return fun() cancel
function M.on_report(fn) return _on_report:subscribe(fn) end

---@param fn fun(run_id: string)
---@return fun() cancel
function M.on_dispose(fn) return _on_dispose:subscribe(fn) end

local function _notify_state(run_id)
    local entry = _running[run_id]
    if entry then _on_state_change:emit(run_id, entry) end
end

---@param run_id string
---@param event  neotasks.ProgressEvent
local function _notify_report(run_id, event)
    _on_report:emit(run_id, event)
end

---@param run_id  string
---@param message string
local function _append_report(run_id, message)
    local entry = _running[run_id]
    if not entry then return end
    local ev = { time = os.time(), message = message }
    table.insert(entry.reports, ev)
    _notify_report(run_id, ev)
end

---@return table<string, neotasks.RunEntry>
function M.get_all()
    return vim.tbl_extend("force", {}, _running)
end

-- TOML loading

---@param toml_path string
---@return table<string,neotasks.TaskBase>?, string[]?, table<string,string>?, string?
local function _load_tasks(toml_path)
    local lines = vim.fn.readfile(toml_path)
    if not lines then return nil, nil, nil, "cannot read " .. toml_path end
    local short        = vim.fn.fnamemodify(toml_path, ":~:.")
    local data, errors = toml.decode(table.concat(lines, "\n") .. "\n", task_types.build_resolved_schema())

    ---@param e tomltools.Error
    ---@return string
    local function _fmt_err(e)
        return e.range and (short .. ":" .. (e.range[1] + 1) .. ": " .. e.message)
            or (short .. ": " .. e.message)
    end

    -- Any parse, decode, or schema-validation error is fatal.
    if #errors > 0 then
        return nil, nil, nil, _fmt_err(errors[1])
    end
    if not data or not data.tasks then
        return nil, nil, nil, "no tasks table in " .. toml_path
    end

    -- Tasks are a name-keyed map (`[tasks.<name>]`), so the parser already
    -- guarantees unique names. The name is carried alongside the task data, not
    -- stored on it, keeping previews/encodes free of a synthetic field.
    local table_util = require("neotasks.util.table_util")
    local by_name    = {}
    local ordered    = {} ---@type string[]

    ---@param name string
    local function add_task(name)
        local task = data.tasks[name]
        if type(task) ~= "table" or by_name[name] then return end
        by_name[name]         = task
        ordered[#ordered + 1] = name
    end

    for _, name in ipairs(table_util.ordered_keys_of(data.tasks) or {}) do add_task(name) end
    -- Defensive: include any keys absent from the order metadata, sorted.
    local rest = {}
    for name in pairs(data.tasks) do if not by_name[name] then rest[#rest + 1] = name end end
    table.sort(rest)
    for _, name in ipairs(rest) do add_task(name) end
    do
        local expressions_reg = require("neotasks.expressions")
        for name in pairs(data.expressions or {}) do
            if expressions_reg.get(name) then
                return nil, nil, nil, ("%s: Builtin expression name cannot be used: %s"):format(
                    short, name)
            end
        end
    end
    return by_name, ordered, data.expressions or {}, nil
end

-- Dependency validation

---@param name   string
---@param tasks  table<string,neotasks.TaskBase>
---@param seen   table<string,boolean>
---@return string?  missing dependency name, or nil if all deps exist
local function _find_missing_dep(name, tasks, seen)
    if seen[name] then return nil end
    seen[name] = true
    local task = tasks[name]
    if not task then return name end
    if type(task.depends_on) == "table" then
        for _, dep in ipairs(task.depends_on) do
            local missing = _find_missing_dep(dep, tasks, seen)
            if missing then return missing end
        end
    end
    return nil
end

-- Cycle detection

---@param name    string
---@param tasks   table<string,neotasks.TaskBase>
---@param visited table<string,boolean>
---@param stack   table<string,boolean>
---@return string?
local function _find_cycle(name, tasks, visited, stack)
    if stack[name] then return name end
    if visited[name] then return nil end
    visited[name] = true
    stack[name]   = true
    local task    = tasks[name]
    if task and type(task.depends_on) == "table" then
        for _, dep in ipairs(task.depends_on) do
            local cycle = _find_cycle(dep, tasks, visited, stack)
            if cycle then return name .. " → " .. cycle end
        end
    end
    stack[name] = false
    return nil
end

-- save_buffers

--- Normalize a task's `save_buffers` field into a SaveBuffersConfig, or nil if
--- saving is disabled. Accepts `true` (save all) or `{ include, exclude }`.
---@param value any
---@return neotasks.SaveBuffersConfig?
local function _save_buffers_config(value)
    if value == true then
        return { include_globs = {}, exclude_globs = {} }
    elseif type(value) == "table" then
        return {
            include_globs  = value.include or {},
            exclude_globs  = value.exclude or {},
            include_hidden = value.include_hidden or false,
        }
    end
    return nil
end

--- Save modified project buffers for a task if it opted in, reporting which
--- files were saved. No-op when not in a project or nothing matched. Returns
--- false if any buffer could not be written, so the run can be aborted.
---@param task   neotasks.TaskBase
---@param report fun(message: string)
---@return boolean ok
local function _save_buffers_for(task, report)
    local sb_config = _save_buffers_config(task.save_buffers)
    if not sb_config then return true end
    local root = project.find_root()
    if not root then return true end
    local n, paths, failed = save_buffers.save(root, sb_config)
    if #failed > 0 then
        local msg = "could not save:\n" .. table.concat(failed, "\n")
        report(msg)
        vim.notify(msg, vim.log.levels.ERROR)
        return false
    end
    if n == 0 then return true end
    report("Files saved:\n" .. table.concat(paths, "\n"))
    local lines = { ("saved %d file%s:"):format(n, n == 1 and "" or "s") }
    for i = 1, math.min(n, 5) do lines[#lines + 1] = "  " .. paths[i] end
    if n > 5 then lines[#lines + 1] = ("  … and %d more"):format(n - 5) end
    vim.notify(table.concat(lines, "\n"))
    return true
end

-- Core execution

--- Dispose any finished (non-running, non-waiting) runs for a
--- task, so a fresh run replaces its predecessor instead of stacking up.
---@param task_name string
local function _dispose_finished(task_name)
    local to_dispose = {}
    for rid, e in pairs(_running) do
        if e.task_name == task_name
            and e.state ~= "running" and e.state ~= "waiting"
        then
            table.insert(to_dispose, rid)
        end
    end
    for _, rid in ipairs(to_dispose) do M.dispose(rid) end
end

--- Stop a single run by id: flag it and invoke its cancel (if any). Used both by
--- the public `stop` and to propagate a stop request down to a task's in-flight
--- dependency runs, which are tracked under different task names.
---@param run_id string
local function _stop_run(run_id)
    local entry = _running[run_id]
    if not entry then return end
    if entry.state ~= "running" and entry.state ~= "waiting" then return end
    entry.stop_requested = true
    if entry.cancel then entry.cancel() end
end

--- Run a single task (and its dependencies) as a coroutine. Must be called from
--- within a coroutine (via async.go). Always creates and fully owns its RunEntry,
--- synchronously before the first yield, so callers see it immediately.
---@param name      string
---@param tasks     table<string,neotasks.TaskBase>
---@param run_id?   string   pre-existing run_id to reuse (e.g. a waiting entry)
---@param primary   boolean?  true for user-initiated launches (not dependencies)
---@param expressions? table<string,string>  inline expression templates from the [expressions] table
---@param on_start? fun(run_id: string)  notified with the new run_id when a fresh entry is created, so a caller can track this run (e.g. to cancel it as a dependency)
---@return boolean ok
local function _run_task_coro(name, tasks, run_id, primary, expressions, on_start)
    local task = tasks[name]
    if not task then
        notify.notify_error("unknown task: " .. name)
        return false
    end

    ---@type neotasks.RunEntry
    local entry
    if run_id then
        entry             = _running[run_id]
        entry.state       = "running"
        entry.waiting_for = nil
        if primary then entry.primary = true end
    else
        _dispose_finished(name)

        run_id = _gen_run_id(name)
        entry = {
            task_name = name,
            task_type = task.type,
            state     = "running",
            bufnrs    = {},
            done      = Signal.new(),
            primary   = primary or nil,
            reports   = {},
        }
        _running[run_id] = entry
        if on_start then on_start(run_id) end
    end
    _notify_state(run_id)
    _append_report(run_id, "started")

    local function finish(state)
        entry.state = state
        entry.done:emit()
        _notify_state(run_id)
        _append_report(run_id, state)
        return state == "ok"
    end

    -- depends_on
    local deps = type(task.depends_on) == "table" and task.depends_on or {}
    if #deps > 0 then
        entry.state       = "waiting"
        entry.waiting_for = deps
        -- Run-ids of the in-flight dependency runs, reported here as each starts.
        -- They live under their own task names, so without this a stop aimed at
        -- this waiting task would leave them running and block the coroutine.
        local dep_runs    = {}
        local function track_dep(rid) dep_runs[rid] = true end
        entry.cancel = function()
            for rid in pairs(dep_runs) do _stop_run(rid) end
        end
        _notify_state(run_id)
        _append_report(run_id, "waiting for: " .. table.concat(deps, ", "))

        ---@param dep_name string
        ---@return string
        local function dep_unmet(dep_name)
            return "dependency '" .. dep_name .. "' "
                .. (entry.stop_requested and "stopped" or "failed")
        end

        local deps_ok
        if task.depends_order == "parallel" then
            local fns = vim.tbl_map(function(dep_name)
                return function() return _run_task_coro(dep_name, tasks, nil, nil, expressions, track_dep) end
            end, deps)
            local results = async.wait_all(fns)
            deps_ok = true
            for i, r in ipairs(results) do
                if not r.ok or not r.result then
                    deps_ok = false
                    _append_report(run_id, dep_unmet(deps[i]))
                end
            end
        else
            deps_ok = true
            for _, dep_name in ipairs(deps) do
                local r = async.wait_one(function()
                    return _run_task_coro(dep_name, tasks, nil, nil, expressions, track_dep)
                end)
                if not r.ok or not r.result then
                    deps_ok = false
                    _append_report(run_id, dep_unmet(dep_name))
                    break
                end
            end
        end

        -- The deps cancel is only meaningful while waiting; clear it so a later
        -- stop targets this task's own run rather than the finished dependencies.
        entry.cancel = nil

        if not deps_ok then
            return finish(entry.stop_requested and "stopped" or "failed")
        end

        entry.state       = "running"
        entry.waiting_for = nil
        _notify_state(run_id)
        _append_report(run_id, "dependencies resolved")
    end

    -- stop check (may have been requested while waiting for deps)
    if entry.stop_requested then
        return finish("stopped")
    end

    -- expression resolution
    local expression_ok, resolved = coroutine.yield(function(waker)
        resolver.resolve_expressions(task, { task = task, expressions = expressions or {} },
            function(ok, result, err)
                waker(ok, ok and result or err)
            end)
    end)
    if not expression_ok then
        _append_report(run_id, "expression error: " .. tostring(resolved))
        return finish("failed")
    end
    task = resolved

    -- type-specific run
    local type_def = task_types.get(task.type)
    if not type_def then
        _append_report(run_id, "unknown task type: " .. tostring(task.type))
        return finish("failed")
    end

    -- Types with a command of their own report the resolved (expression-expanded)
    -- config so it's visible in the run log. Composite-style types are skipped:
    -- their behaviour is entirely their dependencies, so it would be noise.
    if not type_def.no_action then
        _append_report(run_id, "resolved task:\n" .. toml.encode(task))
    end

    -- Save buffers immediately before this task's own effective run (after its
    -- dependencies have completed). A dependency that needs saving sets its own
    -- save_buffers flag.
    if not _save_buffers_for(task, function(msg) _append_report(run_id, msg) end) then
        return finish("failed")
    end

    ---@type neotasks.RunCtx
    local ctx = {
        name      = name,
        run_id    = run_id,
        report    = function(msg) _append_report(run_id, msg) end,
        add_bufnr = function(bufnr, opts)
            opts = opts or {}
            local label = opts.label
            if not label then
                label = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
            end
            table.insert(entry.bufnrs, { bufnr = bufnr, label = label, priority = opts.priority or 0 })
            _notify_state(run_id)
            vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
                buffer   = bufnr,
                once     = true,
                callback = function()
                    for i, be in ipairs(entry.bufnrs) do
                        if be.bufnr == bufnr then
                            table.remove(entry.bufnrs, i)
                            break
                        end
                    end
                    _notify_state(run_id)
                end,
            })
        end,
    }

    local ok = coroutine.yield(function(waker)
        local settled = false
        local function settle(result)
            if settled then return end
            settled = true
            waker(result)
        end
        -- A task type's start() runs synchronously here; a throw would otherwise
        -- escape through whatever callback resumed this coroutine and leave the
        -- run stuck. Catch it, report it, and settle the run as failed instead.
        local call_ok, cancel = pcall(type_def.start, task, ctx, settle)
        if not call_ok then
            _append_report(run_id, "task type '" .. tostring(task.type)
                .. "' start() error: " .. tostring(cancel))
            return settle(false)
        end
        if type(cancel) ~= "function" then
            _append_report(run_id, "task type '" .. tostring(task.type)
                .. "' start() must return a cancel function")
            return settle(false)
        end
        entry.cancel = cancel
    end)

    if entry.stop_requested then
        return finish("stopped")
    end
    return finish(ok and "ok" or "failed")
end

-- Internal launch

--- Create a terminal failed RunEntry visible in the task view.
---@param task_name string
---@param message   string
local function _fail_immediately(task_name, message)
    _dispose_finished(task_name)
    local run_id     = _gen_run_id(task_name)
    _running[run_id] = {
        task_name = task_name,
        state     = "failed",
        bufnrs    = {},
        done      = Signal.new(),
        primary   = true,
        reports   = {},
    }
    _running[run_id].done:emit()
    _notify_state(run_id)
    _append_report(run_id, message)
end

--- `run_task_coro` creates its entry synchronously before its first yield,
--- so the entry is live before launch returns.
---@param task_name string
---@param tasks     table<string,neotasks.TaskBase>
---@param run_id?   string   pre-existing run_id to reuse (e.g. a waiting entry)
---@param expressions? table<string,string>  inline expression templates from the [expressions] table
local function _launch(task_name, tasks, run_id, expressions)
    async.go(function()
        return _run_task_coro(task_name, tasks, run_id, true, expressions)
    end, function(co_ok, result)
        if co_ok then return end
        local msg    = "coroutine error: " .. tostring(result)
        local orphan = false
        -- coroutine itself threw — mark any orphaned running entry as failed
        for rid, entry in pairs(_running) do
            if entry.task_name == task_name
                and (entry.state == "running" or entry.state == "waiting") then
                orphan      = true
                entry.state = "failed"
                entry.done:emit()
                _notify_state(rid)
                _append_report(rid, msg)
            end
        end
        if not orphan then _fail_immediately(task_name, msg) end
    end)
end

-- Public

---@param task_name string
---@param toml_path string
function M.run(task_name, toml_path)
    local tasks, _, expressions, err = _load_tasks(toml_path)
    if not tasks then
        _fail_immediately(task_name, err or "load error")
        return
    end

    local task = tasks[task_name]
    if not task then
        _fail_immediately(task_name, "task not found: " .. task_name)
        return
    end

    local missing = _find_missing_dep(task_name, tasks, {})
    if missing then
        _fail_immediately(task_name, "unknown dependency: " .. missing)
        return
    end

    local cycle = _find_cycle(task_name, tasks, {}, {})
    if cycle then
        _fail_immediately(task_name, "dependency cycle: " .. cycle)
        return
    end

    -- Collect any currently-active runs for this task
    local active_signals = {}
    for _, e in pairs(_running) do
        if e.task_name == task_name
            and (e.state == "running" or e.state == "waiting") then
            table.insert(active_signals, e.done)
        end
    end
    local is_running = #active_signals > 0

    if not is_running then
        _launch(task_name, tasks, nil, expressions)
        return
    end

    local policy = task.if_running or "refuse"

    if policy == "refuse" then
        notify.notify_warning("task already running: " .. task_name)
    elseif policy == "parallel" then
        _launch(task_name, tasks, nil, expressions)
    elseif policy == "wait" then
        local run_id = _gen_run_id(task_name)
        _running[run_id] = {
            task_name = task_name,
            state     = "waiting",
            bufnrs    = {},
            done      = Signal.new(),
            primary   = true,
            reports   = {},
        }
        _notify_state(run_id)

        local fns = vim.tbl_map(function(sig)
            return function() async.wait_signal(sig) end
        end, active_signals)

        async.go(function() async.wait_all(fns) end, function()
            _launch(task_name, tasks, run_id, expressions)
        end)
    elseif policy == "restart" then
        M.stop(task_name)

        local fns = vim.tbl_map(function(sig)
            return function() async.wait_signal(sig) end
        end, active_signals)

        async.go(function()
            if #fns > 0 then async.wait_all(fns) end
        end, function()
            _launch(task_name, tasks, nil, expressions)
        end)
    end
end

---@param toml_path string
---@return string[]? ordered
---@return table<string,neotasks.TaskBase>? by_name
---@return string? err
function M.list(toml_path)
    local by_name, ordered, _, err = _load_tasks(toml_path)
    return ordered, by_name, err
end

--- Return the sorted names of every expression usable against the given tasks
--- file: the registered built-in/user ones plus the document's inline
--- `[expressions]`. A file that fails to load just contributes nothing.
---@param toml_path string
---@return string[]
function M.list_expression_names(toml_path)
    local names, seen = {}, {}
    for _, entry in ipairs(require("neotasks.expressions").list()) do
        seen[entry.name] = true
        names[#names + 1] = entry.name
    end
    local _, _, expressions = _load_tasks(toml_path)
    for name in pairs(expressions or {}) do
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

--- Evaluate an expression template string against the given tasks file, resolving
--- both built-in and inline `[expressions]`. The result is delivered to `callback`
--- (like `resolver.resolve_expressions`, on the main loop).
---@param toml_path string
---@param expr      string  a value containing `{{ … }}` slots to resolve
---@param callback  fun(ok: boolean, result: any, err: string?)
function M.eval(toml_path, expr, callback)
    local _, _, expressions, err = _load_tasks(toml_path)
    if err then
        callback(false, nil, err)
        return
    end
    resolver.resolve_expressions(expr, { task = {}, expressions = expressions or {} }, callback)
end

--- Stop all active instances of a task. A task that is only waiting for its
--- dependencies has its in-flight dependency runs cancelled too, so the wait
--- unblocks and the task settles as "stopped".
---@param task_name string
function M.stop(task_name)
    for run_id, entry in pairs(_running) do
        if entry.task_name == task_name then
            _stop_run(run_id)
        end
    end
end

--- Whether a run may be disposed, and why not when it may not. The runner owns
--- a run's lifetime, so this is the single place that decides; a view asks it
--- rather than keeping a copy of the state that would drift from the truth.
---@param run_id string
---@return boolean ok, string? err
function M.can_dispose(run_id)
    local entry = _running[run_id]
    if not entry then return false, "run not found: " .. run_id end
    if entry.state == "running" or entry.state == "waiting" then
        return false, "task is still active; stop it first"
    end
    return true
end

---@class neotasks.DisposableRun
---@field run_id string
---@field label  string  task name and how the run ended, for a picker

--- Every run that can be disposed right now: the finished ones,
--- sorted by label.
---@return neotasks.DisposableRun[]
function M.disposable()
    local out = {}
    for run_id, entry in pairs(_running) do
        if M.can_dispose(run_id) then
            out[#out + 1] = { run_id = run_id, label = entry.task_name .. "  [" .. entry.state .. "]" }
        end
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

--- Dispose a finished run: invoke the type's dispose hook (if any), delete all
--- tracked buffers, remove the entry from state, and emit the dispose signal.
--- Returns false + error string if the run is still active.
---
--- This is the one teardown path. A view never tears a run down itself: it asks
--- for this and reacts to the dispose signal, which is emitted before any
--- buffer is deleted so subscribers can stop displaying them first.
---@param run_id string
---@return boolean ok, string? err
function M.dispose(run_id)
    local ok, err = M.can_dispose(run_id)
    if not ok then return false, err end

    local entry      = _running[run_id]
    -- Subscribers must move off this run's buffers synchronously here; they are
    -- deleted as soon as the signal returns.
    _running[run_id] = nil
    _on_dispose:emit(run_id)

    local bufnrs = vim.deepcopy(entry.bufnrs) -- protect against mutation while iterating
    local type_def = entry.task_type and task_types.get(entry.task_type)
    if type_def and type_def.dispose then
        type_def.dispose(run_id, bufnrs)
    else
        for _, be in ipairs(bufnrs) do
            if vim.api.nvim_buf_is_valid(be.bufnr) then
                vim.api.nvim_buf_delete(be.bufnr, { force = true })
            end
        end
    end
    return true
end

--- Return the state of the most recent run for a task, or "idle" if none.
---@param task_name string
---@return neotasks.TaskState
function M.state(task_name)
    local best_n = -1
    local result = "idle" ---@type neotasks.TaskState
    for id, entry in pairs(_running) do
        if entry.task_name == task_name then
            if entry.state == "running" or entry.state == "waiting" then
                return "running"
            end
            local n = tonumber(id:match("#(%d+)$")) or 0
            if n > best_n then
                best_n = n
                result = entry.state
            end
        end
    end
    return result
end

return M
