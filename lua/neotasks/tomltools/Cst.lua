-- tomltools/toml/Cst.lua
-- Concrete Syntax Tree: every source character is a token, composites group them.
-- leaf nodes have:  kind, text (source slice), value (parsed), range {r1,c1,r2,c2}
-- composite nodes have: kind, range {r1,c1,r2,c2}  (no text/value)

local Tree = require("neotasks.tomltools.Tree")

---@class tomltools.CstData
---@field kind  integer
---@field text  string?    source text (leaf tokens)
---@field value any        parsed value (leaf tokens)
---@field range integer[]  {r1, c1, r2, c2}
---@field tag   integer?   DecodeTree node id stamped by the decoder

---@class tomltools.Cst
---@field _tree tomltools.Tree
---@field _id   integer
---@field _root integer
local Cst   = {}
Cst.__index = Cst

---@enum tomltools.CstKind
local Kind = {
    -- Trivia (whitespace-like; skipped by semantic iterators)
    Whitespace    = 1,
    Newline       = 2,
    Comment       = 3,

    -- Key tokens (leaf)
    BareKey       = 4,
    QuotedKey     = 5,

    -- Value literal tokens (leaf)
    String        = 6,
    Integer       = 7,
    Float         = 8,
    Bool          = 9,
    Datetime      = 10,
    DatetimeLocal = 11,
    DateLocal     = 12,
    TimeLocal     = 13,

    -- Punctuation tokens (leaf)
    Equals        = 14,
    Dot           = 15,
    Comma         = 16,
    LBracket      = 17,
    RBracket      = 18,
    LBrace        = 19,
    RBrace        = 20,

    -- Error recovery token (leaf)
    Error         = 21,

    -- Composite nodes (have children)
    Document      = 22,
    TableSection  = 23,  -- [header] line + following KVPs until next section
    AotSection    = 24,  -- [[header]] + following KVPs
    TableHeader   = 25,  -- the [key.key] line tokens only
    AotHeader     = 26,  -- the [[key.key]] line tokens only
    KeyValuePair  = 27,  -- key (. key)* = value
    Array         = 28,  -- [ items ]
    InlineTable   = 29,  -- { kvps }
}

local trivia_set = { [Kind.Whitespace] = true, [Kind.Newline] = true }

local value_set  = {
    [Kind.String] = true, [Kind.Integer] = true, [Kind.Float] = true, [Kind.Bool] = true,
    [Kind.Datetime] = true, [Kind.DatetimeLocal] = true,
    [Kind.DateLocal] = true, [Kind.TimeLocal] = true,
    [Kind.Array] = true, [Kind.InlineTable] = true,
}

Cst.Kind      = Kind
Cst.value_set = value_set

---@return tomltools.Cst
function Cst.new()
    local self  = setmetatable({}, Cst)
    self._tree  = Tree.new()
    self._id    = 1
    self._root  = 1
    self._tree:add_item(nil, 1, { kind = Kind.Document, range = { 0, 0, 0, 0 } })
    return self
end

---@private
---@return integer
function Cst:_next_id()
    self._id = self._id + 1
    return self._id
end

---@return integer
function Cst:root_id() return self._root end

-- Add a leaf token under parent_id and return its id.
---@param parent_id integer
---@param kind      tomltools.CstKind
---@param text      string?
---@param value     any
---@param r1        integer
---@param c1        integer
---@param r2        integer
---@param c2        integer
---@return integer
function Cst:token(parent_id, kind, text, value, r1, c1, r2, c2)
    local id = self:_next_id()
    self._tree:add_item(parent_id, id, {
        kind = kind, text = text, value = value, range = { r1, c1, r2, c2 },
    })
    return id
end

-- Begin a composite node under parent_id; range is finalized by close().
---@param parent_id integer
---@param kind      tomltools.CstKind
---@param r1        integer
---@param c1        integer
---@return integer
function Cst:open(parent_id, kind, r1, c1)
    local id = self:_next_id()
    self._tree:add_item(parent_id, id, { kind = kind, range = { r1, c1, r1, c1 } })
    return id
end

-- Finalize the end of a composite node's range.
---@param id integer
---@param r2 integer
---@param c2 integer
function Cst:close(id, r2, c2)
    local d = self._tree:get_data(id)
    if d then d.range[3] = r2; d.range[4] = c2 end
end

---@param id integer
---@return tomltools.CstData?
function Cst:data(id)         return self._tree:get_data(id) end

---@param id integer
---@return tomltools.CstKind?
function Cst:kind(id)         local d = self._tree:get_data(id); return d and d.kind end

---@param id integer
---@return integer[]?
function Cst:range(id)        local d = self._tree:get_data(id); return d and d.range end

---@param id integer
---@return integer?
function Cst:parent_id(id)    return self._tree:get_parent_id(id) end

---@param id integer
---@return integer?
function Cst:first_child_id(id)  return self._tree:get_first_child_id(id) end

---@param id integer
---@return integer?
function Cst:last_child_id(id)   return self._tree:get_last_child_id(id) end

---@param id integer
---@return integer?
function Cst:prev_sibling_id(id) return self._tree:get_prev_sibling_id(id) end

