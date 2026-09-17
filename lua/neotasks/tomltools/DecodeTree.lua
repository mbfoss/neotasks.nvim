-- tomltools/toml/DecodeTree.lua

local Tree         = require("neotasks.tomltools.Tree")

---@class tomltools.DecodeNodeData
---@field key    string        path segment (unescaped)
---@field ranges integer[][]   list of {r1,c1,r2,c2} source ranges (one per segment/occurrence)
---@field schema table?        resolved schema fragment for this path

---@class tomltools.PosIndexEntry
---@field r1    integer
---@field c1    integer
---@field r2    integer
---@field c2    integer
---@field id    integer
---@field depth integer

---@class tomltools.DecodeTree
---@field _tree        tomltools.Tree
---@field _root_id     integer
---@field _id_seq      integer
---@field _pos_index   tomltools.PosIndexEntry[]   flat sorted list, built lazily
---@field _index_dirty boolean
local DecodeTree   = {}
DecodeTree.__index = DecodeTree

---@return tomltools.DecodeTree
function DecodeTree.new()
    local self    = setmetatable({}, DecodeTree)
    self._tree    = Tree.new()
    self._id_seq  = 0
    self._id_seq  = self._id_seq + 1
    self._root_id = self._id_seq
    self._tree:add_item(nil, self._id_seq, { key = "", ranges = {}, schema = nil })
    self._pos_index   = {}
    self._index_dirty = false
    return self
end

---@private
---@return integer
function DecodeTree:_next_id()
    self._id_seq = self._id_seq + 1
    return self._id_seq
end

---@return integer
function DecodeTree:root_id()
    return self._root_id
end

-- Find an immediate child of parent_id whose key matches; returns nil if absent.
---@param parent_id integer?
---@param key string
---@return integer?
function DecodeTree:get_child_id(parent_id, key)
    if not parent_id then return nil end
    for child_id, data in self._tree:iter_children(parent_id) do
        if data.key == key then return child_id end
    end
    return nil
end

-- Add a new child node under parent_id; returns its id.
---@param parent_id integer
---@param key string
---@param range integer[]?
---@return integer
function DecodeTree:add_child(parent_id, key, range)
    local id = self:_next_id()
    self._tree:add_item(parent_id, id, { key = key, ranges = range and { range } or {}, schema = nil })
    self._index_dirty = true
    return id
end

