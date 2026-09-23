local M            = {}

local s_util       = require("neotasks.tomltools.schema_util")
local schema_nav   = require("neotasks.tomltools.schema_nav")
local Cst          = require("neotasks.tomltools.Cst")
local expr         = require("neotasks.util.expr")
local sources      = require("neotasks.lsp.server.completion_sources")

local CK           = vim.lsp.protocol.CompletionItemKind
local K            = Cst.Kind
local IF           = vim.lsp.protocol.InsertTextFormat

local empty_result = { isIncomplete = false, items = {} }
---@param items lsp.CompletionItem[]
---@return lsp.CompletionList
local function result(items) return { isIncomplete = false, items = items } end

---@param schema   table?
---@param existing table<string, boolean>?
---@return lsp.CompletionItem[]
local function key_items(schema, existing)
    local items = {}
    for _, entry in ipairs(s_util.get_ordered_properties(schema)) do
        if not (existing and existing[entry.key]) then
            items[#items + 1] = {
                label         = entry.key,
                kind          = CK.Field,
                detail        = s_util.get_type_label(entry.schema),
                documentation = s_util.get_description(entry.schema),
                insertText    = entry.key,
            }
        end
    end
    return items
end

-- One completion item for a string value (an enum member or dynamic candidate).
-- The label carries the quotes; the insert appends a closing quote only when one
-- is open. `range` spans the open quote so partial values still match the label.
---@param value         string
---@param detail        string?
---@param documentation string?
---@param open_quote    string?
---@param range         lsp.Range?
---@return lsp.CompletionItem
local function string_item(value, detail, documentation, open_quote, range)
    local q    = open_quote or '"'
    local item = {
        label         = q .. value .. q,
        kind          = CK.Text,
        detail        = detail,
        documentation = documentation,
        insertText    = open_quote and (value .. q) or (q .. value .. q),
    }
    if range then item.textEdit = { range = range, newText = q .. value .. q } end
    return item
end

