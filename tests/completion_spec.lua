---@diagnostic disable: undefined-global, undefined-field, missing-fields, need-check-nil
-- Unit tests for the LSP completion handler (lua/neotasks/toml/lsp/server/completion.lua).
--
-- Each case is written as a TOML snippet with a single "|" cursor marker. The
-- helper strips the marker, parses + decodes the document into a buffer context,
-- runs the handler, and returns the (sorted) completion labels. This exercises
-- the real pipeline (parser → decoder → DecodeTree → schema navigation) rather
-- than mocking the CST, so the tests double as integration coverage.

local parser     = require("neotasks.tomltools.parser")
local decoder    = require("neotasks.tomltools.decoder")
local completion = require("neotasks.lsp.server.completion")
local CK         = vim.lsp.protocol.CompletionItemKind
local IF         = vim.lsp.protocol.InsertTextFormat

-- Shared schema fixture - covers scalars, enums, booleans, oneOf, nested
-- objects, arrays, and arrays-of-tables with nested objects.
local SCHEMA = {
    type       = "object",
    properties = {
        title   = { type = "string", description = "doc title" },
        version = { type = "integer" },
        debug   = { type = "boolean" },
        mode    = {
            type                 = "string",
            enum                 = { "dev", "prod" },
            ["x-enumDescriptions"] = { "development", "production" },
        },
        level   = { type = "integer", enum = { 1, 2, 3 } },
        server  = {
            type       = "object",
            properties = {
                host = { type = "string" },
                port = { type = "integer" },
                tags = { type = "array", items = { type = "string", enum = { "a", "b" } } },
            },
        },
        db      = {
            type       = "object",
            properties = {
                url  = { type = "string" },
                opts = { type = "object", properties = { pool = { type = "integer" } } },
            },
        },
        tasks   = {
            type  = "array",
            items = {
                type       = "object",
                properties = {
                    name = { type = "string" },
                    cmd  = { type = "string" },
                    env  = {
                        type       = "object",
                        properties = { PATH = { type = "string" }, HOME = { type = "string" } },
                    },
                },
            },
        },
        choice  = {
            oneOf = {
                { type = "string", enum = { "x" } },
                { type = "integer", enum = { 7 } },
            },
        },
        -- Suggested-but-not-required values: offered like an enum, validated like
        -- a plain string.
        console = { type = "string", examples = { "internal", "external" } },
        ports   = { type = "array", items = { type = "integer", examples = { 80, 443 } } },
    },
}

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

-- Build a buffer context (the shape completion.handler expects) from raw text.
local function make_ctx(text, schema)
    local parsed = parser.parse(text)
    local dec    = decoder.decode(parsed.cst)
    return {
        schema      = schema,
        cst         = parsed.cst,
        data        = dec.data,
        decode_tree = dec.decode_tree,
        text        = text,
        lines       = vim.split(text, "\n", { plain = true }),
    }
end

-- Run the handler against a context + position, returning the CompletionList.
local function handle(ctx, row, col)
    local out
    completion.handler(ctx, { position = { line = row, character = col } },
        function(_, res) out = res end)
    return out
end

-- Run completion for a "|"-marked snippet against an arbitrary schema.
local function complete_with(schema, snippet)
    local text, row, col = split_cursor(snippet)
    return handle(make_ctx(text, schema), row, col)
end

-- Run completion for a "|"-marked snippet using the shared SCHEMA.
local function complete(snippet)
    return complete_with(SCHEMA, snippet)
end

