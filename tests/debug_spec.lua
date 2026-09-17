---@diagnostic disable: undefined-global, undefined-field
-- Unit tests for the `debug` type's `parameters`. ndap, absent here, and its
-- input reader are stubbed.

local config      = require("neotasks.config")
local debug       = require("neotasks.types.debug")
local validator   = require("neotasks.tomltools.validator")

local ADAPTER = "fake"

-- The adapter/mode the tests run: lists (typed and untyped), a map, and the
-- scalars beside them, so every authored form is exercised.
local INPUTS = {
    program = { type = "string", required = true, description = "the program to debug" },
    args    = { type = "list", description = "arguments passed to the program" },
    ports   = { type = "list", item_type = "integer" },
    ignore  = { type = "list" },
    env     = { type = "map" },
    cwd     = { type = "string" },
    flag    = { type = "boolean" },
}

-- The mode the tests run.
local MODE = {
    description = "launch the program",
}

--- Value reading as `ndap.run.inputs.read` documents it.
local ENTRY_READER = {
    read = function(input, value)
        local entry_type = input.item_type or input.type or "string"
        local function accept(v)
            if entry_type == "integer" then
                return type(v) == "number" and v == math.floor(v)
            elseif entry_type == "boolean" then
                return type(v) == "boolean"
            elseif entry_type == "string" then
                return type(v) == "string"
            end
            return true
        end

        if input.type == "list" or input.type == "map" then
            if type(value) ~= "table" then
                return nil, ("expected a %s, got a %s"):format(input.type, type(value))
            end
            if input.type == "list" and not vim.islist(value) then
                return nil, "expected a list of entries, got a keyed table"
            end
            for key, item in pairs(value) do
                if input.type == "map" and type(key) ~= "string" then
                    return nil, ("expected string keys, got a %s"):format(type(key))
                end
                if not accept(item) then
                    return nil, ("%s: expected %s, got a %s"):format(key, entry_type, type(item))
                end
            end
            return value
        end

        if not accept(value) then
            return nil, ("expected %s, got a %s"):format(entry_type, type(value))
        end
        return value
    end,
}

-- What the stubbed `start_mode` was handed; nil until a run starts.
local ran
-- Messages the run reported through `ctx.report`.
local reported

local fake_ndap = {
    -- ndap's built-in `remote` is always among them; listing it keeps the type's
    -- "not a registered ndap adapter" warning out of the output.
    available_adapters = function() return { ADAPTER, "remote" } end,
    is_setup           = function() return true end,
    -- Only the fake adapter declares modes; `remote` is listed (as ndap always
    -- lists it) but contributes no branch to the schema.
    mode_required      = function(adapter)
        return adapter == ADAPTER and { "program" } or {}
    end,
    mode_inputs        = function(adapter)
        return adapter == ADAPTER and INPUTS or {}
    end,
    mode_names         = function(adapter)
        return adapter == ADAPTER and { "launch" } or {}
    end,
    mode               = function(adapter)
        return adapter == ADAPTER and MODE or nil
    end,
    -- The starting value ndap scaffolds for an input. Templates seed required
    -- parameters from it when the adapter has no `target` expander.
    input_seed         = function(input)
        if input and input.type == "list" then return {} end
        if input and input.type == "map" then return vim.empty_dict() end
        local kind = input and input.type or "string"
        if kind == "integer" or kind == "number" then return 0 end
        if kind == "boolean" then return false end
        return ""
    end,
    remove_run         = function() end,
    start_mode         = function(adapter, mode, parameters)
        ran = { adapter = adapter, mode = mode, parameters = parameters }
        return { cancel = function() end }
    end,
}

--- Run `fn` with `package.loaded[name]` replaced by `stub`, restoring it after.
---@param name string
---@param stub table
---@param fn fun()
local function stubbed(name, stub, fn)
    local real = package.loaded[name]
    package.loaded[name] = stub
    local ok, err = pcall(fn)
    package.loaded[name] = real
    if not ok then error(err) end
end

--- Everything the type reaches for, stubbed, for the duration of `fn`. Both are
--- required lazily, so replacing them here reaches the type's runs and schema.
---@param fn fun()
local function with_ndap(fn)
    stubbed("ndap", fake_ndap, function()
        stubbed("ndap.run.inputs", ENTRY_READER, fn)
    end)
end

