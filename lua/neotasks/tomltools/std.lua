-- Small standard-library helpers used across the codebase. Keeping them in one
-- place lets the decoder/encoder/validator share a single, well-defined set of
-- table and string utilities with no external dependencies.

local M = {}

-- Shared sentinel metatable marking a table as a TOML/JSON *object* even when it
-- is empty. An empty `{}` is otherwise indistinguishable from an empty array, so
-- `islist` below relies on this tag to tell the two apart: a plain empty table
-- counts as a list, but one carrying this metatable does not.
M.EMPTY_DICT_MT = {}

-- Sentinel for an explicit JSON `null`.
M.NULL = setmetatable({}, { __tostring = function() return "null" end })

--- An empty table tagged as an object rather than an array.
---@return table
function M.empty_dict()
    return setmetatable({}, M.EMPTY_DICT_MT)
end

--- True when `t` is a list (array): a table whose keys are exactly 1..n with no
--- gaps. An empty plain table counts as a list; an `empty_dict()` does not.
---@param t any
---@return boolean
function M.islist(t)
    if type(t) ~= "table" then return false end
    if getmetatable(t) == M.EMPTY_DICT_MT then return false end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

--- Apply `fn` to every value of `t`, preserving keys.
---@param fn fun(v: any): any
---@param t table
---@return table
function M.tbl_map(fn, t)
    local out = {}
    for k, v in pairs(t) do out[k] = fn(v) end
    return out
end

--- Append the list `src` onto the end of the list `dst`, in place.
---@param dst table
---@param src table
---@return table dst
function M.list_extend(dst, src)
    for i = 1, #src do dst[#dst + 1] = src[i] end
    return dst
end

--- True when `value` appears in the list `t`.
---@param t table
---@param value any
---@return boolean
function M.tbl_contains(t, value)
    for _, v in ipairs(t) do
        if v == value then return true end
    end
    return false
end

--- Recursive deep copy, preserving metatables (so `empty_dict()` tags survive).
---@generic T
---@param orig T
---@return T
function M.deepcopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[M.deepcopy(k)] = M.deepcopy(v)
    end
    return setmetatable(copy, getmetatable(orig))
end

--- Split `s` on the literal separator `sep`, keeping empty segments (including a
--- trailing one). The separator is always matched literally (no patterns), which
--- covers the single-character separators this library uses.
---@param s string
---@param sep string
---@param _opts table?  accepted for call-site compatibility; separator is always literal
---@return string[]
function M.split(s, sep, _opts)
    local out, start = {}, 1
    local sep_len = #sep
    while true do
        local i = string.find(s, sep, start, true)
        if not i then
            out[#out + 1] = string.sub(s, start)
            return out
        end
        out[#out + 1] = string.sub(s, start, i - 1)
        start = i + sep_len
    end
end

--- Minimal type assertion: errors unless `value` has the `expected_type`.
---@param name string
---@param value any
---@param expected_type string
function M.validate(name, value, expected_type)
    if type(value) ~= expected_type then
        error(("%s: expected %s, got %s"):format(name, expected_type, type(value)), 2)
    end
end

local function is_identifier(k)
    return type(k) == "string" and k:match("^[%a_][%w_]*$") ~= nil
end

--- Human-readable serialisation of a Lua value for the one display-only call
--- site (schema default rendering). Keys are sorted for determinism.
---@param v any
---@return string
function M.inspect(v)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "nil" then
        return "nil"
    elseif t ~= "table" then
        return tostring(v)
    end

    if M.islist(v) then
        local parts = {}
        for i = 1, #v do parts[i] = M.inspect(v[i]) end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end

    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        local key = is_identifier(k) and k or ("[" .. M.inspect(k) .. "]")
        parts[#parts + 1] = key .. " = " .. M.inspect(v[k])
    end
    if #parts == 0 then return "{}" end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

return M
