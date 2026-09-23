---@class neotasks.runner.resolver
local M = {}

local expressions = require("neotasks.expressions")
local expr = require("neotasks.util.expr")

--- Expression evaluation
--- A task string is literal text with `{{ … }}` *slots*. Nothing outside a slot
--- is special, so the top level never needs escaping: a bare `$`, `\`, or single
--- `}` is literal, and DAP-style `${var}` passes through untouched. Only the
--- two-character sequence `{{` opens a slot; a bare `}}` outside a slot is already
--- literal. To emit a literal `{{`, double it: `{{{{` → `{{` (or use the `lbrace`
--- built-in, `{{ lbrace }}`).
---
--- The text *inside* a slot is a function-call expression, parsed by
--- `neotasks.util.expr` into an AST that this module walks: `name(arg, …)` calls
--- (a bare `name` is a zero-arg call), verbatim string literals
--- (`"…"` / `'…'`), numbers, booleans, `$1`/`$2` positional macro
--- arguments, and the `..` concatenation operator. Nesting is function composition
--- - `upper(env("HOME"))` - so there are no nested `{{ }}` slots and no per-context
--- quoting rules. See docs/expression-grammar.md.
---
--- Because string literals are verbatim, the slot scanner (`_find_span`) skips
--- their contents (via `expr.skip_string`), so a `}}` inside a string never closes
--- the slot early.

---@type fun(str: string, open_at: integer): string?, integer?, string?
local _find_span

--- Find the extent of a `{{ … }}` slot opening at `open_at` (its first `{`).
--- String literals are skipped so a `}}` inside one does not close the slot early.
--- Returns the inner text and the index of the closing `}}`'s second `}`.
---@param str     string
---@param open_at integer
---@return string? inner, integer? close_at, string? err
_find_span = function(str, open_at)
    local n = #str
    local i = open_at + 2
    while i <= n do
        local skip, serr = expr.skip_string(str, i)
        if serr then
            return nil, nil, "Unterminated string in expression"
        elseif skip then
            i = skip
        elseif str:sub(i, i) == "}" and str:sub(i + 1, i + 1) == "}" then
            return str:sub(open_at + 2, i - 1), i + 1
        else
            i = i + 1
        end
    end
    return nil, nil, "Unterminated expression"
end

--- Run `fn` on the main loop and wait (via coroutine yield) for its result, so an
--- expression may call `vim.*` APIs freely. `n` is the number of arguments in
--- `args` - passed explicitly so a trailing `nil` argument survives.
---@param fn   function
---@param args any[]
---@param n    integer
local function _async_call(fn, args, n)
    local parent_co = coroutine.running()
    vim.schedule(function()
        coroutine.wrap(function()
            local ret = vim.F.pack_len(pcall(fn, unpack(args, 1, n)))
            coroutine.resume(parent_co, vim.F.unpack_len(ret))
        end)()
    end)
    return coroutine.yield()
end

---@type fun(inner: string, ctx: neotasks.ExpressionCtx): any, string?
local _eval_expression

---@type fun(node: neotasks.expr.Node, ctx: neotasks.ExpressionCtx): any, string?
local _eval_node

---@type fun(node: neotasks.expr.Node, ctx: neotasks.ExpressionCtx): any, string?
local _eval_call

---@type fun(str: string, ctx: neotasks.ExpressionCtx): string?, string?
local _expand_value

--- Evaluate one AST node to a value: literals yield their value, `concat`
--- stringifies its operands (`nil` becomes `""`), `param` reads the argument
--- frame, `call` delegates to `_eval_call`. Types are preserved for the caller.
---@param node neotasks.expr.Node
---@param ctx  neotasks.ExpressionCtx
---@return any value, string? err
_eval_node = function(node, ctx)
    local kind = node.kind
    if kind == "string" or kind == "number" or kind == "boolean" then
        return node.value
    elseif kind == "param" then
        local frame = ctx._args and ctx._args[#ctx._args]
        if not frame then
            return nil, ("positional argument $%d used outside an inline expression"):format(node.index)
        end
        if node.index < 1 or node.index > frame.n then
            return nil, ("no argument $%d (inline expression received %d)"):format(node.index, frame.n)
        end
        return frame[node.index]
    elseif kind == "concat" then
        local parts = {} ---@type string[]
        for i = 1, #node.parts do
            local val, err = _eval_node(node.parts[i], ctx)
            if err then return nil, err end
            parts[i] = val == nil and "" or tostring(val)
        end
        return table.concat(parts)
    elseif kind == "call" then
        return _eval_call(node, ctx)
    end
    return nil, "internal error: unknown node kind '" .. tostring(kind) .. "'"
end

--- Evaluate a `call` node: arguments first, in the caller's scope, then the name
--- via `expressions.get` or the inline `[expressions]` table, whose template gets
--- a fresh `$1`, `$2`, … frame. `ctx._resolving` guards runaway recursion.
---@param node neotasks.expr.Node
---@param ctx  neotasks.ExpressionCtx
---@return any value, string? err
_eval_call = function(node, ctx)
    local name = node.name --[[@as string]]
    local nargs = #node.args

    -- A nil result is a legitimate value (e.g. an unset env var), so track the
    -- count explicitly rather than via `#` (unreliable with nil array gaps).
    local argvals = {} ---@type any[]
    for k = 1, nargs do
        local val, err = _eval_node(node.args[k], ctx)
        if err then return nil, err end
        argvals[k] = val
    end

    local fn = expressions.get(name)
    if not fn then
        local template = ctx.expressions and ctx.expressions[name]
        if template == nil then return nil, "Unknown expression: '" .. name .. "'" end

        local frame = { n = nargs } ---@type {n:integer,[integer]:any}
        for k = 1, nargs do frame[k] = argvals[k] end

        local resolving = ctx._resolving or {}
        ctx._resolving = resolving
        if resolving[name] then return nil, "Expression cycle detected: '" .. name .. "'" end
        resolving[name] = true

        local args_stack = ctx._args or {}
        ctx._args = args_stack
        args_stack[#args_stack + 1] = frame

        local val, expand_err = _expand_value(template, ctx)

        args_stack[#args_stack] = nil
        resolving[name] = nil
        if expand_err then
            return nil, ("in inline expression `%s`: %s"):format(name, expand_err)
        end
        return val
    end

    -- Built-in / registered function: fn(ctx, arg1, …). Build the argument vector
    -- with an explicit length so a trailing nil survives to the callee.
    local call_args = { ctx } ---@type any[]
    for k = 1, nargs do call_args[k + 1] = argvals[k] end

    local status, val, expression_err = _async_call(fn, call_args, nargs + 1)
    if not status then
        return nil, "[" .. name .. "] Expression crashed: " .. tostring(val)
    end
    if val == nil and expression_err then
        return nil, "[" .. name .. "] " .. tostring(expression_err)
    end
    local valtype = type(val)
    if valtype ~= "nil" and valtype ~= "boolean" and valtype ~= "number" and valtype ~= "string" then
        return nil, "[" .. name .. "] Invalid return type: " .. valtype
    end
    return val
end

--- Evaluate a slot's inner text: parse it to an AST and walk it. Returns the
--- expression's raw value, which `_expand_value` stringifies into place.
---@param inner string
---@param ctx   neotasks.ExpressionCtx
---@return any value, string? err
_eval_expression = function(inner, ctx)
    local ast, perr = expr.parse(inner)
    if not ast then return nil, perr end
    return _eval_node(ast, ctx)
end

--- Expand a string value as interpolation: literal text is copied through and
--- every `{{ … }}` slot is stringified into place, whether the value is one slot
--- or a mix of slots and text. The top level has no escaping, so backslashes and
--- lone braces are literal; `{{{{` emits a literal `{{`.
---@param str string
---@param ctx neotasks.ExpressionCtx
---@return string|nil result, string|nil err
_expand_value = function(str, ctx)
    local res = {} ---@type string[]
    local n, i = #str, 1
    while i <= n do
        local open = str:find("{{", i, true)
        if not open then
            res[#res + 1] = str:sub(i)
            break
        end
        if open > i then res[#res + 1] = str:sub(i, open - 1) end
        if str:sub(open + 2, open + 3) == "{{" then
            -- `{{{{` escapes a literal `{{` - the "double the delimiter" convention.
            res[#res + 1] = "{{"
            i = open + 4
        else
            local content, close, err = _find_span(str, open)
            if not close then return nil, err end
            local val, eval_err = _eval_expression(content --[[@as string]], ctx)
            if eval_err then return nil, eval_err end
            res[#res + 1] = val == nil and "" or tostring(val)
            i = close + 1
        end
    end
    return table.concat(res)
end

--- Human-readable path to a nested key, for error messages: array indices use
--- `[i]`, map keys are dotted (`env.PATH`).
---@param path string?
---@param key any
---@return string
local function _keylabel(path, key)
    if type(key) == "number" then return (path or "") .. "[" .. key .. "]" end
    return path and (path .. "." .. tostring(key)) or tostring(key)
end

---@param tbl  table
---@param seen table
---@param ctx  neotasks.ExpressionCtx
---@param path string?  dotted key path to `tbl`, prefixed onto error messages
---@return boolean ok, string? err
local function _expand_table(tbl, seen, ctx, path)
    seen = seen or {}
    if seen[tbl] then return true end
    seen[tbl] = true
    for k, v in pairs(tbl) do
        local keypath = _keylabel(path, k)
        if type(v) == "table" then
            local ok, err = _expand_table(v, seen, ctx, keypath)
            if not ok then return false, err end
        elseif type(v) == "string" then
            local res, err = _expand_value(v, ctx)
            if err then return false, ("in `%s`: %s"):format(keypath, err) end
            tbl[k] = res
        end
    end
    return true
end

---@param val      any                    string or table to expand
---@param ctx      neotasks.ExpressionCtx
---@param callback fun(ok: boolean, result: any, err: string?)
function M.resolve_expressions(val, ctx, callback)
    coroutine.wrap(function()
        local call_ok, call_ret = xpcall(function()
            if type(val) == "table" then
                local tbl = vim.deepcopy(val)
                local ok, err = _expand_table(tbl, {}, ctx)
                if not ok then error(err) end
                return tbl
            elseif type(val) == "string" then
                local res, err = _expand_value(val, ctx)
                if err then error(err) end
                return res
            else
                return val
            end
        end, debug.traceback)

        local ok, result, err
        if call_ok then
            ok     = true
            result = call_ret
        else
            ok  = false
            err = call_ret
            if type(err) == "string" then
                local clean = err:match(":%d+: (.*)\nstack traceback:")
                if clean then err = clean end
            end
        end

        vim.schedule(function() callback(ok, result, err) end)
    end)()
end

return M
