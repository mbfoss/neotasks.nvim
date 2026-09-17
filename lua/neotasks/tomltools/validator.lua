-- JSON Schema Draft 2020-12 validator — partial implementation.
--
-- IMPLEMENTED
--   Core:        type (incl. "integer"), enum, const
--   String:      minLength, maxLength, pattern
--   Numeric:     minimum, maximum, exclusiveMinimum, exclusiveMaximum, multipleOf
--   Object:      properties, required, additionalProperties, patternProperties,
--                minProperties, maxProperties, dependentRequired, dependentSchemas
--   Array:       prefixItems, items, contains, minContains, maxContains,
--                minItems, maxItems, uniqueItems
--   Composition: allOf, anyOf, oneOf, not, if/then/else
--
-- NOT IMPLEMENTED
--   $ref / $defs
--   unevaluatedProperties / unevaluatedItems
--   $dynamicRef / $dynamicAnchor
--   format assertions (treated as annotation-only).
--   contentEncoding / contentMediaType / contentSchema

local M = {}

local std = require("neotasks.tomltools.std")

---@class loop.json.ValidationError
---@field node_id integer?
---@field err_msg string

---@param errors loop.json.ValidationError[]
---@param node_id integer?
---@param msg string
local function add_error(errors, node_id, msg)
    table.insert(errors, { node_id = node_id, err_msg = msg })
end

local function deep_equal(a, b)
    if a == b then return true end
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return false end
    for k, v in pairs(a) do if not deep_equal(v, b[k]) then return false end end
    for k, v in pairs(b) do if not deep_equal(v, a[k]) then return false end end
    return true
end

local function check_enum(enum_tbl, value)
    for _, v in ipairs(enum_tbl) do
        if v == value then return true end
    end
    return false
end

