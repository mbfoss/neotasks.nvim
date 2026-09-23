---@brief Health check for neotasks.nvim - run with `:checkhealth neotasks`.
---
---Reports the Neovim version and the optional companion plugins, whether
---`setup()` has run, the options that differ from the defaults, the tasks file
---found for the cwd, and the registered task types (with the ezdap adapters the
---`debug` type may use).

local M = {}

local health = vim.health

---The plugin module, read through `package.loaded` rather than required: an
---unloaded neotasks is itself the answer, and loading it here would not have
---run `setup()` anyway.
---@return table?
local function _plugin()
    return package.loaded["neotasks"]
end

---@return boolean
local function _is_setup()
    local plugin = _plugin()
    return (plugin and plugin.is_setup()) or false
end

---Check the Neovim version against the plugin's minimum (see
---`plugin/neotasks.lua`) and report the optional companion plugins.
local function _check_requirements()
    health.start("neotasks: dependencies")

    if vim.fn.has("nvim-0.11") ~= 1 then
        health.error("neotasks.nvim requires Neovim >= 0.11")
    end

    -- Both are optional. ezdap names its adapters without a setup(), but a
    -- `debug` task cannot start before one.
    if not pcall(require, "ezdap.schema") then
        health.info("ezdap.nvim is not installed, so there is no `debug` task type")
    elseif require("ezdap").is_setup() then
        health.ok("ezdap.nvim is installed and set up (the `debug` task type is available)")
    else
        health.warn("ezdap.nvim is installed but require('ezdap').setup() has not been called", {
            "Call require('ezdap').setup() from your config; until then no `debug` task can start",
        })
    end

    if pcall(require, "dock") then
        health.ok("dock.nvim is installed (task output goes to the dock panel)")
    else
        health.info("dock.nvim is not installed, so task output goes to a bottom split")
    end
end

---Report whether `setup()` has run and what it wired up: the user command and
---the tasks-file LSP both hang off it.
local function _check_setup()
    health.start("neotasks: setup")

    if _is_setup() then
        health.ok("setup() has been called")
    else
        health.error("setup() has not been called", {
            "Call require('neotasks').setup() -- the command and LSP are registered by it",
        })
        return
    end

    if vim.fn.exists(":Neotasks") == 2 then
        health.ok(":Neotasks is registered")
    else
        health.error(":Neotasks is not registered")
    end

    local server = require("neotasks.lsp").SERVER_NAME
    local ok, declared = pcall(function() return vim.lsp.config[server] end)
    if ok and declared then
        health.ok(("the `%s` language server is declared for the `neotasks` filetype")
            :format(server))
    else
        health.warn(("the `%s` language server is not declared"):format(server), {
            "It is declared by setup()",
        })
    end
end

---Collect the options whose value differs from the default, as flat paths with
---the value now in force. Lists are compared whole rather than descended into:
---`debug_adapters` is one option, not one option per adapter.
---@param current table
---@param defaults table
---@param prefix string  path of the enclosing table, "" at the top level
---@param out table[]
---@return table[]
local function _diff_config(current, defaults, prefix, out)
    for key, value in pairs(current) do
        local path = prefix .. tostring(key)
        local default = defaults[key]
        if type(value) == "table" and type(default) == "table" and not vim.islist(value) then
            _diff_config(value, default, path .. ".", out)
        elseif not vim.deep_equal(value, default) then
            table.insert(out, {
                path    = path,
                value   = vim.inspect(value),
                unknown = default == nil,
            })
        end
    end
    return out
end

---Report the options that differ from the defaults - the whole config would be
---mostly untouched defaults, and the point here is what this user changed.
---Anything set that the plugin does not define is flagged: `setup()` merges
---`opts` wholesale, so a misspelled option is kept silently.
local function _check_config()
    health.start("neotasks: configuration")

    local plugin = _plugin()
    if not (plugin and plugin.is_setup()) then
        health.info("setup() has not been called")
        return
    end

    local diffs = _diff_config(require("neotasks.config").current, plugin.get_default_config(), "", {})
    table.sort(diffs, function(a, b) return a.path < b.path end)

    if #diffs == 0 then
        health.ok("every option is at its default")
        return
    end

    local lines = {}
    for _, entry in ipairs(diffs) do
        table.insert(lines, ("  %s = %s"):format(entry.path, entry.value))
    end
    health.ok(("%d option%s differ from the defaults:\n%s")
        :format(#diffs, #diffs == 1 and "" or "s", table.concat(lines, "\n")))

    for _, entry in ipairs(diffs) do
        if entry.unknown then
            health.warn(("`%s` is not an option neotasks defines"):format(entry.path), {
                "Check its spelling against :help neotasks-config",
            })
        end
    end
end

---Report the quickfix matchers: the roster a task's `quickfix_matcher` may
---name, then the ones this project's tasks actually require - an unknown name
---there is what stops the task from starting.
local function _check_qfmatchers()
    health.start("neotasks: quickfix matchers")

    local qfmatchers = require("neotasks.types.qfmatchers")
    local names      = qfmatchers.names()

    local builtin, user = {}, {}
    for _, name in ipairs(names) do
        local bucket = qfmatchers.is_user(name) and user or builtin
        bucket[#bucket + 1] = name
    end

    health.ok(("%d built-in: %s"):format(#builtin, table.concat(builtin, ", ")))
    if #user > 0 then
        health.ok(("%d registered by you: %s"):format(#user, table.concat(user, ", ")))
    else
        health.info("no matcher registered via API")
    end
end

---Report the ezdap adapters the `debug` type may use - `debug_adapters`
---resolved against ezdap's registry, since only those get a definition loaded
---and a task on any other adapter refuses to start.
local function _check_debug_adapters()
    local wanted = require("neotasks.config").current.debug_adapters or {}
    if #wanted == 0 then
        health.warn("`debug_adapters` is empty, so only the built-in `remote` adapter is available", {
            "List the adapters you use, e.g. debug_adapters = { 'codelldb' }",
            "See the names available with :lua =require('ezdap').available_adapters()",
        })
        return
    end

    local ok, usable = pcall(require("neotasks.types.debug").adapters)
    if not ok then
        health.warn(("`debug_adapters` cannot be resolved: %s"):format(tostring(usable)), {
            "Run :checkhealth ezdap",
        })
        return
    end
    health.ok(("`debug_adapters`: %s"):format(table.concat(usable, ", ")))

    for _, name in ipairs(wanted) do
        if not vim.tbl_contains(usable, name) then
            health.error(("`%s` is not a registered ezdap adapter"):format(name), {
                "See the names available with :lua =require('ezdap').available_adapters()",
            })
        end
    end
end

---List the registered task types, and for `debug` the adapters behind it.
local function _check_types()
    health.start("neotasks: task types")

    local names = require("neotasks.types").get_names()
    table.sort(names)
    health.ok(("%d registered: %s"):format(#names, table.concat(names, ", ")))

    if vim.tbl_contains(names, "debug") then
        _check_debug_adapters()
    end
end

function M.check()
    _check_requirements()
    _check_setup()
    _check_config()
    _check_types()
    _check_qfmatchers()
end

return M
