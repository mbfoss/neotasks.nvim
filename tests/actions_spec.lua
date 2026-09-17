---@diagnostic disable: undefined-global, undefined-field, missing-fields, need-check-nil
-- Unit tests for the LSP code action providers
-- (lua/neotasks/lsp/server/actions.lua).
--
-- Each case is a TOML snippet with a single "|" cursor marker. The helper
-- strips the marker, runs the real parser/decoder pipeline into a buffer
-- context, asks a provider for actions and applies the chosen one's edits back
-- to the text, so the assertions are on the resulting document.

local parser  = require("neotasks.tomltools.parser")
local decoder = require("neotasks.tomltools.decoder")
local actions = require("neotasks.lsp.server.actions")

local URI     = "file:///neotasks.toml"

-- Helpers

-- Split a snippet on its single "|" cursor marker into (text, row0, col0).
local function split_cursor(s)
    local lines = vim.split(s, "\n", { plain = true })
    for r, line in ipairs(lines) do
        local c = line:find("|", 1, true)
        if c then
            lines[r] = line:sub(1, c - 1) .. line:sub(c + 1)
            return table.concat(lines, "\n"), r - 1, c - 1
        end
    end
    error("snippet has no '|' cursor marker")
end

local function make_ctx(text)
    local parsed = parser.parse(text)
    local dec    = decoder.decode(parsed.cst)
    return {
        schema      = {},
        cst         = parsed.cst,
        data        = dec.data,
        decode_tree = dec.decode_tree,
        text        = text,
        lines       = vim.split(text, "\n", { plain = true }),
    }
end

-- Apply one text edit (each of these actions returns exactly one).
local function apply(text, edit)
    local lines = vim.split(text, "\n", { plain = true })
    local s, e  = edit.range.start, edit.range["end"]
    local head  = (lines[s.line + 1] or ""):sub(1, s.character)
    local tail  = (lines[e.line + 1] or ""):sub(e.character + 1)

    local out   = {}
    for i = 1, s.line do out[#out + 1] = lines[i] end
    out[#out + 1] = head .. edit.newText .. tail
    for i = e.line + 2, #lines do out[#out + 1] = lines[i] end
    return table.concat(out, "\n")
end

-- Run a provider on a "|"-marked snippet; returns the action list and the text.
local function run(provider, snippet)
    local text, row, col = split_cursor(snippet)
    local params         = {
        textDocument = { uri = URI },
        range        = { start = { line = row, character = col }, ["end"] = { line = row, character = col } },
    }
    return provider(make_ctx(text), params), text
end

-- Run a provider and apply its single action; returns the rewritten document.
local function rewrite(provider, snippet)
    local list, text = run(provider, snippet)
    assert.equals(1, #list)
    return apply(text, list[1].edit.changes[URI][1])
end

describe("toggle_inline_table_layout", function()
    local toggle = actions.toggle_inline_table_layout

    it("expands a one-line inline table", function()
        assert.equals([[
[tasks.build]
opts = {
  jobs = 4,
  keep = true,
}]], rewrite(toggle, [[
[tasks.build]
opts = { jobs = 4, k|eep = true }]]))
    end)

    it("collapses an expanded inline table", function()
        assert.equals([[
[tasks.build]
opts = { jobs = 4, keep = true }]], rewrite(toggle, [[
[tasks.build]
opts = {|
  jobs = 4,
  keep = true
}]]))
    end)

    it("keeps the surrounding indentation", function()
        assert.equals([[
[tasks.build]
    opts = {
      jobs = 4,
    }]], rewrite(toggle, [[
[tasks.build]
    opts = { j|obs = 4 }]]))
    end)

    it("fires with the cursor on the opening brace", function()
        assert.equals([[
[tasks.build]
opts = {
  jobs = 4,
}]], rewrite(toggle, [[
[tasks.build]
opts = |{ jobs = 4 }]]))
    end)

    it("picks the innermost table under the cursor", function()
        assert.equals([[opts = { a = {
  b = 1,
} }]], rewrite(toggle, [[opts = { a = { b| = 1 } }]]))
    end)

    it("refuses a table holding comments", function()
        assert.equals(0, #(run(toggle, [[
opts = {|
  # why
  a = 1
}]])))
    end)

    it("refuses a table addressed by an index", function()
        assert.equals(0, #(run(toggle, [==[items = [ { a| = 1 } ]]==])))
    end)

    it("offers nothing away from an inline table", function()
        assert.equals(0, #(run(toggle, [[
[tasks.build]
comm|and = "make"]])))
    end)
