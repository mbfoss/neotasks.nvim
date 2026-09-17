---@class neotasks.debug.Module : neotasks.TaskTypeDef
local M = {}

--- Names already reported by `M.adapters`, so a misconfigured list warns once
--- rather than on every schema build.
---@type table<string, true>
local _warned = {}

---@param key string
---@param msg string
local function _warn_once(key, msg)
    if _warned[key] then return end
    _warned[key] = true
    vim.notify("neotasks: " .. msg, vim.log.levels.WARN)
end

--- The adapters the `debug` type may use: the ones named in
--- `setup{ debug_adapters = … }`, kept to those ndap has registered, plus
--- ndap's built-in `remote` adapter, which is always included. Only these get
--- their definition loaded for the schema and templates.
---@return string[]
function M.adapters()
    local wanted = { "remote" }
    for _, name in ipairs(require("neotasks.config").current.debug_adapters or {}) do
        if name ~= "remote" then wanted[#wanted + 1] = name end
    end

    -- The registered names, which cost no adapter load.
    local available = {}
    for _, name in ipairs(require("ndap").available_adapters()) do
        available[name] = true
    end

    local out = {}
    for _, name in ipairs(wanted) do
        if available[name] then
            out[#out + 1] = name
        else
            _warn_once(name, ("debug_adapters: %q is not a registered ndap adapter"):format(name))
        end
    end
    return out
end

--- The JSON Schema a scalar input's authored value is typed as, by its
--- `ndap.InputType` name. A collection's entries are read as scalars too, so
--- both slots (a scalar's `type`, a collection's `item_type`) land on one of
--- these. An absent or unknown name is `string`, the type an input defaults to.
---@type table<string, table>
local _scalar_schemas = {
    string  = { type = "string" },
    boolean = { type = "boolean" },
    integer = { type = "integer" },
    number  = { type = "number" },
}

--- The `target` expander configured for `adapter`, if any. The function is the
--- user's, so a misconfigured entry warns once and behaves as unset rather
--- than breaking every schema.
---@param adapter string
---@return neotasks.DebugTarget?
function M.target_expander(adapter)
    local fn = (require("neotasks.config").current.debug_targets or {})[adapter]
    if fn == nil then return nil end
    if type(fn) ~= "function" then
        _warn_once("debug_targets:" .. adapter,
            ("debug_targets[%q] is a %s, expected a function"):format(adapter, type(fn)))
        return nil
    end
    return fn
end

--- The `target` property schema, offered only for an adapter with an expander.
---@param adapter string
---@return table
local function _target_schema(adapter)
    return {
        type        = "string",
        minLength   = 1,
        description = ("Shorthand expanded into this mode's inputs by "
            .. "`debug_targets[%q]`; values in `parameters` win"):format(adapter),
    }
end

--- One declared input as JSON Schema, in the typed authored form: a string is
--- the command line's form and reaches no document, so it is not spelled out
--- here. A `list` is an array, a `map` an object, their entries typed by
--- `item_type`; `completion` describes one entry either way, and only a
--- written-out set of values can be shown, as `examples`.
---@param input ndap.Input?
---@return table
local function _input_schema(input)
    input            = input or {}

    local collection = input.type == "list" or input.type == "map"
    local entry_type = collection and input.item_type or input.type
    local scalar     = vim.deepcopy(_scalar_schemas[entry_type] or _scalar_schemas.string)

    -- `completion` describes one *entry*, so its values land on the element
    -- schema: the array's `items`, the object's `additionalProperties`. Only a
    -- written-out set of values can be shown; a source name or a function has
    -- nothing to serialize.
    local completion = input.completion
    if type(completion) == "table" and vim.islist(completion) then
        scalar.examples = vim.deepcopy(completion)
    end

    if input.type == "list" then return { type = "array", items = scalar } end
    if input.type == "map" then return { type = "object", additionalProperties = scalar } end
    return scalar
end

--- The `parameters` object schema for one (adapter, mode): one property per
--- input the mode declares, described with the input's own `description` and
--- typed in the authored form `_input_schema` derives from `ndap.Input`.
---@param ndap ndap.Module
---@param adapter string
---@param mode_name string
---@return table
local function _parameters_schema(ndap, adapter, mode_name)
    local inputs = ndap.mode_inputs(adapter, mode_name)
    -- A `target` expander may fill any of these at start time, so none is
    -- required here; ndap still reports a value neither form supplied.
    local required = M.target_expander(adapter) and {} or ndap.mode_required(adapter, mode_name)

    local props    = {}
    for name, input in pairs(inputs) do
        local prop = _input_schema(input)
        prop.description = input and input.description
        props[name] = prop
    end

    return {
        type                 = "object",
        additionalProperties = false,
        properties           = props,
        required             = (#required > 0) and required or nil,
    }
end

--- A `mode` property schema listing an adapter's mode names,
--- with each name's `description` (from ndap) attached so the LSP can show
--- it on completion/hover.
---@param ndap ndap.Module
---@param adapter string
---@param mode_names string[]
---@return table
local function _mode_name_schema(ndap, adapter, mode_names)
    local one_of = {}
    for _, mode_name in ipairs(mode_names) do
        local mode = ndap.mode(adapter, mode_name)
        one_of[#one_of + 1] = {
            const       = mode_name,
            description = mode and mode.description,
        }
    end
    return {
        type      = "string",
        minLength = 1,
        oneOf     = one_of,
    }
end

--- One adapter's conditional branch: it tests only `adapter` and nests the
--- (adapter, mode) `parameters` branches inside its own `then`, so the
--- navigator walks only the matched adapter's modes. An adapter declaring no
--- modes gets no branch: an empty `mode` oneOf would reject every value.
---@param ndap ndap.Module
---@param adapter string
---@return table?
local function _adapter_branch(ndap, adapter)
    local mode_names = ndap.mode_names(adapter)
    if #mode_names == 0 then return nil end

    local mode_branches = {}
    for _, mode_name in ipairs(mode_names) do
        mode_branches[#mode_branches + 1] = {
            ["if"] = {
                type       = "object",
                required   = { "mode" },
                properties = {
                    mode = { const = mode_name },
                },
            },
            ["then"] = {
                properties = {
                    parameters = _parameters_schema(ndap, adapter, mode_name),
                },
            },
        }
    end

    -- `target` is per adapter, not per mode: one expander receives the mode in
    -- its context and decides what the string means there.
    local then_properties = {
        mode = _mode_name_schema(ndap, adapter, mode_names),
    }
    if M.target_expander(adapter) then
        then_properties.target = _target_schema(adapter)
    end

    return {
        ["if"] = {
            type       = "object",
            required   = { "adapter" },
            properties = { adapter = { const = adapter } },
        },
        ["then"] = {
            properties = then_properties,
            allOf      = mode_branches,
        },
    }
end

--- The per-adapter branches, for every adapter that declares modes.
---@param ndap ndap.Module
---@param adapters string[]  the configured adapter names
---@return table[]
local function _mode_branches(ndap, adapters)
    local branches = {}
    for _, adapter in ipairs(adapters) do
        branches[#branches + 1] = _adapter_branch(ndap, adapter)
    end
    return branches
end

--- The `debug` task schema. neotasks owns only the framework fields; the
--- vocabulary of a mode's inputs is defined entirely under `parameters`, projected
--- from ndap's per-adapter named modes. `parameters` holds those inputs in the
--- authored form, not the DAP launch/attach body: a mode's `build` is what turns
--- them into that body, which a task never spells out.
---@return table
local function _schema()
    local ndap          = require("ndap")
    local adapters      = M.adapters()
    local mode_branches = _mode_branches(ndap, adapters)

    if vim.tbl_isempty(mode_branches) then
        return {
            ["x-order"] = {
                "name", "type", "if_running", "depends_on", "depends_order", "save_buffers",
                "adapter",
            },
            properties  = {
            },
        }
    end

    return {
        description = "Definition of a `debug` task (runs via a DAP adapter)",
        ["x-order"] = {
            "name", "type", "if_running", "depends_on", "depends_order", "save_buffers",
            "adapter", "mode", "target", "parameters",
        },
        required    = { "adapter", "mode" },
        properties  = {
            adapter    = {
                type        = "string",
                minLength   = 1,
                description = "Name of the DAP adapter to use, from `setup{ debug_adapters }`",
                enum        = (#adapters > 0) and adapters or nil,
            },
            mode       = {
                type        = "string",
                minLength   = 1,
                description = "Name of the adapter's named mode to run (its available launch/attach shapes)",
            },
            parameters = {
                type                 = { "object", "null" },
                additionalProperties = true,
                description          = "Values for the selected `mode`'s inputs",
            },
        },
        allOf       = mode_branches,
    }
end

---A `debug` task: the framework base plus the adapter/mode selection
---and the values for that mode's inputs.
---@class neotasks.DebugTask : neotasks.TaskBase
---@field save_buffers?  boolean|neotasks.TaskSaveBuffers
---@field adapter        string
---@field mode           string
---@field target?        string  shorthand expanded by `setup{ debug_targets }`
---@field parameters?    table<string, any>

--- A value the expander returned, read as its input's type.
---@param name string
---@param input ndap.Input
---@param value any
---@return string? err
local function _validate_value(name, input, value)
    local _, err = require("ndap.run.inputs").read(input, value)
    if err then return ("target function returned %q: %s"):format(name, err) end
    return nil
end

--- The `parameters` with the `target` filled by the adapter's expander; a throw,
--- a bad key or an unreadable value is reported. `parameters` wins where both set one.
---@param expand neotasks.DebugTarget?  the adapter's configured expander
---@param target string?  the authored target
---@param ctx neotasks.DebugTargetCtx
---@return table<string, any> parameters, string? err
function M.apply_target(expand, target, ctx)
    local out = vim.deepcopy(ctx.parameters or {})
    if target == nil or target == "" then return out end
    if type(target) ~= "string" then
        return out, "target must be a string"
    end
    if not target:find("%S") then return out end
    if type(expand) ~= "function" then
        return out, "this adapter has no `debug_targets` function; set parameters instead"
    end

    local ok, expanded = pcall(expand, target, ctx)
    if not ok then
        return out, ("target function failed: %s"):format(tostring(expanded))
    end
    if expanded == nil then return out end
    if type(expanded) ~= "table" then
        return out, ("target function returned a %s, expected a table or nil"):format(type(expanded))
    end

    for name, value in pairs(expanded) do
        if type(name) ~= "string" then
            return out, ("target function returned a %s key, expected an input name")
                :format(type(name))
        end
        local input = ctx.inputs[name]
        if input == nil then
            return out, ("target function returned %q, which mode %q does not declare")
                :format(name, ctx.mode)
        end
        local value_err = _validate_value(name, input, value)
        if value_err then return out, value_err end
        if out[name] == nil or out[name] == "" then out[name] = vim.deepcopy(value) end
    end
    return out
end

--- Each live run's ndap run handle, by run id, so disposing a run can drop what
--- it left in ndap. Entries are dropped as the runs are disposed.
---@type table<integer, ndap.runner.Run>
local _ndap_runs = {}

---@param task    neotasks.DebugTask
---@param ctx     neotasks.RunCtx
---@param on_done fun(ok: boolean)
---@return fun()
function M.start(task, ctx, on_done)
    -- Listing adapters needs no ndap setup(), but running one does.
    if not require("ndap").is_setup() then
        ctx.report("require('ndap').setup() has not been called")
        on_done(false)
        return function() end
    end

    -- Only the listed adapters are loaded, so an unlisted one has no schema
    -- behind it and does not run; say what to add rather than starting blind.
    if not vim.tbl_contains(M.adapters(), task.adapter) then
        ctx.report(("adapter %q is not in setup{ debug_adapters = { … } }"):format(task.adapter))
        on_done(false)
        return function() end
    end

    local ndap = require("ndap")

    -- A `target` string is expanded into the mode's inputs by its adapter's
    -- configured function; a failure stops before a session exists.
    local parameters, target_err = M.apply_target(
        M.target_expander(task.adapter),
        task.target,
        {
            adapter    = task.adapter,
            mode       = task.mode,
            parameters = vim.deepcopy(task.parameters or {}),
            inputs     = ndap.mode_inputs(task.adapter, task.mode),
        })
    if target_err then
        ctx.report(target_err)
        on_done(false)
        return function() end
    end

    -- ndap resolves the mode and runs the session; we present the run. Its
    -- buffers, its progress and its outcome arrive through these callbacks,
    -- and ndap's own panels never see it. A mode's `build` may prompt the user
    -- first, so the run can still be resolving here; `cancel` calls that off
    -- too.
    local run = require("ndap").start_mode(task.adapter, task.mode, parameters, {
        name      = ctx.name,
        add_bufnr = ctx.add_bufnr,
        report    = ctx.report,
        on_done   = on_done,
    })

    -- Only a bad adapter or mode name leaves no run, and ndap has reported it.
    if not run then
        on_done(false)
        return function() end
    end

    _ndap_runs[ctx.run_id] = run
    return function() run.cancel() end
end

--- Delete the run's buffers and let ndap drop what the run left in its own UI.
--- A run that never got as far as starting has no handle to drop.
---@param run_id integer
---@param bufnrs neotasks.BufEntry[]
function M.dispose(run_id, bufnrs)
    local run = _ndap_runs[run_id]
    _ndap_runs[run_id] = nil
    if run then require("ndap").remove_run(run) end

    for _, be in ipairs(bufnrs) do
        if vim.api.nvim_buf_is_valid(be.bufnr) then
            vim.api.nvim_buf_delete(be.bufnr, { force = true })
        end
    end
end

M.schema                = _schema
M.supports_save_buffers = true

---@return neotasks.TaskTemplate[]
M.templates             = function()
    return require("neotasks.types.debug.templates")()
end

return M
