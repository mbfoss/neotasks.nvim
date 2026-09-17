local _c = {
    bg_dark   = '#26272B',
    bg        = '#2e2f33',
    bg_panel  = '#34353a',
    bg_alt    = '#3a3b40',
    bg_cursor = '#3e3f46',
    bg_line   = '#3a3b41',
    bg_visual = '#3c4a66',
    bg_float  = '#46474f',
    surface   = '#505157',
    line      = '#585963',
    overlay   = '#6e6f77',
    muted     = '#a0a2ad',
    fg_dim    = '#dcdce4',
    subtle    = '#ececf4',
    fg        = '#f2f2f5',
    fg_alt    = '#fafafd',
    bright    = '#f5f6fb',

    red       = '#ecaaaa',
    orange    = '#ecba8a',
    yellow    = '#edd897',
    green     = '#a2d4a2',
    teal      = '#8bcec9',
    sky       = '#97ccdf',
    blue      = '#90b8e3',
    lavender  = '#b9a8e9',
    pink      = '#e4a8ca',

    flame     = '#e47474',
    amber     = '#d8a866',
    lime      = '#b2d87c',
    cyan      = '#6ccdd8',
    indigo    = '#7e97d8',
    mauve     = '#be94c8',

    bg_red    = '#6C4343',
    bg_amber  = '#4B4336',
    bg_green  = '#324637',
    bg_teal   = '#304944',
    bg_blue   = '#333E52',
    bg_purple = '#41384D',
}

vim.g.colors_name = 'pastelstone'
if vim.fn.exists('syntax_on') then vim.cmd('syntax reset') end
vim.o.background    = 'dark'
vim.o.termguicolors = true

local function _hl(group, opts)
    if type(opts) == 'string' then
        vim.api.nvim_set_hl(0, group, { link = opts })
        return
    end
    local val = {}
    if opts.fg  then val.fg = opts.fg end
    if opts.bg  then val.bg = opts.bg end
    if opts.sp  then val.sp = opts.sp end
    if opts.gui then
        for x in opts.gui:gmatch('([^,]+)') do
            if x ~= 'none' then val[x] = true end
        end
    end
    vim.api.nvim_set_hl(0, group, val)
end

-- ── Core ──────────────────────────────────────────────────────────
_hl('Normal',        { fg = _c.fg,      bg = _c.bg })
_hl('NormalNC',      { fg = _c.fg,      bg = _c.bg })
_hl('NormalFloat',   { fg = _c.fg,      bg = _c.bg_float })
_hl('FloatBorder',   { fg = _c.overlay, bg = _c.bg_float })
_hl('FloatTitle',    { fg = _c.blue,    bg = _c.bg_float, gui = 'bold' })

_hl('Bold',          { gui = 'bold' })
_hl('Italic',        { gui = 'italic' })
_hl('Underlined',    { fg = _c.sky,     gui = 'underline' })

-- ── Cursor & selection ────────────────────────────────────────────
_hl('Cursor',        { fg = _c.bg,      bg = _c.fg })
_hl('TermCursor',    { fg = _c.bg,      bg = _c.fg })
_hl('TermCursorNC',  { fg = _c.bg,      bg = _c.muted })
_hl('Visual',        { bg = _c.bg_visual })
_hl('VisualNOS',     { bg = _c.bg_visual })
_hl('MatchParen',    { bg = _c.overlay, gui = 'bold' })
_hl('SnippetTabstop',{ bg = _c.bg_alt,  sp = _c.teal, gui = 'undercurl' })

-- ── Search ────────────────────────────────────────────────────────
_hl('Search',        { fg = _c.bg,      bg = _c.yellow })
_hl('IncSearch',     { fg = _c.bg,      bg = _c.amber,  gui = 'bold' })
_hl('Substitute',    { fg = _c.bg,      bg = _c.orange })
_hl('CurSearch',     { fg = _c.bg,      bg = _c.amber })

-- ── UI chrome ─────────────────────────────────────────────────────
_hl('StatusLine',    { fg = _c.fg_dim,  bg = _c.bg_float, gui = 'none' })
_hl('StatusLineNC',  { fg = _c.muted,   bg = _c.bg_float, gui = 'none' })
_hl('WinBar',        { fg = _c.fg_dim,  bg = _c.bg_float, gui = 'none' })
_hl('WinBarNC',      { fg = _c.muted,   bg = _c.bg_float, gui = 'none' })
_hl('VertSplit',     { fg = _c.line })
_hl('WinSeparator',  { fg = _c.line })
_hl('TabLine',       { fg = _c.muted,   bg = _c.bg_panel, gui = 'none' })
_hl('TabLineFill',   { fg = _c.muted,   bg = _c.bg_panel, gui = 'none' })
_hl('TabLineSel',    { fg = _c.lime,    bg = _c.bg_panel, gui = 'bold' })
_hl('Title',         { fg = _c.blue,    gui = 'bold' })
_hl('Directory',     { fg = _c.cyan })