-- Append a range to an existing node's range list.
---@param id integer
---@param range integer[]?
function DecodeTree:add_range_by_id(id, range)
    if range then
        local data = self._tree:get_data(id)
        data.ranges[#data.ranges + 1] = range
        self._index_dirty = true
    end
end

---@param id integer
---@return integer[][]
function DecodeTree:ranges_of_id(id)
    local data = self._tree:get_data(id)
    return data and data.ranges or {}
end

---@param id integer
---@return integer[]?
function DecodeTree:range_of_id(id)
    return self:ranges_of_id(id)[1]
end

---@param id integer
---@return integer[]?
function DecodeTree:get_value_range(id)
    local data = self._tree:get_data(id)
    return data and data.value_range
end

---@param handler fun(id:any, data:any, depth:number):boolean?
function DecodeTree:walk_tree(handler)
    return self._tree:walk_tree(handler)
end

--------------------------------------------------------------------------------
-- Position index
--------------------------------------------------------------------------------

---@private
-- Rebuild the flat sorted position index from the tree.
-- Entries are sorted by (r1, c1); depth reflects tree depth so that the deepest
-- (most specific) containing node wins on lookup.
function DecodeTree:_rebuild_index()
    if not self._index_dirty then return end

    local entries = {}
    self._tree:walk_tree(function(id, data, depth)
        if id ~= self._root_id and data.ranges then
            for _, r in ipairs(data.ranges) do
                entries[#entries + 1] = {
                    r1 = r[1],
                    c1 = r[2],
                    r2 = r[3],
                    c2 = r[4],
                    id = id,
                    depth = depth,
                }
            end
        end
        return true
    end)

    table.sort(entries, function(a, b)
        if a.r1 ~= b.r1 then return a.r1 < b.r1 end
        return a.c1 < b.c1
    end)

    self._pos_index   = entries
    self._index_dirty = false
end

---@private
-- Binary search: returns the index of the rightmost entry whose start ≤ (row, col).
-- Returns 0 if no such entry exists.
---@param row integer
---@param col integer
---@return integer
function DecodeTree:_bsearch_start(row, col)
    local idx = self._pos_index
    local lo, hi, found = 1, #idx, 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local e   = idx[mid]
        if e.r1 < row or (e.r1 == row and e.c1 <= col) then
            found = mid
            lo    = mid + 1
        else
            hi = mid - 1
        end
    end
    return found
end

---@param row integer  0-indexed
---@param col integer  0-indexed
---@return integer?  id of the deepest node whose range contains (row, col)
function DecodeTree:pos_to_id(row, col)
    self:_rebuild_index()

    local hi = self:_bsearch_start(row, col)
    if hi == 0 then return nil end

    local best_id, best_depth = nil, -1
    for i = hi, 1, -1 do
        local e = self._pos_index[i]
        if (row > e.r1 or (row == e.r1 and col >= e.c1))
            and (row < e.r2 or (row == e.r2 and col <= e.c2)) then
            if e.depth > best_depth then
                best_depth = e.depth
                best_id    = e.id
            end
        end
    end

    return best_id
end

---@param id integer
---@return integer?
function DecodeTree:get_parent_id(id)
    return self._tree:get_parent_id(id)
end

---@param id integer
function DecodeTree:mark_as_key_node(id)
    local data = self._tree:get_data(id)
    if data then data.is_key_node = true end
end

---@param id integer
---@return boolean
function DecodeTree:is_key_node(id)
    local data = self._tree:get_data(id)
    return data ~= nil and data.is_key_node == true
end

-- Store the source range of the value for a node. The range starts at the
-- first character of the value token (after `=` and any whitespace), so that
-- cursor_on_value triggers even when the cursor is between `=` and the value.
---@param id    integer
---@param range integer[]  {r1, c1, r2, c2}
function DecodeTree:set_value_range(id, range)
    local data = self._tree:get_data(id)
    if data and range then data.value_range = range end
end

-- Store the source range of the key token itself (not including `=` or value).
---@param id    integer
---@param range integer[]  {r1, c1, r2, c2}
function DecodeTree:set_key_range(id, range)
    local data = self._tree:get_data(id)
    if data and range then data.key_range = range end
end

-- Returns true when (row, col) is at or past the start of the value range,
-- i.e. the cursor is on the value side of the key-value pair (not on the
-- key token or the `=` operator).
---@param id  integer
---@param row integer
---@param col integer
---@return boolean
function DecodeTree:cursor_on_value(id, row, col)
    local data = self._tree:get_data(id)
    if not data or not data.value_range then return false end
    local vr = data.value_range
    return row > vr[1] or (row == vr[1] and col >= vr[2])
end

-- Returns true when (row, col) is within the key token itself. Nodes without a
-- stored key_range (e.g. table-section headers) fall back to checking that the
-- cursor is before the value range start. Incomplete pairs without `=` return
-- true only when is_key_node is set.
---@param id  integer
---@param row integer
---@param col integer
---@return boolean
function DecodeTree:cursor_on_key(id, row, col)
    local data = self._tree:get_data(id)
    if not data then return false end
    if not data.value_range then return data.is_key_node == true end
    -- Cursor must be before the value start (not on `=` side or value).
    local vr = data.value_range
    if not (row < vr[1] or (row == vr[1] and col < vr[2])) then return false end
    -- When a precise key token range is stored, require cursor to be within it
    -- so the gap between the key text and `=` does not trigger key completions.
    local kr = data.key_range
    if not kr then return true end
    return (row > kr[1] or (row == kr[1] and col >= kr[2]))
        and (row < kr[3] or (row == kr[3] and col <= kr[4] + 1))
end

--------------------------------------------------------------------------------
-- Path utilities
--------------------------------------------------------------------------------

-- Returns a set of immediate child keys under parent_id.
---@param parent_id integer?
---@return table<string, boolean>
function DecodeTree:child_keys(parent_id)
    if not parent_id or not self._tree:have_item(parent_id) then return {} end
    local keys = {}
    for _, data in self._tree:iter_children(parent_id) do
        keys[data.key] = true
    end
    return keys
end

-- Among the immediate children of array_id, the element whose source starts
-- latest at or before (row, col). A single-bracket sub-table header ([a.b])
-- attaches to the most recent [[a]] element before it, so callers use this to
-- pick which array-of-tables element a header binds to. Returns the element's
-- node id and its key ("1", "2", …); nil when there is no matching child.
---@param array_id integer
---@param row      integer
---@param col      integer
---@return integer? id
---@return string?  key
function DecodeTree:bound_element(array_id, row, col)
    local best_id, best_key, best_r, best_c
    for child_id, data in self._tree:iter_children(array_id) do
        local sr, sc
        for _, rg in ipairs(data.ranges or {}) do
            if not sr or rg[1] < sr or (rg[1] == sr and rg[2] < sc) then sr, sc = rg[1], rg[2] end
        end
        if sr and (sr < row or (sr == row and sc <= col))
            and (not best_r or sr > best_r or (sr == best_r and sc > best_c)) then
            best_id, best_key, best_r, best_c = child_id, data.key, sr, sc
        end
    end
    return best_id, best_key
end

-- Returns the key segments from root down to id (not including root).
---@param id integer
---@return string[]
function DecodeTree:key_parts_of(id)
    local parts   = {}
    local current = id
    while current ~= self._root_id do
        local data = self._tree:get_data(current)
        table.insert(parts, 1, data.key)
        current = self._tree:get_parent_id(current)
    end
    return parts
end

return DecodeTree
