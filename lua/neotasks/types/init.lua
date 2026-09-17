local schema_mod = require("neotasks.types.schema")

---@alias neotasks.TypeLoader string|fun(): neotasks.TaskTypeDef|neotasks.TaskTypeDef

---@class neotasks.Types
local M = {}

---@type table<string, neotasks.TypeLoader>
local _loaders = {}

---@type table<string, neotasks.TaskTypeDef>
local _cache = {}

---@param name string
---@return neotasks.TaskTypeDef?
local function _resolve(name)
    if _cache[name] then return _cache[name] end
    local loader = _loaders[name]
    if loader == nil then return nil end
    local def
    if type(loader) == "string" then
        def = require(loader) ---@type neotasks.TaskTypeDef
    elseif type(loader) == "function" then
        def = loader()
    else
        def = loader
    end
    _cache[name] = def
    return def
end

--- Register a task type.
--- `loader` may be a module path string, a zero-arg factory function, or a
--- fully-resolved TaskTypeDef table.
---@param name   string
---@param loader neotasks.TypeLoader
function M.register(name, loader)
    _loaders[name] = loader
    _cache[name]   = nil
end

--- Return the resolved TaskTypeDef for `name`, or nil if unknown.
---@param name string
---@return neotasks.TaskTypeDef?
function M.get(name)
    return _resolve(name)
end

--- Return all registered type names without resolving any loaders.
---@return string[]
function M.get_names()
    return vim.tbl_keys(_loaders)
end

--- Resolve and return all registered types.
---@return table<string, neotasks.TaskTypeDef>
function M.get_all()
    local result = {}
    for name in pairs(_loaders) do
        result[name] = _resolve(name)
    end
    return result
end

---@return table JSON Schema
function M.build_schema()
    return schema_mod.build(M.get_all())
end

---@param node table
local function _resolve_schema_fns(node)
    if type(node) ~= "table" then return end
    if type(node.enum) == "function" then
        local ok, raw = pcall(node.enum --[[@as function]])
        if ok and type(raw) == "table" and #raw > 0 then
            local labels, descs, has_desc = {}, {}, false
            for _, v in ipairs(raw) do
                if type(v) == "table" then
                    labels[#labels + 1] = tostring(v.label)
                    descs[#descs + 1]   = v.description
                    if v.description then has_desc = true end
                else
                    labels[#labels + 1] = tostring(v)
                end
            end
            node.enum = labels
            if has_desc then node["x-enumDescriptions"] = descs end
        else
            node.enum = nil
        end
    end
    if type(node["x-enumDescriptions"]) == "function" then
        local ok, raw = pcall(node["x-enumDescriptions"] --[[@as function]])
        node["x-enumDescriptions"] = (ok and type(raw) == "table") and raw or nil
    end
    for _, v in pairs(node) do _resolve_schema_fns(v) end
end

--- Like build_schema() but with all function-valued enum fields evaluated to
--- concrete arrays — safe to JSON-encode or pass to the validator.
---@return table
function M.build_resolved_schema()
    local s = vim.deepcopy(M.build_schema())
    _resolve_schema_fns(s)
    return s
end

--- True if the companion ezdap plugin is available. Probes the specific
--- submodule the `debug` type needs; a plain `require` is side-effect-free here.
---@return boolean
local function _has_ezdap()
    return (pcall(require, "ezdap.schema"))
end

-- Built-in task types (loaded lazily on first use)
M.register("composite",   "neotasks.types.composite")
M.register("process",     "neotasks.types.process")
M.register("shell",       "neotasks.types.shell")

-- The `debug` type depends on ezdap for its schema, templates, and execution,
-- so it is registered only when ezdap is installed. Without it, neotasks runs
-- fine and simply offers no `debug` task type (rather than crashing on use).
if _has_ezdap() then
    M.register("debug",   "neotasks.types.debug")
end

return M