end)

describe("inline_table_to_section", function()
    local promote = actions.inline_table_to_section

    it("moves the pair out to a section of its own", function()
        assert.equals([[
[tasks.build]
type = "shell"

[tasks.build.opts]
jobs = 4
keep = true]], rewrite(promote, [[
[tasks.build]
type = "shell"
opts = { jobs = 4, k|eep = true }]]))
    end)

    it("puts the section after the pairs that follow it", function()
        assert.equals([[
[tasks.build]
type = "shell"
command = "make"

[tasks.build.opts]
jobs = 4]], rewrite(promote, [[
[tasks.build]
opts = { j|obs = 4 }
type = "shell"
command = "make"]]))
    end)

    it("keeps a following section out of the way", function()
        assert.equals([[
[tasks.build]
type = "shell"

[tasks.build.env]
FOO = "1"

[tasks.test]
type = "shell"]], rewrite(promote, [[
[tasks.build]
type = "shell"
env = { F|OO = "1" }

[tasks.test]
type = "shell"]]))
    end)

    it("uses the dotted path of a dotted key", function()
        assert.equals([[
[tasks]

[tasks.build.env]
FOO = "1"]], rewrite(promote, [[
[tasks]
build.env = { F|OO = "1" }]]))
    end)

    it("keeps nested tables inline", function()
        assert.equals([[
[tasks.debug]

[tasks.debug.parameters]
args = [ 1, 2 ]
env = { A = "1" }]], rewrite(promote, [[
[tasks.debug]
parameters = { a|rgs = [ 1, 2 ], env = { A = "1" } }]]))
    end)

    it("keeps the surrounding indentation", function()
        assert.equals([[
[tasks.build]
    type = "shell"

    [tasks.build.opts]
    jobs = 4]], rewrite(promote, [[
[tasks.build]
    type = "shell"
    opts = { j|obs = 4 }]]))
    end)

    it("promotes a pair at document scope in place", function()
        assert.equals([[
[opts]
jobs = 4

[tasks.build]
type = "shell"]], rewrite(promote, [[
opts = { j|obs = 4 }

[tasks.build]
type = "shell"]]))
    end)

    it("keeps a document-scope pair above the sections", function()
        assert.equals([[
name = "demo"

[opts]
jobs = 4

[tasks.build]
type = "shell"]], rewrite(promote, [[
opts = { j|obs = 4 }
name = "demo"

[tasks.build]
type = "shell"]]))
    end)

    it("fires with the cursor on the opening brace", function()
        assert.equals([[
[tasks.build]

[tasks.build.opts]
jobs = 4]], rewrite(promote, [[
[tasks.build]
opts = |{ jobs = 4 }]]))
    end)

    it("refuses a pair holding comments", function()
        assert.equals(0, #(run(promote, [[
[tasks.build]
opts = { j|obs = 4 } # why]])))
    end)

    it("refuses a table nested in another inline table", function()
        assert.equals(0, #(run(promote, [[
[tasks.build]
opts = { env = { A| = "1" } }]])))
    end)

    it("refuses a table inside an array-of-tables entry", function()
        assert.equals(0, #(run(promote, [==[
[[items]]
opts = { j|obs = 4 }]==])))
    end)

    it("offers nothing away from an inline table", function()
        assert.equals(0, #(run(promote, [[
[tasks.build]
comm|and = "make"]])))
    end)
end)