--- Drive one `debug` start with `parameters` and `target`, through the stubs.
--- Returns whether the run settled without ndap, and what `start_mode` was handed.
---@param parameters table<string, any>?
---@param target string?
---@return boolean? settled, table? run
local function start(parameters, target)
    ran, reported = nil, {}
    local ctx = {
        name      = "task",
        run_id    = 1,
        report    = function(msg) reported[#reported + 1] = msg end,
        add_bufnr = function() end,
    }
    local settled
    debug.start(
        {
            type       = "debug",
            adapter    = ADAPTER,
            mode       = "launch",
            target     = target,
            parameters = parameters,
        },
        ctx,
        function(ok) settled = ok end)
    return settled, ran
end

--- The `parameters` schema node, wherever the conditional branches place it
--- (each adapter/mode branch carries its own).
---@param schema table
---@return table?
local function parameters_schema(schema)
    local found
    local function walk(node)
        if found or type(node) ~= "table" then return end
        if node.properties and node.properties.parameters
            and node.properties.parameters.properties then
            found = node.properties.parameters
            return
        end
        for _, v in pairs(node) do walk(v) end
    end
    walk(schema)
    return found
end

--- The `parameters` property schema for the input `name`, wherever the
--- conditional branches place it (each adapter/mode branch carries its own).
---@param schema table
---@param name string
---@return table?
local function parameter_schema(schema, name)
    local params = parameters_schema(schema)
    return params and params.properties and params.properties[name]
end

--- The `target` property schema, wherever the conditional branches place it
--- (the adapter branch carries it, and only when an expander is configured).
---@param schema table
---@return table?
local function target_schema(schema)
    local found
    local function walk(node)
        if found or type(node) ~= "table" then return end
        if node.properties and node.properties.target
            and node.properties.target.type then
            found = node.properties.target
            return
        end
        for _, v in pairs(node) do walk(v) end
    end
    walk(schema)
    return found
end

describe("debug parameters – values pass through as written", function()
    before_each(function() config.current.debug_adapters = { ADAPTER } end)
    after_each(function() config.current.debug_adapters = {} end)

    it("passes an array through as written", function()
        with_ndap(function()
            start({ args = { "--one", "two" } })
            assert.are.same({ "--one", "two" }, ran.parameters.args)
        end)
    end)

    it("leaves a scalar string alone", function()
        with_ndap(function()
            start({ cwd = "/tmp/one two" })
            assert.are.equal("/tmp/one two", ran.parameters.cwd)
        end)
    end)

    it("leaves a map alone, entries and all", function()
        with_ndap(function()
            start({ env = { PATH = "/bin" } })
            assert.are.same({ PATH = "/bin" }, ran.parameters.env)
        end)
    end)

    it("does not write through the task's own parameters", function()
        with_ndap(function()
            local parameters = { args = { "--one", "two" } }
            start(parameters)
            assert.are.same({ "--one", "two" }, parameters.args)
        end)
    end)
end)

describe("debug target – an adapter's expander fills inputs", function()
    local seen_ctx
    local function expand(target, ctx)
        seen_ctx = ctx
        return { program = target, args = { "--one" } }
    end

    before_each(function()
        config.current.debug_adapters = { ADAPTER }
        config.current.debug_targets = { [ADAPTER] = expand }
    end)
    after_each(function()
        config.current.debug_adapters = {}
        config.current.debug_targets = {}
        seen_ctx = nil
    end)

    it("fills the inputs it returns", function()
        with_ndap(function()
            start(nil, "./app")
            assert.are.equal("./app", ran.parameters.program)
            assert.are.same({ "--one" }, ran.parameters.args)
        end)
    end)

    it("lets parameters win over what it returns", function()
        with_ndap(function()
            start({ program = "./other" }, "./app")
            assert.are.equal("./other", ran.parameters.program)
            assert.are.same({ "--one" }, ran.parameters.args)
        end)
    end)

    it("hands it the mode, the authored parameters and the inputs", function()
        with_ndap(function()
            start({ cwd = "/tmp" }, "./app")
            assert.are.equal(ADAPTER, seen_ctx.adapter)
            assert.are.equal("launch", seen_ctx.mode)
            assert.are.same({ cwd = "/tmp" }, seen_ctx.parameters)
            assert.are.equal(INPUTS.program, seen_ctx.inputs.program)
        end)
    end)

    it("rejects a returned list written as one string", function()
        config.current.debug_targets[ADAPTER] = function(target)
            return { program = target, args = "--one two" }
        end
        with_ndap(function()
            local settled = start(nil, "./app")
            assert.is_false(settled)
            assert.is_nil(ran)
            assert.is_truthy(reported[1]:find('"args"', 1, true))
            assert.is_truthy(reported[1]:find("expected a list", 1, true))
        end)
    end)

    it("does nothing when the target is unset or whitespace", function()
        with_ndap(function()
            start({ program = "./app" })
            assert.are.equal("./app", ran.parameters.program)
            assert.is_nil(seen_ctx)

            start({ program = "./app" }, "   ")
            assert.are.equal("./app", ran.parameters.program)
            assert.is_nil(seen_ctx)
        end)
    end)

    it("fails when a target is set and no expander is configured", function()
        config.current.debug_targets = {}
        with_ndap(function()
            local settled = start(nil, "./app")
            assert.is_false(settled)
            assert.is_nil(ran)
            assert.is_truthy(reported[1]:find("no `debug_targets` function", 1, true))
        end)
    end)

    it("reports an expander that throws, without starting", function()
        config.current.debug_targets[ADAPTER] = function() error("boom") end
        with_ndap(function()
            local settled = start(nil, "./app")
            assert.is_false(settled)
            assert.is_nil(ran)
            assert.is_truthy(reported[1]:find("target function failed", 1, true))
            assert.is_truthy(reported[1]:find("boom", 1, true))
        end)
    end)

    it("reports a return that is not a table", function()
        config.current.debug_targets[ADAPTER] = function() return 42 end
        with_ndap(function()
            local settled = start(nil, "./app")
            assert.is_false(settled)
            assert.is_nil(ran)
            assert.is_truthy(reported[1]:find("expected a table", 1, true))
        end)
    end)

    it("reports an input the mode does not declare", function()
        config.current.debug_targets[ADAPTER] = function() return { nope = true } end
        with_ndap(function()
            local settled = start(nil, "./app")
            assert.is_false(settled)
            assert.is_nil(ran)
            assert.is_truthy(reported[1]:find('"nope"', 1, true))
        end)
    end)

    it("reports a key that is not an input name at all", function()
        config.current.debug_targets[ADAPTER] = function() return { [1] = "x" } end
        with_ndap(function()
            local settled = start(nil, "./app")
            assert.is_false(settled)
            assert.is_nil(ran)
            assert.is_truthy(reported[1]:find("expected an input name", 1, true))
        end)
    end)

    it("reports a returned value of the wrong type", function()
        config.current.debug_targets[ADAPTER] = function() return { flag = "yes" } end
        with_ndap(function()
            local settled = start(nil, "./app")
            assert.is_false(settled)
            assert.is_nil(ran)
            assert.is_truthy(reported[1]:find('"flag"', 1, true))
            assert.is_truthy(reported[1]:find("expected boolean", 1, true))
        end)
    end)

    it("reports a returned list with an entry of the wrong type", function()
        config.current.debug_targets[ADAPTER] = function() return { ports = { 8080, "x" } } end
        with_ndap(function()
            local settled = start(nil, "./app")
            assert.is_false(settled)
            assert.is_nil(ran)
            assert.is_truthy(reported[1]:find('"ports"', 1, true))
            assert.is_truthy(reported[1]:find("expected integer", 1, true))
        end)
    end)

    it("reports a returned list that is not an array", function()
        config.current.debug_targets[ADAPTER] = function() return { args = { a = "b" } } end
        with_ndap(function()
            local settled = start(nil, "./app")
            assert.is_false(settled)
            assert.is_nil(ran)
            assert.is_truthy(reported[1]:find("expected a list", 1, true))
        end)
    end)

    it("reports a returned map that is not keyed by strings", function()
        config.current.debug_targets[ADAPTER] = function() return { env = { "PATH" } } end
        with_ndap(function()
            local settled = start(nil, "./app")
            assert.is_false(settled)
            assert.is_nil(ran)
            assert.is_truthy(reported[1]:find('"env"', 1, true))
            assert.is_truthy(reported[1]:find("expected string keys", 1, true))
        end)
    end)

    it("does not write through the task's own parameters", function()
        with_ndap(function()
            local parameters = { cwd = "/tmp" }
            start(parameters, "./app")
            assert.is_nil(parameters.program)
            assert.are.equal("/tmp", parameters.cwd)
        end)
    end)
end)

describe("debug schema – target", function()
    before_each(function() config.current.debug_adapters = { ADAPTER } end)
    after_each(function()
        config.current.debug_adapters = {}
        config.current.debug_targets = {}
    end)

    it("offers target only when the adapter has an expander", function()
        local without
        with_ndap(function() without = debug.schema() end)
        assert.is_nil(target_schema(without))
        assert.is_true(vim.tbl_contains(without["x-order"], "target"))

        config.current.debug_targets = { [ADAPTER] = function() return nil end }
        local with
        with_ndap(function() with = debug.schema() end)
        local t = target_schema(with)
        assert.are.equal("string", t.type)
        assert.is_truthy(t.description:find(ADAPTER, 1, true))
    end)

    it("drops required inputs when a target can fill them", function()
        config.current.debug_targets = { [ADAPTER] = function() return nil end }
        local s
        with_ndap(function() s = debug.schema() end)
        assert.is_nil(parameters_schema(s).required)
    end)

    it("keeps required inputs without an expander", function()
        local s
        with_ndap(function() s = debug.schema() end)
        assert.are.same({ "program" }, parameters_schema(s).required)
    end)

    -- The full task schema wraps each type with `additionalProperties = false`,
    -- which only sees that node's own `properties`; a field declared inside an
    -- adapter branch (target) must not be rejected by it.
    it("accepts target through the full task schema", function()
        local function validate_with_expander(expander, task)
            config.current.debug_targets = expander and { [ADAPTER] = expander } or {}
            local schema
            with_ndap(function() schema = require("neotasks.types").build_schema() end)
            return validator.validate(schema, { tasks = { task = task } })
        end

        local ok, errors = validate_with_expander(function() return nil end, {
            type = "debug", adapter = ADAPTER, mode = "launch", target = "prog --x",
        })
        assert.is_true(ok, vim.inspect(errors))

        ok, errors = validate_with_expander(nil, {
            type = "debug", adapter = ADAPTER, mode = "launch", target = "prog --x",
        })
        assert.is_false(ok)
        assert.matches("invalid property name: target",
            table.concat(vim.tbl_map(function(e) return e.err_msg end, errors), "\n"))

        ok, errors = validate_with_expander(function() return nil end, {
            type = "debug", adapter = ADAPTER, mode = "launch", targt = "prog --x",
        })
        assert.is_false(ok)
        assert.matches("invalid property name: targt",
            table.concat(vim.tbl_map(function(e) return e.err_msg end, errors), "\n"))
    end)
end)

describe("debug templates – target", function()
    before_each(function() config.current.debug_adapters = { ADAPTER } end)
    after_each(function()
        config.current.debug_adapters = {}
        config.current.debug_targets = {}
    end)

    --- The one fake-adapter template, built through the stubs.
    ---@return table
    local function template()
        local list
        with_ndap(function() list = debug.templates() end)
        return list[1].task
    end

    it("seeds only target when an expander is configured", function()
        config.current.debug_targets = { [ADAPTER] = function() return nil end }
        local task = template()
        assert.are.equal("", task.target)
        assert.is_nil(task.parameters)
    end)

    it("seeds required parameters when there is no expander", function()
        local task = template()
        assert.is_nil(task.target)
        assert.are.equal("", task.parameters.program)
    end)
end)

describe("debug schema – list inputs", function()
    before_each(function() config.current.debug_adapters = { ADAPTER } end)
    after_each(function() config.current.debug_adapters = {} end)

    --- The property schema for `name`, built through the stubbed ndap.
    ---@param name string
    ---@return table
    local function prop(name)
        local s
        with_ndap(function() s = parameter_schema(debug.schema(), name) end)
        assert.is_table(s)
        return s
    end

    it("accepts an array, not a string", function()
        local p = prop("args")
        assert.are.equal("array", p.type)
        assert.are.same({ type = "string" }, p.items)
        assert.is_true((validator.validate(p, { "--one", "two" })))
        assert.is_false((validator.validate(p, "--one two")))
        assert.is_false((validator.validate(p, 42)))
    end)

    it("types a typed list's entries by its item_type", function()
        local p = prop("ports")
        assert.are.equal("array", p.type)
        assert.are.same({ type = "integer" }, p.items)
    end)

    it("leaves a scalar input the plain scalar schema", function()
        assert.are.equal("string", prop("cwd").type)
    end)
end)
