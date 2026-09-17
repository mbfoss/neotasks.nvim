" Vim filetype plugin for the neotasks tasks file.
"
" Provides structure folding without treesitter: each TOML table header
" (`[tasks.build]`) or array-of-tables header (`[[tasks]]`) opens a fold that
" runs to the next header, and dotted key paths nest (`[tasks.build.env]` folds
" inside `[tasks.build]`). Uses `foldmethod=expr` since the header lines are
" one-liners that a syntax-region fold can't span.

if exists('b:did_ftplugin')
  finish
endif
let b:did_ftplugin = 1

let s:cpo_save = &cpo
set cpo&vim

setlocal commentstring=#\ %s
setlocal comments=:#

" Split a header line's key path into its top-level components, honouring quoted
" keys (which may themselves contain dots). `[tasks."a.b".env]` → [tasks, "a.b", env].
function! s:HeaderPath(line) abort
  let l:inner = matchstr(a:line, '\v^\s*\[{1,2}\zs.{-}\ze\]{1,2}\s*%(#.*)?$')
  let l:parts = []
  let l:cur = ''
  let l:quote = ''
  for l:i in range(len(l:inner))
    let l:c = l:inner[l:i]
    if l:quote !=# ''
      let l:cur .= l:c
      if l:c ==# l:quote | let l:quote = '' | endif
    elseif l:c ==# '"' || l:c ==# "'"
      let l:quote = l:c
      let l:cur .= l:c
    elseif l:c ==# '.'
      call add(l:parts, trim(l:cur))
      let l:cur = ''
    else
      let l:cur .= l:c
    endif
  endfor
  call add(l:parts, trim(l:cur))
  return l:parts
endfunction

" Fold level of a header = 1 + the number of preceding headers whose key path is
" a strict prefix of this one. So `[tasks.build.env]` nests under `[tasks.build]`,
" while sibling top-level sections (`[expressions]`, `[tasks.build]`) stay level 1
" regardless of how many dots they carry.
function! NeotasksTomlFold(lnum) abort
  let l:line = getline(a:lnum)
  if l:line !~# '\v^\s*\['
    " Non-header line: stay in the fold opened by the last header.
    return '='
  endif

  let l:path = s:HeaderPath(l:line)
  let l:plen = len(l:path)
  let l:level = 1
  for l:n in range(1, a:lnum - 1)
    let l:prev = getline(l:n)
    if l:prev !~# '\v^\s*\[' | continue | endif
    let l:q = s:HeaderPath(l:prev)
    let l:qlen = len(l:q)
    if l:qlen < l:plen && join(l:q, "\x01") ==# join(l:path[0 : l:qlen - 1], "\x01")
      let l:level += 1
    endif
  endfor
  return '>' . l:level
endfunction

" Fold title: the task's `name` value. When the fold body has a `name = "..."`
" key, that is the title; otherwise it falls back to the header key path with a
" leading `tasks.` dropped (so `[tasks.build]` reads as `build`,
" `[tasks.build.env]` as `build.env`). The folded line count is appended.
function! NeotasksTomlFoldText() abort
  let l:name = ''
  for l:n in range(v:foldstart + 1, v:foldend)
    if getline(l:n) =~# '\v^\s*\[' | break | endif
    let l:m = matchlist(getline(l:n), '\v^\s*name\s*\=\s*[''"]([^''"]+)[''"]')
    if !empty(l:m) | let l:name = l:m[1] | break | endif
  endfor

  if l:name ==# ''
    let l:path = s:HeaderPath(getline(v:foldstart))
    if len(l:path) > 1 && l:path[0] ==# 'tasks'
      let l:name = join(l:path[1:], '.')
    else
      let l:name = join(l:path, '.')
    endif
  endif

  let l:count = v:foldend - v:foldstart + 1
  return '+' . v:folddashes . ' ' . l:count . ' lines: ' . l:name
endfunction

setlocal foldmethod=expr
setlocal foldexpr=NeotasksTomlFold(v:lnum)
setlocal foldtext=NeotasksTomlFoldText()
setlocal foldlevel=99

let b:undo_ftplugin = 'setlocal foldmethod< foldexpr< foldtext< foldlevel< commentstring< comments<'

let &cpo = s:cpo_save
unlet s:cpo_save

" vim: et sw=2 sts=2
