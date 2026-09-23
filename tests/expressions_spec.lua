local resolver = require("neotasks.runner.resolver")
local expressions   = require("neotasks.expressions")

--- Drive the async `resolve_expressions` synchronously.
---@param val any
---@param ctx table?
---@return boolean ok, any result, string? err
local function resolve(val, ctx)
    local done, rok, result, rerr
    resolver.resolve_expressions(val, ctx or { task = {}, expressions = {} },
        function(ok, res, err)
            rok, result, rerr, done = ok, res, err, true
        end)
    assert.is_true(vim.wait(2000, function() return done end), "resolve_expressions timed out")
    return rok, result, rerr
end

describe("expression stringification", function()
    before_each(function()
        expressions.register("ret_num", function() return 42 end)
        expressions.register("ret_bool", function() return false end)
        expressions.register("ret_str", function() return "hello" end)
        expressions.register("ret_nil", function() return nil end)
    end)

    it("stringifies a number when the whole value is a single expression", function()
        local ok, res = resolve({ port = "{{ ret_num }}" })
        assert.is_true(ok)
        assert.are.equal("string", type(res.port))
        assert.are.equal("42", res.port)
    end)

    it("stringifies a boolean (including false) for a sole expression", function()
        local ok, res = resolve({ flag = "{{ ret_bool }}" })
        assert.is_true(ok)
        assert.are.equal("string", type(res.flag))
        assert.are.equal("false", res.flag)
    end)

    it("keeps surrounding whitespace around a sole expression", function()
        local ok, res = resolve({ port = "  {{ ret_num }}  " })
        assert.is_true(ok)
        assert.are.equal("  42  ", res.port)
    end)

    it("stringifies when the expression is mixed with literal text", function()
        local ok, res = resolve({ label = "port={{ ret_num }}" })
        assert.is_true(ok)
        assert.are.equal("string", type(res.label))
        assert.are.equal("port=42", res.label)
    end)

    it("stringifies when multiple expressions are concatenated", function()
        local ok, res = resolve({ x = "{{ ret_num }}{{ ret_num }}" })
        assert.is_true(ok)
        assert.are.equal("4242", res.x)
    end)

    it("keeps string-returning expressions as strings", function()
        local ok, res = resolve({ x = "{{ ret_str }}" })
        assert.is_true(ok)
        assert.are.equal("hello", res.x)
    end)

    it("yields an empty string when a sole expression returns nil", function()
        local ok, res = resolve({ x = "{{ ret_nil }}" })
        assert.is_true(ok)
        assert.are.equal("", res.x)
    end)
end)

describe("scalar literals", function()
    it("stringifies a number literal", function()
        local ok, res = resolve({ port = "{{ 8080 }}" })
        assert.is_true(ok)
        assert.are.equal("string", type(res.port))
        assert.are.equal("8080", res.port)
    end)

    it("stringifies a float and a negative number", function()
        local ok, res = resolve({ a = "{{ 3.14 }}", b = "{{ -1 }}" })
        assert.is_true(ok)
        assert.are.equal("3.14", res.a)
        assert.are.equal("-1", res.b)
    end)

    it("stringifies boolean literals", function()
        local ok, res = resolve({ a = "{{ true }}", b = "{{ false }}" })
        assert.is_true(ok)
        assert.are.equal("true", res.a)
        assert.are.equal("false", res.b)
    end)

    it("stringifies a number literal when interpolated", function()
        local ok, res = resolve({ x = "port={{ 8080 }}" })
        assert.is_true(ok)
        assert.are.equal("port=8080", res.x)
    end)
end)

