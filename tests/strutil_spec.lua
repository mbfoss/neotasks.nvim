---@diagnostic disable: undefined-global, undefined-field
-- Unit tests for `split_words`, the one rule that turns an authored string
-- into argv: process command strings and one-string `list` values both use it.

local strutil = require("neotasks.util.strutil")

describe("split_words", function()
    it("splits on runs of whitespace", function()
        assert.are.same({ "a", "b", "c" }, strutil.split_words("a b\tc"))
        assert.are.same({ "a", "b" }, strutil.split_words("  a   b  "))
        assert.are.same({ "a", "b" }, strutil.split_words("a\nb"))
    end)

    it("returns no words for an empty or whitespace-only string", function()
        assert.are.same({}, strutil.split_words(""))
        assert.are.same({}, strutil.split_words(" \t\n "))
    end)

    it("treats a quote as an ordinary character", function()
        assert.are.same({ "--name='my", "app'" }, strutil.split_words([[--name='my app']]))
        assert.are.same({ [["a]], [[b"]] }, strutil.split_words([["a b"]]))
    end)

    it("takes a backslash literally", function()
        assert.are.same({ "rg", [[\d+]], "." }, strutil.split_words([[rg \d+ .]]))
        assert.are.same({ [[Foo\Bar\Baz]] }, strutil.split_words([[Foo\Bar\Baz]]))
        assert.are.same({ [[C:\Users\me\proj]], "--x" }, strutil.split_words([[C:\Users\me\proj --x]]))
    end)
end)