---@param id integer
---@return integer?
function Cst:next_sibling_id(id) return self._tree:get_next_sibling_id(id) end

---@param id integer
---@param v  integer
function Cst:set_tag(id, v) local d = self._tree:get_data(id); if d then d.tag = v end end

---@param id integer
---@return integer?
function Cst:get_tag(id)    local d = self._tree:get_data(id); return d and d.tag end

-- Iterate all children of parent_id.
---@param parent_id integer
---@return fun(): integer?, tomltools.CstData?
function Cst:children(parent_id)
    return self._tree:iter_children(parent_id)
end

-- Iterate children, skipping Whitespace and Newline tokens.
---@param parent_id integer
---@return fun(): integer?, tomltools.CstData?
function Cst:iter_semantic(parent_id)
    local iter = self._tree:iter_children(parent_id)
    return function()
        while true do
            local id, d = iter()
            if not id then return nil end
            if not trivia_set[d.kind] then return id, d end
        end
    end
end

-- Find the first immediate child whose kind matches any of the given kinds.
---@param parent_id integer
---@param ...       tomltools.CstKind
---@return integer?
---@return tomltools.CstData?
function Cst:first_child_of_kind(parent_id, ...)
    local want = { ... }
    local id   = self._tree:get_first_child_id(parent_id)
    while id do
        local d = self._tree:get_data(id)
        for _, w in ipairs(want) do
            if d.kind == w then return id, d end
        end
        id = self._tree:get_next_sibling_id(id)
    end
    return nil
end

-- Walk up from id, returning the nearest ancestor whose kind matches any argument.
---@param id integer
---@param ... tomltools.CstKind
---@return integer?
function Cst:ancestor_of_kind(id, ...)
    local want = { ... }
    local cur  = self._tree:get_parent_id(id)
    while cur do
        local k = self:kind(cur)
        for _, w in ipairs(want) do
            if k == w then return cur end
        end
        cur = self._tree:get_parent_id(cur)
    end
    return nil
end

-- Collect BareKey/QuotedKey data from a header or KVP node (stops at Equals or LBrace).
---@param node_id integer
---@return tomltools.CstData[]
function Cst:get_keys(node_id)
    local keys = {}
    for _, d in self:iter_semantic(node_id) do
        if d.kind == Kind.BareKey or d.kind == Kind.QuotedKey then
            keys[#keys + 1] = d
        elseif d.kind == Kind.Equals or d.kind == Kind.LBrace then
            break
        end
    end
    return keys
end

-- Return the first value node id+data after the Equals token in a KVP.
---@param kvp_id integer
---@return integer?
---@return tomltools.CstData?
function Cst:get_value(kvp_id)
    local after = false
    for id, d in self:iter_semantic(kvp_id) do
        if after and value_set[d.kind] then return id, d end
        if d.kind == Kind.Equals then after = true end
    end
    return nil, nil
end

-- Iterate children that are value nodes (for arrays: skips brackets, commas, trivia).
---@param parent_id integer
---@return fun(): integer?, tomltools.CstData?
function Cst:iter_values(parent_id)
    local iter = self._tree:iter_children(parent_id)
    return function()
        while true do
            local id, d = iter()
            if not id then return nil end
            if value_set[d.kind] then return id, d end
        end
    end
end

-- Walk every node in the tree, calling handler(id, data, depth).
---@param handler fun(id: integer, data: tomltools.CstData, depth: integer)
function Cst:walk(handler)
    self._tree:walk_tree(handler)
end

-- Find the deepest leaf whose range contains (row, col).
-- When no token contains the cursor (e.g. trailing empty line past all tokens),
-- falls back to the deepest leaf that ends nearest before the cursor so that
-- section context is preserved. Always returns a valid id.
-- Ranges end one past their last column, so a cursor sitting on that boundary
-- counts as inside. Pass right_gravity to give the boundary
-- to whatever starts there instead.
---@param row integer
---@param col integer
---@param right_gravity boolean?
---@return integer
function Cst:token_at(row, col, right_gravity)
    local function contains(r)
        local last = right_gravity and r[4] - 1 or r[4]
        if r[1] > row or (r[1] == row and r[2] > col) then return false end
        if r[3] < row or (r[3] == row and last < col) then return false end
        return true
    end
    local function descend(id)
        for child_id, d in self._tree:iter_children(id) do
            if contains(d.range) then
                if self._tree:have_children(child_id) then
                    local found = descend(child_id)
                    if found then return found end
                end
                return child_id
            end
        end
        return nil
    end
    -- Walk last_child → prev_sibling to find the deepest leaf ending just before
    -- the cursor without scanning all children.
    local function nearest_preceding(id)
        local child = self._tree:get_last_child_id(id)
        while child do
            local d = self._tree:get_data(child)
            if d and (d.range[3] < row or (d.range[3] == row and d.range[4] <= col)) then
                if self._tree:have_children(child) then
                    return nearest_preceding(child) or child
                end
                return child
            end
            child = self._tree:get_prev_sibling_id(child)
        end
        return nil
    end
    return descend(self._root) or nearest_preceding(self._root) or self._root
end

return Cst
