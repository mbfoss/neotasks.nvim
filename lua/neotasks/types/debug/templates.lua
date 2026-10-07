local ordered = require("neotasks.util.table_util").ordered

--- Debug templates are projected from ndap's per-adapter named modes rather
--- than hand-maintained: one entry per (adapter, mode) declared by the adapters
--- listed in `setup{ debug_adapters }`, with `parameters` prefilled for the
--- mode's required inputs.

--- Build the `parameters` skeleton for one (adapter, mode): every required
--- input, sorted. Starting values come from ndap's input registry, so the task
--- is seeded in the authored form the tasks-file schema demands.
---@param ndap ndap.Module
---@param adapter string
---@param mode_name string
---@return table params, string[] order  empty when the mode requires nothing
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
    local templates = {}
    for _, adapter in ipairs(require("neotasks.types.debug").adapters()) do
        for _, mode_name in ipairs(ndap.mode_names(adapter)) do
            local task_keys = { "name", "type", "adapter", "mode" }
            local task = {
                name    = "debug-" .. adapter,
                type    = "debug",
                adapter = adapter,
                mode = mode_name,
            }
            local params, order = _parameters(ndap, adapter, mode_name)
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
