# Expression grammar — design spec (draft)

Status: **draft, for review.** Function-call expression grammar for the
interior of a `{{ … }}` slot in
[resolver.lua](../lua/neotasks/runner/resolver.lua).

## Goal

One uniform model inside a slot: function calls, comma-separated arguments,
verbatim string literals.

- Nesting is function composition `f(g(x))` — no recursive brace matching, no
  per-context quoting rules.
- Same syntax family as HCL, GitHub Actions `${{ }}`, Jinja expressions.
- Non-goal: control flow (`if`/`for`). This is value interpolation, not
  templating.

## Delimiters & top-level rules

- A slot is `{{ … }}`. Only `{{` is special; everything else at the top level
  is literal — a bare `$`, `\`, lone `}`, or DAP-style `${var}` passes through
  untouched.
- `{{{{` emits a literal `{{`; `lbrace()` does the same from expression
  position.
- **Always string interpolation**: every slot is stringified into place and the
  value stays a string, whether it is one slot or slots mixed with text (`nil`
  becomes `""`). Types are preserved only *within* a slot, where an
  expression's arguments keep their native type.

## The grammar (inside a slot)

### Values

| Kind      | Syntax                    | Notes                                                |
|-----------|---------------------------|------------------------------------------------------|
| String    | `"…"`, `'…'`              | **Always verbatim.** Pick the quote your content lacks. |
| Number    | `8080`, `3.14`, `-1`      | Lua number.                                          |
| Boolean   | `true`, `false`           |                                                      |
| Call      | `name` or `name(a, b, …)` | Bare `name` ≡ zero-arg `name()`.                     |
| Param ref | `$1`, `$2`, …             | Positional macro argument (in `[expressions]` only). |
| Group     | `( expr )`                |                                                      |
| Concat    | `a .. b`                  | Stringifies both sides; left-associative.            |

**No free variables**: every identifier names a built-in, registered or inline
expression, so `name` is unambiguously a zero-arg call.

### The `$` sigil

`$` is special **only in expression position** (inside a slot):

- `$` + one or more digits → positional param (`$1`, `$2`).
- `$` + a letter → **reserved** for future named params (parse error for now).

A literal `$` never needs an escape: outside slots and inside verbatim string
literals it is an ordinary character — which is why DAP-style `${var}` passes
through untouched and `'$'` yields `$`. In expression position a `$` is only
ever wanted as text, and text belongs in a string.

### Strings, quoting, and TOML

A string literal is the exact bytes between its delimiters — no escape
sequences, no interpolation. Two interchangeable delimiters exist so you can
pick one your content doesn't contain:

- `"…"` / `'…'` — both verbatim.
- They double as TOML string delimiters, so mind the *outer* tasks-file value:
  a `"` inside a TOML basic string is TOML-decoded before the expression parser
  sees it.
  Pair a `'…'` expression string with a TOML basic (`"…"`) value, and a `"…"`
  expression string with a TOML literal (`'…'`) value, to avoid double-layer
  escaping.
- Escapes come from TOML: it decodes `\n`, `\t` and the rest in a basic string
  before the expression parser runs, and leaves a literal string raw, so a real
  newline in an expression string is a real newline passed through. There is no
  escape layer on top of that.

Interpolating a value into a string means **concatenating** it; `$1` and
`{{…}}` inside a string are literal, never expanded:

```
{{ shell("printf 'a, b'") }}          # double quotes: the ' inside is literal
{{ shell("echo " .. file()) }}        # compose a command
{{ env("HOME") }}
```

### Quote-aware slot scanning

The scanner finding a slot's closing `}}` skips string contents, so braces and
`}}` inside a string never close the slot early:

```
{{ shell("sed 's/}}/X/'") }}          # }} inside the string is fine
```

### Concatenation operator

- `..` — the only operator in v1; stringifies both operands.
- No arithmetic (a `lua(…)` call if ever needed).
- `+ - * / | . []` are **reserved** by the tokenizer (clear parse error), so
  pipelines and arithmetic can be added later cleanly.

### EBNF

```ebnf
expr      = concat ;
concat    = primary { ".." primary } ;
primary   = call | literal | param | "(" expr ")" ;
call      = ident [ "(" [ arglist ] ")" ] ;
arglist   = expr { "," expr } [ "," ] ;
param     = "$" digit { digit } ;
literal   = string | number | boolean ;
string    = '"' { any } '"' | "'" { any } "'" ;
number    = [ "-" ] digit { digit } [ "." digit { digit } ] ;
boolean   = "true" | "false" ;
ident     = alpha { alpha | digit | "_" | "-" } ;
```

## Inline macros (`[expressions]` table)

`[expressions]` maps a name to a **template string** that may contain slots.

- **Positional params `$1`, `$2`, …**, referenced from expression position.
- Called like any function: `{{ greet("world") }}`.
- Arguments are evaluated in the **caller's** scope, type-preservingly (a `$1`
  passed on to another call keeps its number/boolean); a template always
  expands to a string.
- Cycle detection applies, as does "a real/registered expression shadows an
  inline one of the same name".
- Referencing an unsupplied `$N`, or `$N` outside a macro, is an error.

```toml
[expressions]
greet  = "'Hello, ' .. $1 .. '!'"
backup = "shell('cp ' .. $1 .. ' ' .. $1 .. '.bak')"
tagged = "greet($1) .. ' [' .. env('USER') .. ']'"
```

Named params (`greet(name) = …`) are out of scope for v1; `$` + non-digit is
reserved for that.

## Module layout

The grammar lives in **one pure module** — tokenizer + parser producing an AST,
with **no `vim` calls and no evaluation**. Both consumers import it:

- **Runner** ([resolver.lua](../lua/neotasks/runner/resolver.lua)) walks the
  AST to evaluate, calling into
  [expressions.lua](../lua/neotasks/expressions.lua) for function bodies.
- **LSP** ([completion.lua](../lua/neotasks/lsp/server/completion.lua)) parses
  to locate the cursor (name position? argument N? which call?) for completion
  and signature help.

Proposed home: `util/expr.lua` (per the shared-helpers convention). Purity is
what matters — the LSP must not pull in the evaluator's side effects.
`expressions.lua` stays the function **registry**; the evaluator stays in the
runner.

## Expression functions

`M.register(name, fn)` and the `neotasks.ExpressionFn` signature (`fn(ctx, …)`)
are unchanged; a function receives its evaluated arguments positionally. There
is no "raw-body" flavor — a verbatim string literal covers that need.

## LSP impact

A real parser upgrades completion:

- Names completed after `{{` **and** after `(` (nested calls).
- Signature help per argument, driven by `,`.
- Diagnostics on unterminated string/paren and on reserved operators.
- Hover on a function name (existing descriptions).

## Decisions

1. **Pipelines** — deferred; `|` is reserved by the tokenizer, so pipes can be
   added later without a breaking change. `f(g(x))` + `..` covers the pain now.
2. **Concat token** — `..` (Lua-native, no arithmetic confusion).
3. **Macro params** — positional `$1`, `$2`, …; `$` + letter reserved for
   future named params.
