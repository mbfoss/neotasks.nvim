---@diagnostic disable: undefined-global, undefined-field, need-check-nil
-- Unit tests for the task execution engine (lua/neotasks/runner/exec.lua):
-- TOML loading + validation, dependency ordering, `if_running` policies,
-- stop/cascade, dispose, list/state queries, and the observer
-- signals. Tests drive `exec` through purpose-built, controllable task types and
-- poll for terminal states (every run settles asynchronously via the scheduler).

local exec       = require("neotasks.runner.exec")
local task_types = require("neotasks.types")
local ui         = require("neotasks.ui")

local tasks_filename = require("neotasks.config").tasks_filename

-- The built-in `debug` type projects its schema from the companion `ezdap` plugin,
-- absent from the isolated test env. Every run rebuilds the full schema, so
-- override `debug` with a schemaless stub (no debug tasks are exercised here).
task_types.register("debug", {
    start = function(_, _, done) done(true); return function() end end,
})

-- controllable task types
-- Shared, test-mutable state the custom types report into. Reset in before_each.
local run_order = {}          -- names, in the order t_order tasks start
local manual    = {}          -- manual.done := the current t_manual run's on_done
local disposed  = { flag = false }

-- Completes ok / failed immediately.
task_types.register("t_ok", {
    start = function(_, _, done) done(true); return function() end end,
})
task_types.register("t_fail", {
    start = function(_, _, done) done(false); return function() end end,
})
-- Never finishes on its own; cancelling completes it as failed on the next tick,
-- the way a real long-running process settles when terminated (jobstop → on_exit
-- fires asynchronously, so a run's done signal never emits inside stop() itself).
task_types.register("t_block", {
    start = function(_, _, done)
        return function() vim.schedule(function() done(false) end) end
    end,
})
-- Records its start order, then succeeds.
task_types.register("t_order", {
    start = function(_, ctx, done)
        table.insert(run_order, ctx.name)
        done(true)
        return function() end
    end,
})
-- Completion is driven by the test via `manual.done`.
task_types.register("t_manual", {
    start = function(_, _, done)
        manual.done = done
        return function() done(false) end
    end,
})
-- Has a dispose hook (flips `disposed.flag`) so dispose behaviour is observable.
task_types.register("t_disposable", {
    start   = function(_, _, done) done(true); return function() end end,
    dispose = function() disposed.flag = true end,
})
-- Has a string field so an expression can be planted and made to fail.
task_types.register("t_expr", {
    schema = { properties = { cmd = { type = "string" } } },
    start  = function(_, _, done) done(true); return function() end end,
})

-- helpers

--- Write task TOML to a fresh temp file and return its absolute path. Tasks are a
--- name-keyed map, but for brevity the specs still write `[[tasks]]` followed by
--- `name="X"`; this rewrites each such pair into a `[tasks.X]` header.
---@param lines string[]
---@return string path
local function write_tasks(lines)
    local out = {}
    local i   = 1
    while i <= #lines do
        local nm = lines[i] == "[[tasks]]"
            and lines[i + 1] and lines[i + 1]:match('^%s*name%s*=%s*"([^"]*)"')
        if nm then
            out[#out + 1] = ("[tasks.%s]"):format(nm)
            i = i + 2 -- skip the [[tasks]] header and the name line
        else
            out[#out + 1] = lines[i]
            i = i + 1
        end
    end

    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local path = vim.fs.joinpath(root, tasks_filename)
    vim.fn.writefile(out, path)
    return path
end

--- All live run entries for a task name.
---@param name string
---@return neotasks.RunEntry[]
local function entries_for(name)
    local out = {}
    for _, e in pairs(exec.get_all()) do
        if e.task_name == name then out[#out + 1] = e end
    end
    return out
end

--- The (first) live entry for a task name, or nil.
---@param name string
---@return neotasks.RunEntry?
local function entry_for(name)
    return entries_for(name)[1]
end

--- The run id of the (first) live entry for a task name, or nil.
---@param name string
---@return string?
local function id_for(name)
    for id, e in pairs(exec.get_all()) do
        if e.task_name == name then return id end
    end
end

--- Poll until `pred` is true, asserting it became true within the timeout.
---@param pred fun(): boolean
---@param msg? string
local function wait_until(pred, msg)
    assert.is_true(vim.wait(2000, pred, 10), msg or "condition not met in time")
end

--- Wait for a task's single run to reach `want` and return the entry.
---@param name string
---@param want neotasks.TaskState
---@return neotasks.RunEntry
local function wait_state(name, want)
    wait_until(function()
        local e = entry_for(name)
        return e ~= nil and e.state == want
    end, ("task %q never reached state %q"):format(name, want))
    return entry_for(name)
end

--- Wait until the current t_manual run has started (its on_done is captured),
--- then return that completion callback.
---@return fun(ok: boolean)
local function wait_manual()
    wait_until(function() return manual.done ~= nil end, "manual task never started")
    return manual.done
end

--- Does any of an entry's reports contain `needle` (plain substring)?
---@param entry neotasks.RunEntry
---@param needle string
---@return boolean
local function has_report(entry, needle)
    for _, ev in ipairs(entry.reports) do
        if ev.message:find(needle, 1, true) then return true end
    end
    return false
end

-- suite

describe("runner exec", function()
    local prev_notify, prev_warn, warnings

    before_each(function()
        -- Silence and capture user-facing notifications.
        warnings          = {}
        prev_notify       = vim.notify
        vim.notify        = function() end
        prev_warn         = ui.notify_warning
        ui.notify_warning = function(msg) table.insert(warnings, msg) end

        -- Reset shared type state.
        for k in pairs(run_order) do run_order[k] = nil end
        manual.done   = nil
        disposed.flag = false
    end)

    after_each(function()
        vim.notify        = prev_notify
        ui.notify_warning = prev_warn

        -- Settle any lingering active runs so they don't outlive the test.
        for _, e in pairs(exec.get_all()) do
            if e.state == "running" or e.state == "waiting" then exec.stop(e.task_name) end
        end
        vim.wait(1000, function()
            for _, e in pairs(exec.get_all()) do
                if e.state == "running" or e.state == "waiting" then return false end
            end
            return true
        end)
    end)

    describe("basic runs", function()
        it("runs a task to success", function()
            local path = write_tasks({ "[[tasks]]", 'name="ok"', 'type="t_ok"' })
            exec.run("ok", path)
            local e = wait_state("ok", "ok")
            assert.is_true(has_report(e, "started"))
        end)

        it("marks a task failed when its command fails", function()
            local path = write_tasks({ "[[tasks]]", 'name="bad"', 'type="t_fail"' })
            exec.run("bad", path)
            wait_state("bad", "failed")
        end)

        it("marks a task failed on an expression error", function()
            local path = write_tasks({
                "[[tasks]]", 'name="e"', 'type="t_expr"', 'cmd="{{ nope }}"',
            })
            exec.run("e", path)
            local e = wait_state("e", "failed")
            assert.is_true(has_report(e, "expression error"))
        end)
    end)

    describe("load / validation errors", function()
        it("fails immediately for an unknown task", function()
            local path = write_tasks({ "[[tasks]]", 'name="known"', 'type="t_ok"' })
            exec.run("ghost", path)
            local e = wait_state("ghost", "failed")
            assert.is_true(has_report(e, "task not found"))
        end)

        it("fails immediately when a dependency is missing", function()
            local path = write_tasks({
                "[[tasks]]", 'name="need"', 'type="t_ok"', 'depends_on=["absent"]',
            })
            exec.run("need", path)
            local e = wait_state("need", "failed")
            assert.is_true(has_report(e, "unknown dependency: absent"))
        end)

        it("fails immediately on a dependency cycle", function()
            local path = write_tasks({
                "[[tasks]]", 'name="c1"', 'type="t_ok"', 'depends_on=["c2"]', "",
                "[[tasks]]", 'name="c2"', 'type="t_ok"', 'depends_on=["c1"]',
            })
            exec.run("c1", path)
            local e = wait_state("c1", "failed")
            assert.is_true(has_report(e, "dependency cycle"))
        end)

        it("fails on duplicate task names", function()
            -- Two tasks with the same name are two identical `[tasks.dup]`
            -- headers, which TOML rejects outright as a redefinition.
            local path = write_tasks({
                "[[tasks]]", 'name="dup"', 'type="t_ok"', "",
                "[[tasks]]", 'name="dup"', 'type="t_ok"',
            })
            exec.run("dup", path)
            local e = wait_state("dup", "failed")
            assert.is_true(has_report(e, "Duplicate table header"))
        end)

        it("fails when the file has no valid tasks table", function()
            local path = write_tasks({ 'title = "nope"' })
            exec.run("whatever", path)
            local e = wait_state("whatever", "failed")
            assert.is_true(#e.reports > 0)
        end)
    end)

    describe("dependencies", function()
        it("runs sequential dependencies before the task, in order", function()
            local path = write_tasks({
                "[[tasks]]", 'name="a"', 'type="t_order"', "",
                "[[tasks]]", 'name="b"', 'type="t_order"', "",
                "[[tasks]]", 'name="main"', 'type="t_order"', 'depends_on=["a","b"]',
            })
            exec.run("main", path)
            wait_state("main", "ok")
            assert.same({ "a", "b", "main" }, run_order)
        end)

        it("skips later deps and fails the task when a dependency fails", function()
            local path = write_tasks({
                "[[tasks]]", 'name="bad"', 'type="t_fail"', "",
                "[[tasks]]", 'name="after"', 'type="t_order"', "",
                "[[tasks]]", 'name="m"', 'type="t_order"', 'depends_on=["bad","after"]',
            })
            exec.run("m", path)
            local m = wait_state("m", "failed")
            -- Neither the later dep nor the task itself ran their command.
            assert.same({}, run_order)
            assert.is_true(has_report(m, "dependency 'bad' failed"))
        end)

        it("runs parallel dependencies before the task", function()
            local path = write_tasks({
                "[[tasks]]", 'name="pa"', 'type="t_order"', "",
                "[[tasks]]", 'name="pb"', 'type="t_order"', "",
                "[[tasks]]", 'name="pm"', 'type="t_order"',
                'depends_on=["pa","pb"]', 'depends_order="parallel"',
            })
            exec.run("pm", path)
            wait_state("pm", "ok")
            -- Both deps precede the task; order between them is unspecified.
            assert.equal(3, #run_order)
            assert.equal("pm", run_order[3])
        end)
    end)

    describe("if_running policies", function()
        it("refuses a second run by default and warns", function()
            local path = write_tasks({ "[[tasks]]", 'name="rf"', 'type="t_block"' })
            exec.run("rf", path)
            wait_state("rf", "running")

            exec.run("rf", path)
            assert.equal(1, #entries_for("rf"))
            assert.is_true(#warnings >= 1)
            assert.is_true(warnings[1]:find("already running", 1, true) ~= nil)
        end)

        it("starts a parallel instance when if_running=parallel", function()
            local path = write_tasks({
                "[[tasks]]", 'name="pl"', 'type="t_block"', 'if_running="parallel"',
            })
            exec.run("pl", path)
            wait_state("pl", "running")

            exec.run("pl", path)
            wait_until(function() return #entries_for("pl") == 2 end,
                "expected two parallel instances")
        end)

        it("queues a second run when if_running=wait until the first finishes", function()
            local path = write_tasks({
                "[[tasks]]", 'name="wt"', 'type="t_manual"', 'if_running="wait"',
            })
            exec.run("wt", path)
            wait_state("wt", "running")

            exec.run("wt", path)
            -- Two instances: one running, one queued (waiting).
            wait_until(function()
                local running, waiting = 0, 0
                for _, e in ipairs(entries_for("wt")) do
                    if e.state == "running" then running = running + 1 end
                    if e.state == "waiting" then waiting = waiting + 1 end
                end
                return running == 1 and waiting == 1
            end, "expected one running and one waiting instance")

            -- Completing the first lets the queued instance start.
            wait_manual()(true)
            wait_until(function()
                local running = 0
                for _, e in ipairs(entries_for("wt")) do
                    if e.state == "running" then running = running + 1 end
                end
                return running == 1
            end, "queued instance did not start after the first finished")
        end)

        it("stops the running instance and starts a new one when if_running=restart", function()
            local path = write_tasks({
                "[[tasks]]", 'name="rs"', 'type="t_block"', 'if_running="restart"',
            })
            exec.run("rs", path)
            -- Wait until the first instance is actually cancellable, so the
            -- restart's internal stop can terminate it (and let the new one start).
            wait_until(function()
                local e = entry_for("rs")
                return e ~= nil and e.cancel ~= nil
            end)
            local id1 = id_for("rs")

            exec.run("rs", path)
            -- A fresh running instance appears under a new id.
            wait_until(function()
                for id, e in pairs(exec.get_all()) do
                    if e.task_name == "rs"
                        and e.state == "running" and id ~= id1 then
                        return true
                    end
                end
                return false
            end, "restart did not start a new running instance")
            -- The original was stopped (and possibly already disposed).
            wait_until(function()
                local e1 = exec.get_all()[id1]
                return e1 == nil or e1.state == "stopped"
            end, "original instance was neither stopped nor disposed")
        end)
    end)

    describe("stop", function()
        it("stops a directly running task", function()
            local path = write_tasks({ "[[tasks]]", 'name="solo"', 'type="t_block"' })
            exec.run("solo", path)
            -- Wait until it is actually cancellable (cancel is set once start runs).
            wait_until(function()
                local e = entry_for("solo")
                return e ~= nil and e.cancel ~= nil
            end)

            exec.stop("solo")
            wait_state("solo", "stopped")
        end)

        it("cancels the in-flight dependency of a task that is only waiting", function()
            local path = write_tasks({
                "[[tasks]]", 'name="dep"', 'type="t_block"', "",
                "[[tasks]]", 'name="top"', 'type="t_block"', 'depends_on=["dep"]',
            })
            exec.run("top", path)
            wait_until(function()
                local d = entry_for("dep")
                return d ~= nil and d.cancel ~= nil
            end)
            assert.equal("waiting", entry_for("top").state)
            assert.equal("running", entry_for("dep").state)

            exec.stop("top")
            -- The stop cascades to the dependency, unblocking the wait; both settle.
            wait_until(function()
                local t, d = entry_for("top"), entry_for("dep")
                return t ~= nil and d ~= nil
                    and t.state == "stopped" and d.state == "stopped"
            end)
        end)
    end)

    describe("dispose", function()
        it("disposes a finished run and invokes the type dispose hook", function()
            local path = write_tasks({ "[[tasks]]", 'name="d"', 'type="t_disposable"' })
            exec.run("d", path)
            wait_state("d", "ok")

            local ok = exec.dispose(id_for("d"))
            assert.is_true(ok)
            assert.is_true(disposed.flag)
            assert.is_nil(entry_for("d"))
        end)

        it("refuses to dispose an active run", function()
            local path = write_tasks({ "[[tasks]]", 'name="da"', 'type="t_block"' })
            exec.run("da", path)
            wait_state("da", "running")

            local ok, err = exec.dispose(id_for("da"))
            assert.is_false(ok)
            assert.is_string(err)
        end)

        it("errors for an unknown run id", function()
            local ok, err = exec.dispose("no-such#1")
            assert.is_false(ok)
            assert.is_string(err)
        end)
    end)

    describe("list", function()
        it("returns ordered names and the by-name map", function()
            local path = write_tasks({
                "[[tasks]]", 'name="one"', 'type="t_ok"', "",
                "[[tasks]]", 'name="two"', 'type="t_ok"',
            })
            local ordered, by_name, err = exec.list(path)
            assert.is_nil(err)
            assert.same({ "one", "two" }, ordered)
            assert.equal("t_ok", by_name.one.type)
        end)

        it("returns an error for an invalid file", function()
            local path = write_tasks({ 'title="x"' })
            local ordered, _, err = exec.list(path)
            assert.is_nil(ordered)
            assert.is_string(err)
        end)
    end)

    describe("state", function()
        it("is idle for a task that has never run", function()
            assert.equal("idle", exec.state("never-run"))
        end)

        it("reports running while active and the terminal state afterwards", function()
            local path = write_tasks({ "[[tasks]]", 'name="st"', 'type="t_manual"' })
            exec.run("st", path)
            local done = wait_manual()
            assert.equal("running", exec.state("st"))

            done(true)
            wait_state("st", "ok")
            assert.equal("ok", exec.state("st"))
        end)
    end)

    describe("signals", function()
        it("emits state-change, report, and dispose events", function()
            local path = write_tasks({ "[[tasks]]", 'name="sig"', 'type="t_ok"' })
            local state_ids, reports, disposed_ids = {}, {}, {}
            local un1 = exec.on_state_change(function(id) state_ids[id] = true end)
            local un2 = exec.on_report(function(_, ev) table.insert(reports, ev.message) end)
            local un3 = exec.on_dispose(function(id) table.insert(disposed_ids, id) end)

            exec.run("sig", path)
            wait_state("sig", "ok")
            local id = id_for("sig")
            assert.is_true(state_ids[id])
            assert.is_true(vim.tbl_contains(reports, "started"))

            assert.is_true(exec.dispose(id))
            assert.is_true(vim.tbl_contains(disposed_ids, id))

            un1(); un2(); un3()
        end)
    end)
end)
