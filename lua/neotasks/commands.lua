local config       = require("neotasks.config").current
local runner       = require("neotasks.runner")
local task_types   = require("neotasks.types")
local runview      = require("neotasks.ui.runview")
local ui           = require("neotasks.ui")
local select       = require("neotasks.util.select").select
local toml         = require("neotasks.tomltools")
local project       = require("neotasks.project")

local M            = {}

---@type { name: string, path: string }?
local _last_task   = nil

--- Run a task. With no name, prompts with the project's task list.
---@param args string[]
local function _run_command(args)
    if #args > 1 then
        ui.notify_error("run takes at most one task name")
        return
    end
    local wanted = args[1]
    local cwd, err = project.find_root()
    if not cwd then
        ui.notify_error(err or "not in a project root")
        return
    end

    local path = vim.fs.normalize(vim.fs.joinpath(cwd, config.tasks_filename))
    local names, by_name, list_err = runner.list_tasks(path)
    if not names then
        ui.notify_error(list_err or "failed to load tasks")
        return
    end

    if wanted then
        if not (by_name and by_name[wanted]) then
            ui.notify_error("no such task: " .. wanted)
            return
        end
        _last_task = { name = wanted, path = path }
        runner.run(wanted, path)
        return
    end

    local items = vim.tbl_map(function(name)
        local task    = by_name and by_name[name]
        local content = task and toml.encode_entry(task, {style = "table", key = "task"}) or nil
        return { name = name, preview = content and { content = content, filetype = "neotasks" } or nil }
    end, names)

    select(items, {
        prompt      = "Run task:",
        format_item = function(item) return item.name end,
    }, function(choice)
        if not choice then return end
        _last_task = { name = choice.name, path = path }
        runner.run(choice.name, path)
    end)
end

--- Prompt for (or take, from the command arguments) an expression template and
--- print its resolved value. Runs against the current project's tasks file so
--- inline `[expressions]` are available alongside the built-ins.
---@param args string[]
local function _eval_command(args)
    local cwd, err = project.find_root()
    if not cwd then
        ui.notify_error(err or "not in a project root")
        return
    end
    local path = vim.fs.normalize(vim.fs.joinpath(cwd, config.tasks_filename))

    local function run(expr)
        if not expr or expr == "" then return end
        local label = expr
        -- A bare expression (no `{{ … }}` slot) is treated as an expression name
        -- and wrapped, so `:Neotasks eval file` resolves the `file` expression.
        if not expr:find("{{", 1, true) then
            expr = "{{ " .. expr .. " }}"
        end
        runner.eval_expression(expr, path, function(ok, result, eval_err)
            if not ok then
                ui.notify_error(eval_err or "expression evaluation failed")
                return
            end
            local text = type(result) == "string" and result or vim.inspect(result)
            vim.api.nvim_echo({ { label .. ": ", "Title" }, { text } }, true, {})
        end)
    end

    if #args > 0 then
        run(table.concat(args, " "))
    else
        vim.ui.input({ prompt = "Evaluate expression: " }, run)
    end
end

local function _restart_command()
    if not _last_task then
        ui.notify_warning("no task has been run yet")
        return
    end
    local cwd, err = project.find_root()
    if not cwd then
        ui.notify_error(err or "not in a project root")
        return
    end
    local path = vim.fs.normalize(vim.fs.joinpath(cwd, config.tasks_filename))
    if path ~= _last_task.path then
        ui.notify_warning("project changed since last run")
        return
    end
    runner.run(_last_task.name, _last_task.path)
end

local function _stop_command()
    local all = require("neotasks.runner.exec").get_all()
    local names, seen = {}, {}
    for _, entry in pairs(all) do
        if (entry.state == "running" or entry.state == "waiting")
            and not seen[entry.task_name]
        then
            seen[entry.task_name] = true
            table.insert(names, entry.task_name)
        end
    end
    table.sort(names)
    if #names == 0 then
        ui.notify_warning("no running tasks")
        return
    end
    vim.ui.select(names, { prompt = "Stop task:" }, function(choice)
        if not choice then return end
        runner.stop(choice)
    end)
end

local function _stop_all_command()
    local all = require("neotasks.runner.exec").get_all()
    local seen = {}
    for _, entry in pairs(all) do
        if (entry.state == "running" or entry.state == "waiting")
            and not seen[entry.task_name]
        then
            seen[entry.task_name] = true
            runner.stop(entry.task_name)
        end
    end
    if not next(seen) then
        ui.notify_warning("no running tasks")
    end
end

--- Dispose finished runs: `all` (the default) disposes every one, `one`
--- prompts for a single run.
---@param args string[]
local function _clean_command(args)
    local mode = args[1] or "all"
    if #args > 1 or (mode ~= "all" and mode ~= "one") then
        ui.notify_error("clean takes an optional argument: all|one")
        return
    end
    local entries = runner.disposable()
    if mode == "all" then
        for _, e in ipairs(entries) do
            runner.dispose(e.run_id)
        end
        return
    end
    if #entries == 0 then
        ui.notify_warning("no finished tasks to dispose")
        return
    end
    local labels = vim.tbl_map(function(e) return e.label end, entries)
    vim.ui.select(labels, { prompt = "Dispose task:" }, function(choice)
        if not choice then return end
        for _, e in ipairs(entries) do
            if e.label == choice then
                local ok, err = runner.dispose(e.run_id)
                if not ok then ui.notify_error(err or "dispose failed") end
                return
            end
        end
    end)