_hl('ColorColumn',   { bg = _c.bg_cursor })
_hl('CursorColumn',  { bg = _c.bg_cursor })
_hl('CursorLine',    { bg = _c.bg_line })
_hl('CursorLineNr',  { fg = _c.subtle,  bg = _c.bg_line })
_hl('LineNr',        { fg = _c.muted,   bg = _c.bg })
_hl('SignColumn',    { fg = _c.muted,   bg = _c.bg })
_hl('FoldColumn',    { fg = _c.overlay, bg = _c.bg })
_hl('Folded',        { fg = _c.fg_dim,  bg = _c.bg_panel })
_hl('QuickFixLine',  { bg = _c.bg_cursor })
_hl('NonText',       { fg = _c.overlay })
_hl('SpecialKey',    { fg = _c.overlay })
_hl('Conceal',       { fg = _c.overlay })
_hl('Whitespace',    { fg = _c.overlay })

-- ── Popup menu ────────────────────────────────────────────────────
_hl('PMenu',         { fg = _c.fg,      bg = _c.bg_float })
_hl('PMenuSel',      { fg = _c.bg,      bg = _c.blue })
_hl('PMenuSbar',     { bg = _c.bg_alt })
_hl('PMenuThumb',    { bg = _c.overlay })

-- ── Messages ──────────────────────────────────────────────────────
_hl('ModeMsg',       { fg = _c.lime })
_hl('MoreMsg',       { fg = _c.green })
_hl('Question',      { fg = _c.sky })
_hl('WarningMsg',    { fg = _c.amber })
_hl('ErrorMsg',      { fg = _c.red,     bg = _c.bg })
_hl('Error',         { fg = _c.red,     bg = _c.bg })
_hl('Debug',         { fg = _c.flame })
_hl('TooLong',       { fg = _c.red })
_hl('WildMenu',      { fg = _c.bg,      bg = _c.amber })

-- ── Syntax ────────────────────────────────────────────────────────
_hl('Comment',       { fg = _c.muted,   gui = 'italic' })
_hl('String',        { fg = _c.green })
_hl('Character',     { fg = _c.green })
_hl('Number',        { fg = _c.orange })
_hl('Float',         { fg = _c.orange })
_hl('Boolean',       { fg = _c.orange })
_hl('Constant',      { fg = _c.orange })
_hl('Identifier',    { fg = _c.sky,     gui = 'none' })
_hl('Function',      { fg = _c.blue })
_hl('Keyword',       { fg = _c.lavender })
_hl('Conditional',   { fg = _c.lavender })
_hl('Repeat',        { fg = _c.lavender })
_hl('Statement',     { fg = _c.lavender })
_hl('Operator',      { fg = _c.mauve,   gui = 'none' })
_hl('Exception',     { fg = _c.red })
_hl('Macro',         { fg = _c.flame })
_hl('PreProc',       { fg = _c.indigo })
_hl('Include',       { fg = _c.indigo })
_hl('Define',        { fg = _c.lavender, gui = 'none' })
_hl('Type',          { fg = _c.yellow,  gui = 'none' })
_hl('Typedef',       { fg = _c.yellow })
_hl('StorageClass',  { fg = _c.yellow })
_hl('Structure',     { fg = _c.yellow })
_hl('Special',       { fg = _c.teal })
_hl('SpecialChar',   { fg = _c.cyan })
_hl('Tag',           { fg = _c.amber })
_hl('Label',         { fg = _c.yellow })
_hl('Delimiter',     { fg = _c.pink })
_hl('Todo',          { fg = _c.amber, gui = 'bold' })

-- ── Diff ──────────────────────────────────────────────────────────
_hl('DiffAdd',       { bg = _c.bg_green })
_hl('DiffDelete',    { fg = _c.overlay })
_hl('DiffChange',    { bg = _c.bg_amber })
_hl('DiffText',      { bg = _c.bg_teal,  gui = 'bold' })
-- _hl('DiffAdded',     { fg = _c.green,    bg = _c.bg })
-- _hl('DiffRemoved',   { fg = _c.red,      bg = _c.bg })
-- _hl('DiffFile',      { fg = _c.flame,    bg = _c.bg })
-- _hl('DiffNewFile',   { fg = _c.lime,     bg = _c.bg })
-- _hl('DiffLine',      { fg = _c.indigo,   bg = _c.bg })

