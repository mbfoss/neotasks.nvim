local M          = {}

local table_util = require("neotasks.tomltools.table_util")
local std        = require("neotasks.tomltools.std")
local parser     = require("neotasks.tomltools.parser")
local DecodeTree = require("neotasks.tomltools.DecodeTree")
local Cst        = require("neotasks.tomltools.Cst")

local K          = Cst.Kind

-- CST kind → TOML type string (for type_map)
local kind_to_type = {
    [K.String]        = "string",
    [K.Integer]       = "integer",
    [K.Float]         = "float",
    [K.Bool]          = "bool",
    [K.Datetime]      = "datetime",
    [K.DatetimeLocal] = "datetime-local",
    [K.DateLocal]     = "date-local",
    [K.TimeLocal]     = "time-local",
}

local literal_kinds = {
    [K.String]        = true, [K.Integer]       = true, [K.Float]  = true,
    [K.Bool]          = true, [K.Datetime]       = true,
    [K.DatetimeLocal] = true, [K.DateLocal]      = true, [K.TimeLocal] = true,
}

---@param cst tomltools.Cst
---@param with_type_map boolean?
---@return any                       data
---@return tomltools.DecodeTree decode_tree
---@return table[]                   errors
---@return table<integer,string>?    value_types
local function evaluate(cst, with_type_map)
    local root       = std.empty_dict()
    local dt         = DecodeTree.new()
    local errors     = {}
    local kind_by_id = {}
    local type_by_id = with_type_map and {} or nil

    local function set_type(id, t) if type_by_id then type_by_id[id] = t end end
    local function add_err(e)      table.insert(errors, e) end

    local dead_end_table     = std.empty_dict()
    local current_table      = root
    local inline_table_ids   = {}
    local dotted_key_ids     = {}
    local explicit_table_ids = {}

    local key_orders = {}  ---@type table<table, string[]>
    local function track_key(tbl, key)
        local ko = key_orders[tbl]
        if not ko then ko = {}; key_orders[tbl] = ko end
        ko[#ko + 1] = key
    end

    local root_id = dt:root_id()
    dt:add_range_by_id(root_id, { 0, 0, 0, 0 })
    kind_by_id[root_id] = "Table"
    set_type(root_id, "table")

    local current_id = root_id  ---@type integer?

    local eval_value  -- forward decl

    -- Resolve a chain of dotted-key data objects as an implicit table path, starting from
    -- (scope_table, scope_id), navigating keys[from..to].  Returns (table, id) at the leaf,
    -- or (nil, nil) on error.
    ---@param keys        tomltools.CstData[]
    ---@param from        integer
    ---@param to          integer
    ---@param scope_table table
    ---@param scope_id    integer
    ---@return table?
    ---@return integer?
    local function navigate_dotted(keys, from, to, scope_table, scope_id)
        local cur_table = scope_table
        local cur_id    = scope_id
        for i = from, to do
            if not cur_id then return nil, nil end
            local key       = keys[i].value
            local key_range = keys[i].range
            local next_id   = dt:get_child_id(cur_id, key)
            local nkind     = next_id and kind_by_id[next_id]

            if next_id then
                if nkind == "Table" then
                    if inline_table_ids[next_id] then
                        add_err({ message = "Cannot extend inline table: " .. key, range = key_range })
                        return nil, nil
                    end
                    if explicit_table_ids[next_id] then
                        add_err({ message = "Cannot use dotted key to extend explicitly-defined table: " .. key,
                                  range = key_range })
                        return nil, nil
                    end
                    cur_table = cur_table[key]
                    cur_id    = next_id
                elseif nkind == "ArrayOfTables" then
                    add_err({ message = "Cannot use dotted key to extend array of tables: " .. key,
                              range = key_range })
                    return nil, nil
                else
                    add_err({ message = "Cannot extend non-table key: " .. key, range = key_range })
                    return nil, nil
                end
                dt:add_range_by_id(next_id, key_range)
            else
                cur_table[key] = std.empty_dict()
                track_key(cur_table, key)
                local new_id   = dt:add_child(cur_id, key, key_range)
                kind_by_id[new_id] = "Table"
                set_type(new_id, "table")
                dotted_key_ids[new_id] = true
                cur_table = cur_table[key]
                cur_id    = new_id
            end
        end
        return cur_table, cur_id
    end

    -- Process a KVP CST node at (scope_table, scope_id). Handles dotted keys.
    ---@param kvp_id      integer
    ---@param scope_table table
    ---@param scope_id    integer?
    local function process_kvp_at(kvp_id, scope_table, scope_id)
        if not scope_id then return end
        local keys = cst:get_keys(kvp_id)
        if #keys == 0 then return end

        local val_id, val_data = cst:get_value(kvp_id)
        if not val_data or val_data.kind == K.Error then return end
        local kvp_range = cst:range(kvp_id) or { 0, 0, 0, 0 }

        -- Navigate intermediate dotted keys (all but the last)
        local leaf_table, leaf_id
        if #keys > 1 then
            leaf_table, leaf_id = navigate_dotted(keys, 1, #keys - 1, scope_table, scope_id)
        else
            leaf_table, leaf_id = scope_table, scope_id
        end
        if not leaf_table then return end
        ---@cast leaf_id integer

        local last_key   = keys[#keys]
        local key        = last_key.value
        local key_range  = last_key.range
        local existing_id   = dt:get_child_id(leaf_id, key)
        local existing_kind = existing_id and kind_by_id[existing_id]

        if existing_id and existing_kind then
            if existing_kind == "Table" and val_data and val_data.kind == K.InlineTable then
                if inline_table_ids[existing_id] then
                    add_err({ message = "Cannot extend inline table: " .. key, range = key_range })
                else
                    -- dotted-key table or explicit table: both cannot be replaced by an inline table
                    add_err({ message = "Cannot redefine existing table as inline table: " .. key,
                              range = key_range })
                end
            elseif existing_kind == "Table" then
                add_err({ message = "Cannot overwrite table with non-table value: " .. key, range = key_range })
            else
                local msg = existing_kind == "ArrayOfTables"
                    and ("Cannot overwrite array of tables: " .. key)
                    or  ("Duplicate key: " .. key)
                add_err({ message = msg, range = key_range })
            end
        else
            local child_id = dt:add_child(leaf_id, key, kvp_range)
            dt:set_key_range(child_id, key_range)
            if val_data then dt:set_value_range(child_id, val_data.range) end
            cst:set_tag(kvp_id, child_id)
            leaf_table[key] = eval_value(val_id, val_data, child_id)
            track_key(leaf_table, key)
        end
    end

    -- Process KVPs that are direct children of a section or the document.
    ---@param sec_id      integer
    ---@param scope_table table
    ---@param scope_id    integer?
    local function process_section_kvps(sec_id, scope_table, scope_id)
        for kvp_id, d in cst:iter_semantic(sec_id) do
            if d.kind == K.KeyValuePair then
                process_kvp_at(kvp_id, scope_table, scope_id)
            end
        end
    end

    -- Evaluate an inline table: iterate its KVP children (handling dotted keys).
    ---@param node_id integer
    ---@param dt_id   integer
    ---@return table
    local function eval_inline_table(node_id, dt_id)
        kind_by_id[dt_id] = "Table"
        set_type(dt_id, "table")
        inline_table_ids[dt_id] = true
        cst:set_tag(node_id, dt_id)
        local result = std.empty_dict()

        local function process_inline_kvp(kvp_id, scope_tbl, scope_id)
            if not scope_id then return end
            local keys = cst:get_keys(kvp_id)
            if #keys == 0 then return end
            local vi, vd   = cst:get_value(kvp_id)
            if not vd or vd.kind == K.Error then return end
            local kvpr     = cst:range(kvp_id) or { 0, 0, 0, 0 }

            local leaf_tbl, leaf_id
            if #keys > 1 then
                leaf_tbl, leaf_id = navigate_dotted(keys, 1, #keys - 1, scope_tbl, scope_id)
            else
                leaf_tbl, leaf_id = scope_tbl, scope_id
            end
            if not leaf_tbl then return end

            local last = keys[#keys]
            local key  = last.value
            if leaf_tbl[key] ~= nil then
                add_err({ message = "Duplicate key in inline table: " .. key, range = last.range or kvpr })
            else
                local sub_id = dt:add_child(leaf_id, key, kvpr)
                dt:set_key_range(sub_id, last.range)
                if vd then dt:set_value_range(sub_id, vd.range) end
                cst:set_tag(kvp_id, sub_id)
                leaf_tbl[key] = eval_value(vi, vd, sub_id)
                track_key(leaf_tbl, key)
            end
        end

        for kvp_id, d in cst:iter_semantic(node_id) do
            if d.kind == K.KeyValuePair then
                process_inline_kvp(kvp_id, result, dt_id)
            end
        end
        return result
    end

    ---@param val_id   integer
    ---@param val_data tomltools.CstData?
    ---@param dt_id    integer
    ---@return any
    eval_value = function(val_id, val_data, dt_id)
        if not val_data then return nil end
        local k = val_data.kind

        if k == K.Error then
            return nil
        end

        if literal_kinds[k] then
            kind_by_id[dt_id] = "Literal"
            set_type(dt_id, kind_to_type[k] or "string")
            return val_data.value
        end

        if k == K.Array then
            kind_by_id[dt_id] = "Array"
            set_type(dt_id, "array")
            local result = {}
            local idx    = 0
            for item_id, item_d in cst:iter_values(val_id) do
                idx = idx + 1
                local item_dt_id = dt:add_child(dt_id, tostring(idx), item_d.range)
                table.insert(result, eval_value(item_id, item_d, item_dt_id))
            end
            return result
        end

        if k == K.InlineTable then
            return eval_inline_table(val_id, dt_id)
        end

        return nil
    end

    -- ===== main document walk =====

    for sec_id, d in cst:iter_semantic(cst:root_id()) do
        if d.kind == K.TableSection then
            current_table = root
            current_id    = dt:root_id()
            local invalid = false

            -- Find the TableHeader child and extract keys
            local hdr_id
            for cid, cd in cst:iter_semantic(sec_id) do
                if cd.kind == K.TableHeader then hdr_id = cid; break end
            end
            local keys = hdr_id and cst:get_keys(hdr_id) or {}
            if #keys == 0 then
                add_err({ message = "Empty table header", range = cst:range(sec_id) or { 0, 0, 0, 0 } })
                invalid = true
            end

            local sec_range = cst:range(sec_id) or { 0, 0, 0, 0 }
            local nkeys     = #keys

            for i, key_data in ipairs(keys) do
                if not current_id then invalid = true; break end
                local key       = key_data.value
                local is_last   = (i == nkeys)
                local next_id   = dt:get_child_id(current_id, key)
                local nkind     = next_id and kind_by_id[next_id]
                local key_range = is_last and sec_range or (key_data.range or sec_range)

                if nkind == "ArrayOfTables" then
                    if is_last then
                        add_err({ message = "Cannot use [table] for array-of-tables key: " .. key,
                                  range = key_data.range or sec_range })
                        invalid = true; break
                    end
                    assert(next_id)
                    local arr         = current_table[key]
                    local idx         = #arr
                    local arr_elem_id = dt:get_child_id(next_id, tostring(idx))
                    if not arr_elem_id then invalid = true; break end
                    current_table = arr[idx]
                    current_id    = arr_elem_id
                    dt:add_range_by_id(next_id, key_data.range or sec_range)
                elseif nkind and nkind ~= "Table" then
                    add_err({ message = "Cannot redefine non-table: " .. key, range = key_data.range or sec_range })
                    invalid = true; break
                else
                    if next_id and inline_table_ids[next_id] then
                        add_err({ message = "Cannot extend inline table with [table]: " .. key,
                                  range = key_data.range or sec_range })
                        invalid = true; break
                    end
                    if not next_id then
                        current_table[key] = std.empty_dict()
                        track_key(current_table, key)
                        next_id = dt:add_child(current_id, key, key_range)
                        kind_by_id[next_id] = "Table"
                    else
                        dt:add_range_by_id(next_id, key_range)
                    end
                    set_type(next_id, "table")
                    current_table = current_table[key]
                    current_id    = next_id
                end
            end

            if not invalid and current_id then
                if explicit_table_ids[current_id] then
                    add_err({ message = "Duplicate table header", range = sec_range })
                    invalid = true
                elseif dotted_key_ids[current_id] then
                    add_err({ message = "Cannot redefine table created by dotted key", range = sec_range })
                    invalid = true
                else
                    explicit_table_ids[current_id] = true
                end
            end

            if invalid then current_table = dead_end_table; current_id = nil end
            if current_id then cst:set_tag(sec_id, current_id) end
            process_section_kvps(sec_id, current_table, current_id)

        elseif d.kind == K.AotSection then
            current_table = root
            current_id    = dt:root_id()
            local invalid = false

            local hdr_id
            for cid, cd in cst:iter_semantic(sec_id) do
                if cd.kind == K.AotHeader then hdr_id = cid; break end
            end
            local keys      = hdr_id and cst:get_keys(hdr_id) or {}
            local sec_range = cst:range(sec_id) or { 0, 0, 0, 0 }
            local num_keys  = #keys

            for i, key_data in ipairs(keys) do
                if not current_id then invalid = true; break end
                local key     = key_data.value
                local is_last = (i == num_keys)
                local next_id = dt:get_child_id(current_id, key)
                local nkind   = next_id and kind_by_id[next_id]

                if is_last then
                    if nkind and nkind ~= "ArrayOfTables" then
                        add_err({ message = "Cannot redefine non-array as [[aot]]: " .. key,
                                  range = key_data.range or sec_range })
                        invalid = true; break
                    end
                    if not next_id then
                        current_table[key] = {}
                        track_key(current_table, key)
                        next_id = dt:add_child(current_id, key, sec_range)
                        kind_by_id[next_id] = "ArrayOfTables"
                    else
                        dt:add_range_by_id(next_id, sec_range)
                    end
                    set_type(next_id, "array")
                    local tbl_arr     = current_table[key]
                    local next_tbl    = std.empty_dict()
                    table.insert(tbl_arr, next_tbl)
                    local elem_id = dt:add_child(next_id, tostring(#tbl_arr), sec_range)
                    kind_by_id[elem_id] = "Table"
                    set_type(elem_id, "table")
                    current_table = next_tbl
                    current_id    = elem_id
                else
                    if nkind == "ArrayOfTables" then
                        assert(next_id)
                        local arr         = current_table[key]
                        local idx         = #arr
                        local arr_elem_id = dt:get_child_id(next_id, tostring(idx))
                        if not arr_elem_id then invalid = true; break end
                        current_table = arr[idx]
                        current_id    = arr_elem_id
                    elseif nkind and nkind ~= "Table" then
                        add_err({ message = "Cannot redefine non-table ancestor: " .. key,
                                  range = key_data.range or sec_range })
                        invalid = true; break
                    else
                        if next_id and inline_table_ids[next_id] then
                            add_err({ message = "Cannot extend inline table with [[aot]]: " .. key,
                                      range = key_data.range or sec_range })
                            invalid = true; break
                        end
                        if not next_id then
                            current_table[key] = std.empty_dict()
                            track_key(current_table, key)
                            next_id = dt:add_child(current_id, key, key_data.range or sec_range)
                            kind_by_id[next_id] = "Table"
                        end
                        set_type(next_id, "table")
                        current_table = current_table[key]
                        current_id    = next_id
                    end
                    if next_id then dt:add_range_by_id(next_id, key_data.range or sec_range) end
                end
            end

            if invalid then current_table = dead_end_table; current_id = nil end
            if current_id then cst:set_tag(sec_id, current_id) end
            process_section_kvps(sec_id, current_table, current_id)

        elseif d.kind == K.KeyValuePair then
            process_kvp_at(sec_id, root, dt:root_id())
        end
    end

    local value_types
    if with_type_map and type_by_id then
        value_types = {}
        for tid, t in pairs(type_by_id) do value_types[tid] = t end
    end

    -- Attach insertion-order metadata to every table we tracked keys for. This
    -- covers intermediate implicit tables (e.g. `a` in `[a.b]` / `[a.c]`)
    for tbl, ko in pairs(key_orders) do
        table_util.ordered(tbl, ko)
    end
    return root, dt, errors, value_types
end

function M.decode(input, opts)
    local cst

    if type(input) == "string" then
        local parsed = parser.parse(input)
        if not parsed.ok then
            return {
                ok          = false,
                data        = nil,
                errors      = parsed.errors,
                decode_tree = DecodeTree.new(),
            }
        end
        cst = parsed.cst
    else
        cst = input
    end

    local data, dt, errs, value_types = evaluate(cst, opts and opts.type_map)
    return {
        ok          = #errs == 0,
        data        = data,
        errors      = errs,
        decode_tree = dt,
        type_map    = (opts and opts.type_map) and value_types or nil,
    }
end

return M
