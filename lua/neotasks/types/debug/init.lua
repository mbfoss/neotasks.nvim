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
--- `setup{ debug_adapters = … }`, kept to those ezdap has registered, plus
--- ezdap's built-in `remote` adapter, which is always included. Only these get
--- their definition loaded for the schema and templates.
---@return string[]
function M.adapters()
    local wanted = { "remote" }
    for _, name in ipairs(require("neotasks.config").current.debug_adapters or {}) do
        if name ~= "remote" then wanted[#wanted + 1] = name end
    end

    -- The registered names, which cost no adapter load.
    local available = {}
    for _, name in ipairs(require("ezdap").available_adapters()) do
        available[name] = true
    end

    local out = {}
    for _, name in ipairs(wanted) do
        if available[name] then
            out[#out + 1] = name
        else
            _warn_once(name, ("debug_adapters: %q is not a registered ezdap adapter"):format(name))
        end
    end
    return out
end

--- The JSON Schema a scalar input's authored value is typed as, by its
--- `ezdap.InputType` name. A collection's entries are read as scalars too, so
--- both slots — a scalar's `type`, a collection's `item_type` — land on one of
--- these. An absent or unknown name is `string`, the type an input defaults to.
---@type table<string, table>
local _scalar_schemas = {
    string  = { type = "string" },
    boolean = { type = "boolean" },
    integer = { type = "integer" },
    number  = { type = "number" },
}

--- One declared input as JSON Schema, in the typed authored form: a string is
--- the command line's form and reaches no document, so it is not spelled out
--- here. A `list` is an array and a `map` an object, their entries typed by
--- `item_type`; `completion` describes one entry either way, and only a
--- written-out set of values can be shown, as `examples`.
---@param input ezdap.Input?
---@return table
local function _input_schema(input)
    input = input or {}

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
--- typed in the authored form `_input_schema` derives from `ezdap.Input`.
---@param ezdap ezdap.Module
---@param adapter string
---@param mode_name string
---@return table
local function _parameters_schema(ezdap, adapter, mode_name)
    local required = ezdap.mode_required(adapter, mode_name)

    local props    = {}
    for name, input in pairs(ezdap.mode_inputs(adapter, mode_name)) do
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
--- with each name's `description` (from ezdap) attached so the LSP can show
--- it on completion/hover.
---@param ezdap ezdap.Module
---@param adapter string
---@param mode_names string[]
---@return table
local function _mode_name_schema(ezdap, adapter, mode_names)
    local one_of = {}
    for _, mode_name in ipairs(mode_names) do
        local mode = ezdap.mode(adapter, mode_name)
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
--- modes gets no branch - an empty `mode` oneOf would reject every value.
---@param ezdap ezdap.Module
---@param adapter string
---@return table?
local function _adapter_branch(ezdap, adapter)
    local mode_names = ezdap.mode_names(adapter)
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
                    parameters = _parameters_schema(ezdap, adapter, mode_name),
                },
            },
        }
    end

    return {
        ["if"] = {
            type       = "object",
            required   = { "adapter" },
            properties = { adapter = { const = adapter } },
        },
        ["then"] = {
            properties = {
                mode = _mode_name_schema(ezdap, adapter, mode_names),
            },
            allOf = mode_branches,
        },
    }
end

--- The per-adapter branches, for every adapter that declares modes.
---@param ezdap ezdap.Module
---@param adapters string[]  the configured adapter names
---@return table[]
local function _mode_branches(ezdap, adapters)
    local branches = {}
    for _, adapter in ipairs(adapters) do
        branches[#branches + 1] = _adapter_branch(ezdap, adapter)
    end
    return branches
end

--- The `debug` task schema. neotasks owns only the framework fields; the DAP
--- vocabulary lives entirely under `parameters` and is projected from ezdap's
--- per-adapter named modes.
---@return table
local function _schema()
    local ezdap         = require("ezdap")
    local adapters      = M.adapters()
    local mode_branches = _mode_branches(ezdap, adapters)

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
            "adapter", "mode", "parameters",
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
---@field parameters?    table<string, any>

--- Each live run's ezdap run handle, by run id, so disposing a run can drop what
--- it left in ezdap. Entries are dropped as the runs are disposed.
---@type table<integer, ezdap.runner.Run>
local _ezdap_runs = {}

---@param task    neotasks.DebugTask
---@param ctx     neotasks.RunCtx
---@param on_done fun(ok: boolean)
---@return fun()
function M.start(task, ctx, on_done)
    -- Listing adapters needs no ezdap setup(), but running one does.
    if not require("ezdap").is_setup() then
        ctx.report("require('ezdap').setup() has not been called")
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

    -- ezdap resolves the mode and runs the session; we present the run - its
    -- buffers, its progress and its outcome arrive through these callbacks, and
    -- ezdap's own panels never see it. A mode's `build` may prompt the user first,
    -- so the run can still be resolving here; `cancel` calls that off too.
    local run = require("ezdap").run_mode(task.adapter, task.mode, task.parameters, {
        name      = ctx.name,
        add_bufnr = ctx.add_bufnr,
        report    = ctx.report,
        on_done   = on_done,
    })

    -- Only a bad adapter or mode name leaves no run, and ezdap has reported it.
    if not run then
        on_done(false)
        return function() end
    end

    _ezdap_runs[ctx.run_id] = run
    return function() run.cancel() end
end

--- Delete the run's buffers and let ezdap drop what the run left in its own UI.
--- A run that never got as far as starting has no handle to drop.
---@param run_id integer
---@param bufnrs neotasks.BufEntry[]
function M.dispose(run_id, bufnrs)
    local run = _ezdap_runs[run_id]
    _ezdap_runs[run_id] = nil
    if run then require("ezdap").remove_run(run) end

    for _, be in ipairs(bufnrs) do
        if vim.api.nvim_buf_is_valid(be.bufnr) then
            vim.api.nvim_buf_delete(be.bufnr, { force = true })
        end
    end
end

M.schema                = _schema
M.supports_save_buffers = true

---@return neotasks.TaskTemplate[]
M.templates = function()
    return require("neotasks.types.debug.templates")()
end

return M