end

---@param args string[]
local function _lsp_dump_command(args)
    if not config.lsp_debug_commands then
        ui.notify_warning("lsp_debug_commands is not enabled")
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    local what = args[1] or "data"
    require("neotasks.lsp").dump(buf, what)
end

local function _add_template_command()
    local bufnr = vim.api.nvim_get_current_buf()
    local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
    if fname ~= config.tasks_filename then
        ui.notify_warning("not in the tasks file (" .. config.tasks_filename .. ")")
        return
    end

    local all_types  = task_types.get_all()
    local type_names = {}
    for name, def in pairs(all_types) do
        if def.templates then type_names[#type_names + 1] = name end
    end
    table.sort(type_names)

    if #type_names == 0 then
        ui.notify_warning("no task types with templates defined")
        return
    end

    local async = require("neotasks.util.async")

    -- Insert the chosen template as a new `[tasks.<name>]` section. The template's
    -- own name becomes the header key (tasks are keyed by name), and the block is
    -- put on its own line(s) at the cursor, blank-separated from any preceding text.
    -- Nested tables stay inline so the whole template is one contiguous block.
    local function apply(tmpl)
        local task  = vim.deepcopy(tmpl.task)
        local name  = (type(task.name) == "string" and task.name ~= "") and task.name or "task"
        task.name   = nil
        local block = toml.encode_entry(task, {
            style            = "table",
            key              = { "tasks", name },
            inline_subtables = true,
        })
        if vim.api.nvim_get_current_line() ~= "" then table.insert(block, 1, "") end
        vim.api.nvim_put(block, "l", true, true)
    end

    local function show_templateselect(type_name)
        local type_def = all_types[type_name]
        local function doselect(templates)
            if not templates or #templates == 0 then
                ui.notify_warning("no templates for type: " .. type_name)
                return
            end
            if #templates == 1 then
                vim.schedule(function() apply(templates[1]) end)
                return
            end
            vim.ui.select(templates, {
                prompt      = "Choose " .. type_name .. " template:",
                format_item = function(item) return item.label end,
            }, function(choice)
                if choice then vim.schedule(function() apply(choice) end) end
            end)
        end
        if type(type_def.templates) == "function" then
            local fn = type_def.templates ---@cast fn function
            async.go(fn, function(ok, result)
                if ok then doselect(result --[[@as neotasks.TaskTemplate[] ]]) end
            end)
        else
            doselect(type_def.templates --[[@as neotasks.TaskTemplate[] ]])
        end
    end

    if #type_names == 1 then
        show_templateselect(type_names[1])
    else
        vim.ui.select(type_names, { prompt = "Task type:" }, function(choice)
            if choice then show_templateselect(choice) end
        end)
    end
end

--- Dispatch a `:Neotasks …` invocation. Called through `util.usercmd.handle`, which
--- has already split the arguments and will report any error raised here.
---@param _cmd     string
---@param args     string[]
---@param _opts    vim.api.keyset.create_user_command.command_args
function M.run(_cmd, args, _opts)
    -- Subscribing here, not on first open, is what gives every run its log
    -- buffer from its first report onward — even when nothing is on screen yet.
    runview.setup()

    local action = args[1]
    table.remove(args, 1)
    if action == nil or action == "" or action == "run" then
        _run_command(args)
    elseif action == "clean" then
        _clean_command(args)
    elseif action == "rerun" then
        _restart_command()
    elseif action == "eval" then
        _eval_command(args)
    elseif action == "stop" then
        _stop_command()
    elseif action == "cancel" then
        _stop_all_command()
    elseif action == "template" then
        _add_template_command()
    elseif action == "lsp_dump" then
        _lsp_dump_command(args)
    elseif action == "panel" then
        runview.toggle()
    else
        ui.notify_warning("Invalid action: " .. tostring(action))
    end
end

--- Completion candidates for `:Neotasks …`. `rest` holds the arguments completed
--- so far, excluding the one being typed; `util.usercmd.complete` filters the
--- returned list by `_arg_lead`.
---@param _cmd      string
---@param rest      string[]
---@param _arg_lead string
---@return string[]
function M.complete(_cmd, rest, _arg_lead)
    if #rest == 0 then
        local actions = { "run", "clean", "rerun", "eval", "stop", "cancel", "template", "panel" }
        if config.lsp_debug_commands then
            table.insert(actions, "lsp_dump")
        end
        return actions
    end
    if rest[1] == "run" and #rest == 1 then
        local cwd = project.find_root()
        if not cwd then return {} end
        local path = vim.fs.normalize(vim.fs.joinpath(cwd, config.tasks_filename))
        return runner.list_tasks(path) or {}
    end
    if rest[1] == "eval" and #rest == 1 then
        local cwd = project.find_root()
        if not cwd then return {} end
        local path = vim.fs.normalize(vim.fs.joinpath(cwd, config.tasks_filename))
        return runner.list_expression_names(path)
    end
    if rest[1] == "clean" and #rest == 1 then
        return { "all", "one" }
    end
    if rest[1] == "lsp_dump" and #rest == 1 then
        return { "cst", "decode_tree", "data", "schema" }
    end
    return {}
end

return M
