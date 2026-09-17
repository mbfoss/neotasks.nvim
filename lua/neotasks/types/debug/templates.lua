local ordered = require("neotasks.util.table_util").ordered

--- Debug templates are projected from ndap's per-adapter named modes rather
--- than hand-maintained: one entry per (adapter, mode) declared by the adapters
--- listed in `setup{ debug_adapters }`, with `parameters` prefilled for the
--- mode's required inputs.

--- Build the `parameters` skeleton for one (adapter, mode): every required
--- input, sorted, seeded from ndap's input registry in an authored form the
--- tasks-file schema accepts. A written value still wins when the task runs.
---@param ndap ndap.Module
---@param adapter string
---@param mode_name string
---@return table params, string[] order
local function _parameters(ndap, adapter, mode_name)
    local required = ndap.mode_required(adapter, mode_name)
    local inputs   = ndap.mode_inputs(adapter, mode_name)

    local params, order = {}, {}
    for _, name in ipairs(required) do
        params[name] = ndap.input_seed(inputs[name])
        order[#order + 1] = name
    end
    return params, order
end

---@return neotasks.TaskTemplate[]
return function()
    local ndap = require("ndap")
    local debug = require("neotasks.types.debug")
    local templates = {}
    for _, adapter in ipairs(debug.adapters()) do
        for _, mode_name in ipairs(ndap.mode_names(adapter)) do
            local task_keys = { "name", "type", "adapter", "mode" }
            local task = {
                name    = "debug-" .. adapter,
                type    = "debug",
                adapter = adapter,
                mode = mode_name,
            }
            -- Only an adapter with a configured expander offers `target`, the
            -- field the schema advertises for it. Its required inputs are then
            -- the expander's to fill, so they are not seeded: a seed would win
            -- over the target (an integer seed of 0, notably, cannot read as
            -- unset), and a missing one is still reported by ndap at start.
            local params, order = {}, {}
            if debug.target_expander(adapter) then
                task.target = ""
                task_keys[#task_keys + 1] = "target"
            else
                params, order = _parameters(ndap, adapter, mode_name)
            end
            if #order > 0 then
                task.parameters = ordered(params, order)
                task_keys[#task_keys + 1] = "parameters"
            end
            templates[#templates + 1] = {
                label = ("%s - %s"):format(adapter, mode_name),
                task  = ordered(task, task_keys),
            }
        end
    end
    return templates
end
