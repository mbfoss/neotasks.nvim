-- neotasks/lsp/builtin_actions.lua
-- Built-in code action providers. Assigned to every buffer context in server.lua.
-- Each provider matches the signature: fun(ctx, params) -> lsp.CodeAction[]

local M          = {}

local schema_nav = require("neotasks.tomltools.schema_nav")
local s_util     = require("neotasks.tomltools.schema_util")
local Cst        = require("neotasks.tomltools.Cst")
local encoder    = require("neotasks.tomltools.encoder")

local K          = Cst.Kind

-- Helpers

---@param sl   integer  0-indexed start line
---@param sc   integer  0-indexed start char (inclusive)
---@param el   integer  0-indexed end line
---@param ec   integer  0-indexed end char (exclusive)
---@param text string
---@return lsp.TextEdit
local function text_edit(sl, sc, el, ec, text)
    return {
        range   = { start = { line = sl, character = sc }, ["end"] = { line = el, character = ec } },
        newText = text,
    }
end

---@param title string
---@param kind  string
---@param uri   string
---@param edits lsp.TextEdit[]
---@return lsp.CodeAction
local function make_action(title, kind, uri, edits)
    return { title = title, kind = kind, edit = { changes = { [uri] = edits } } }
end

-- Returns the CST scope node and DecodeTree id for the section containing (row,col),
-- falling back to document root when the cursor is not inside any section.
---@param cst tomltools.Cst
---@param dt  tomltools.DecodeTree
---@param row integer
---@param col integer
---@return integer?  scope_id   nil at document root
---@return integer   dt_id
local function enclosing_scope(cst, dt, row, col)
    local tok_id   = cst:token_at(row, col)
    local scope_id = cst:ancestor_of_kind(tok_id, K.TableSection, K.AotSection)
    local dt_id    = (scope_id and cst:get_tag(scope_id)) or dt:root_id()
    return scope_id, dt_id
end

---@param lines string[]
---@param row   integer  0-indexed
---@return string
local function line_at(lines, row)
    return lines[row + 1] or ""
end

--- Leading whitespace of a source row, so rewritten blocks keep the surrounding
--- indentation of hand-indented files.
---@param lines string[]
---@param row   integer
---@return string
local function indent_of(lines, row)
    return line_at(lines, row):match("^[ \t]*") or ""
end

--- True when the node's subtree holds a comment. The table-shape actions re-emit
--- values through the encoder, which works from decoded data and so cannot carry
--- comments along.
---@param cst tomltools.Cst
---@param id  integer
---@return boolean
local function has_comment(cst, id)
    for child_id, d in cst:children(id) do
        if d.kind == K.Comment then return true end
        if has_comment(cst, child_id) then return true end
    end
    return false
end

--- The decoded table a CST node addresses, plus the key path leading to it. The
--- decoder tags pair, inline-table and section nodes with their DecodeTree id,
--- so the path comes straight from the decode tree. Returns nil for anything
--- that is not a decoded table - including a node the decoder rejected, and one
--- addressed by an index (an array element), which no path of keys reaches.
---@param cst     tomltools.Cst
---@param dt      tomltools.DecodeTree
---@param data    table?
---@param node_id integer
---@return table?    value
---@return string[]? parts
local function decoded_table_at(cst, dt, data, node_id)
    local dt_id = cst:get_tag(node_id)
    if not dt_id then return nil end

    local parts = dt:key_parts_of(dt_id)
    if #parts == 0 then return nil end

    local value = vim.tbl_get(data or {}, unpack(parts))
    if type(value) ~= "table" then return nil end
    return value, parts
end

--- Encode a decoded value with a forced layout, as an array or an inline table.
--- Which one is decided by the CST node kind rather than by the value's shape,
--- since an empty table is both a valid `[]` and a valid `{}`.
---@param value     table
---@param is_array  boolean
---@param multiline boolean
---@param indent    string   indentation of the line the value starts on
---@return string
local function encode_layout(value, is_array, multiline, indent)
    local text
    if is_array then
        text = encoder.encode_array(value, { multiline = multiline, indent = indent })
    elseif multiline then
        text = encoder.encode_inline(value, { multiline = true, indent = indent })
    else
        text = encoder.encode_inline(value)
    end
    -- The `key = ` prefix already occupies the first line's indentation.
    return (text:gsub("^[ \t]+", ""))
end

