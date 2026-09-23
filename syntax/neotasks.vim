" Vim syntax file
" Language: neotasks tasks file (TOML + {{ … }} expression slots)
"
" This is the tasks-file filetype's highlighting. It deliberately uses Vim's
" regex engine (no treesitter): neotasks registers `neotasks.toml` as its own
" `neotasks` filetype, for which no treesitter parser exists, so highlighting
" comes from this file alone.
"
" The TOML part mirrors the stock runtime `syntax/toml.vim` and reuses the
" `toml*` highlight groups so colorschemes with TOML support still apply. On
" top of that, string values additionally highlight neotasks expression slots
" (`{{ name }}`, `{{ name(args) }}`, `..` concat, `$1` params, verbatim string
" literals) via the `neotasksExpr*` groups. See lua/neotasks/util/expr.lua
" for the slot grammar.

if exists('b:current_syntax')
  finish
endif

let s:cpo_save = &cpo
set cpo&vim

" ── Expression slots ──────────────────────────────────────────────────────────
" Defined first so the TOML string regions below can pull them in via
" @neotasksExprCluster.

" `{{{{` is an escaped literal `{{`, not a slot opener (see expr.lua's slot
" scanner). Defined *after* the slot region below so it wins at that position
" (last-defined item has priority at a shared start column) and consumes all
" four braces, preventing a spurious slot from opening on the inner `{{`.

" Interior tokens of a slot.
syn keyword neotasksExprBool true false contained
syn match   neotasksExprParam  /\$\d\+/ contained
syn match   neotasksExprNumber /-\=\d\+\%(\.\d\+\)\=/ contained
syn match   neotasksExprConcat /\.\./ contained
syn match   neotasksExprPunct  /[(),]/ contained
" A callee name (bare ident is a zero-arg call). `true`/`false` are caught by
" the keyword above, which outranks this match.
syn match   neotasksExprFunc   /\<[[:alpha:]][[:alnum:]_-]*\>/ contained
" Verbatim string-literal arguments - both delimiters are accepted (see _delims
" in expr.lua). No escapes inside.
syn region  neotasksExprString start=/'/ end=/'/ contained keepend
syn region  neotasksExprString start=/"/ end=/"/ contained keepend

syn cluster neotasksExprBody contains=neotasksExprBool,neotasksExprParam,neotasksExprNumber,neotasksExprConcat,neotasksExprPunct,neotasksExprFunc,neotasksExprString

" The slot itself. No `keepend`: a contained verbatim string is allowed to span
" a `}}` so that e.g. `{{ shell("echo }}") }}` closes on the *outer* `}}`,
" matching how the runtime slot scanner skips strings.
syn region  neotasksExpr matchgroup=neotasksExprDelim start=/{{/ end=/}}/ contained contains=@neotasksExprBody

