---@diagnostic disable: undefined-global, undefined-field
-- Unit tests for the `debug` type's `parameters`: a `list` may be authored as one
-- string, which the run splits. ndap, absent here, and its entry reader are stubbed.

local config      = require("neotasks.config")
local debug       = require("neotasks.types.debug")
local validator   = require("neotasks.tomltools.validator")

local ADAPTER = "fake"

-- The adapter/mode the tests run: lists (typed and untyped), a map, and the
-- scalars beside them, so every authored form is exercised. Every list takes
-- the one-string form, split on whitespace.
local INPUTS = {
    args   = { type = "list", description = "arguments passed to the program" },
    ports  = { type = "list", item_type = "integer" },
    ignore = { type = "list" },
    env    = { type = "map" },
    cwd    = { type = "string" },
    flag   = { type = "boolean" },
}

--- Entry reading as `ndap.run.inputs` documents it: a string entry is itself, an
--- integer entry is parsed, and one that will not parse is an error naming it.
local ENTRY_READER = {
    parse_entry = function(input, raw)
        if (input.item_type or input.type) == "integer" then
            local n = raw:match("^%s*[-+]?%d+%s*$") and tonumber(raw)
            if not n then return nil, ("expected an integer, got %q"):format(raw) end
            return math.floor(n)
        end
        return raw
    end,
}

-- What the stubbed `run_mode` was handed; nil until a run starts.
local ran
-- Messages the run reported through `ctx.report`.
local reported

local fake_ndap = {
    -- ndap's built-in `remote` is always among them; listing it keeps the type's
    -- "not a registered ndap adapter" warning out of the output.
    available_adapters = function() return { ADAPTER, "remote" } end,
    is_setup           = function() return true end,
    mode_required      = function() return {} end,
    mode_inputs        = function() return INPUTS end,
    mode_names         = function() return { "launch" } end,
    mode               = function() return { description = "launch the program" } end,
    remove_run         = function() end,
    run_mode           = function(adapter, mode, parameters)
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

--- Drive one `debug` start with `parameters`, through the stubs. Returns whether
--- the run settled without ndap, and what `run_mode` was handed.
---@param parameters table<string, any>?
---@return boolean? settled, table? run
local function start(parameters)
    ran, reported = nil, {}
    local ctx = {
        name      = "task",
        run_id    = 1,
        report    = function(msg) reported[#reported + 1] = msg end,
        add_bufnr = function() end,
    }
    local settled
    debug.start(
        { type = "debug", adapter = ADAPTER, mode = "launch", parameters = parameters },
        ctx,
        function(ok) settled = ok end)
    return settled, ran
end

--- The `parameters` property schema for the input `name`, wherever the
--- conditional branches place it (each adapter/mode branch carries its own).
---@param schema table
---@param name string
---@return table?
local function parameter_schema(schema, name)
    local found
    local function walk(node)
        if found or type(node) ~= "table" then return end
        local params = node.properties and node.properties.parameters
        local prop   = params and params.properties and params.properties[name]
        if prop then
            found = prop
            return
        end
        for _, v in pairs(node) do walk(v) end
    end
    walk(schema)
    return found
end

describe("debug parameters – a list written as one string", function()
    before_each(function() config.current.debug_adapters = { ADAPTER } end)
    after_each(function() config.current.debug_adapters = {} end)

    it("splits it into the entries ndap reads", function()
        with_ndap(function()
            start({ args = "--one two" })
            assert.are.same({ "--one", "two" }, ran.parameters.args)
        end)
    end)

    it("splits on whitespace, with no quoting", function()
        with_ndap(function()
            start({ args = [["--flag=a b" --x]] })
            assert.are.same({ [["--flag=a]], [[b"]], "--x" }, ran.parameters.args)
        end)
    end)

    it("keeps a backslash literal in an entry", function()
        with_ndap(function()
            start({ args = [[C:\Users\me\proj]] })
            assert.are.same({ [[C:\Users\me\proj]] }, ran.parameters.args)
        end)
    end)

    it("splits any list, not only a command", function()
        with_ndap(function()
            start({ ignore = "**/vendor/** **/node_modules/**" })
            assert.are.same({ "**/vendor/**", "**/node_modules/**" }, ran.parameters.ignore)
        end)
    end)

    it("reads each entry as the input's entry type", function()
        with_ndap(function()
            start({ ports = "8080 9090" })
            assert.are.same({ 8080, 9090 }, ran.parameters.ports)
        end)
    end)

    it("fails the run, reporting the entry, without starting a session", function()
        with_ndap(function()
            local settled = start({ ports = "8080 not-a-port" })
            assert.is_false(settled)
            assert.is_nil(ran)
            assert.is_truthy(reported[1] and reported[1]:find("ports", 1, true))
            assert.is_truthy(reported[1] and reported[1]:find("expected an integer", 1, true))
        end)
    end)
end)

describe("debug parameters – the forms that are not split", function()
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

    it("leaves an unset input's empty string for ndap to read as unset", function()
        with_ndap(function()
            start({ args = "" })
            assert.are.equal("", ran.parameters.args)
        end)
    end)

    it("reads whitespace alone as unset too, not as no entries", function()
        with_ndap(function()
            start({ args = "  \t " })
            assert.are.equal("", ran.parameters.args)
        end)
    end)

    it("does not write through the task's own parameters", function()
        with_ndap(function()
            local parameters = { args = "--one two" }
            start(parameters)
            assert.are.equal("--one two", parameters.args)
        end)
    end)
end)

describe("debug schema – a list input's authored forms", function()
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

    it("accepts an array and a string, typed the same either way", function()
        local p = prop("args")
        assert.is_true(vim.tbl_contains(p.type, "array"))
        assert.is_true(vim.tbl_contains(p.type, "string"))
        assert.are.same({ type = "string" }, p.items)

        -- Both forms validate: the string one is what the run splits, so the
        -- diagnostics that reject a mistyped parameter accept it too.
        assert.is_true((validator.validate(p, { "--one", "two" })))
        assert.is_true((validator.validate(p, "--one two")))
        assert.is_false((validator.validate(p, 42)))
    end)

    it("types a typed list's entries by its item_type", function()
        local p = prop("ports")
        assert.is_true(vim.tbl_contains(p.type, "string"))
        assert.are.same({ type = "integer" }, p.items)
    end)

    it("says the string form is allowed, beside the input's own description", function()
        local p = prop("args")
        assert.is_truthy(p.description:find("arguments passed to the program", 1, true))
        assert.is_truthy(p.description:find("one string", 1, true))
    end)

    it("accepts a string for any list", function()
        local p = prop("ignore")
        assert.is_true(vim.tbl_contains(p.type, "string"))
        assert.is_true((validator.validate(p, "**/vendor/** **/node_modules/**")))
    end)

    it("leaves a scalar input the plain scalar schema", function()
        assert.are.equal("string", prop("cwd").type)
    end)
end)
