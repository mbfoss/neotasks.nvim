local M = {}

---@param t table
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

---@param t table
---@return string[]?
function M.ordered_keys_of(t)
    if type(t) ~= "table" then return nil end
    local mt = getmetatable(t)
    return mt and type(mt.keys_order) == "table" and mt.keys_order or nil
end

return M
