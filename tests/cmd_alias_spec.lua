---@diagnostic disable: undefined-global, undefined-field
-- Unit tests for `neotasks.create_cmd_alias`: the alias must be a `:Neotasks` in
-- every way that matters -- same arguments as typed, same completion, same
-- refusal to take a name already in use. The harness (tests/init.lua) has
-- already run `setup()`, which is a precondition of the function; the
-- before-`setup()` refusal is covered by a headless driver instead, since
-- `setup()` here is once-per-process.

local neotasks = require("neotasks")

-- Every case registers its own name, so the file is order-independent.
local n = 0

---Register a fresh alias and return its name.
---@return string
local function alias()
    n = n + 1
    local name = ("TasksAlias%d"):format(n)
    assert.is_true(neotasks.create_cmd_alias(name))
    return name
end

---Run `fn` with `vim.notify` captured, restoring it afterwards.
---@param fn fun()
---@return string[]
local function notified(fn)
    local notes = {}
    local real = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end
    local ok, err = pcall(fn)
    vim.notify = real
    if not ok then error(err) end
    return notes
end

---Run `fn` with the module `name` replaced by `stub`, restoring it afterwards.
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

describe("create_cmd_alias", function()
    it("registers the plugin's own argument shape", function()
        local name = alias()
        local cmd = vim.api.nvim_get_commands({})[name]
        assert.are.equal("*", cmd.nargs)
        assert.is_nil(cmd.range)
        assert.is_truthy(cmd.definition:find("alias for :Neotasks", 1, true))
    end)

    it("forwards the line as typed, escapes intact", function()
        local name = alias()
        local cap = {}
        stubbed("neotasks.commands", {
            run = function(cmd, args, opts) cap = { cmd, args, opts } end,
        }, function()
            vim.cmd(name .. [[ run my\ task]])
        end)
        assert.are.equal(name, cap[1])
        assert.are.same({ "run", "my task" }, cap[2])
        assert.are.equal("run my\\ task", cap[3].args)
    end)

    -- The subcommand completer is handed over as the third argument, not the
    -- alias's cursor position, so identity is what the case pins down.
    it("delegates completion with the alias's own line", function()
        local name = alias()
        local got
        local subs = function() return { "stub" } end
        stubbed("neotasks.commands", { complete = subs }, function()
            stubbed("neotasks.util.usercmd", {
                complete = function(a, l, c)
                    got = { a, l, c }
                    return { "stub" }
                end,
            }, function()
                local line = name .. " run "
                assert.are.same({ "stub" }, vim.fn.getcompletion(line, "cmdline"))
                assert.are.same({ "", line, subs }, got)
            end)
        end)
    end)

    it("leaves a name that is already taken alone", function()
        local name = alias()
        local notes = notified(function()
            assert.is_false(neotasks.create_cmd_alias(name))
        end)
        assert.are.same(
            { ("[neotasks] :%s is already taken, so no alias was created"):format(name) }, notes)
    end)

    it("leaves the command's own name alone", function()
        notified(function()
            assert.is_false(neotasks.create_cmd_alias("Neotasks"))
        end)
    end)

    it("refuses a name that cannot be a user command", function()
        assert.has_error(function() neotasks.create_cmd_alias("tasks") end)
        assert.has_error(function() neotasks.create_cmd_alias(nil) end)
    end)
end)
