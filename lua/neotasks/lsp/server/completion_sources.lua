--- Named dynamic value sources for schema `x-completionType` fields.
--- A string field carrying `["x-completionType"] = "<name>"` is completed from
--- the resolver registered here under `<name>`, rather than from a static enum.
--- Each resolver is a pure function of the completion context and returns the
--- candidate values (with optional per-item detail/documentation) to offer.
local M = {}

--- A single completion candidate produced by a source.
---@class neotasks.CompletionCandidate
---@field name           string  the value inserted (unquoted)
---@field detail?        string  short hint shown to the right in the menu
---@field documentation? string  expanded documentation

--- The context a source is resolved against.
---@class neotasks.CompletionSourceCtx
---@field data any       decoded document data (may be nil or partial while typing)
---@field path string[]  key path of the node being completed (root-relative)

--- Task names declared in the document, excluding the task the cursor sits
--- inside (a task cannot depend on itself). Backs `depends_on`.
---@param ctx neotasks.CompletionSourceCtx
---@return neotasks.CompletionCandidate[]
function M.TaskNamesExceptSelf(ctx)
    local tasks = type(ctx.data) == "table" and ctx.data.tasks or nil
    if type(tasks) ~= "table" then return {} end
    -- The value's path is { "tasks", <name>, "depends_on" }; the segment aligned
    -- with the enumerated collection (index 2) is the task being edited.
    local self_name = (ctx.path and ctx.path[1] == "tasks") and ctx.path[2] or nil
    local out = {}
    for name, node in pairs(tasks) do
        if name ~= self_name then
            out[#out + 1] = {
                name          = name,
                detail        = type(node) == "table" and node.type or nil,
                documentation = type(node) == "table" and node.description or nil,
            }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

return M