-- ── Git ───────────────────────────────────────────────────────────
_hl('gitcommitSummary',        { fg = _c.lime })
_hl('gitcommitComment',        { fg = _c.muted })
_hl('gitcommitOverflow',       { fg = _c.red })
_hl('gitcommitUntracked',      { fg = _c.muted })
_hl('gitcommitDiscarded',      { fg = _c.muted })
_hl('gitcommitSelected',       { fg = _c.muted })
_hl('gitcommitHeader',         { fg = _c.lavender })
_hl('gitcommitSelectedType',   { fg = _c.blue })
_hl('gitcommitUnmergedType',   { fg = _c.sky })
_hl('gitcommitDiscardedType',  { fg = _c.sky })
_hl('gitcommitBranch',         { fg = _c.amber,    gui = 'bold' })
_hl('gitcommitUntrackedFile',  { fg = _c.yellow })
_hl('gitcommitUnmergedFile',   { fg = _c.flame,    gui = 'bold' })
_hl('gitcommitDiscardedFile',  { fg = _c.red,      gui = 'bold' })
_hl('gitcommitSelectedFile',   { fg = _c.green,    gui = 'bold' })

-- ── Spell ─────────────────────────────────────────────────────────
_hl('SpellBad',      { gui = 'undercurl', sp = _c.red })
_hl('SpellLocal',    { gui = 'undercurl', sp = _c.cyan })
_hl('SpellCap',      { gui = 'undercurl', sp = _c.blue })
_hl('SpellRare',     { gui = 'undercurl', sp = _c.mauve })

-- ── Diagnostics ───────────────────────────────────────────────────
_hl('DiagnosticError',                { fg = _c.red })
_hl('DiagnosticWarn',                 { fg = _c.amber })
_hl('DiagnosticInfo',                 { fg = _c.sky })
_hl('DiagnosticHint',                 { fg = _c.teal })
_hl('DiagnosticOk',                   { fg = _c.lime })
_hl('DiagnosticUnderlineError',       { gui = 'undercurl', sp = _c.red })
_hl('DiagnosticUnderlineWarning',     { gui = 'undercurl', sp = _c.amber })
_hl('DiagnosticUnderlineWarn',        { gui = 'undercurl', sp = _c.amber })
_hl('DiagnosticUnderlineInformation', { gui = 'undercurl', sp = _c.sky })
_hl('DiagnosticUnderlineHint',        { gui = 'undercurl', sp = _c.teal })
_hl('DiagnosticUnderlineOk',          { gui = 'undercurl', sp = _c.lime })

-- ── LSP ───────────────────────────────────────────────────────────
_hl('LspReferenceText',            { gui = 'underline', sp = _c.subtle })
_hl('LspReferenceRead',            { gui = 'underline', sp = _c.subtle })
_hl('LspReferenceWrite',           { gui = 'underline', sp = _c.amber })
_hl('LspInlayHint',                { fg = _c.muted,     gui = 'italic' })
_hl('LspSignatureActiveParameter', { fg = _c.lavender,  gui = 'bold' })

-- ── Treesitter ────────────────────────────────────────────────────
_hl('@variable',              { fg = _c.fg })
_hl('@variable.builtin',      { fg = _c.cyan,     gui = 'italic' })
_hl('@variable.parameter',    { fg = _c.fg })
_hl('@variable.member',       { fg = _c.sky })

_hl('@string',                { fg = _c.green })
_hl('@string.escape',         { fg = _c.cyan })
_hl('@string.regex',          { fg = _c.teal })
_hl('@string.special',        { fg = _c.cyan })

_hl('@number',                { fg = _c.orange })
_hl('@number.float',          { fg = _c.orange })
_hl('@boolean',               { fg = _c.orange })

_hl('@constant',              { fg = _c.orange })
_hl('@constant.builtin',      { fg = _c.cyan,     gui = 'italic' })
_hl('@constant.macro',        { fg = _c.flame })

_hl('@function',              { fg = _c.blue })
_hl('@function.builtin',      { fg = _c.cyan,     gui = 'italic' })
_hl('@function.macro',        { fg = _c.flame })
_hl('@function.method',       { fg = _c.sky })
_hl('@function.call',         { fg = _c.blue })
_hl('@function.method.call',  { fg = _c.sky })

_hl('@constructor',           { fg = _c.lime })

_hl('@keyword',               { fg = _c.lavender })
_hl('@keyword.function',      { fg = _c.lavender })
_hl('@keyword.operator',      { fg = _c.mauve })
_hl('@keyword.return',        { fg = _c.lavender })
_hl('@keyword.import',        { fg = _c.indigo })
_hl('@keyword.conditional',   { fg = _c.lavender })
_hl('@keyword.repeat',        { fg = _c.lavender })
_hl('@keyword.exception',     { fg = _c.red })

