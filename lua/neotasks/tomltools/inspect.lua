-- Inspect a TOML document to find the structural context at a cursor position.

local Cst     = require("neotasks.tomltools.Cst")
local parser  = require("neotasks.tomltools.parser")
local decoder = require("neotasks.tomltools.decoder")
local std     = require("neotasks.tomltools.std")
local _K      = Cst.Kind

local M = {}

---@class tomltools.PathNode
---@field name   string        TOML key segment
---@field type   "array"|"aot"
---@field indent string?       indentation of existing items; present for "array" nodes

---@param lines  string[]
---@param cst    tomltools.Cst
---@param arr_id integer
---@return string
local function _array_item_indent(lines, cst, arr_id)
    for _, vd in cst:iter_values(arr_id) do
        if vd.kind == _K.InlineTable then
            local line = lines[vd.range[1] + 1] or ""
            return line:match("^(%s*)") or "  "
        end
    end
    return "  "
end

-- The section enclosing the cursor: the token itself when the cursor landed on a
-- section composite (its trailing gap, where no leaf token contains the cursor),
-- otherwise the nearest ancestor section of one of the given kinds. nil when the
-- cursor is not inside any such section.
---@param cst    tomltools.Cst
---@param tok_id integer
---@param ...    tomltools.CstKind
---@return integer?
local function _enclosing_section(cst, tok_id, ...)
    local k = cst:kind(tok_id)
    for _, want in ipairs({ ... }) do
        if k == want then return tok_id end
    end
    return cst:ancestor_of_kind(tok_id, ...)
end

-- Whether any KeyValuePair follows the cursor within `section_id`. Insertion is
-- only valid in a section's trailing gap; a cursor sitting *before* an existing
-- key is rejected, since a new section header there would capture that key into
-- the wrong table. When the cursor landed on the section composite itself, it is
-- past all children and nothing follows.
---@param cst        tomltools.Cst
---@param section_id integer
---@param tok_id     integer
---@return boolean
local function _kvp_follows(cst, section_id, tok_id)
    if tok_id == section_id then return false end
    -- Anchor = the direct child of the section that contains the cursor token.
    local anchor = tok_id ---@type integer?
    while anchor and cst:parent_id(anchor) ~= section_id do
        anchor = cst:parent_id(anchor)
    end
    local sib = anchor and cst:next_sibling_id(anchor)
    while sib do
        if cst:kind(sib) == _K.KeyValuePair then return true end
        sib = cst:next_sibling_id(sib)
    end
    return false
end

--- Find the TOML structural path at the cursor.
--- Returns a list of PathNodes from outermost to innermost relevant container,
--- an empty list when the cursor is at document root (valid AoT insertion point),
--- or nil when parsing fails or the cursor is not at any insertable position.
---@param text string
---@param row  integer  0-indexed
---@param col  integer  0-indexed
---@return tomltools.PathNode[]?
function M.find_path(text, row, col)
    local parsed = parser.parse(text)
    if not parsed.cst then return nil end
    local decoded = decoder.decode(parsed.cst)
    local cst, dt = parsed.cst, decoded.decode_tree
    local lines   = std.split(text, "\n", { plain = true })

    local tok_id = cst:token_at(row, col)

    -- Cursor inside an Array (not inside an InlineTable within it).
    local anc = cst:ancestor_of_kind(tok_id, _K.Array, _K.InlineTable)
    if anc and cst:kind(anc) == _K.Array then
        local name
        local tag = cst:get_tag(anc)
        if tag and dt then
            local parts = dt:key_parts_of(tag)
            name = parts[#parts]
        else
            local kvp_id = cst:ancestor_of_kind(anc, _K.KeyValuePair)
            if kvp_id then
                local keys = cst:get_keys(kvp_id)
                name = keys[#keys] and keys[#keys].value
            end
        end
        if name then
            return { { name = name, type = "array", indent = _array_item_indent(lines, cst, anc) } }
        end
    end

    -- Section insertion points: the cursor sits in a section's trailing gap (not
    -- inside any KVP, and with no further key following it), where a new sibling
    -- entry or top-level section can be inserted.
    if not cst:ancestor_of_kind(tok_id, _K.KeyValuePair) then
        -- [[key]] AoT section → a sibling [[key]] entry belongs here.
        local aot_id = _enclosing_section(cst, tok_id, _K.AotSection)
        if aot_id and not _kvp_follows(cst, aot_id, tok_id) then
            local hdr_id = cst:first_child_of_kind(aot_id, _K.AotHeader)
            local keys   = hdr_id and cst:get_keys(hdr_id)
            if keys and #keys >= 1 then
                return { { name = keys[1].value, type = "aot" } }
            end
        end

        -- [key] / [key.sub] table section.
        local tbl_id = _enclosing_section(cst, tok_id, _K.TableSection)
        if tbl_id and not _kvp_follows(cst, tbl_id, tok_id) then
            local hdr_id = cst:first_child_of_kind(tbl_id, _K.TableHeader)
            local keys   = hdr_id and cst:get_keys(hdr_id)
            if keys and #keys >= 2 then
                -- A dotted [a.b] header lives inside the [[a]] array; treat the
                -- cursor as being between that array's entries.
                return { { name = keys[1].value, type = "aot" } }
            elseif keys and #keys == 1 then
                -- A single top-level [a] table: its trailing gap is a
                -- document-root position where a new top-level section fits.
                return {}
            end
        end
    end

    -- Cursor at document root (only trivia).
    local _trivial = {
        [_K.Whitespace] = true, [_K.Newline] = true,
        [_K.Comment]    = true, [_K.Document] = true,
    }

    ---@type integer?,boolean
    local cur, at_root = tok_id, true
    while cur do
        if not _trivial[cst:kind(cur)] then at_root = false; break end
        cur = cst:parent_id(cur)
    end
    if at_root then return {} end

    return nil
end

return M