---@param schema table
---@param data any
---@param node_id integer?
---@param dt tomltools.DecodeTree?
---@param errors loop.json.ValidationError[]
local function _validate(schema, data, node_id, dt, errors)
    local function child_id(key)
        return dt and node_id and dt:get_child_id(node_id, key) or nil
    end

    -- type
    if schema.type ~= nil then
        local allowed = type(schema.type) == "table" and schema.type or { schema.type }
        local ok, bad_schema, bad_type = false, nil, nil
        for _, t in ipairs(allowed) do
            if t == "null" then if data == nil then ok = true end
            elseif t == "boolean" then if type(data) == "boolean" then ok = true end
            elseif t == "integer" then if type(data) == "number" and data == math.floor(data) then ok = true end
            elseif t == "number" then if type(data) == "number" then ok = true end
            elseif t == "string" then if type(data) == "string" then ok = true end
            elseif t == "array" then if std.islist(data) then ok = true end
            elseif t == "object" then if type(data) == "table" and not std.islist(data) then ok = true end
            else bad_schema,bad_type = true,t end
            if ok then break end
        end
        if bad_schema then
            add_error(errors, node_id, "Invalid type in schema: " .. tostring(bad_type))
        elseif not ok then
            local expected = std.tbl_map(function (v) return v == "object" and "table" or v end, allowed)
            local got = type(data) ---@type string
            if got == "table" then got = std.islist(data) and "array" or "table"
            elseif data == nil then got = "null" end
            add_error(errors, node_id, ("expected %s, got %s"):format(table.concat(expected, " or "), got))
        end
    end

    -- enum
    if schema.enum ~= nil and not check_enum(schema.enum, data) then
        local strs = {}
        for _, v in ipairs(schema.enum) do table.insert(strs, tostring(v)) end
        add_error(errors, node_id, "valid values: " .. table.concat(strs, ", "))
    end

    -- const
    if schema.const ~= nil and not deep_equal(data, schema.const) then
        add_error(errors, node_id, ("expected %s, got %s"):format(tostring(schema.const), tostring(data)))
    end

    -- string keywords
    if type(data) == "string" then
        if type(schema.minLength) == "number" and #data < schema.minLength then
            add_error(errors, node_id,
                schema.minLength > 1
                    and ("string must be at least %d characters"):format(schema.minLength)
                    or "string cannot be empty")
        end
        if type(schema.maxLength) == "number" and #data > schema.maxLength then
            add_error(errors, node_id, ("string must be at most %d characters"):format(schema.maxLength))
        end
        if schema.pattern ~= nil and not data:match(schema.pattern) then
            add_error(errors, node_id, ("string does not match pattern %q"):format(schema.pattern))
        end
    end

    -- numeric keywords
    if type(data) == "number" then
        if type(schema.minimum) == "number" and data < schema.minimum then
            add_error(errors, node_id, ("value must be >= %g"):format(schema.minimum))
        end
        if type(schema.maximum) == "number" and data > schema.maximum then
            add_error(errors, node_id, ("value must be <= %g"):format(schema.maximum))
        end
        if type(schema.exclusiveMinimum) == "number" and data <= schema.exclusiveMinimum then
            add_error(errors, node_id, ("value must be > %g"):format(schema.exclusiveMinimum))
        end
        if type(schema.exclusiveMaximum) == "number" and data >= schema.exclusiveMaximum then
            add_error(errors, node_id, ("value must be < %g"):format(schema.exclusiveMaximum))
        end
        if type(schema.multipleOf) == "number" and schema.multipleOf > 0 and data % schema.multipleOf ~= 0 then
            add_error(errors, node_id, ("value must be a multiple of %g"):format(schema.multipleOf))
        end
    end

    -- object keywords — apply whenever data is an object, regardless of schema.type
    if type(data) == "table" and not std.islist(data) then
        local props         = schema.properties or {}
        local required      = schema.required or {}
        local pattern_props = schema.patternProperties or {}

        local missing
        for _, key in ipairs(required) do
            if data[key] == nil then
                missing = missing or {}
                table.insert(missing, key)
            end
        end
        if missing then
            add_error(errors, node_id,
                ("required propert%s missing: %s"):format(
                    #missing == 1 and "y" or "ies", table.concat(missing, ", ")))
        end

        for key, subschema in pairs(props) do
            if data[key] ~= nil then
                _validate(subschema, data[key], child_id(key), dt, errors)
            end
        end

        local addl = schema.additionalProperties
        for key, value in pairs(data) do
            local handled = props[key] ~= nil
            for pattern, subschema in pairs(pattern_props) do
                if type(key) == "string" and key:match(pattern) then
                    handled = true
                    _validate(subschema, value, child_id(key), dt, errors)
                end
            end
            if not handled then
                if addl == false then
                    add_error(errors, child_id(key), "invalid property name: " .. tostring(key))
                elseif type(addl) == "table" then
                    _validate(addl, value, child_id(key), dt, errors)
                end
            end
        end

        if schema.minProperties ~= nil or schema.maxProperties ~= nil then
            local count = 0
            for _ in pairs(data) do count = count + 1 end
            if type(schema.minProperties) == "number" and count < schema.minProperties then
                add_error(errors, node_id,
                    ("object must have at least %d propert%s"):format(
                        schema.minProperties, schema.minProperties == 1 and "y" or "ies"))
            end
            if type(schema.maxProperties) == "number" and count > schema.maxProperties then
                add_error(errors, node_id,
                    ("object must have at most %d propert%s"):format(
                        schema.maxProperties, schema.maxProperties == 1 and "y" or "ies"))
            end
        end

        if schema.dependentRequired then
            for prop, deps in pairs(schema.dependentRequired) do
                if data[prop] ~= nil then
                    for _, dep in ipairs(deps) do
                        if data[dep] == nil then
                            add_error(errors, node_id, ("property %q requires %q"):format(prop, dep))
                        end
                    end
                end
            end
        end

        if schema.dependentSchemas then
            for prop, subschema in pairs(schema.dependentSchemas) do
                if data[prop] ~= nil then
                    _validate(subschema, data, node_id, dt, errors)
                end
            end
        end
    end

    -- array keywords — apply whenever data is an array, regardless of schema.type
    if std.islist(data) then
        -- prefixItems: positional schemas (Draft 2020-12)
        local prefix_len = 0
        if schema.prefixItems then
            prefix_len = #schema.prefixItems
            for i, value in ipairs(data) do
                if schema.prefixItems[i] then
                    _validate(schema.prefixItems[i], value, child_id(tostring(i)), dt, errors)
                end
            end
        end

        -- items: applies only to elements after prefixItems (Draft 2020-12 semantics)
        if schema.items then
            for i, value in ipairs(data) do
                if i > prefix_len then
                    _validate(schema.items, value, child_id(tostring(i)), dt, errors)
                end
            end
        end

        if schema.contains then
            local min_c = type(schema.minContains) == "number" and schema.minContains or 1
            local max_c = type(schema.maxContains) == "number" and schema.maxContains or math.huge
            local match_count = 0
            for _, value in ipairs(data) do
                local tmp = {}
                _validate(schema.contains, value, nil, dt, tmp)
                if #tmp == 0 then match_count = match_count + 1 end
            end
            if match_count < min_c then
                add_error(errors, node_id,
                    ("array must contain at least %d matching item%s"):format(min_c, min_c == 1 and "" or "s"))
            end
            if max_c ~= math.huge and match_count > max_c then
                add_error(errors, node_id,
                    ("array must contain at most %d matching item%s"):format(max_c, max_c == 1 and "" or "s"))
            end
        end

        if type(schema.minItems) == "number" and #data < schema.minItems then
            add_error(errors, node_id,
                ("array must have at least %d item%s"):format(schema.minItems, schema.minItems == 1 and "" or "s"))
        end
        if type(schema.maxItems) == "number" and #data > schema.maxItems then
            add_error(errors, node_id,
                ("array must have at most %d item%s"):format(schema.maxItems, schema.maxItems == 1 and "" or "s"))
        end

        if schema.uniqueItems then
            local reported = false
            for i = 1, #data do
                if reported then break end
                for j = i + 1, #data do
                    if deep_equal(data[i], data[j]) then
                        add_error(errors, node_id,
                            ("duplicate items at indices %d and %d"):format(i, j))
                        reported = true
                        break
                    end
                end
            end
        end
    end

    -- if / then / else
    if schema["if"] then
        local tmp = {}
        _validate(schema["if"], data, node_id, dt, tmp)
        if #tmp == 0 then
            if schema["then"] then _validate(schema["then"], data, node_id, dt, errors) end
        else
            if schema["else"] then _validate(schema["else"], data, node_id, dt, errors) end
        end
    end

    -- allOf: all sub-schemas must pass
    if schema.allOf then
        for _, sub in ipairs(schema.allOf) do
            _validate(sub, data, node_id, dt, errors)
        end
    end

    -- anyOf: at least one sub-schema must pass; report best-match errors on total failure
    if schema.anyOf then
        local best_errors, best_count = nil, math.huge
        local any_pass = false
        for _, sub in ipairs(schema.anyOf) do
            local tmp = {}
            _validate(sub, data, node_id, dt, tmp)
            if #tmp == 0 then
                any_pass = true
                break
            end
            if #tmp < best_count then
                best_count = #tmp
                best_errors = tmp
            end
        end
        if not any_pass and best_errors then
            std.list_extend(errors, best_errors)
        end
    end

    -- oneOf: exactly one sub-schema must pass
    if schema.oneOf then
        local pass_count = 0
        local best_errors, best_count = nil, math.huge
        local all_const, consts = true, {}
        for _, sub in ipairs(schema.oneOf) do
            if sub.const ~= nil then
                table.insert(consts, tostring(sub.const))
            else
                all_const = false
            end
            local tmp = {}
            _validate(sub, data, node_id, dt, tmp)
            if #tmp == 0 then
                pass_count = pass_count + 1
            elseif #tmp < best_count then
                best_count = #tmp
                best_errors = tmp
            end
        end
        if pass_count == 0 then
            -- When every branch is just a `const` (the common "enum via oneOf"
            -- pattern used to attach a per-value description), report the full
            -- set of valid values instead of one arbitrary branch's mismatch.
            if all_const and #consts > 0 then
                add_error(errors, node_id, "valid values: " .. table.concat(consts, ", "))
            elseif best_errors then
                std.list_extend(errors, best_errors)
            end
        elseif pass_count > 1 then
            add_error(errors, node_id,
                ("value matches %d oneOf schemas, expected exactly 1"):format(pass_count))
        end
    end

    -- not
    if schema["not"] then
        local tmp = {}
        _validate(schema["not"], data, node_id, dt, tmp)
        if #tmp == 0 then
            add_error(errors, node_id, "value must not match the schema")
        end
    end
end

---@param schema table
---@param data any
---@param dt tomltools.DecodeTree?
---@return boolean valid
---@return loop.json.ValidationError[] errors
function M.validate(schema, data, dt)
    local errors  = {}
    local root_id = dt and dt:root_id() or nil
    _validate(schema, data, root_id, dt, errors)
    return #errors == 0, errors
end

return M
