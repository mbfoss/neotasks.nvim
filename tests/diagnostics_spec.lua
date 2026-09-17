---@diagnostic disable: undefined-global, undefined-field
-- Unit tests for expression diagnostics in the LSP diagnostics builder
-- (lua/neotasks/lsp/server/diagnostics.lua). A malformed `{{ … }}` expression in
-- a decoded string value should surface as a diagnostic; valid ones should not.

local parser      = require("neotasks.tomltools.parser")
local decoder     = require("neotasks.tomltools.decoder")
local diagnostics = require("neotasks.lsp.server.diagnostics")

-- Build diagnostics for a TOML document. No schema is passed, so only parse-error
-- and expression diagnostics are produced (the document below is always valid TOML).
---@param text string
---@return lsp.Diagnostic[]
local function diags(text)
    local parsed = parser.parse(text)
    local dec    = decoder.decode(parsed.cst)
    local ctx    = {
        schema        = nil,
        cst           = parsed.cst,
        data          = dec.data,
        decode_tree   = dec.decode_tree,
        parse_errors  = parsed.errors,
        decode_errors = dec.errors,
        text          = text,
        lines         = vim.split(text, "\n", { plain = true }),
    }
    return diagnostics.build(nil, ctx)
end

---@return string[]
local function messages(text)
    local out = {}
    for _, d in ipairs(diags(text)) do out[#out + 1] = d.message end
    return out
end

describe("expression diagnostics", function()
    it("flags a reserved operator", function()
        local m = messages([[cmd = "{{ 1 + 2 }}"]])
        assert.equal(1, #m)
        assert.matches("invalid expression", m[1])
        assert.matches("reserved", m[1])
    end)

    it("flags a bad argument separator", function()
        assert.matches("invalid expression", messages([[cmd = "{{ f(a b) }}"]])[1])
    end)

    it("flags a reserved named parameter", function()
        assert.matches("reserved", messages([[cmd = "{{ $name }}"]])[1])
    end)

    it("flags an unexpected trailing token", function()
        assert.matches("trailing", messages([[cmd = "{{ a b }}"]])[1])
    end)

    it("strips the internal column suffix from the message", function()
        assert.is_nil(messages([[cmd = "{{ 1 + 2 }}"]])[1]:find("at col"))
    end)

    it("does not flag a valid expression", function()
        assert.same({}, messages([[cmd = "{{ shell('echo hi') }}"]]))
    end)

    it("does not flag a bare call or literal", function()
        assert.same({}, messages("a = \"{{ file }}\"\nb = \"{{ 8080 }}\""))
    end)

    it("does not flag a }} inside a verbatim string", function()
        assert.same({}, messages([[cmd = "{{ shell('sed s/}}/x/') }}"]]))
    end)

    it("does not flag an unterminated slot (left for run time)", function()
        assert.same({}, messages([[cmd = "{{ env"]]))
    end)

    it("flags only the malformed slot when several are present", function()
        local m = messages([[cmd = "{{ env() }} then {{ 1 + 2 }}"]])
        assert.equal(1, #m)
        assert.matches("reserved", m[1])
    end)

    it("flags an expression in a nested table value", function()
        local m = messages("[env]\nPORT = \"{{ 1 + 2 }}\"")
        assert.equal(1, #m)
        assert.matches("reserved", m[1])
    end)

    it("flags an expression in an array element", function()
        local m = messages("args = [\"{{ ok() }}\", \"{{ a b }}\"]")
        assert.equal(1, #m)
        assert.matches("trailing", m[1])
    end)

    it("points the diagnostic at the offending value's range", function()
        local d = diags([[cmd = "{{ 1 + 2 }}"]])[1]
        assert.equal(0, d.range.start.line)
        -- range covers the string value (starts at the opening quote, col 6)
        assert.is_true(d.range.start.character >= 6)
    end)
end)
