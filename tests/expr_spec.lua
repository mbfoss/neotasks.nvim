---@diagnostic disable: undefined-global, undefined-field, need-check-nil
-- Unit tests for the pure expression tokenizer + parser
-- (lua/neotasks/util/expr.lua). These assert AST shape and error messages only;
-- evaluation lives in the runner and is tested separately.

local expr = require("neotasks.util.expr")

--- Parse and assert success, returning the AST.
local function ast(src)
    local node, err = expr.parse(src)
    assert.is_nil(err, "unexpected parse error: " .. tostring(err))
    return node
end

--- Parse and assert failure, returning the error message.
local function fail(src)
    local node, err = expr.parse(src)
    assert.is_nil(node)
    assert.is_string(err)
    return err
end

describe("calls", function()
    it("parses a bare name as a zero-arg call", function()
        local n = ast("file")
        assert.equal("call", n.kind)
        assert.equal("file", n.name)
        assert.equal(0, #n.args)
        assert.is_nil(n.paren_open)
    end)

    it("parses an explicit zero-arg call", function()
        local n = ast("file()")
        assert.equal("call", n.kind)
        assert.equal(0, #n.args)
        assert.is_number(n.paren_open)
    end)

    it("parses a call with arguments", function()
        local n = ast('env("HOME")')
        assert.equal("env", n.name)
        assert.equal(1, #n.args)
        assert.equal("string", n.args[1].kind)
        assert.equal("HOME", n.args[1].value)
    end)

    it("parses several comma-separated arguments", function()
        local n = ast('prompt("Path", "default", "file")')
        assert.equal(3, #n.args)
        assert.equal("default", n.args[2].value)
    end)

    it("allows a trailing comma", function()
        local n = ast('prompt("a", "b",)')
        assert.equal(2, #n.args)
    end)

    it("nests calls as arguments", function()
        local n = ast('upper(env("HOME"))')
        assert.equal("upper", n.name)
        assert.equal("call", n.args[1].kind)
        assert.equal("env", n.args[1].name)
    end)
end)

describe("string literals (verbatim)", function()
    it("takes double-quoted contents literally, including single quotes", function()
        assert.equal("printf 'a, b'", ast([[shell("printf 'a, b'")]]).args[1].value)
    end)

    it("takes single-quoted contents literally, including double quotes", function()
        assert.equal('say "hi"', ast([[echo('say "hi"')]]).args[1].value)
    end)

    it("does not interpret braces or a }} inside a string", function()
        assert.equal("sed 's/}}/X/'", ast([[shell("sed 's/}}/X/'")]]).args[1].value)
    end)

    it("does not expand a nested {{ }} inside a string", function()
        assert.equal("{{ file }}", ast("x('{{ file }}')").args[1].value)
    end)

    it("does not treat $1 inside a string as a param", function()
        local n = ast("x('$1')")
        assert.equal("string", n.args[1].kind)
        assert.equal("$1", n.args[1].value)
    end)
end)

describe("scalar literals", function()
    it("parses an integer", function()
        local n = ast("8080")
        assert.equal("number", n.kind)
        assert.equal(8080, n.value)
    end)

    it("parses a negative number", function()
        assert.equal(-1, ast("-1").value)
    end)

    it("parses a float", function()
        assert.equal(3.14, ast("3.14").value)
    end)

    it("parses booleans as boolean nodes, not calls", function()
        assert.equal("boolean", ast("true").kind)
        assert.equal(true, ast("true").value)
        assert.equal(false, ast("false").value)
    end)
end)

describe("params and the $ sigil", function()
    it("parses a positional param", function()
        local n = ast("$1")
        assert.equal("param", n.kind)
        assert.equal(1, n.index)
    end)

    it("parses a multi-digit param", function()
        assert.equal(12, ast("$12").index)
    end)
end)

describe("concatenation", function()
    it("flattens a .. chain into parts", function()
        local n = ast('"a" .. "b" .. "c"')
        assert.equal("concat", n.kind)
        assert.equal(3, #n.parts)
        assert.equal("b", n.parts[2].value)
    end)

    it("composes calls and params", function()
        local n = ast('"cp " .. $1 .. ".bak"')
        assert.equal(3, #n.parts)
        assert.equal("param", n.parts[2].kind)
    end)

    it("respects grouping without leaving a group node", function()
        local n = ast('env(("HOME"))')
        assert.equal("string", n.args[1].kind)
    end)
end)

describe("spans", function()
    it("records 1-based offsets on the callee name", function()
        local n = ast(' env("x") ')
        assert.equal(2, n.name_from)
        assert.equal(4, n.name_to)
    end)
end)

describe("errors", function()
    it("rejects an empty expression", function()
        assert.matches("empty expression", fail(""))
        assert.matches("empty expression", fail("   "))
    end)

    it("reports an unterminated string", function()
        assert.matches("unterminated string", fail('shell("echo hi)'))
    end)

    it("reports a missing close paren", function()
        assert.matches("expected '%)'", fail('env("HOME"'))
    end)

    it("reports a reserved operator", function()
        assert.matches("reserved", fail("1 + 1"))
        assert.matches("reserved", fail("a | b"))
    end)

    it("reports a lone dot as reserved", function()
        assert.matches("reserved", fail("a . b"))
    end)

    it("reports a reserved named param", function()
        assert.matches("reserved", fail("$name"))
    end)

    it("reports a bare dollar", function()
        assert.matches("'%$'", fail("$"))
    end)

    it("reports an unexpected trailing token", function()
        assert.matches("trailing", fail("file file"))
    end)

    it("reports a bad argument separator", function()
        assert.matches("expected ',' or '%)'", fail([[f("a" "b")]]))
    end)

    it("reports an unexpected character", function()
        assert.matches("unexpected character", fail("f(#)"))
    end)

    it("treats a backtick as an unexpected character", function()
        assert.matches("unexpected character", fail("env(`HOME`)"))
    end)
end)