" Escape for a literal `{{`; defined last so it outranks the slot opener.
syn match   neotasksExprEscape /{{{{/ contained

syn cluster neotasksExprCluster contains=neotasksExpr,neotasksExprEscape

" ── TOML ──────────────────────────────────────────────────────────────────────

syn match tomlEscape /\\[betnfr"/\\]/ display contained
syn match tomlEscape /\\x\x\{2}/ contained
syn match tomlEscape /\\u\x\{4}/ contained
syn match tomlEscape /\\U\x\{8}/ contained
syn match tomlLineEscape /\\$/ contained

" Basic strings
syn region tomlString oneline start=/"/ skip=/\\\\\|\\"/ end=/"/ keepend contains=tomlEscape,@neotasksExprCluster
" Multi-line basic strings
syn region tomlString start=/"""/ end=/"""/ keepend contains=tomlEscape,tomlLineEscape,@neotasksExprCluster
" Literal strings
syn region tomlString oneline start=/'/ end=/'/ keepend contains=@neotasksExprCluster
" Multi-line literal strings
syn region tomlString start=/'''/ end=/'''/ keepend contains=@neotasksExprCluster

syn match tomlInteger /[+-]\=[1-9]\(_\=\d\)*/ display
syn match tomlInteger /[+-]\=0/ display
syn match tomlInteger /[+-]\=0x[[:xdigit:]]\(_\=[[:xdigit:]]\)*/ display
syn match tomlInteger /[+-]\=0o[0-7]\(_\=[0-7]\)*/ display
syn match tomlInteger /[+-]\=0b[01]\(_\=[01]\)*/ display
syn match tomlInteger /[+-]\=\(inf\|nan\)/ display

syn match tomlFloat /[+-]\=\d\(_\=\d\)*\.\d\+/ display
syn match tomlFloat /[+-]\=\d\(_\=\d\)*\(\.\d\(_\=\d\)*\)\=[eE][+-]\=\d\(_\=\d\)*/ display

syn match tomlBoolean /\<\%(true\|false\)\>/ display

" https://tools.ietf.org/html/rfc3339
syn match tomlDate /\d\{4\}-\d\{2\}-\d\{2\}/ display
syn match tomlDate /\d\{2\}:\d\{2\}\%(:\d\{2\}\%(\.\d\+\)\?\)\?/ display
syn match tomlDate /\d\{4\}-\d\{2\}-\d\{2\}[Tt ]\d\{2\}:\d\{2\}\%(:\d\{2\}\%(\.\d\+\)\?\)\?\%([Zz]\|[+-]\d\{2\}:\d\{2\}\)\?/ display

syn match tomlDotInKey /\v[^.]+\zs\./ contained display
syn match tomlKey /\v(^|[{,])\s*\zs[[:alnum:]._-]+\ze\s*\=/ contains=tomlDotInKey display
syn region tomlKeyDq oneline start=/\v(^|[{,])\s*\zs"/ end=/"\ze\s*=/ contains=tomlEscape
syn region tomlKeySq oneline start=/\v(^|[{,])\s*\zs'/ end=/'\ze\s*=/

syn region tomlTable oneline start=/^\s*\[[^\[]/ end=/\]/ contains=tomlKey,tomlKeyDq,tomlKeySq,tomlDotInKey

syn region tomlTableArray oneline start=/^\s*\[\[/ end=/\]\]/ contains=tomlKey,tomlKeyDq,tomlKeySq,tomlDotInKey

syn region tomlKeyValueArray start=/=\s*\[\zs/ end=/\]/ contains=@tomlValue

syn region tomlArray start=/\[/ end=/\]/ contains=@tomlValue contained

syn cluster tomlValue contains=tomlArray,tomlString,tomlInteger,tomlFloat,tomlBoolean,tomlDate,tomlComment

syn keyword tomlTodo TODO FIXME XXX BUG contained

syn match tomlComment /#.*/ contains=@Spell,tomlTodo

" ── Highlight links ───────────────────────────────────────────────────────────

hi def link tomlComment Comment
hi def link tomlTodo Todo
hi def link tomlTableArray Title
hi def link tomlTable Title
hi def link tomlDotInKey Normal
hi def link tomlKeySq Identifier
hi def link tomlKeyDq Identifier
hi def link tomlKey Identifier
hi def link tomlDate Constant
hi def link tomlBoolean Boolean
hi def link tomlFloat Float
hi def link tomlInteger Number
hi def link tomlString String
hi def link tomlLineEscape SpecialChar
hi def link tomlEscape SpecialChar

hi def link neotasksExprDelim  Special
hi def link neotasksExprEscape SpecialChar
hi def link neotasksExprFunc   Identifier
hi def link neotasksExprParam  Identifier
hi def link neotasksExprString String
hi def link neotasksExprNumber Number
hi def link neotasksExprBool   Boolean
hi def link neotasksExprConcat Operator
hi def link neotasksExprPunct  Delimiter

syn sync minlines=500
let b:current_syntax = 'neotasks'

let &cpo = s:cpo_save
unlet s:cpo_save

" vim: et sw=2 sts=2