-- Sorted list of completion labels.
local function labels(res)
    local out = {}
    for _, it in ipairs(res.items or {}) do out[#out + 1] = it.label end
    table.sort(out)
    return out
end

-- Completion labels in handler order (not sorted) - for ordering assertions.
local function ordered(res)
    local out = {}
    for _, it in ipairs(res.items or {}) do out[#out + 1] = it.label end
    return out
end

-- Find the first item with the given label.
local function item(res, label)
    for _, it in ipairs(res.items or {}) do
        if it.label == label then return it end
    end
    return nil
end

-- Assert that a snippet yields exactly the expected (order-independent) labels.
local function expect(snippet, expected)
    table.sort(expected)
    assert.same(expected, labels(complete(snippet)))
end

-- Guards
describe("completion – guards", function()
    it("returns empty when no schema is set", function()
        local ctx = make_ctx("mode = ", nil)
        assert.same({}, labels(handle(ctx, 0, 7)))
    end)

    it("returns empty when there is no CST", function()
        assert.same({}, labels(handle({ schema = SCHEMA, cst = nil }, 0, 0)))
    end)

    it("returns empty when the row is past the document", function()
        assert.same({}, labels(handle(make_ctx("ab", SCHEMA), 5, 0)))
    end)

    it("returns empty when the column is past the line", function()
        assert.same({}, labels(handle(make_ctx("ab", SCHEMA), 0, 99)))
    end)
end)

-- [table.header] completion
describe("completion – table headers", function()
    it("suggests all reachable object table paths", function()
        -- Only object tables (and object sub-tables of an array element) - scalar
        -- and array-of-string properties are not table headers.
        expect("[|", { "db", "db.opts", "server", "tasks.env" })
    end)

    it("filters paths by the already-typed prefix", function()
        expect("[ser|", { "server" })
    end)

    it("suggests dotted sub-table paths after a parent segment", function()
        expect("[db.|", { "db.opts" })
    end)

    it("descends into array-of-tables element sub-tables", function()
        expect("[tasks.|", { "tasks.env" })
    end)

    it("emits Module items with a whole-path textEdit", function()
        local it = item(complete("[ser|"), "server")
        assert.not_nil(it)
        assert.equals(CK.Module, it.kind)
        assert.equals("server", it.textEdit.newText)
    end)
end)

-- [[array.of.tables]] completion
describe("completion – array-of-tables headers", function()
    it("suggests array-of-tables paths only", function()
        expect("[[|", { "tasks" })
    end)

    it("filters AoT paths by typed prefix", function()
        expect("[[ta|", { "tasks" })
    end)
end)

-- Value side (after '=')
describe("completion – value side", function()
    it("suggests string enum members with their quotes", function()
        expect("mode = |", { '"dev"', '"prod"' })
    end)

    it("suggests numeric enum members", function()
        expect("level = |", { "1", "2", "3" })
    end)

    it("suggests booleans", function()
        expect("debug = |", { "false", "true" })
    end)

    it("offers a quote starter for plain strings", function()
        expect("title = |", { '"', "'" })
    end)

    it("offers nothing for an unconstrained integer", function()
        expect("version = |", {})
    end)

    it("suggests `examples` values the same way as enum members", function()
        expect("console = |", { '"internal"', '"external"' })
    end)

    it("still offers `examples` values while a value is partially typed", function()
        expect('console = "int|"', { '"internal"', '"external"' })
    end)

    it("offers item `examples` inside an array literal", function()
        expect("ports = [|]", { "80", "443" })
    end)

    it("merges enum members across oneOf branches", function()
        expect("choice = |", { "7", '"x"' })
    end)

    it("offers an array starter for array-typed values", function()
        expect("[server]\ntags = |", { "[]" })
    end)

    it("offers item-enum members inside an array literal", function()
        expect('[server]\ntags = [|]', { '"a"', '"b"' })
    end)

    it("offers item completions before the closing bracket", function()
        -- Cursor sits between the string and ']' → still inside the array literal.
        expect('[server]\ntags = ["a"|]', { '"a"', '"b"' })
    end)

    it("suppresses completions after a complete scalar value", function()
        expect("debug = true |", {})
    end)

    it("quotes string enum labels and inserts when no quote is open", function()
        local it = item(complete("mode = |"), '"dev"')
        assert.equals(CK.Text, it.kind)
        assert.equals('"dev"', it.insertText)
        assert.equals("string", it.detail)
        assert.equals("development", it.documentation) -- x-enumDescriptions
    end)

    it("only appends the closing quote when a quote is already open", function()
        local it = item(complete('mode = "|"'), '"dev"')
        assert.equals('dev"', it.insertText)
    end)

    it("still offers enum members while a value is partially typed", function()
        -- Regression: the quoted label must survive the client's prefix filter.
        expect('mode = "de|', { '"dev"', '"prod"' })
    end)

    it("replaces the open quote through the cursor via textEdit", function()
        -- mode = "de|  → open quote at col 7, cursor at col 10. The textEdit spans
        -- the quote so the client's filter prefix ("de) matches the quoted label,
        -- and inserts the full literal.
        local it = item(complete('mode = "de|'), '"dev"')
        assert.not_nil(it.textEdit)
        assert.same({ line = 0, character = 7 }, it.textEdit.range.start)
        assert.same({ line = 0, character = 10 }, it.textEdit.range["end"])
        assert.equals('"dev"', it.textEdit.newText)
    end)

    it("replaces via textEdit for a partially-typed array item enum", function()
        local it = item(complete('[server]\ntags = ["a|'), '"a"')
        assert.not_nil(it.textEdit)
        assert.same({ line = 1, character = 8 }, it.textEdit.range.start)
        assert.same({ line = 1, character = 10 }, it.textEdit.range["end"])
        assert.equals('"a"', it.textEdit.newText)
    end)
end)

-- Key side (before '=')
describe("completion – key side", function()
    it("suggests section keys on a trailing blank line", function()
        expect("[server]\n|", { "host", "port", "tags" })
    end)

    it("suggests section keys while typing a key", function()
        expect("[server]\nh|", { "host", "port", "tags" })
    end)

    it("excludes keys already present in the section", function()
        expect('[server]\nhost = "x"\n|', { "port", "tags" })
    end)

    it("suggests nested-table keys", function()
        expect("[db]\n|", { "opts", "url" })
        expect("[db.opts]\n|", { "pool" })
    end)

    it("resolves value schema inside a nested table", function()
        expect("[db.opts]\npool = |", {})
    end)

    it("emits Field items carrying type detail and documentation", function()
        local it = item(complete("|"), "title")
        assert.equals(CK.Field, it.kind)
        assert.equals("title", it.insertText)
        assert.equals("string", it.detail)
        assert.equals("doc title", it.documentation)
    end)
end)

-- Document root
describe("completion – document root", function()
    it("suggests every top-level key in an empty document", function()
        expect("|", {
            "choice", "console", "db", "debug", "level", "mode", "ports",
            "server", "tasks", "title", "version",
        })
    end)

    it("excludes top-level keys already present", function()
        expect('title = "x"\n|', {
            "choice", "console", "db", "debug", "level", "mode", "ports",
            "server", "tasks", "version",
        })
    end)
end)

-- Inline tables
describe("completion – inline tables", function()
    it("suggests keys inside an inline table", function()
        expect("server = { h| }", { "host", "port", "tags" })
    end)

    it("excludes keys already present in an inline table", function()
        expect('server = { host = "x", | }', { "port", "tags" })
    end)

    it("suggests a value starter inside an inline table", function()
        expect("server = { host = | }", { '"', "'" })
    end)

    it("offers nothing for an unconstrained value inside an inline table", function()
        expect("server = { port = | }", {})
    end)

    it("returns nothing for an inline table on an unknown key", function()
        expect("nope = { x| }", {})
    end)
end)

-- Section scope (trailing blank lines after a header)
describe("completion – section scope", function()
    it("suggests array-of-tables element keys after [[tasks]]", function()
        expect("[[tasks]]\n|", { "cmd", "env", "name" })
    end)

    it("excludes element keys already present", function()
        expect('[[tasks]]\nname = "x"\n|', { "cmd", "env" })
    end)

    it("suggests sub-table keys after [tasks.env]", function()
        expect("[[tasks]]\n[tasks.env]\n|", { "HOME", "PATH" })
    end)
end)

-- Undecoded sections (duplicate / invalid / unknown headers): a rejected section
-- carries no decode tag, but the cursor on its trailing line must still resolve
-- keys from the header path. Regression test for "[tasks.env] suggests `tasks`".
describe("completion – undecoded sections", function()
    it("resolves keys from the header path for a duplicate [table]", function()
        expect("[[tasks]]\n[tasks.env]\n[tasks.env]\n|", { "HOME", "PATH" })
    end)

    it("does not fall back to top-level keys for a duplicate section", function()
        local res = complete("[[tasks]]\n[tasks.env]\n[tasks.env]\n|")
        assert.is_nil(item(res, "tasks")) -- the reported bug: top-level key leaked in
        assert.same({ "HOME", "PATH" }, labels(res))
    end)

    it("returns nothing for an unknown section header", function()
        expect("[bogus]\n|", {})
    end)

    it("returns nothing for a duplicate unknown section header", function()
        expect("[bogus]\n[bogus]\n|", {})
    end)
end)

-- Name-keyed maps (additionalProperties as an object schema), mirroring the tasks
-- file where `tasks` is `{ type=object, additionalProperties = <task schema> }`
-- and names are user-defined, so completion resolves keys through it.
describe("completion – name-keyed maps", function()
    local KEYED = {
        type                 = "object",
        additionalProperties = false,
        properties           = {
            tasks = {
                type                 = "object",
                additionalProperties = {
                    type       = "object",
                    properties = {
                        type = { type = "string", enum = { "shell" } },
                        cmd  = { type = "string" },
                        env  = {
                            type       = "object",
                            properties = { HOME = { type = "string" }, PATH = { type = "string" } },
                        },
                    },
                },
            },
        },
    }

    it("suggests a keyed entry's keys via additionalProperties", function()
        assert.same({ "cmd", "env", "type" }, labels(complete_with(KEYED, "[tasks.build]\n|")))
    end)

    it("excludes keys already present in the entry", function()
        assert.same({ "cmd", "env" }, labels(complete_with(KEYED, '[tasks.build]\ntype = "shell"\n|')))
    end)

    it("suggests sub-table keys under a keyed entry", function()
        assert.same({ "HOME", "PATH" },
            labels(complete_with(KEYED, "[tasks.build]\n[tasks.build.env]\n|")))
    end)

    it("enumerates existing entries and their sub-tables as header paths", function()
        local res = complete_with(KEYED, '[tasks.build]\n[tasks.build.env]\nHOME = "/h"\n[|')
        assert.same({ "tasks", "tasks.build", "tasks.build.env" }, labels(res))
    end)

    it("resolves keys from the header path for a duplicate keyed sub-table", function()
        assert.same({ "HOME", "PATH" },
            labels(complete_with(KEYED, "[tasks.build]\n[tasks.build.env]\n[tasks.build.env]\n|")))
    end)
end)

-- Property ordering & item shape
describe("completion – property ordering", function()
    it("honours an explicit x-order", function()
        local schema = {
            type        = "object",
            ["x-order"] = { "zeta", "alpha", "mid" },
            properties  = {
                zeta  = { type = "string" },
                alpha = { type = "integer" },
                mid   = { type = "boolean" },
            },
        }
        assert.same({ "zeta", "alpha", "mid" }, ordered(complete_with(schema, "|")))
    end)

    it("falls back to alphabetical order without x-order", function()
        local schema = {
            type       = "object",
            properties = {
                banana = { type = "string" },
                apple  = { type = "string" },
                cherry = { type = "string" },
            },
        }
        assert.same({ "apple", "banana", "cherry" }, ordered(complete_with(schema, "|")))
    end)
end)

-- Value starters & multi-type values
describe("completion – value starters", function()
    local schema = {
        type       = "object",
        properties = {
            flexi = { type = { "array", "object" } },
            multi = { type = { "string", "integer" } },
            nul   = { type = { "string", "null" } },
            konst = { const = "FIXED" },
            strarr = { type = { "string", "array" }, items = { type = "string" } },
        },
    }

    it("offers both array and object starters for a union type", function()
        assert.same({ "[]", "{}" }, labels(complete_with(schema, "flexi = |")))
    end)

    it("offers no value starters inside an open string for a string|array union", function()
        -- Regression: `[]`/`{}` starters must not be suggested inside the string.
        assert.same({}, labels(complete_with(schema, 'strarr = "|"')))
    end)

    it("still offers the array starter for a string|array union at value start", function()
        assert.same({ '"', "'", "[]" }, labels(complete_with(schema, "strarr = |")))
    end)

    it("emits snippet inserts for the array/object starters", function()
        local res = complete_with(schema, "flexi = |")
        local arr = item(res, "[]")
        assert.equals(CK.Value, arr.kind)
        assert.equals("[$1]", arr.insertText)
        assert.equals(IF.Snippet, arr.insertTextFormat)
        local obj = item(res, "{}")
        assert.equals("{$1}", obj.insertText)
        assert.equals(IF.Snippet, obj.insertTextFormat)
    end)

    it("offers only a quote starter for a string|integer union", function()
        assert.same({ '"', "'" }, labels(complete_with(schema, "multi = |")))
    end)

    it("treats a nullable string as a string", function()
        assert.same({ '"', "'" }, labels(complete_with(schema, "nul = |")))
    end)
end)

-- Type labels in completion item detail
describe("completion – type labels", function()
    local schema = {
        type       = "object",
        properties = {
            flx = { type = { "array", "object" } },
            nl  = { type = { "string", "null" } },
            mx  = { type = { "string", "integer" } },
            arr = { type = "array" },
            obj = { type = "object" },
        },
    }

    it("renders union, nullable, array and object type labels", function()
        local res = complete_with(schema, "|")
        assert.equals("array|object", item(res, "flx").detail)
        assert.equals("string", item(res, "nl").detail) -- null is stripped
        assert.equals("string|integer", item(res, "mx").detail)
        assert.equals("array", item(res, "arr").detail)
        assert.equals("object", item(res, "obj").detail)
    end)
end)

-- additionalProperties / patternProperties (open-set maps)
describe("completion – open-set maps", function()
    local schema = {
        type       = "object",
        properties = {
            envmap = { type = "object", additionalProperties = { type = "string", enum = { "on", "off" } } },
            pat    = { type = "object", patternProperties = { ["^x_"] = { type = "integer", enum = { 10, 20 } } } },
        },
    }

    it("offers no key completions for an open-ended map", function()
        -- Keys are arbitrary, so there is nothing to enumerate.
        assert.same({}, labels(complete_with(schema, "[envmap]\n|")))
    end)

    it("resolves value enums via additionalProperties for a decoded key", function()
        assert.same({ '"off"', '"on"' }, labels(complete_with(schema, '[envmap]\nFOO = "on|"')))
    end)

    it("resolves value enums via patternProperties for a decoded key", function()
        assert.same({ "10", "20" }, labels(complete_with(schema, "[pat]\nx_count = 1|0")))
    end)

    it("does not yet resolve values for an undecoded key under a map", function()
        -- Characterizes a known limitation: the undecoded-KVP path only walks
        -- `properties`, so additionalProperties/patternProperties are not reached
        -- until the pair has a parseable value.
        assert.same({}, labels(complete_with(schema, "[envmap]\nFOO = |")))
    end)
end)

-- Dotted and quoted keys
describe("completion – dotted & quoted keys", function()
    it("resolves a quoted table header", function()
        expect('["server"]\n|', { "host", "port", "tags" })
    end)

    it("resolves the value schema of a dotted key", function()
        expect("server.host = |", { '"', "'" })
    end)
end)

-- Nested and arrayed inline tables
describe("completion – nested inline tables", function()
    it("suggests keys of a nested inline table", function()
        expect("db = { opts = { p| } }", { "pool" })
    end)

    it("suggests element keys inside an inline-table array literal", function()
        expect("tasks = [ { | } ]", { "cmd", "env", "name" })
    end)

    it("resolves a value inside an inline-table array literal", function()
        expect('tasks = [ { name = | } ]', { '"', "'" })
    end)
end)

-- Array-of-tables element binding
describe("completion – array-of-tables binding", function()
    it("binds [tasks.env] to the most recent [[tasks]] element", function()
        expect('[[tasks]]\nname = "a"\n[[tasks]]\n[tasks.env]\n|', { "HOME", "PATH" })
    end)

    it("suggests element keys on a fresh [[tasks]] element", function()
        expect('[[tasks]]\nname = "a"\n[[tasks]]\n|', { "cmd", "env", "name" })
    end)
end)

-- Document-root dedup is position-independent
describe("completion – root dedup position independence", function()
    it("excludes a top-level key even when its section is below the cursor", function()
        expect('|\n[server]\nhost = "x"\n', {
            "choice", "console", "db", "debug", "level", "mode", "ports",
            "tasks", "title", "version",
        })
    end)
end)

-- Header textEdit replacement range
describe("completion – header replacement range", function()
    it("replaces the whole typed dotted path, starting after the bracket", function()
        local it = item(complete("[db.|"), "db.opts")
        assert.not_nil(it)
        assert.same({ line = 0, character = 1 }, it.textEdit.range.start)
        assert.same({ line = 0, character = 4 }, it.textEdit.range["end"])
        assert.equals("db.opts", it.textEdit.newText)
    end)

    it("excludes the exact already-typed path, offering only deeper paths", function()
        -- After typing the full parent name, only sub-tables remain.
        expect("[db|", { "db.opts" })
        -- A leaf table with no sub-tables yields nothing once fully typed.
        expect("[server|", {})
    end)
end)

-- Dynamic value sources (schema `x-completionType`), mirroring `depends_on`: a
-- string array whose items carry `["x-completionType"] = "TaskNamesExceptSelf"`,
-- completed from the document's sibling task names.
describe("completion – dynamic sources (x-completionType)", function()
    local SRC = {
        type                 = "object",
        additionalProperties = false,
        properties           = {
            tasks = {
                type                 = "object",
                additionalProperties = {
                    type       = "object",
                    properties = {
                        type       = { type = "string", enum = { "shell", "process" } },
                        depends_on = {
                            type  = { "array", "null" },
                            items = { type = "string", ["x-completionType"] = "TaskNamesExceptSelf" },
                        },
                    },
                },
            },
        },
    }

    it("offers sibling task names, excluding the current task", function()
        assert.same({ '"lint"', '"test"' },
            labels(complete_with(SRC, '[tasks.build]\ndepends_on = [|]\n[tasks.lint]\n[tasks.test]\n')))
    end)

    it("excludes self before the array is decoded (unterminated literal)", function()
        -- Unterminated array at EOF: the pair fails to decode, so the path is
        -- rebuilt from the enclosing [tasks.build] header + the typed key. The
        -- sibling headers precede it, so they still parse into the task data.
        local res = complete_with(SRC, '[tasks.lint]\n[tasks.test]\n[tasks.build]\ndepends_on = [|')
        assert.is_nil(item(res, '"build"'))
        assert.same({ '"lint"', '"test"' }, labels(res))
    end)

    it("completes inside an open quote via textEdit", function()
        local it = item(complete_with(SRC, '[tasks.build]\ndepends_on = ["li|"]\n[tasks.lint]\n'), '"lint"')
        assert.not_nil(it.textEdit)
        assert.equals('"lint"', it.textEdit.newText)
    end)

    it("carries the task type as detail", function()
        local it = item(complete_with(SRC,
            '[tasks.lint]\ntype = "shell"\n[tasks.build]\ndepends_on = [|]\n'), '"lint"')
        assert.equals(CK.Text, it.kind)
        assert.equals("shell", it.detail)
    end)

    it("offers nothing when there are no other tasks", function()
        assert.same({}, labels(complete_with(SRC, '[tasks.build]\ndepends_on = [|]\n')))
    end)

    it("ignores an unknown source name", function()
        local schema = {
            type       = "object",
            properties = { pick = { type = "string", ["x-completionType"] = "NoSuchSource" } },
        }
        assert.same({ '"', "'" }, labels(complete_with(schema, "pick = |")))
    end)
end)

-- Guards against schema/registry drift: every `x-completionType` referenced by
-- the real task schema must have a matching resolver, or completion silently
-- returns nothing for that field.
describe("completion – x-completionType registry consistency", function()
    it("has a source for every x-completionType used by the schema", function()
        local sources = require("neotasks.lsp.server.completion_sources")
        local types   = require("neotasks.types")
        local seen    = {}
        local function walk(node)
            if type(node) ~= "table" then return end
            local name = node["x-completionType"]
            if type(name) == "string" then
                assert.is_function(sources[name],
                    ("no completion source registered for x-completionType %q"):format(name))
                seen[name] = true
            end
            for _, v in pairs(node) do walk(v) end
        end
        -- Shared base fields - where depends_on and other dynamic-source fields live.
        walk(require("neotasks.types.schema").base_properties)
        -- Plus each task type's own static schema fragment. Best effort: a type
        -- whose schema needs an unavailable backend (e.g. `debug` → ezdap) is
        -- skipped rather than failing the whole suite in a bare environment.
        for _, tname in ipairs(types.get_names()) do
            local ok, def = pcall(types.get, tname)
            local ts      = ok and def and def.schema
            if type(ts) == "function" then ts = select(2, pcall(ts)) end
            if type(ts) == "table" then walk(ts) end
        end
        assert.is_true(seen.TaskNamesExceptSelf, "expected depends_on to reference a dynamic source")
    end)
end)

describe("completion – expression names inside {{ … }}", function()
    local EXPRS = { { name = "env", description = "env var" }, { name = "shell" } }

    -- Build a ctx that carries the pushed built-in expression list.
    local function complete_expr(snippet)
        local text, row, col = split_cursor(snippet)
        local ctx = make_ctx(text, SCHEMA)
        ctx.expressions = EXPRS
        return handle(ctx, row, col)
    end

    it("offers expression names right after {{", function()
        assert.same({ "env", "shell" }, labels(complete_expr([[title = "{{|"]])))
    end)

    it("offers names after {{ and a space", function()
        assert.same({ "env", "shell" }, labels(complete_expr([[title = "{{ |"]])))
    end)

    it("marks items as Function kind with descriptions", function()
        local it = item(complete_expr([[title = "{{|"]]), "env")
        assert.not_nil(it)
        assert.equals(CK.Function, it.kind)
        assert.equals("env var", it.documentation)
    end)

    it("does not offer expression names elsewhere in a string", function()
        assert.same({}, labels(complete_expr([[title = "hello |"]])))
    end)

    it("still offers while a partial name is typed (manual <C-Space>)", function()
        assert.same({ "env", "shell" }, labels(complete_expr([[title = "{{ en|"]])))
    end)

    it("replaces the partial name via textEdit", function()
        -- title = "{{ en|  → cursor at column 14, partial "en" starts at 12.
        local it = item(complete_expr([[title = "{{ en|"]]), "env")
        assert.not_nil(it)
        assert.same({ line = 0, character = 12 }, it.textEdit.range.start)
        assert.same({ line = 0, character = 14 }, it.textEdit.range["end"])
        assert.equals("env", it.textEdit.newText)
    end)

    it("replaces only the name, not the braces, when there is no space (\"{{abc\")", function()
        -- title = "{{ab|  → cursor at column 13; the `{{` is at 9-10, "ab" at 11.
        local it = item(complete_expr([[title = "{{ab|"]]), "env")
        assert.not_nil(it)
        assert.same({ line = 0, character = 11 }, it.textEdit.range.start)
        assert.same({ line = 0, character = 13 }, it.textEdit.range["end"])
        assert.equals("env", it.textEdit.newText)
    end)

    it("stops offering once a space moves past the name into arguments", function()
        assert.same({}, labels(complete_expr([[title = "{{ env |"]])))
    end)

    it("does not offer inside a closed slot", function()
        assert.same({}, labels(complete_expr([[title = "{{ env }}x|"]])))
    end)

    it("does not reach back across an earlier closed slot (only replaces the name)", function()
        -- title = "{{}}{{na|  → the second slot's name "na" starts at column 15.
        local it = item(complete_expr([[title = "{{}}{{na|"]]), "env")
        assert.not_nil(it)
        assert.same({ line = 0, character = 15 }, it.textEdit.range.start)
        assert.same({ line = 0, character = 17 }, it.textEdit.range["end"])
        assert.equals("env", it.textEdit.newText)
    end)

    it("does not offer after a {{{{ escape (a literal {{, not an opener)", function()
        assert.same({}, labels(complete_expr([[title = "{{{{|"]])))
    end)

    it("offers after a real opener that follows a {{{{ escape", function()
        assert.same({ "env", "shell" }, labels(complete_expr([[title = "{{{{{{|"]])))
    end)

    it("fires across a line break in a multiline string", function()
        assert.same({ "env", "shell" }, labels(complete_expr("title = \"\"\"{{\n  |")))
    end)

    it("offers a partial name typed on the next line of a multiline string", function()
        assert.same({ "env", "shell" }, labels(complete_expr("title = \"\"\"{{\nen|")))
    end)

    it("offers names after an opening paren (nested call)", function()
        assert.same({ "env", "shell" }, labels(complete_expr([[title = "{{ upper(|"]])))
    end)

    it("offers a partial name after an opening paren", function()
        assert.same({ "env", "shell" }, labels(complete_expr([[title = "{{ upper(en|"]])))
    end)

    it("offers names after an argument comma", function()
        assert.same({ "env", "shell" }, labels(complete_expr([[title = "{{ f(env(), |"]])))
    end)

    it("offers names after a concat operator", function()
        assert.same({ "env", "shell" }, labels(complete_expr([[title = "{{ env() .. |"]])))
    end)

    it("does not offer inside a string literal in a slot", function()
        assert.same({}, labels(complete_expr([[title = "{{ shell('en|"]])))
    end)

    it("does not offer right after a completed call", function()
        assert.same({}, labels(complete_expr([[title = "{{ env()|"]])))
    end)
end)
