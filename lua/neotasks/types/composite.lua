local ordered = require("neotasks.util.table_util").ordered

-- Composite tasks have no command of their own; their entire behaviour is
-- the dependency resolution done by exec.lua before run() is called.
---@type neotasks.TaskTypeDef
return {
    no_action = true,
    ---@return fun()
    start = function(_, _, on_done)
        on_done(true)
        return function() end
    end,

    schema = {
        description = "Definition of a `composite` task",
        ["x-order"] = { "name", "type", "if_running", "depends_on", "depends_order", "save_buffers" },
    },

    templates = {
        {
            label = "Task Sequence",
            task  = ordered(
                { name = "Sequence", type = "composite", depends_on = { "", "" }, depends_order = "sequence" },
                { "name", "type", "depends_on", "depends_order" }
            ),
        },
        {
            label = "Parallel Tasks",
            task  = ordered(
                { name = "Parallel", type = "composite", depends_on = { "", "" }, depends_order = "parallel" },
                { "name", "type", "depends_on", "depends_order" }
            ),
        },
    },
}