_hl('@type',                  { fg = _c.yellow })
_hl('@type.builtin',          { fg = _c.indigo,   gui = 'italic' })
_hl('@type.definition',       { fg = _c.yellow })

_hl('@attribute',             { fg = _c.amber })
_hl('@annotation',            { fg = _c.mauve })

_hl('@namespace',             { fg = _c.indigo })
_hl('@module',                { fg = _c.indigo })
_hl('@module.builtin',        { fg = _c.indigo,   gui = 'italic' })

_hl('@operator',              { fg = _c.mauve })
_hl('@punctuation.delimiter', { fg = _c.pink })
_hl('@punctuation.bracket',   { fg = _c.subtle })
_hl('@punctuation.special',   { fg = _c.mauve })

_hl('@comment',               { fg = _c.muted,    gui = 'italic' })
_hl('@comment.documentation', { fg = _c.subtle,   gui = 'italic' })
_hl('@comment.error',         { fg = _c.red,      gui = 'bold' })
_hl('@comment.warning',       { fg = _c.amber,    gui = 'bold' })
_hl('@comment.todo',          { fg = _c.amber,    gui = 'bold' })
_hl('@comment.note',          { fg = _c.sky,      gui = 'bold' })

_hl('@tag',                   { fg = _c.amber })
_hl('@tag.delimiter',         { fg = _c.pink })
_hl('@tag.attribute',         { fg = _c.sky })

_hl('@property',              { fg = _c.sky })

_hl('@text.strong',           { gui = 'bold' })
_hl('@text.emphasis',         { fg = _c.mauve,    gui = 'italic' })
_hl('@text.underline',        { gui = 'underline' })
_hl('@text.strike',           { gui = 'strikethrough' })
_hl('@text.title',            { fg = _c.blue,     gui = 'bold' })
_hl('@text.literal',          { fg = _c.teal })
_hl('@text.uri',              { fg = _c.sky,      gui = 'underline' })
_hl('@text.reference',        { fg = _c.lavender })
_hl('@text.todo',             { fg = _c.amber,    bg = _c.bg_alt, gui = 'bold' })
_hl('@text.warning',          { fg = _c.amber })
_hl('@text.danger',           { fg = _c.red })
_hl('@text.note',             { fg = _c.sky })

_hl('@markup.strong',         { gui = 'bold' })
_hl('@markup.italic',         { gui = 'italic' })
_hl('@markup.underline',      { gui = 'underline' })
_hl('@markup.strikethrough',  { gui = 'strikethrough' })
_hl('@markup.heading',        { fg = _c.blue,     gui = 'bold' })
_hl('@markup.heading.1',      { fg = _c.blue,     gui = 'bold' })
_hl('@markup.heading.2',      { fg = _c.indigo,   gui = 'bold' })
_hl('@markup.heading.3',      { fg = _c.lavender, gui = 'bold' })
_hl('@markup.heading.4',      { fg = _c.sky,      gui = 'bold' })
_hl('@markup.raw',            { fg = _c.teal })
_hl('@markup.raw.block',      { fg = _c.teal })
_hl('@markup.link',           { fg = _c.sky,      gui = 'underline' })
_hl('@markup.link.label',     { fg = _c.lavender })
_hl('@markup.link.url',       { fg = _c.sky,      gui = 'underline' })
_hl('@markup.list',           { fg = _c.pink })
_hl('@markup.list.checked',   { fg = _c.lime })
_hl('@markup.list.unchecked', { fg = _c.subtle })
_hl('@markup.quote',          { fg = _c.muted,    gui = 'italic' })
_hl('@markup.math',           { fg = _c.cyan })

_hl('NvimInternalError',      { fg = _c.bg, bg = _c.flame })

-- ── Terminal colors ───────────────────────────────────────────────
vim.g.terminal_color_0  = _c.bg
vim.g.terminal_color_1  = _c.red
vim.g.terminal_color_2  = _c.green
vim.g.terminal_color_3  = _c.yellow
vim.g.terminal_color_4  = _c.blue
vim.g.terminal_color_5  = _c.lavender
vim.g.terminal_color_6  = _c.teal
vim.g.terminal_color_7  = _c.fg
vim.g.terminal_color_8  = _c.muted
vim.g.terminal_color_9  = _c.flame
vim.g.terminal_color_10 = _c.lime
vim.g.terminal_color_11 = _c.amber
vim.g.terminal_color_12 = _c.indigo
vim.g.terminal_color_13 = _c.mauve
vim.g.terminal_color_14 = _c.cyan
vim.g.terminal_color_15 = _c.bright