describe("section_to_inline_table", function()
    local fold = actions.section_to_inline_table

    it("folds a section into a pair of its parent", function()
        assert.equals([[
[tasks.build]
type = "shell"
env = { FOO = "1", BAR = "2" }]], rewrite(fold, [[
[tasks.build]
type = "shell"

[tasks.build.e|nv]
FOO = "1"
BAR = "2"]]))
    end)

    it("fires with the cursor on the opening bracket", function()
        assert.equals([[
[tasks.build]
type = "shell"
env = { FOO = "1" }]], rewrite(fold, [[
[tasks.build]
type = "shell"

|[tasks.build.env]
FOO = "1"]]))
    end)

    it("folds an empty section", function()
        assert.equals([[
[tasks.build]
type = "shell"
env = {}]], rewrite(fold, [==[
[tasks.build]
type = "shell"

[tasks.build.env|]]==]))
    end)

    it("keeps the sections around it apart", function()
        assert.equals([[
[tasks.build]
type = "shell"
env = { FOO = "1" }

[tasks.test]
type = "shell"]], rewrite(fold, [[
[tasks.build]
type = "shell"

[tasks.buil|d.env]
FOO = "1"

[tasks.test]
type = "shell"]]))
    end)

    it("leaves a trailing comment for the next section", function()
        assert.equals([[
[tasks.build]
env = { FOO = "1" }

# the tests
[tasks.test]
type = "shell"]], rewrite(fold, [[
[tasks.build]

[tasks.build.e|nv]
FOO = "1"

# the tests
[tasks.test]
type = "shell"]]))
    end)

    it("folds a top-level section that opens the document", function()
        assert.equals([[
expressions = { outdir = "build" }

[tasks.build]
type = "shell"]], rewrite(fold, [[
[expressio|ns]
outdir = "build"

[tasks.build]
type = "shell"]]))
    end)

    it("moves the pair up to a parent that comes first", function()
        assert.equals([[
[tasks]
build = { type = "shell" }

[other]
x = 1]], rewrite(fold, [[
[tasks]

[other]
x = 1

[tasks.bu|ild]
type = "shell"]]))
    end)

    it("moves the pair down to a parent that comes after it", function()
        assert.equals([[
[tasks]
other = 1
build = { type = "shell" }]], rewrite(fold, [[
[tasks.bu|ild]
type = "shell"

[tasks]
other = 1]]))
    end)

    it("refuses a section with a deeper section below it", function()
        assert.equals(0, #(run(fold, [[
[tasks.build]
type = "shell"

[tasks.buil|d.env]
FOO = "1"

[tasks.build.env.nested]
A = 1]])))
    end)

    it("refuses a section whose parent is not in the file", function()
        assert.equals(0, #(run(fold, [[
[tasks.build.e|nv]
FOO = "1"]])))
    end)

    it("refuses a top-level section that a section precedes", function()
        assert.equals(0, #(run(fold, [[
[tasks.build]
type = "shell"

[expressio|ns]
outdir = "build"]])))
    end)

    it("refuses a section holding comments", function()
        assert.equals(0, #(run(fold, [[
[tasks.build]

[tasks.build.e|nv]
# why
FOO = "1"]])))
    end)

    it("refuses an array-of-tables entry", function()
        assert.equals(0, #(run(fold, [==[
[[ite|ms]]
name = "a"]==])))
    end)

    it("offers nothing away from the header line", function()
        assert.equals(0, #(run(fold, [[
[tasks.build]

[tasks.build.env]
FO|O = "1"]])))
    end)
end)

describe("toggle_array_layout", function()
    local toggle = actions.toggle_array_layout

    it("expands a one-line array", function()
        assert.equals([==[
[tasks.test]
depends_on = [
  "build",
  "lint",
]]==], rewrite(toggle, [==[
[tasks.test]
depends_on = [ "bu|ild", "lint" ]]==]))
    end)

    it("collapses an expanded array", function()
        assert.equals([==[
[tasks.test]
depends_on = [ "build", "lint" ]]==], rewrite(toggle, [==[
[tasks.test]
depends_on = [|
  "build",
  "lint",
]]==]))
    end)

    it("fires with the cursor on the opening bracket", function()
        assert.equals([==[
[tasks.test]
depends_on = [
  "build",
]]==], rewrite(toggle, [==[
[tasks.test]
depends_on = |[ "build" ]]==]))
    end)

    it("keeps the surrounding indentation", function()
        assert.equals([==[
[tasks.test]
    args = [
      1,
      2,
    ]]==], rewrite(toggle, [==[
[tasks.test]
    args = [ 1|, 2 ]]==]))
    end)

    it("works on an array inside an inline table", function()
        assert.equals([[opts = { args = [
  1,
  2,
], jobs = 4 }]], rewrite(toggle, [[opts = { args = [ 1|, 2 ], jobs = 4 }]]))
    end)

    it("leaves the enclosing table to the table action", function()
        local list = run(actions.toggle_inline_table_layout, [[opts = { args = [ 1|, 2 ] }]])
        assert.equals(0, #list)
    end)

    it("refuses an array holding comments", function()
        assert.equals(0, #(run(toggle, [==[
args = [|
  1, # why
  2,
]]==])))
    end)

    it("refuses an array nested in another array", function()
        assert.equals(0, #(run(toggle, [==[pairs = [ [ 1|, 2 ], [ 3, 4 ] ]]==])))
    end)

    it("offers nothing for an empty array", function()
        assert.equals(0, #(run(toggle, [==[args = [|]]==])))
    end)

    it("offers nothing away from an array", function()
        assert.equals(0, #(run(toggle, [[
[tasks.build]
comm|and = "make"]])))
    end)
end)