describe("expression arguments", function()
    -- Report the args an expression received, as "#<count>:<a>|<b>|...".
    local function register_nargs(name)
        expressions.register(name, function(_, ...)
            local a = { ... }
            return "#" .. #a .. ":" .. table.concat(a, "|")
        end)
    end

    it("does not re-split a nested expression's output", function()
        register_nargs("nargs1")
        expressions.register("withcomma", function() return "a,b" end)
        -- The nested expression yields "a,b"; it arrives as ONE argument.
        local ok, res = resolve({ x = "{{ nargs1(withcomma) }}" })
        assert.is_true(ok)
        assert.are.equal("#1:a,b", res.x)
    end)

    it("passes a nested call's value as a single argument", function()
        register_nargs("nargs2")
        expressions.register("second", function(_, _, b) return b end)
        local ok, res = resolve({ x = "{{ nargs2(second('missing', 'xyz')) }}" })
        assert.is_true(ok)
        assert.are.equal("#1:xyz", res.x)
    end)

    it("keeps a whole string argument together despite spaces", function()
        register_nargs("nargs3")
        local ok, res = resolve({ x = "{{ nargs3('a b c') }}" })
        assert.is_true(ok)
        assert.are.equal("#1:a b c", res.x)
    end)

    it("keeps a comma literal inside a string argument", function()
        register_nargs("nargs4")
        local ok, res = resolve({ x = "{{ nargs4('a,b', 'c') }}" })
        assert.is_true(ok)
        assert.are.equal("#2:a,b|c", res.x)
    end)

    it("keeps a lone backslash literal inside a string", function()
        register_nargs("nargs4c")
        local ok, res = resolve({ x = [[{{ nargs4c('a\b') }}]] })
        assert.is_true(ok)
        assert.are.equal([[#1:a\b]], res.x)
    end)

    it("separates arguments by comma", function()
        register_nargs("nargs4e")
        local ok, res = resolve({ x = "{{ nargs4e('a', 'b') }}" })
        assert.is_true(ok)
        assert.are.equal([[#2:a|b]], res.x)
    end)

    it("preserves an empty argument via an empty string", function()
        register_nargs("nargs5")
        local ok, res = resolve({ x = "{{ nargs5('a', '', 'c') }}" })
        assert.is_true(ok)
        assert.are.equal("#3:a||c", res.x)
    end)
end)

describe("top-level literals (no escaping)", function()
    it("leaves a DAP-style ${...} untouched", function()
        local ok, res = resolve({ x = [[${workspaceFolder}/app]] })
        assert.is_true(ok)
        assert.are.equal("${workspaceFolder}/app", res.x)
    end)

    it("leaves a lone dollar and single brace literal", function()
        local ok, res = resolve({ x = [[price is ${5}]] })
        assert.is_true(ok)
        assert.are.equal("price is ${5}", res.x)
    end)

    it("keeps backslashes literal", function()
        local ok, res = resolve({ x = [[C:\Users\me]] })
        assert.is_true(ok)
        assert.are.equal([[C:\Users\me]], res.x)
    end)

    it("still expands a slot beside literal text", function()
        expressions.register("who", function() return "bob" end)
        local ok, res = resolve({ x = [[$USER={{ who }}]] })
        assert.is_true(ok)
        assert.are.equal("$USER=bob", res.x)
    end)
end)

describe("{{{{ literal-brace escape (doubling)", function()
    it("emits a literal {{ from {{{{", function()
        local ok, res = resolve({ x = "{{{{" })
        assert.is_true(ok)
        assert.are.equal("{{", res.x)
    end)

    it("leaves a bare }} literal without any escape", function()
        local ok, res = resolve({ x = "a }} b" })
        assert.is_true(ok)
        assert.are.equal("a }} b", res.x)
    end)

    it("produces a literal {{ }} pair around text", function()
        local ok, res = resolve({ x = "echo {{{{x}}" })
        assert.is_true(ok)
        assert.are.equal("echo {{x}}", res.x)
    end)

    it("composes an escape with a real slot", function()
        expressions.register("who2", function() return "bob" end)
        local ok, res = resolve({ x = "{{{{{{ who2 }}}}" })
        assert.is_true(ok)
        assert.are.equal("{{bob}}", res.x)
    end)

    it("does not treat {{{{ as a sole-value slot (keeps it a string)", function()
        local ok, res = resolve({ x = "{{{{}}" })
        assert.is_true(ok)
        assert.are.equal("{{}}", res.x)
    end)
end)

describe("lbrace builtin (literal-brace escape)", function()
    it("emits a literal {{", function()
        local ok, res = resolve({ x = "{{ lbrace }}" })
        assert.is_true(ok)
        assert.are.equal("{{", res.x)
    end)

    it("composes with a real slot into a {{ }} pair", function()
        expressions.register("who3", function() return "bob" end)
        local ok, res = resolve({ x = "{{ lbrace }}{{ who3 }}}}" })
        assert.is_true(ok)
        assert.are.equal("{{bob}}", res.x)
    end)
end)

describe("string literals inside a slot", function()
    local function register_echo(name)
        expressions.register(name, function(_, a) return a end)
    end

    it("takes a verbatim string, not expanding a nested {{ }}", function()
        register_echo("br3")
        expressions.register("inner3", function() return "X" end)
        local ok, res = resolve({ x = "{{ br3('{{ inner3 }}') }}" })
        assert.is_true(ok)
        assert.are.equal("{{ inner3 }}", res.x)
    end)

    it("keeps a }} inside a string from closing the slot", function()
        register_echo("br3b")
        local ok, res = resolve({ x = "{{ br3b('a }} b') }}" })
        assert.is_true(ok)
        assert.are.equal("a }} b", res.x)
    end)

    it("composes a nested expression via concat", function()
        register_echo("br4")
        expressions.register("inner4", function() return "X" end)
        local ok, res = resolve({ x = "{{ br4('v=' .. inner4) }}" })
        assert.is_true(ok)
        assert.are.equal("v=X", res.x)
    end)

    it("keeps quotes inside a backtick string", function()
        register_echo("br5")
        local ok, res = resolve({ x = [[{{ br5('say "hi"') }}]] })
        assert.is_true(ok)
        assert.are.equal([[say "hi"]], res.x)
    end)

    it("errors clearly on an unterminated slot", function()
        register_echo("br8")
        local ok, _, err = resolve({ x = "{{ br8 oops" })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("Unterminated expression"))
    end)

    it("errors clearly on an unterminated string", function()
        register_echo("br9")
        local ok, _, err = resolve({ x = "{{ br9('oops }}" })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("Unterminated string"))
    end)
end)

describe("inline expressions ([expressions] table)", function()
    -- Build a ctx whose inline `[expressions]` table holds the given templates.
    local function ctx(exprs)
        return { task = {}, expressions = exprs }
    end

    it("expands an inline expression referenced by name", function()
        local ok, res = resolve({ x = "curl {{ api }}" },
            ctx({ api = "http://localhost:8080" }))
        assert.is_true(ok)
        assert.are.equal("curl http://localhost:8080", res.x)
    end)

    it("lets an inline expression reference other inline expressions", function()
        local ok, res = resolve({ x = "{{ api }}" },
            ctx({ api = "http://{{ host }}:{{ port }}", host = "localhost", port = "8080" }))
        assert.is_true(ok)
        assert.are.equal("http://localhost:8080", res.x)
    end)

    it("stringifies a literal yielded by an inline expression", function()
        local ok, res = resolve({ x = "{{ count }}" }, ctx({ count = "{{ 5 }}" }))
        assert.is_true(ok)
        assert.are.equal("5", res.x)
        assert.are.equal("string", type(res.x))
    end)

    it("prefers a built-in/registered expression over an inline one of the same name", function()
        expressions.register("regwins", function() return "registered" end)
        local ok, res = resolve({ x = "{{ regwins }}" }, ctx({ regwins = "inline" }))
        assert.is_true(ok)
        assert.are.equal("registered", res.x)
    end)

    it("errors on a direct cycle", function()
        local ok, _, err = resolve({ x = "{{ a }}" }, ctx({ a = "{{ a }}" }))
        assert.is_false(ok)
        assert.is_truthy(err and err:match("cycle"))
    end)

    it("errors on an indirect cycle", function()
        local ok, _, err = resolve({ x = "{{ a }}" }, ctx({ a = "{{ b }}", b = "{{ a }}" }))
        assert.is_false(ok)
        assert.is_truthy(err and err:match("cycle"))
    end)

    it("errors on an unknown name that is neither registered nor inline", function()
        local ok, _, err = resolve({ x = "{{ nope }}" }, ctx({}))
        assert.is_false(ok)
        assert.is_truthy(err and err:match("Unknown expression"))
    end)

    it("reuses the same inline expression twice without a false cycle", function()
        local ok, res = resolve({ x = "{{ a }}-{{ a }}" }, ctx({ a = "v" }))
        assert.is_true(ok)
        assert.are.equal("v-v", res.x)
    end)
end)

describe("inline expression arguments ($1, $2, …)", function()
    local function ctx(exprs)
        return { task = {}, expressions = exprs }
    end

    it("substitutes a positional argument", function()
        local ok, res = resolve({ x = "{{ greet('World') }}" }, ctx({ greet = "hello {{ $1 }}" }))
        assert.is_true(ok)
        assert.are.equal("hello World", res.x)
    end)

    it("substitutes several positional arguments", function()
        local ok, res = resolve({ x = "{{ pair('a', 'b') }}" }, ctx({ pair = "{{ $1 }}-{{ $2 }}" }))
        assert.is_true(ok)
        assert.are.equal("a-b", res.x)
    end)

    it("stringifies a numeric argument in a sole $N template", function()
        local ok, res = resolve({ x = "{{ id(5) }}" }, ctx({ id = "{{ $1 }}" }))
        assert.is_true(ok)
        assert.are.equal("string", type(res.x))
        assert.are.equal("5", res.x)
    end)

    it("evaluates arguments in the caller's scope", function()
        -- The argument itself references another inline expression.
        local ok, res = resolve({ x = "{{ wrap(who) }}" },
            ctx({ wrap = "<{{ $1 }}>", who = "bob" }))
        assert.is_true(ok)
        assert.are.equal("<bob>", res.x)
    end)

    it("does not leak arguments into a nested argless inline call", function()
        -- `outer` receives an arg; it calls `inner` with NO args, so inner's $1
        -- must not see outer's argument - it errors instead.
        local ok, _, err = resolve({ x = "{{ outer('hi') }}" },
            ctx({ outer = "{{ inner }}", inner = "{{ $1 }}" }))
        assert.is_false(ok)
        assert.is_truthy(err and err:match("no argument"))
    end)

    it("passes an argument through to a nested inline call", function()
        local ok, res = resolve({ x = "{{ outer('hi') }}" },
            ctx({ outer = "{{ inner($1) }}", inner = "[{{ $1 }}]" }))
        assert.is_true(ok)
        assert.are.equal("[hi]", res.x)
    end)

    it("errors when a referenced argument was not supplied", function()
        local ok, _, err = resolve({ x = "{{ pair('only') }}" }, ctx({ pair = "{{ $1 }}-{{ $2 }}" }))
        assert.is_false(ok)
        assert.is_truthy(err and err:match("no argument %$2"))
    end)

    it("errors on a positional reference outside any inline expression", function()
        local ok, _, err = resolve({ x = "{{ $1 }}" }, ctx({}))
        assert.is_false(ok)
        assert.is_truthy(err and err:match("outside an inline expression"))
    end)
end)

describe("shell builtin", function()
    it("returns command stdout with the trailing newline stripped", function()
        local ok, res = resolve({ x = "{{ shell('printf hello') }}" })
        assert.is_true(ok)
        assert.are.equal("hello", res.x)
    end)

    it("keeps the command's own quoting via a verbatim string", function()
        local ok, res = resolve({ x = [[{{ shell("printf 'a,b'") }}]] })
        assert.is_true(ok)
        assert.are.equal("a,b", res.x)
    end)

    it("interpolates in a larger string", function()
        local ok, res = resolve({ x = "user={{ shell('printf bob') }}" })
        assert.is_true(ok)
        assert.are.equal("user=bob", res.x)
    end)

    it("errors on a non-zero exit status", function()
        local ok, _, err = resolve({ x = "{{ shell('false') }}" })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("shell command failed"))
    end)

    it("errors when given no command", function()
        local ok, _, err = resolve({ x = "{{ shell() }}" })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("requires a command"))
    end)
end)

describe("error context", function()
    before_each(function()
        expressions.register("boom", function() return nil, "kaboom" end)
    end)

    it("names the failing expression", function()
        local ok, _, err = resolve({ command = "{{ boom }}" })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("%[boom%]"))
    end)

    it("names the config field the error occurred in", function()
        local ok, _, err = resolve({ command = "{{ boom }}" })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("in `command`"))
    end)

    it("reports a dotted path for a nested map key", function()
        local ok, _, err = resolve({ env = { PORT = "{{ boom }}" } })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("in `env%.PORT`"))
    end)

    it("reports an indexed path for an array element", function()
        local ok, _, err = resolve({ args = { "ok", "{{ boom }}" } })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("in `args%[2%]`"))
    end)

    it("names the inline expression an error came from", function()
        local ok, _, err = resolve({ command = "{{ bad }}" },
            { task = {}, expressions = { bad = "{{ boom }}" } })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("in inline expression `bad`"))
        assert.is_truthy(err and err:match("in `command`"))  -- field kept too
        assert.is_truthy(err and err:match("%[boom%]"))        -- and the failing expression
    end)

    it("names an unknown expression and its field", function()
        local ok, _, err = resolve({ command = "{{ nope }}" })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("Unknown expression: 'nope'"))
        assert.is_truthy(err and err:match("in `command`"))
    end)
end)
