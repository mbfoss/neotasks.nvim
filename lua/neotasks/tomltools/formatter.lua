local M   = {}
local Cst = require("neotasks.tomltools.Cst")
local K   = Cst.Kind

local function needs_quotes(key)
    return not key:match("^[A-Za-z0-9_%-]+$")
end

local function quote_key(key)
    if needs_quotes(key) then
        return '"' .. key:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
    end
    return key
end


---@param cst tomltools.Cst
---@return string
function M.format(cst)
    local format_value  -- forward decl

    local function format_array(arr_id, arr_range, indent)
        local items = {}
        for vid, vd in cst:iter_values(arr_id) do
            table.insert(items, format_value(vid, vd, indent + 1))
        end
        if #items == 0 then return "[]" end
        local multiline = arr_range[1] ~= arr_range[3]
        if not multiline then
            return "[ " .. table.concat(items, ", ") .. " ]"
        end
        local pad   = string.rep("  ", indent + 1)
        local close = string.rep("  ", indent)
        local lines = { "[" }
        for i, item in ipairs(items) do
            lines[#lines + 1] = pad .. item .. (i < #items and "," or "")
        end
        lines[#lines + 1] = close .. "]"
        return table.concat(lines, "\n")
    end

    local function format_inline_table(tbl_id, tbl_range, indent)
        local multiline = tbl_range[1] ~= tbl_range[3]

        -- collect KVPs and Comments in document order (skip Comma, ws, nl)
        local items = {}
        for id, d in cst:iter_semantic(tbl_id) do
            if d.kind == K.KeyValuePair or d.kind == K.Comment then
                items[#items + 1] = { id = id, d = d }
            end
        end

        if not multiline then
            -- single-line: no comments possible, just format KVPs
            local parts = {}
            for _, item in ipairs(items) do
                if item.d.kind == K.KeyValuePair then
                    local keys = cst:get_keys(item.id)
                    local vi, vd = cst:get_value(item.id)
                    if #keys > 0 then
                        local kp = {}
                        for _, kd in ipairs(keys) do kp[#kp + 1] = quote_key(kd.value) end
                        parts[#parts + 1] = table.concat(kp, ".") .. " = " .. (vd and format_value(vi, vd, indent + 1) or '""')
                    end
                end
            end
            if #parts == 0 then return "{}" end
            return "{ " .. table.concat(parts, ", ") .. " }"
        end

        -- multiline: interleave KVPs and comments, detect trailing comments by row
        local last_kvp_idx = 0
        for i, item in ipairs(items) do
            if item.d.kind == K.KeyValuePair then last_kvp_idx = i end
        end

        local pad   = string.rep("  ", indent + 1)
        local close = string.rep("  ", indent)
        local lines = { "{" }
        local i = 1
        while i <= #items do
            local item = items[i]
            if item.d.kind == K.KeyValuePair then
                local keys = cst:get_keys(item.id)
                local vi, vd = cst:get_value(item.id)
                if #keys > 0 then
                    local kp = {}
                    for _, kd in ipairs(keys) do kp[#kp + 1] = quote_key(kd.value) end
                    local val_str = vd and format_value(vi, vd, indent + 1) or '""'
                    local line = pad .. table.concat(kp, ".") .. " = " .. val_str
                                     .. (i < last_kvp_idx and "," or "")
                    -- check if the next item is a trailing comment on the same row
                    local kvp_row = item.d.range and item.d.range[3]
                    local next = items[i + 1]
                    if next and next.d.kind == K.Comment
                            and next.d.range and next.d.range[1] == kvp_row then
                        line = line .. " " .. next.d.text
                        i = i + 1  -- consume the trailing comment
                    end
                    lines[#lines + 1] = line
                end
            elseif item.d.kind == K.Comment then
                lines[#lines + 1] = pad .. item.d.text
            end
            i = i + 1
        end
        lines[#lines + 1] = close .. "}"
        return table.concat(lines, "\n")
    end

    format_value = function(val_id, val_data, indent)
        indent = indent or 0
        if not val_data then return '""' end
        local k = val_data.kind
        if k == K.String then
            return val_data.text
        elseif k == K.Bool then
            return tostring(val_data.value)
        elseif k == K.Float then
            local v = val_data.value
            if v ~= v then return "nan"
            elseif v == math.huge then return "inf"
            elseif v == -math.huge then return "-inf" end
            return tostring(v)
        elseif k == K.Integer then
            return tostring(math.floor(val_data.value))
        elseif k == K.Datetime or k == K.DatetimeLocal or k == K.DateLocal or k == K.TimeLocal then
            return val_data.value  -- already a formatted string
        elseif k == K.Array then
            return format_array(val_id, val_data.range, indent)
        elseif k == K.InlineTable then
            return format_inline_table(val_id, val_data.range, indent)
        end
        return '""'
    end

    local function format_kvp(kvp_id)
        local keys = cst:get_keys(kvp_id)
        if #keys == 0 then return nil end
        local key_parts = {}
        for _, kd in ipairs(keys) do key_parts[#key_parts + 1] = quote_key(kd.value) end
        local vi, vd = cst:get_value(kvp_id)
        local val_str = vd and format_value(vi, vd) or '""'
        local line = table.concat(key_parts, ".") .. " = " .. val_str
        -- append trailing comment if present
        for _, cd in cst:iter_semantic(kvp_id) do
            if cd.kind == K.Comment then line = line .. " " .. cd.text; break end
        end
        return line
    end

    local out   = {}
    local first = true

    for sec_id, d in cst:iter_semantic(cst:root_id()) do
        if d.kind == K.TableSection or d.kind == K.AotSection then
            if not first then out[#out + 1] = "" end
            first = false

            -- find header child
            local hdr_kind = d.kind == K.TableSection and K.TableHeader or K.AotHeader
            local hdr_id
            for cid, cd in cst:iter_semantic(sec_id) do
                if cd.kind == hdr_kind then hdr_id = cid; break end
            end

            local keys = hdr_id and cst:get_keys(hdr_id) or {}
            local key_parts = {}
            for _, kd in ipairs(keys) do key_parts[#key_parts + 1] = quote_key(kd.value) end
            local header = (d.kind == K.AotSection and "[[" or "[")
                        .. table.concat(key_parts, ".")
                        .. (d.kind == K.AotSection and "]]" or "]")

            -- trailing comment from header
            if hdr_id then
                for _, cd in cst:iter_semantic(hdr_id) do
                    if cd.kind == K.Comment then header = header .. " " .. cd.text; break end
                end
            end
            out[#out + 1] = header

            for kvp_id, cd in cst:iter_semantic(sec_id) do
                if cd.kind == K.KeyValuePair then
                    local line = format_kvp(kvp_id)
                    if line then out[#out + 1] = line end
                elseif cd.kind == K.Comment then
                    out[#out + 1] = cd.text
                end
            end

        elseif d.kind == K.KeyValuePair then
            local line = format_kvp(sec_id)
            if line then out[#out + 1] = line; first = false end

        elseif d.kind == K.Comment then
            out[#out + 1] = d.text; first = false
        end
    end

    return table.concat(out, "\n")
end

return M