--- Source text between two positions, end exclusive.
---@param lines string[]
---@param sr    integer
---@param sc    integer
---@param er    integer
---@param ec    integer
---@return string
local function slice(lines, sr, sc, er, ec)
    if sr == er then return line_at(lines, sr):sub(sc + 1, ec) end
    local parts = { line_at(lines, sr):sub(sc + 1) }
    for r = sr + 1, er - 1 do parts[#parts + 1] = line_at(lines, r) end
    parts[#parts + 1] = line_at(lines, er):sub(1, ec)
    return table.concat(parts, "\n")
end

--- The range to cut for a block occupying whole lines: the block itself plus
--- the newline in front of it and any blank lines above, so what it leaves
--- behind is the gap that was already there.
---@param lines string[]
---@param sr    integer  first row of the block
---@param er    integer  last row of the block
---@return integer[]     {r1, c1, r2, c2}
local function block_range(lines, sr, er)
    local ec = #line_at(lines, er)
    if sr == 0 then return { 0, 0, er, ec } end
    local top = sr - 1
    while top > 0 and line_at(lines, top):match("^[ \t]*$") do top = top - 1 end
    return { top, #line_at(lines, top), er, ec }
end

--- One edit that cuts the range `rm` and puts `text` at `ins`, which has to lie
--- outside `rm`. Emitting the cut and the insertion as two edits would leave
--- their order undefined wherever the positions meet, which is the common case.
---@param lines string[]
---@param rm    integer[]  {r1, c1, r2, c2}
---@param ins   integer[]  {row, col}
---@param text  string
---@return lsp.TextEdit
local function cut_paste(lines, rm, ins, text)
    if ins[1] < rm[1] or (ins[1] == rm[1] and ins[2] <= rm[2]) then
        return text_edit(ins[1], ins[2], rm[3], rm[4], text .. slice(lines, ins[1], ins[2], rm[1], rm[2]))
    end
    local mid = slice(lines, rm[3], rm[4], ins[1], ins[2])
    -- A block that starts the file has no newline above it for the cut to
    -- take, so the blank space below it goes instead.
    if rm[1] == 0 and rm[2] == 0 then mid = (mid:gsub("^\n+", "")) end
    return text_edit(rm[1], rm[2], ins[1], ins[2], mid .. text)
end

--- Where a new key-value pair belongs in a scope: after the last pair already
--- there, or right after the header when the scope has none. `skip` is the row
--- span of a block being moved out, so nothing inside it becomes the anchor.
--- Returns nil for a document root that holds no pairs of its own.
---@param cst      tomltools.Cst
---@param scope_id integer
---@param skip     integer[]  {first row, last row}
---@return integer? row
---@return integer? col
local function scope_insert_pos(cst, scope_id, skip)
    local anchor
    for child_id, d in cst:iter_semantic(scope_id) do
        if d.kind == K.KeyValuePair and (d.range[1] > skip[2] or d.range[3] < skip[1]) then
            anchor = child_id
        end
    end
    anchor = anchor or cst:first_child_of_kind(scope_id, K.TableHeader, K.AotHeader)
    local r = anchor and cst:range(anchor)
    if not r then return nil end
    return r[3], r[4]
end

--- True when `parts` begins with every segment of `prefix`.
---@param parts  string[]
---@param prefix string[]
---@return boolean
local function starts_with(parts, prefix)
    if #parts < #prefix then return false end
    for i = 1, #prefix do
        if parts[i] ~= prefix[i] then return false end
    end
    return true
end

--- Iterate the document's sections with their decoded key paths. Sections the
--- decoder rejected carry no path and are skipped.
---@param cst tomltools.Cst
---@param dt  tomltools.DecodeTree
---@return fun(): integer?, string[]?
local function iter_sections(cst, dt)
    local iter = cst:iter_semantic(cst:root_id())
    return function()
        while true do
            local id, d = iter()
            if not id or not d then return nil end
            if d.kind == K.TableSection or d.kind == K.AotSection then
                local tag = cst:get_tag(id)
                if tag then return id, dt:key_parts_of(tag) end
            end
        end
    end
end

--- The innermost array or inline table containing the cursor, so that the two
--- layout actions never both fire for one position.
---@param cst tomltools.Cst
---@param row integer
---@param col integer
---@return integer?              node_id
---@return tomltools.CstKind?    kind
local function enclosing_container(cst, row, col)
    local function probe(right_gravity)
        local tok_id = cst:token_at(row, col, right_gravity)
        local kind   = cst:kind(tok_id)
        if kind == K.Array or kind == K.InlineTable then return tok_id, kind end
        local node_id = cst:ancestor_of_kind(tok_id, K.Array, K.InlineTable)
        if node_id then return node_id, cst:kind(node_id) end
    end
    -- The cursor on an opening "{" or "[" sits on the end boundary of the token
    -- before it, outside the container; right gravity puts it in. Left gravity
    -- still answers for a cursor just past the closing one.
    local node_id, kind = probe(true)
    if node_id then return node_id, kind end
    return probe(false)
end

-- Action: fill missing required keys

--- Offers to insert all required keys that are absent from the enclosing section.
--- Uses schema defaults as placeholder values; falls back to `""` for untyped keys.
---@param ctx    neotasks.LspBufferContext
---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
function M.fill_required_keys(ctx, params)
    if not (ctx.cst and ctx.decode_tree and ctx.schema and ctx.lines) then return {} end

    local cst             = ctx.cst
    local dt              = ctx.decode_tree --[[@as tomltools.DecodeTree]]
    local schema          = ctx.schema --[[@as table]]
    local data            = ctx.data
    local row             = params.range.start.line
    local col             = params.range.start.character

    local scope_id, dt_id = enclosing_scope(cst, dt, row, col)

    local sch             = schema_nav.schema_at(schema, data, dt, dt_id)
    if not sch or not sch.required or #sch.required == 0 then return {} end

    -- Collect required keys absent from the decode tree for this scope.
    local missing = {}
    for _, req_key in ipairs(sch.required) do
        if not dt:get_child_id(dt_id, req_key) then
            missing[#missing + 1] = req_key
        end
    end
    if #missing == 0 then return {} end

    -- Build `key = value` lines, using schema defaults where available.
    local new_lines = {}
    for _, key in ipairs(missing) do
        local prop_sch            = sch.properties and sch.properties[key]
        local default             = prop_sch and s_util.get_default_toml(prop_sch)
        local value               = (default and default ~= "") and default or '""'
        new_lines[#new_lines + 1] = key .. " = " .. value
    end

    -- Insert after the last KVP in scope (or end of section/document as fallback).
    local parent_id = scope_id or cst:root_id()
    local last_kvp_id
    for child_id, child_d in cst:iter_semantic(parent_id) do
        if child_d.kind == K.KeyValuePair then
            last_kvp_id = child_id
        end
    end

    local ins_row, ins_col, prefix
    if last_kvp_id then
        local r = cst:range(last_kvp_id)
        if not r then return {} end
        ins_row, ins_col, prefix = r[3], r[4], "\n"
    elseif scope_id then
        local header_id = cst:first_child_of_kind(scope_id, K.TableHeader, K.AotHeader)
        local r         = header_id and cst:range(header_id) or cst:range(scope_id)
        if not r then return {} end
        ins_row, ins_col, prefix = r[3], r[4], "\n"
    else
        ins_row, ins_col, prefix = #ctx.lines - 1, #(ctx.lines[#ctx.lines] or ""), ""
    end

    local n     = #missing
    local label = "Fill " .. n .. " missing required key" .. (n > 1 and "s" or "")
    return {
        make_action(label, "quickfix", params.textDocument.uri, {
            text_edit(ins_row, ins_col, ins_row, ins_col, prefix .. table.concat(new_lines, "\n")),
        })
    }
end

-- Action: expand / collapse an inline table

--- Offers to switch the inline table under the cursor between its one-line and
--- its expanded form.
---@param ctx    neotasks.LspBufferContext
---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
function M.toggle_inline_table_layout(ctx, params)
    if not (ctx.cst and ctx.decode_tree and ctx.lines and ctx.data) then return {} end

    local cst           = ctx.cst --[[@as tomltools.Cst]]
    local dt            = ctx.decode_tree --[[@as tomltools.DecodeTree]]
    local lines         = ctx.lines --[[@as string[] ]]
    local node_id, kind = enclosing_container(cst, params.range.start.line, params.range.start.character)
    if not node_id or kind ~= K.InlineTable or has_comment(cst, node_id) then return {} end

    local value = decoded_table_at(cst, dt, ctx.data, node_id)
    if not value then return {} end

    local r         = cst:range(node_id) --[[@as integer[] ]]
    local multiline = r[1] ~= r[3]
    local new_text  = encode_layout(value, false, not multiline, indent_of(lines, r[1]))
    local title     = multiline and "Collapse inline table to one line" or "Expand inline table across lines"

    return {
        make_action(title, "refactor.rewrite", params.textDocument.uri,
            { text_edit(r[1], r[2], r[3], r[4], new_text) }),
    }
end

-- Action: expand / collapse an array

--- Offers to switch the array under the cursor between its one-line and its
--- expanded form. The array has to be a pair's own value: an array nested in
--- another array is addressed by index, which no path of keys reaches.
---@param ctx    neotasks.LspBufferContext
---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
function M.toggle_array_layout(ctx, params)
    if not (ctx.cst and ctx.decode_tree and ctx.lines and ctx.data) then return {} end

    local cst           = ctx.cst --[[@as tomltools.Cst]]
    local dt            = ctx.decode_tree --[[@as tomltools.DecodeTree]]
    local lines         = ctx.lines --[[@as string[] ]]
    local node_id, kind = enclosing_container(cst, params.range.start.line, params.range.start.character)
    if not node_id or kind ~= K.Array or has_comment(cst, node_id) then return {} end

    local kvp_id = cst:ancestor_of_kind(node_id, K.KeyValuePair)
    local val_id = kvp_id and cst:get_value(kvp_id)
    if val_id ~= node_id then return {} end

    local value = decoded_table_at(cst, dt, ctx.data, kvp_id --[[@as integer]])
    -- An empty array has no layout to switch to.
    if not value or #value == 0 then return {} end

    local r         = cst:range(node_id) --[[@as integer[] ]]
    local multiline = r[1] ~= r[3]
    local new_text  = encode_layout(value, true, not multiline, indent_of(lines, r[1]))
    local title     = multiline and "Collapse array to one line" or "Expand array across lines"

    return {
        make_action(title, "refactor.rewrite", params.textDocument.uri,
            { text_edit(r[1], r[2], r[3], r[4], new_text) }),
    }
end

-- Action: inline table → section

--- The pair whose value is the inline table under the cursor, when that pair
--- sits at section (or document) scope. A pair nested inside another inline
--- table has no section of its own to become.
---@param cst tomltools.Cst
---@param row integer
---@param col integer
---@return integer? kvp_id
---@return integer? scope_id  the enclosing section, nil at document root
local function section_scope_pair(cst, row, col)
    local node_id, kind = enclosing_container(cst, row, col)
    if not node_id or kind ~= K.InlineTable then return nil end

    local kvp_id = cst:ancestor_of_kind(node_id, K.KeyValuePair)
    if not kvp_id or cst:get_value(kvp_id) ~= node_id then return nil end

    local parent = cst:parent_id(kvp_id)
    local pkind  = parent and cst:kind(parent)
    if pkind == K.TableSection or pkind == K.AotSection then return kvp_id, parent end
    if pkind == K.Document then return kvp_id, nil end
    return nil
end

--- Offers to rewrite `opts = { … }` as its own `[tasks.build.opts]` section.
--- The section goes after the last pair of the scope the pair lived in, since
--- everything below a header belongs to it.
---@param ctx    neotasks.LspBufferContext
---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
function M.inline_table_to_section(ctx, params)
    if not (ctx.cst and ctx.decode_tree and ctx.lines and ctx.data) then return {} end

    local cst              = ctx.cst --[[@as tomltools.Cst]]
    local dt               = ctx.decode_tree --[[@as tomltools.DecodeTree]]
    local lines            = ctx.lines --[[@as string[] ]]
    local kvp_id, scope_id = section_scope_pair(cst, params.range.start.line, params.range.start.character)
    if not kvp_id or has_comment(cst, kvp_id) then return {} end

    local value, parts = decoded_table_at(cst, dt, ctx.data, kvp_id)
    if not value or not parts then return {} end

    local r      = cst:range(kvp_id) --[[@as integer[] ]]
    local rm     = block_range(lines, r[1], r[3])
    local ir, ic = scope_insert_pos(cst, scope_id or cst:root_id(), { r[1], r[3] })
    -- A pair alone at document scope has nothing to anchor to; the section it
    -- becomes is valid exactly where the pair already is.
    local ins    = { ir or rm[1], ic or rm[2] }

    local body = { encoder.encode_header(parts) }
    for _, l in ipairs(encoder.encode_kvps(value)) do body[#body + 1] = l end

    local indent = indent_of(lines, r[1])
    local block  = table.concat(body, "\n")
    if indent ~= "" then block = indent .. block:gsub("\n", "\n" .. indent) end
    -- A section header wants a blank line above it, unless it opens the file.
    local sep = (ins[1] == 0 and ins[2] == 0) and "" or "\n\n"

    return {
        make_action("Convert to section " .. encoder.encode_header(parts), "refactor.rewrite",
            params.textDocument.uri, { cut_paste(lines, rm, ins, sep .. block) }),
    }
end

-- Action: section → inline table

--- The section that opens `parts` as a scope, or the document root for an empty
--- path. nil when no section carries that path.
---@param cst   tomltools.Cst
---@param dt    tomltools.DecodeTree
---@param parts string[]
---@return integer?
local function section_for_path(cst, dt, parts)
    if #parts == 0 then return cst:root_id() end
    for id, p in iter_sections(cst, dt) do
        if #p == #parts and starts_with(p, parts) then return id end
    end
    return nil
end

--- True when another section extends `parts`, e.g. [a.b.c] below [a.b]. Its
--- keys are part of the decoded table, so folding one up would have to move
--- the other too.
---@param cst   tomltools.Cst
---@param dt    tomltools.DecodeTree
---@param parts string[]
---@return boolean
local function has_subsection(cst, dt, parts)
    for _, p in iter_sections(cst, dt) do
        if #p > #parts and starts_with(p, parts) then return true end
    end
    return false
end

--- True when a comment sits among the section's pairs, which re-encoding them
--- would drop. Comments past the last pair belong to the gap before the next
--- section and stay where they are.
---@param cst     tomltools.Cst
---@param sec_id  integer
---@param last_id integer  the section's last pair, or its header when it has none
---@return boolean
local function pairs_have_comment(cst, sec_id, last_id)
    for child_id, d in cst:iter_semantic(sec_id) do
        if d.kind == K.Comment or has_comment(cst, child_id) then return true end
        if child_id == last_id then return false end
    end
    return false
end

--- Offers to fold a `[tasks.build.env]` section back into an `env = { … }` pair
--- of its parent section. Triggered from the header line only, and refused when
--- the pair would have nowhere valid to land: no parent section in the file, or
--- a deeper section whose keys the fold would strand.
---@param ctx    neotasks.LspBufferContext
---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
function M.section_to_inline_table(ctx, params)
    if not (ctx.cst and ctx.decode_tree and ctx.lines and ctx.data) then return {} end

    local cst    = ctx.cst --[[@as tomltools.Cst]]
    local dt     = ctx.decode_tree --[[@as tomltools.DecodeTree]]
    local lines  = ctx.lines --[[@as string[] ]]
    local row    = params.range.start.line

    -- Right gravity: the previous section ends at the opening "[" of this
    -- header, and the cursor there belongs to the header it opens.
    local tok_id = cst:token_at(row, params.range.start.character, true)
    local sec_id = cst:ancestor_of_kind(tok_id, K.TableSection, K.AotSection) or tok_id
    -- An [[aot]] entry is one element of an array, not a key of its own.
    if cst:kind(sec_id) ~= K.TableSection then return {} end

    local hdr_id = cst:first_child_of_kind(sec_id, K.TableHeader)
    local hdr_r  = hdr_id and cst:range(hdr_id)
    if not hdr_r or hdr_r[1] ~= row then return {} end

    local value, parts = decoded_table_at(cst, dt, ctx.data, sec_id)
    if not value or not parts or has_subsection(cst, dt, parts) then return {} end

    local last_id = hdr_id --[[@as integer]]
    for child_id, d in cst:iter_semantic(sec_id) do
        if d.kind == K.KeyValuePair then last_id = child_id end
    end
    if pairs_have_comment(cst, sec_id, last_id) then return {} end

    local parent_parts = { unpack(parts, 1, #parts - 1) }
    local scope_id     = section_for_path(cst, dt, parent_parts)
    if not scope_id then return {} end

    local last_r = cst:range(last_id) --[[@as integer[] ]]
    local rm     = block_range(lines, hdr_r[1], last_r[3])
    local ir, ic = scope_insert_pos(cst, scope_id, { hdr_r[1], last_r[3] })
    -- Nothing at document root to anchor to: the pair may only go where the
    -- section already is, and only while no earlier section opened a scope.
    if not ir or not ic then
        if cst:first_child_of_kind(cst:root_id(), K.TableSection, K.AotSection) ~= sec_id then return {} end
        ir, ic = rm[1], rm[2]
    end

    local pair = indent_of(lines, hdr_r[1]) .. encoder.encode_kvp(parts[#parts], value)
    local sep  = (ir == 0 and ic == 0) and "" or "\n"

    return {
        make_action("Convert " .. encoder.encode_header(parts) .. " to inline table", "refactor.rewrite",
            params.textDocument.uri, { cut_paste(lines, rm, { ir, ic }, sep .. pair) }),
    }
end

-- Provider list

--- All built-in providers as a ready-to-assign list for context.code_action_providers.
---@type (fun(ctx: neotasks.LspBufferContext, params: table): lsp.CodeAction[]?)[]
M.providers = {
    M.fill_required_keys,
    M.toggle_inline_table_layout,
    M.toggle_array_layout,
    M.inline_table_to_section,
    M.section_to_inline_table,
}

return M
