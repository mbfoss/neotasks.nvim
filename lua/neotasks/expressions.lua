---@class neotasks.ExpressionCtx
---@field task        table                decoded task data (pre-resolution)
---@field expressions table<string,string> named inline expression templates from the [expressions] table
---@field _resolving? table<string,true>   names of inline expressions currently on the resolution stack (cycle guard)
---@field _args?      {n:integer,[integer]:any}[]  stack of positional-argument frames; the top frame backs $1, $2, … inside an inline template

---@alias neotasks.ExpressionFn fun(ctx: neotasks.ExpressionCtx, ...): any, string?

local M             = {}

--- All expressions, built-in and user-registered, keyed by name. Built-ins are
--- defined below via `function _expressions.<name>`; `M.register` adds user ones.
--- One map keeps both lookup (`M.get`) and enumeration (`M.list`) complete.
---@type table<string, neotasks.ExpressionFn>
local _expressions  = {}

--- Set of built-in names, snapshotted once all built-ins are defined. Used to
--- forbid overriding a built-in via `M.register`.
---@type table<string, boolean>
local _builtin      = {}

--- One-line descriptions, keyed by name, surfaced in LSP completion. Built-in
--- descriptions are seeded below; `M.register` may add one via `opts.description`.
---@type table<string, string>
local _descriptions = {}

local _valid_complete_types = {
  arglist = true,
  augroup = true,
  breakpoint = true,
  buffer = true,
  color = true,
  command = true,
  compiler = true,
  diff_buffer = true,
  dir = true,
  dir_in_path = true,
  environment = true,
  event = true,
  expression = true,
  file = true,
  file_in_path = true,
  filetype = true,
  function_ = true,
  help = true,
  highlight = true,
  history = true,
  keymap = true,
  locale = true,
  lua = true,
  mapclear = true,
  mapping = true,
  menu = true,
  messages = true,
  option = true,
  packadd = true,
  retab = true,
  runtime = true,
  scriptnames = true,
  shellcmd = true,
  shellcmdline = true,
  sign = true,
  syntax = true,
  syntime = true,
  tag = true,
  tag_listfiles = true,
  user = true,
  var = true,
  custom = true,
  customlist = true,
}

-- Helpers

local _nofile_err   = "current buffer is not a regular file"
local _badtype_err  = "current file type is not `%s`"

local function _is_file()
    local buf = vim.api.nvim_get_current_buf()
    return vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

local function _check_file(filetype)
    if not _is_file() then return _nofile_err end
    if filetype and filetype ~= vim.bo.filetype then
        return _badtype_err:format(filetype)
    end
end

-- Built-in expressions

--- Emit a literal `{{`, equivalent to writing `{{{{`. Takes no argument, since
--- passing the braces in would reopen a slot. A literal `}}` needs no escape -
--- it is already literal outside a slot.
---@return string
function _expressions.lbrace()
    return "{{"
end

function _expressions.file(_, filetype)
    local err = _check_file(filetype)
    if err then return nil, err end
    return vim.fn.expand("%:p")
end

function _expressions.filename(_, filetype)
    local err = _check_file(filetype)
    if err then return nil, err end
    return vim.fn.expand("%:t")
end

function _expressions.fileroot(_, filetype)
    local err = _check_file(filetype)
    if err then return nil, err end
    return vim.fn.expand("%:p:r")
end

function _expressions.filedir(_)
    local err = _check_file()
    if err then return nil, err end
    return vim.fn.expand("%:p:h")
end

function _expressions.fileext(_)
    local err = _check_file()
    if err then return nil, err end
    local ext = vim.fn.expand("%:e")
    return (ext ~= "" and ext) or nil
end

---@param ctx neotasks.ExpressionCtx
function _expressions.cwd(ctx)
    return (ctx.task and ctx.task.cwd) or vim.fn.resolve(vim.fn.getcwd())
end

function _expressions.projectdir(_, resolve)
    local cwd = vim.fn.getcwd()
    local tasks_file = vim.fs.joinpath(cwd, require("neotasks.config").current.tasks_filename)
    if vim.fn.filereadable(tasks_file) == 0 then
        return nil, "tasks file not found in cwd: " .. cwd
    end
    return vim.fn.resolve(cwd)
