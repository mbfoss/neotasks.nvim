local M = {}

--- Wrap a table with a __tostring that emits keys in the given order.
--- Remaining keys are appended sorted. Subtables with __tostring are
--- serialized recursively via tostring().
---@param t    table
---@param keys string[]
---@return table
function M.ordered(t, keys)
    if next(t) and next(keys) ~= nil then
        return setmetatable(t, {
            keys_order = keys
        })
    else
        return t
    end
end

function M.ordered_keys_of(t)
    if type(t) ~= "table" then return nil end
    local mt = getmetatable(t)
    return mt and type(mt.keys_order) == "table" and mt.keys_order or nil
end

return M