---@param schema     table?
---@param open_quote string?
---@param ctx        { data: any, path: string[]?, range: lsp.Range? }
---@return lsp.CompletionItem[]
local function value_items(schema, open_quote, ctx)
    if not schema then return {} end
    if schema.oneOf then
        local items, seen = {}, {}
        for _, sub in ipairs(schema.oneOf) do
            for _, item in ipairs(value_items(schema_nav.flatten(sub, nil), open_quote, ctx)) do
                if not seen[item.label] then
                    seen[item.label] = true
                    items[#items + 1] = item
                end
            end
        end
        return items
    end
    if schema.const ~= nil then
        local v = schema.const
        if type(v) == "string" then
            return { string_item(v, s_util.get_type_label(schema), schema.description, open_quote, ctx.range) }
        end
        return {
            {
                label         = tostring(v),
                kind          = CK.Text,
                detail        = s_util.get_type_label(schema),
                documentation = schema.description,
                insertText    = tostring(v),
            },
        }
    end
    -- `enum` is the values a schema *allows*; `examples` the ones it merely suggests
    -- (a value outside them still validates). Both are offered the same way here -
    -- only diagnostics tell them apart.
    local listed = schema.enum or schema.examples
    if listed then
        local descs  = schema["x-enumDescriptions"]
        local detail = s_util.get_type_label(schema)
        local items  = {}
        for i, v in ipairs(listed) do
            if type(v) == "string" then
                items[#items + 1] = string_item(v, detail, descs and descs[i] or nil, open_quote, ctx.range)
            else
                -- Non-string members (numbers/booleans) are inserted bare and
                -- never sit inside a quoted literal, so no textEdit is needed.
                items[#items + 1] = {
                    label         = tostring(v),
                    kind          = CK.Text,
                    detail        = detail,
                    documentation = descs and descs[i] or nil,
                    insertText    = tostring(v),
                }
            end
        end
        return items
    end
    -- Dynamic string values from a named source (schema `x-completionType`).
    -- Handled before the open-quote guard below so it works inside `["…"]`.
    local source = schema["x-completionType"] and sources[schema["x-completionType"]]
    if source then
        local items = {}
        for _, cand in ipairs(source({ data = ctx.data, path = ctx.path or {} })) do
            items[#items + 1] = string_item(cand.name, cand.detail, cand.documentation, open_quote, ctx.range)
        end
        return items
    end
    local t    = schema.type
    local desc = schema.description
    local function has(n) return t == n or (type(t) == "table" and vim.tbl_contains(t, n)) end
    -- Inside an open string literal only listed values (handled above) can be offered.
    -- A `[`, `{`, or bareword typed here is literal string content, not a value
    -- starter, so offer nothing for a string|array (or string|object|boolean) union.
    if open_quote then return {} end
    if has("boolean") then
        return {
            { label = "true",  kind = CK.Value, insertText = "true" },
            { label = "false", kind = CK.Value, insertText = "false" },
        }
    end
    local items = {}
    if has("array") then
        items[#items + 1] = {
            label = "[]",
            documentation = desc,
            kind = CK.Value,
            insertTextFormat = IF
                .Snippet,
            insertText = "[$1]"
        }
    end
    if has("object") then
        items[#items + 1] = {
            label = "{}",
            documentation = desc,
            kind = CK.Value,
            insertTextFormat =
                IF.Snippet,
            insertText = "{$1}"
        }
    end
    if has("string") then
        items[#items + 1] = {
            label = '"',
            documentation = desc,
            kind = CK.Text,
            insertText =
            '"'
        }
        items[#items + 1] = {
            label = "'",
            documentation = desc,
            kind = CK.Text,
            insertText =
            "'"
        }
    end
    return items
end

---@param gather_fn     fun(schema: table, data: any, prefix: string, out: table[], pos: table?, dt_node: integer?)
---@param root_schema   table
---@param root_data     any
---@param typed_keys    string[]
---@param replace_range lsp.Range   range covering the already-typed dotted path
---@param pos           tomltools.HeaderPos?  cursor context for array-element binding
---@param root_dt_id    integer?    decode-tree root id (anchors position-aware descent)
---@return lsp.CompletionItem[]
local function header_items(gather_fn, root_schema, root_data, typed_keys, replace_range, pos, root_dt_id)
    local paths = {}
    gather_fn(root_schema, root_data, "", paths, pos, root_dt_id)
    local prefix = table.concat(typed_keys, ".")
    local items  = {}
    for _, entry in ipairs(paths) do
        if entry.path:sub(1, #prefix) == prefix and entry.path ~= prefix then
            -- Composite paths contain dots, which most clients treat as word
            -- boundaries, so a bare insertText would replace only the last segment
            -- and duplicate the rest. An explicit textEdit spans the whole path.
            items[#items + 1] = {
                label    = entry.path,
                kind     = CK.Module,
                textEdit = { range = replace_range, newText = entry.path },
            }
        end
    end
    return items
end

-- Position where the dotted key path begins inside a [header] / [[header]], i.e.
-- immediately after the opening bracket(s), used as the start of the completion
-- replacement range. Falls back to the header start if no bracket token exists.
---@param cst    tomltools.Cst
---@param hdr_id integer
---@return integer row
---@return integer col
local function header_keys_start(cst, hdr_id)
    local last_bracket
    for _, d in cst:iter_semantic(hdr_id) do
        if d.kind == K.LBracket then
            last_bracket = d
        else
            break
        end
    end
    if last_bracket then return last_bracket.range[3], last_bracket.range[4] end
    local hr = cst:range(hdr_id)
    if hr then return hr[1], hr[2] end
    return 0, 0
end

---@param schema table
---@param data   any
---@param dt     tomltools.DecodeTree
---@param dt_id  integer?
---@return table?
local function schema_for_node(schema, data, dt, dt_id)
    if dt_id then
        return schema_nav.schema_at(schema, data, dt, dt_id)
    end
    return schema_nav.flatten(schema, data)
end

---@param parent_sch table?
---@param keys       tomltools.CstData[]
---@return table?
local function schema_for_keys(parent_sch, keys)
    if #keys == 0 then return nil end
    local sch = parent_sch
    for _, kd in ipairs(keys) do
        if sch and sch.properties and sch.properties[kd.value] then
            sch = sch.properties[kd.value]
        else
            return nil
        end
    end
    return sch
end

---@param schema table?
---@param name   string
---@return boolean
local function is_type(schema, name)
    local t = schema and schema.type
    return t == name or (type(t) == "table" and vim.tbl_contains(t, name))
end

-- Resolve a section's schema from its [header] key path when the section has no
-- decode tag (e.g. a header the decoder rejected). Array-of-tables levels descend
-- into `items`, mirroring how [a.b] binds to an [[a]] element.
---@param root_schema table?
---@param keys        tomltools.CstData[]   header key parts
---@return table?
local function schema_for_header_keys(root_schema, keys)
    if #keys == 0 then return nil end
    local sch = root_schema
    for _, kd in ipairs(keys) do
        local flat = sch and schema_nav.flatten(sch, nil)
        if not flat then return nil end
        local next_sch
        if flat.properties and flat.properties[kd.value] then
            next_sch = flat.properties[kd.value]
        elseif type(flat.additionalProperties) == "table" then
            -- Open-set map (e.g. a task under [tasks.<name>]): the key is
            -- user-defined, so navigate into the value schema.
            next_sch = flat.additionalProperties
        else
            return nil
        end
        sch = schema_nav.flatten(next_sch, nil)
        if is_type(sch, "array") and sch.items then sch = schema_nav.flatten(sch.items, nil) end
    end
    return sch
end

---@param cst    tomltools.Cst
---@param kvp_id integer
---@param row    integer
---@param col    integer
---@return boolean
local function cursor_after_equals(cst, kvp_id, row, col)
    for _, d in cst:iter_semantic(kvp_id) do
        if d.kind == K.Equals then
            local r = d.range
            return row > r[3] or (row == r[3] and col >= r[4])
        end
    end
    return false
end

-- Start position (0-based row, col) of the `=` in a key-value pair - a point
-- outside any `{{ … }}` slot, used as the forward-scan origin for slot detection.
---@param cst    tomltools.Cst
---@param kvp_id integer
---@return integer? row, integer? col
local function equals_start(cst, kvp_id)
    for _, d in cst:iter_semantic(kvp_id) do
        if d.kind == K.Equals then return d.range[1], d.range[2] end
    end
    return nil
end

---@param cst    tomltools.Cst
---@param tok_id integer
---@return boolean
local function directly_in_array(cst, tok_id)
    local anc = cst:ancestor_of_kind(tok_id, K.Array, K.InlineTable)
    return anc ~= nil and cst:kind(anc) == K.Array
end

-- Document text from (r1,c1) to (r2,c2), all 0-based, joining lines with "\n".
---@param lines string[]
---@param r1 integer
---@param c1 integer
---@param r2 integer
---@param c2 integer
---@return string
local function slice(lines, r1, c1, r2, c2)
    if r1 == r2 then return (lines[r1 + 1] or ""):sub(c1 + 1, c2) end
    local parts = { (lines[r1 + 1] or ""):sub(c1 + 1) }
    for r = r1 + 1, r2 - 1 do parts[#parts + 1] = lines[r + 1] or "" end
    parts[#parts + 1] = (lines[r2 + 1] or ""):sub(1, c2)
    return table.concat(parts, "\n")
end

-- Whether the cursor sits inside an unterminated string literal within `interior`
-- (a completed string earlier does not count).
---@param interior string
---@return boolean
local function in_open_string(interior)
    local i, n = 1, #interior
    while i <= n do
        local skip, err = expr.skip_string(interior, i)
        if err then return true end
        if skip then i = skip else i = i + 1 end
    end
    return false
end

-- When the cursor is in expression-*name* position inside a `{{ … }}` slot (its
-- start, or after `(`, `,`, `..`, but not in a string or after a complete name),
-- return the partial name and start column. Scans from `(sr, sc)`, outside slots.
---@param lines string[]
---@param sr integer  scan-start row (0-based)
---@param sc integer  scan-start col (0-based)
---@param row integer
---@param col integer
---@return { partial: string, start: integer }?
local function slot_name_at(lines, sr, sc, row, col)
    local interior = expr.scan_slot(slice(lines, sr, sc, row, col))
    if not interior or in_open_string(interior) then return nil end
    local partial = interior:match("([%w_%-]*)$") or ""
    local head    = (interior:sub(1, #interior - #partial):gsub("%s+$", ""))
    if head == "" or head:sub(-1) == "(" or head:sub(-1) == "," or head:sub(-2) == ".." then
        return { partial = partial, start = col - #partial }
    end
    return nil
end

-- Completion items for the expression names available inside a slot. When a
-- `range` is given (covering a partially-typed name), each item replaces it via
-- textEdit so a manual completion over `{{ en` swaps in the full name cleanly.
---@param catalog { name: string, description: string? }[]?
---@param range   lsp.Range?
---@return lsp.CompletionItem[]
local function expression_items(catalog, range)
    local items = {}
    for _, e in ipairs(catalog or {}) do
        local item = { ---@type lsp.CompletionItem
            label         = e.name,
            kind          = CK.Function,
            documentation = e.description,
        }
        if range then
            item.textEdit = { range = range, newText = e.name }
        else
            item.insertText = e.name
        end
        items[#items + 1] = item
    end
    return items
end

---@param context  neotasks.LspBufferContext
---@param params   lsp.CompletionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CompletionList)
function M.handler(context, params, callback)
    if not (context.schema and context.cst) then
        callback(nil, empty_result); return
    end

    local schema = context.schema --[[@as table]]
    local cst    = context.cst
    local dt     = context.decode_tree
    local data   = context.data
    local row    = params.position.line
    local col    = params.position.character

    local lines  = context.lines
    if not dt or not lines or row >= #lines or col > #(lines[row + 1] or "") then
        callback(nil, empty_result); return
    end

    local tok_id    = cst:token_at(row, col)
    local tok_d     = cst:data(tok_id) --[[@as tomltools.CstData?]]
    local tok_k     = tok_d and tok_d.kind --[[@as tomltools.CstKind?]]
    local is_trivia = tok_k == K.Whitespace or tok_k == K.Newline or tok_k == K.Comment

    -- Cursor context so the gather binds [a.b] headers to the most recent
    -- [[a]] element before the cursor (not merely the array's last element).
    local pos       = { dt = dt, row = row, col = col }
    local root_dt   = dt:root_id()

    -- [table.header] → suggest valid table paths from schema
    local hdr_id    = cst:ancestor_of_kind(tok_id, K.TableHeader)
    if hdr_id then
        local typed  = vim.tbl_map(function(kd) return kd.value end, cst:get_keys(hdr_id))
        local sr, sc = header_keys_start(cst, hdr_id)
        local rng    = { start = { line = sr, character = sc }, ["end"] = { line = row, character = col } }
        callback(nil, result(header_items(schema_nav.gather_table_paths, schema, data, typed, rng, pos, root_dt)))
        return
    end

    -- [[array.of.tables]] header → suggest valid AoT paths from schema
    local aot_id = cst:ancestor_of_kind(tok_id, K.AotHeader)
    if aot_id then
        local typed  = vim.tbl_map(function(kd) return kd.value end, cst:get_keys(aot_id))
        local sr, sc = header_keys_start(cst, aot_id)
        local rng    = { start = { line = sr, character = sc }, ["end"] = { line = row, character = col } }
        callback(nil, result(header_items(schema_nav.gather_array_table_paths, schema, data, typed, rng, pos, root_dt)))
        return
    end

    -- Cursor is inside a key-value pair (key = value).
    -- Ancestor search stops at InlineTable boundaries so we don't escape inline scope.
    local anc    = cst:ancestor_of_kind(tok_id, K.KeyValuePair, K.InlineTable)
    local kvp_id = (anc and cst:kind(anc) == K.KeyValuePair and anc)
        or (tok_k == K.KeyValuePair and tok_id)
        or nil

    if kvp_id then
        if cursor_after_equals(cst, kvp_id, row, col) then
            -- In the name position of a `{{ … }}` slot: offer expression names
            -- instead of schema value items. Scans from the `=` (outside any
            -- slot); the partial name is replaced via textEdit.
            local sr, sc = equals_start(cst, kvp_id)
            local slot   = sr and slot_name_at(lines, sr, sc --[[@as integer]], row, col)
            if slot then
                local range = {
                    start   = { line = row, character = slot.start },
                    ["end"] = { line = row, character = col },
                }
                local exprs
                local inline_exprs = data and data.expressions or nil
                if inline_exprs then
                    exprs = {}
                    for _, v in ipairs(context.expressions) do exprs[#exprs + 1] = v end
                    for k in pairs(inline_exprs) do exprs[#exprs + 1] = { name = k } end
                else
                    exprs = context.expressions
                end
                callback(nil, result(expression_items(exprs, range)))
                return
            end
            -- Value side: suggest enum members, booleans, [] / {} starters.
            local val_id   = cst:get_value(kvp_id)
            local in_array = directly_in_array(cst, tok_id)
            -- Suppress if the value is already complete (trivia after a non-array value,
            -- or cursor on ] closing an inline array).
            if (is_trivia and val_id and not in_array) or tok_k == K.RBracket then
                callback(nil, empty_result); return
            end

            local dt_id = cst:get_tag(kvp_id)
            local sch
            -- Root-relative key path of the node being completed; drives the
            -- dynamic `x-completionType` sources (e.g. self-exclusion). Built for
            -- both the decoded and the still-undecoded pair so it survives typing.
            local path
            if dt_id then
                -- KVP is already decoded: look up its schema directly.
                path = dt:key_parts_of(dt_id)
                if in_array then
                    -- Cursor inside an inline array literal → offer the array item schema.
                    sch = schema_nav.schema_at(schema, data, dt, dt_id)
                    sch = sch and sch.items
                else
                    -- Use raw (non-flattened) schema so value_items can enumerate all oneOf branches.
                    sch = schema_nav.raw_schema_at(schema, data, dt, dt_id)
                end
            else
                -- KVP not yet in the decode tree (incomplete / new key): resolve schema
                -- by navigating from the enclosing section's schema using the typed key path.
                local enc_id  = cst:ancestor_of_kind(kvp_id, K.TableSection, K.AotSection, K.InlineTable)
                local enc_tag = enc_id and cst:get_tag(enc_id)
                -- Inline table not yet decoded → no schema context available.
                if enc_id and cst:kind(enc_id) == K.InlineTable and not enc_tag then
                    callback(nil, empty_result); return
                end
                local enc_dt     = enc_tag or dt:root_id()
                local parent_sch = schema_nav.schema_at(schema, data, dt, enc_dt)
                local keys       = cst:get_keys(kvp_id)
                sch              = schema_for_keys(parent_sch, keys)
                if in_array then sch = sch and schema_nav.flatten(sch, data).items end
                -- Rebuild the path from the enclosing section down through the
                -- typed keys, since there is no decode node to read it from.
                path = enc_tag and dt:key_parts_of(enc_tag) or {}
                for _, kd in ipairs(keys) do path[#path + 1] = kd.value end
            end

            local open_quote = tok_k == K.String and tok_d and tok_d.text:sub(1, 1) or nil
            -- Replacement range for enum-string values: from the opening quote
            -- (string token start) through the cursor. Lets the client filter and
            -- insert against a partially-typed value; only set when a string is open.
            local str_range  = tok_k == K.String and tok_d and {
                start   = { line = tok_d.range[1], character = tok_d.range[2] },
                ["end"] = { line = row, character = col },
            } or nil
            callback(nil, result(value_items(sch, open_quote, { data = data, path = path, range = str_range })))
        else
            -- Key side: suggest sibling keys allowed by the parent schema.
            local keys = cst:get_keys(kvp_id)
            -- Trivia after a complete key (e.g. "key<space><cursor>") → nothing to complete.
            if is_trivia and #keys > 0 then
                callback(nil, empty_result); return
            end

            local dt_id     = cst:get_tag(kvp_id)
            local parent_id = dt_id and dt:get_parent_id(dt_id)
            if not parent_id then
                -- KVP not yet decoded: find the enclosing section to get the parent scope.
                local enc_id  = cst:ancestor_of_kind(kvp_id, K.TableSection, K.AotSection, K.InlineTable)
                local enc_tag = enc_id and cst:get_tag(enc_id)
                if enc_id and cst:kind(enc_id) == K.InlineTable and not enc_tag then
                    callback(nil, empty_result); return
                end
                parent_id = enc_tag or dt:root_id()
            end
            callback(nil, result(key_items(schema_for_node(schema, data, dt, parent_id), dt:child_keys(parent_id))))
        end
        return
    end

    -- Cursor is in whitespace between KVPs inside a section or inline table.
    -- token_at may land on the section composite itself when the cursor sits in
    -- its trailing gap, so treat that node as the scope, not just its ancestors.
    local scope_id = ((tok_k == K.InlineTable or tok_k == K.TableSection or tok_k == K.AotSection) and tok_id)
        or cst:ancestor_of_kind(tok_id, K.InlineTable, K.TableSection, K.AotSection)
    if scope_id then
        local scope_tag = cst:get_tag(scope_id)
        if not scope_tag then
            local scope_kind = cst:kind(scope_id)
            -- Inline table not yet decoded → no schema context available.
            if scope_kind == K.InlineTable then
                callback(nil, empty_result); return
            end
            -- Section not bound to a decode node (e.g. a duplicate/invalid header
            -- the decoder rejected): resolve its schema from the header key path
            -- rather than falling through to top-level keys.
            local hdr = cst:first_child_of_kind(scope_id, K.TableHeader, K.AotHeader)
            local sch = hdr and schema_for_header_keys(schema, cst:get_keys(hdr))
            callback(nil, result(key_items(sch, nil)))
            return
        end
        callback(nil, result(key_items(schema_for_node(schema, data, dt, scope_tag), dt:child_keys(scope_tag))))
        return
    end

    -- Cursor at document root (no enclosing section) → top-level keys.
    if tok_k == K.Document or cst:ancestor_of_kind(tok_id, K.Document) then
        local root_id = dt:root_id()
        callback(nil, result(key_items(schema_for_node(schema, data, dt, root_id), dt:child_keys(root_id))))
        return
    end

    callback(nil, empty_result)
end

return M
