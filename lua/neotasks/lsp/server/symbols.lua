local M = {}

local schema_nav = require("neotasks.tomltools.schema_nav")

local SK = vim.lsp.protocol.SymbolKind

---@param r integer[]  {r1, c1, r2, c2} 0-indexed
---@return lsp.Range
local function to_lsp_range(r)
    return {
        start   = { line = r[1], character = r[2] },
        ["end"] = { line = r[3], character = r[4] },
    }
end

---@param b integer[]   mutable {r1,c1,r2,c2} bounds (modified in-place)
---@param r integer[]?  range to include
local function expand(b, r)
    if not r then return end
    if r[1] < b[1] or (r[1] == b[1] and r[2] < b[2]) then b[1] = r[1]; b[2] = r[2] end
    if r[3] > b[3] or (r[3] == b[3] and r[4] > b[4]) then b[3] = r[3]; b[4] = r[4] end
end

-- Bounding range that covers every stored range in the subtree rooted at id.
---@param dt tomltools.DecodeTree
---@param id integer
---@return integer[]?
local function subtree_bounds(dt, id)
    local b = { math.huge, math.huge, -1, -1 }
    dt._tree:walk_node(id, function(_, ndata, _)
        for _, r in ipairs(ndata.ranges or {}) do expand(b, r) end
        expand(b, ndata.value_range)
        expand(b, ndata.key_range)
        return true
    end)
    return b[1] ~= math.huge and b or nil
end

-- Navigate decoded data by key-path segments (numeric segments → array index).
---@param data  any
---@param parts string[]
---@return any
local function data_at(data, parts)
    local cur = data
    for _, seg in ipairs(parts) do
        if type(cur) ~= "table" then return nil end
        local idx = tonumber(seg)
        cur = idx and cur[idx] or cur[seg]
    end
    return cur
end

-- Map a TOML value + optional schema to an LSP SymbolKind.
-- top=true for nodes that are direct children of the document root.
---@param val    any
---@param schema table?
---@param top    boolean
---@return integer
local function infer_kind(val, schema, top)
    local st = schema and type(schema.type) == "string" and schema.type
    if st == "object"                       then return top and SK.Module or SK.Object  end
    if st == "array"                        then return SK.Array                        end
    if st == "string"                       then return SK.String                       end
    if st == "integer" or st == "number"    then return SK.Number                       end
    if st == "boolean"                      then return SK.Boolean                      end
    -- fall back to the Lua value
    if type(val) == "table" then
        return vim.islist(val) and SK.Array or (top and SK.Module or SK.Object)
    end
    if type(val) == "string"  then return SK.String  end
    if type(val) == "number"  then return SK.Number  end
    if type(val) == "boolean" then return SK.Boolean end
    return top and SK.Module or SK.Variable
end

-- Short detail string for scalar symbols (value preview).
---@param val any
---@return string?
local function scalar_detail(val)
    if type(val) == "string" then
        return #val <= 60 and val or (val:sub(1, 57) .. "...")
    elseif type(val) == "boolean" or type(val) == "number" then
        return tostring(val)
    end
end

-- Build lsp.DocumentSymbol[] recursively for all children of parent_id.
---@param dt          tomltools.DecodeTree
---@param parent_id   integer
---@param root_schema table?
---@param root_data   any
---@param top         boolean  true when building direct children of the document root
---@return lsp.DocumentSymbol[]
local function build_symbols(dt, parent_id, root_schema, root_data, top)
    local symbols = {}
    local has_schema = root_schema and next(root_schema) ~= nil

    for child_id, node_data in dt._tree:iter_children(parent_id) do
        local first_range = dt:range_of_id(child_id)
        if not first_range then goto continue end

        local full_range = subtree_bounds(dt, child_id) or first_range
        local sel_range  = node_data.key_range or first_range

        local parts = dt:key_parts_of(child_id)
        local val   = data_at(root_data, parts)
        local schema
        if has_schema then
            schema = schema_nav.schema_at(root_schema --[[@as table]], root_data, dt, child_id)
        end

        local kind = infer_kind(val, schema, top)

        local detail
        if schema and schema.title then
            detail = schema.title
        elseif kind ~= SK.Object and kind ~= SK.Array and kind ~= SK.Module then
            detail = scalar_detail(val)
        end

        local children
        if dt._tree:have_children(child_id) then
            local sub = build_symbols(dt, child_id, root_schema, root_data, false)
            if #sub > 0 then children = sub end
        end

        local sym = {
            name           = node_data.key,
            kind           = kind,
            range          = to_lsp_range(full_range),
            selectionRange = to_lsp_range(sel_range),
        }
        if detail   then sym.detail   = detail   end
        if children then sym.children = children end

        symbols[#symbols + 1] = sym
        ::continue::
    end
    return symbols
end

---@param context  neotasks.LspBufferContext
---@param _params  lsp.DocumentSymbolParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.DocumentSymbol[])
function M.handler(context, _params, callback)
    local dt = context.decode_tree
    if not dt then
        callback(nil, {})
        return
    end

    local symbols = build_symbols(dt, dt:root_id(), context.schema, context.data, true)
    callback(nil, symbols)
end

return M