end

---@param varname string
function _expressions.env(_, varname)
    if not varname then return nil, "env expression requires a variable name" end
    local val = vim.fn.getenv(varname)
    return (val ~= vim.NIL and val) or nil
end

--- Run a shell command and return its stdout with trailing newlines stripped,
--- like `$(...)`. A non-zero exit status is an error. The command is an ordinary
--- string argument: `{{ shell("printf 'a, b'") }}`.
---@param cmd string  the command
---@return string? output, string? err
function _expressions.shell(_, cmd)
    cmd = cmd or ""
    if cmd == "" then return nil, "shell expression requires a command" end
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
        return nil, ("shell command failed (exit %d): %s"):format(vim.v.shell_error, vim.trim(out))
    end
    return (out:gsub("[\r\n]+$", ""))
end

---@param prompt_text string
---@param default string?
---@param completion string?
function _expressions.prompt(_, prompt_text, default, completion)
    if completion and not _valid_complete_types[completion] then
        error("invalid completion type: " .. tostring(completion))
    end
    if not prompt_text then return nil, "prompt expression requires prompt text" end
    local co = coroutine.running()
    vim.schedule(function()
        vim.cmd("redraw!")
        vim.ui.input({ prompt = prompt_text .. ": ", default = default, completion = completion },
            function(input) coroutine.resume(co, input) end)
    end)
    local result = coroutine.yield()
    if result == nil then return nil, "Prompt cancelled" end
    if completion == "file" or completion == "dir" then
        if vim.fn.isabsolutepath(result) == 0 then
            return vim.fn.resolve(vim.fs.joinpath(vim.fn.getcwd(), result))
        end
    end
    return result
end

-- Everything defined above is a built-in; snapshot the name set so `M.register`
-- can forbid overriding one, and seed their completion descriptions.
for name in pairs(_expressions) do _builtin[name] = true end

_descriptions.lbrace        = "{{lbrace}} is resolved to a literal `{{` \nequivalent to `{{{{`"
_descriptions.file          = "Absolute path of the current file (optionally require a filetype)"
_descriptions.filename      = "Filename (with extension) of the current file"
_descriptions.fileroot      = "Absolute path of the current file without its extension"
_descriptions.filedir       = "Absolute directory of the current file"
_descriptions.fileext       = "Extension of the current file (without the dot)"
_descriptions.cwd           = "The task's working directory, or the editor cwd"
_descriptions.projectdir    = "Absolute path of the project root (where the tasks file lives)"
_descriptions.env           = "Value of an environment variable: env VARNAME"
_descriptions.shell         = "stdout of a shell command, trailing newlines stripped: shell CMD…"
_descriptions.prompt        = "Ask for input at run time: prompt TEXT [default] [completion]"

-- Public API

--- Look up an expression function by name (built-in or user-registered; both
--- live in the same map, and a user one can never shadow a built-in - see
--- `register`).
---@param name string
---@return neotasks.ExpressionFn?
function M.get(name)
    return _expressions[name]
end

--- List every expression (built-in and user-registered) as `{ name, description }`
--- entries, sorted by name, for the tasks-file LSP's completion inside a slot.
--- Inline `[expressions]` live in the document, not this registry, so are absent.
---@return { name: string, description: string? }[]
function M.list()
    local names = vim.tbl_keys(_expressions)
    table.sort(names)
    local out = {} ---@type { name: string, description: string? }[]
    for _, name in ipairs(names) do
        out[#out + 1] = { name = name, description = _descriptions[name] }
    end
    return out
end

--- Register a user expression for use in task config values. Built-in expressions
--- cannot be overridden; attempting to do so raises an error. `opts.description`
--- is shown in LSP completion.
---@param name string
---@param fn   neotasks.ExpressionFn
---@param opts? { desc?: string }
function M.register(name, fn, opts)
    if _builtin[name] then
        error("neotasks: cannot override built-in expression '" .. name .. "'", 2)
    end
    _expressions[name]  = fn
    _descriptions[name] = opts and opts.desc or nil
end

return M
