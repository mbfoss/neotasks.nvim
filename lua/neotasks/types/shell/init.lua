local ordered    = require("neotasks.util.table_util").ordered
local term       = require("neotasks.util.term")
local notify     = require("neotasks.ui")
local qfmatchers = require("neotasks.types.qfmatchers")

---@param s string
---@return string
local function _strip_ansi(s)
    return (s:gsub("\27%[[%d;]*[A-Za-z]", ""))
end

---@param name string?
---@return (fun(line: string): neotasks.QfItem?)?, string?
local function _make_qf_parser(name)
    if not name or name == "" then return nil end
    local fn = qfmatchers.get(name)
    if not fn then return nil, "unknown quickfix matcher: " .. name end
    local ctx = {}
    return function(line) return fn(_strip_ansi(line), ctx) end
end

--- Human-readable dump of the arguments handed to `term.spawn`, so the run log
--- shows exactly what was executed. Callback options are omitted.
---@param cmd  string
---@param opts neotasks.util.SpawnOpts
---@return string
local function _spawn_summary(cmd, opts)
    local lines = {
        "term.spawn:",
        "  cmd: " .. cmd,
        "  bufname: " .. tostring(opts.bufname),
        "  cwd: " .. (opts.cwd or "(inherited)"),
        "  clear_env: " .. tostring(opts.clear_env or false),
    }
    if opts.env and next(opts.env) then
        local keys = vim.tbl_keys(opts.env)
        table.sort(keys)
        lines[#lines + 1] = "  env:"
        for _, key in ipairs(keys) do
            lines[#lines + 1] = "    " .. key .. "=" .. tostring(opts.env[key])
        end
    end
    return table.concat(lines, "\n")
end

---@class neotasks.ShellTask : neotasks.TaskBase
---@field command?          string                command line evaluated by the shell (pipes, globs, redirection, `&&`)
---@field cwd?              string                working directory used when executing the command
---@field env?              table<string,string>  environment variables as a key-value map
---@field clear_env?        boolean               pass `env` verbatim without merging the current environment
---@field quickfix_matcher? string                name of a quickfix matcher used to parse output

--- The `shell` task type: runs a command string through the shell, so shell
--- syntax (pipes, globs, redirection, `&&`, …) is interpreted.
---@type neotasks.TaskTypeDef
local M = {
    ---@type neotasks.RunFn
    start = function(task, ctx, on_done)
        ---@cast task neotasks.ShellTask
        local command = task.command
        if type(command) ~= "string" then
            notify.notify_error("shell task '" .. ctx.name .. "': command must be a string")
            on_done(false)
            return function() end
        end

        local qf_parse, qf_err = _make_qf_parser(task.quickfix_matcher)
        if qf_err then
            notify.notify_error(qf_err)
            on_done(false)
            return function() end
        end

        if qf_parse then
            vim.fn.setqflist({}, "r")
        end

        -- A string command is evaluated by the shell (vim.fn.jobstart semantics).
        local cmd = command

        -- A readable buffer name in place of the opaque `term://…`; run_id is
        -- unique per instance (`<name>#<counter>`), and `:term` matches how the
        -- run's other buffers are named.
        local bufname = "neotasks://" .. ctx.run_id .. ":term"

        local on_data
        if qf_parse then
            on_data = function(_, data)
                vim.schedule(function()
                    if not data then return end
                    local items = {}
                    for _, line in ipairs(data) do
                        if line ~= "" then
                            local qf_item = qf_parse(line)
                            if qf_item then items[#items + 1] = qf_item end
                        end
                    end
                    if #items > 0 then vim.fn.setqflist(items, "a") end
                end)
            end
        end

        ---@type neotasks.util.SpawnOpts
        local spawn_opts = {
            bufname   = bufname,
            cwd       = task.cwd,
            env       = task.env,
            clear_env = task.clear_env,
            on_stdout = on_data,
            on_stderr = on_data,
            on_exit   = function(code) on_done(code == 0) end,
        }
        ctx.report(_spawn_summary(cmd, spawn_opts))

        local handle, spawn_err = term.spawn(cmd, spawn_opts)

        if not handle then
            vim.schedule(function()
                ctx.report("job start failed: " .. tostring(spawn_err))
                on_done(false)
            end)
            return function() end
        end
        ctx.add_bufnr(handle.bufnr, { label = "term" })
        return function() handle.stop() end
    end,

    schema = {
        description = "Definition of a `shell` task",
        ["x-order"] = { "name", "type", "if_running", "depends_on", "depends_order", "save_buffers", "command", "cwd", "env", "clear_env", "quickfix_matcher" },
        required    = { "command" },
        properties  = {
            command          = {
                type        = "string",
                minLength   = 1,
                description = "Command line evaluated by the shell; pipes, globs, redirection and `&&` all work.",
            },
            cwd              = { type = { "string", "null" }, description = "Working directory used when executing the command" },
            env              = {
                type                 = { "object", "null" },
                description          = "Environment variables as a key-value map",
                additionalProperties = { type = "string" },
            },
            clear_env        = {
                type        = { "boolean", "null" },
                description = "Pass `env` verbatim without merging with the current process environment",
            },
            quickfix_matcher = {
                type        = { "string", "null" },
                description = "Name of a quickfix matcher used to parse command output into quickfix entries",
                enum        = qfmatchers.names,
            },
        },
    },

    templates = {
        {
            label = "Shell command",
            task  = ordered({ name = "command", type = "shell", command = "" },
                { "name", "type", "command" }),
        },
    },
}

return M
