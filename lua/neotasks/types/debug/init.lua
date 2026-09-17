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
--- `setup{ debug_adapters = … }`, kept to those ezdap has registered. Only
--- these get their definition loaded for the schema and templates.
---@return string[]
function M.adapters()
    local wanted = require("neotasks.config").debug_adapters or {}
    if #wanted == 0 then return {} end

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

--- Widen one input's schema to every form the tasks file may write it in: the
--- typed form ezdap's input registry states, plus the string form it reads for
--- the same value (`port = "8080"`, `env = "A=1,B=2"`) — `resolve_task` takes
--- either. The typed constraints stay, and apply to the typed form alone.
---@param prop table  the input's typed form, as JSON Schema (mutated in place)
---@return table
local function _authored_forms(prop)
    if prop.type ~= "string" then
        prop.type = { prop.type, "string" }
    end
    return prop
end

--- The `parameters` object schema for one (adapter, mode): one property per
--- input the mode declares, described with the input's own `description` and
--- typed in the authored forms ezdap's input registry states as JSON Schema.
--- Every input resolves to a row there, so every one of them is described.
---@param sch table  the `ezdap.schema` module
---@param adapter string
---@param mode_name string
---@return table
local function _parameters_schema(sch, adapter, mode_name)
    local dap_inputs = require("ezdap.inputs")
    local required   = sch.mode_required(adapter, mode_name)

    local props      = {}
    for name, input in pairs(sch.mode_inputs(adapter, mode_name)) do
        local prop = _authored_forms(dap_inputs.json_schema(input))
        prop.description = input.description
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
---@param sch table  the `ezdap.schema` module
---@param adapter string
---@param mode_names string[]
---@return table
local function _mode_name_schema(sch, adapter, mode_names)
    local one_of = {}
    for _, mode_name in ipairs(mode_names) do
        local mode = sch.mode(adapter, mode_name)
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
--- modes gets no branch — an empty `mode` oneOf would reject every value.
---@param sch table  the `ezdap.schema` module
---@param adapter string
---@return table?
local function _adapter_branch(sch, adapter)
    local mode_names = sch.mode_names(adapter)
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
                    parameters = _parameters_schema(sch, adapter, mode_name),
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
                mode = _mode_name_schema(sch, adapter, mode_names),
            },
            allOf = mode_branches,
        },
    }
end

--- The per-adapter branches, for every adapter that declares modes.
---@param sch table  the `ezdap.schema` module
---@param adapters string[]  the configured adapter names
---@return table[]
local function _mode_branches(sch, adapters)
    local branches = {}
    for _, adapter in ipairs(adapters) do
        branches[#branches + 1] = _adapter_branch(sch, adapter)
    end
    return branches
end

--- The `debug` task schema. neotasks owns only the framework fields; the DAP
--- vocabulary lives entirely under `parameters` and is projected from ezdap's
--- per-adapter named modes.
---@return table
local function _schema()
    local sch           = require("ezdap.schema")
    local adapters      = M.adapters()
    local mode_branches = _mode_branches(sch, adapters)

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
---@field adapter        string
---@field mode           string
---@field parameters?    table<string, any>

--- Each live run's ezdap run handle, by run id, so disposing a run can drop what
--- it left in ezdap. Entries are dropped as the runs are disposed.
---@type table<string, ezdap.runner.Run>
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

    -- ezdap resolves the mode and runs the session; we present the run — its
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
---@param run_id string
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

M.schema = _schema

---@return neotasks.TaskTemplate[]
M.templates = function()
    return require("neotasks.types.debug.templates")()
end

return M
