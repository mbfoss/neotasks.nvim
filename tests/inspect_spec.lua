---@diagnostic disable: undefined-global, undefined-field, need-check-nil
-- Tests for the public run-inspection API: `require("neotasks").list_runs()` and the
-- runner wrapper behind it. Runs are driven through purpose-built task types,
-- and the shared run registry is cleared before and after every test.

local exec   = require("neotasks.runner.exec")
local runner = require("neotasks.runner")
local types  = require("neotasks.types")
local plugin = require("neotasks")

local tasks_filename = require("neotasks.config").current.tasks_filename

-- Names of our own, so loading this spec cannot replace a type another spec
-- depends on (busted runs every spec in one Neovim).
types.register("insp_ok", {
    start = function(_, _, done) done(true); return function() end end,
})
types.register("insp_fail", {
    start = function(_, _, done) done(false); return function() end end,
})
-- Never finishes on its own; stopping it settles as "stopped" on the next tick.
types.register("insp_block", {
    start = function(_, _, done)
        return function() vim.schedule(function() done(false) end) end
    end,
})

-- helpers

--- Write task TOML to a fresh temp file and return its absolute path. Tasks are
--- a name-keyed map, but the specs write the concise `[[tasks]]` + `name="X"`
--- form; this rewrites it into `[tasks.X]` headers.
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
            i = i + 2
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

--- Poll until `pred` is true, asserting it became true within the timeout.
---@param pred fun(): boolean
---@param msg? string
local function wait_until(pred, msg)
    assert.is_true(vim.wait(2000, pred, 10), msg or "condition not met in time")
end

--- Wait for a task's single raw run to reach status `want`.
---@param name string
---@param want neotasks.TaskStatus
local function wait_status(name, want)
    wait_until(function()
        for _, e in pairs(exec.get_all()) do
            if e.task_name == name and (e.result or e.state) == want then return true end
        end
        return false
    end, ("task %q never reached state %q"):format(name, want))
end

--- The snapshot for a task, or nil.
---@param name string
---@return neotasks.RunInfo?
local function snapshot_for(name)
    for _, r in ipairs(runner.list_runs()) do
        if r.task_name == name then return r end
    end
end

--- Wait until a task's run can actually be cancelled. `state == "running"` is set
--- before the type's `start()` runs, so stopping any earlier asks for a stop that
--- has no cancel function yet and leaves the blocking task running.
---@param name string
local function wait_cancellable(name)
    wait_until(function()
        for _, e in pairs(exec.get_all()) do
            if e.task_name == name and e.cancel ~= nil then return true end
        end
        return false
    end, ("task %q never became cancellable"):format(name))
end

--- Settle and dispose everything, so specs start and end with an empty registry.
local function clear_runs()
    -- Retry: a stop requested before `start()` installed its cancel function
    -- only takes effect on a later stop, once the function exists.
    for _ = 1, 40 do
        local active = false
        for _, e in pairs(exec.get_all()) do
            if e.state == "running" or e.state == "waiting" then
                active = true
                exec.stop(e.task_name)
            end
        end
        if not active then break end
        vim.wait(50)
    end
    for _, d in ipairs(exec.disposable()) do exec.dispose(d.run_id) end
end

-- suite

describe("runs inspection", function()
    before_each(clear_runs)
    after_each(clear_runs)

    it("returns an empty list when nothing is live", function()
        assert.same({}, plugin.list_runs())
    end)

    it("reports a running primary run", function()
        local path = write_tasks({ "[[tasks]]", 'name="block"', 'type="insp_block"' })
        exec.run("block", path)
        wait_status("block", "running")

        local r = snapshot_for("block")
        assert.is_not_nil(r)
        assert.is_number(r.run_id)
        assert.equal("block", r.task_name)
        assert.equal("insp_block", r.task_type)
        assert.equal("running", r.state)
        assert.is_nil(r.result)
        assert.equal("running", r.status)
        assert.is_true(r.active)
        assert.is_true(r.primary)
    end)

    it("reports a completed run's result", function()
        local path = write_tasks({ "[[tasks]]", 'name="ok"', 'type="insp_ok"' })
        exec.run("ok", path)
        wait_status("ok", "succeeded")

        local r = snapshot_for("ok")
        assert.equal("complete", r.state)
        assert.equal("succeeded", r.result)
        assert.equal("succeeded", r.status)
        assert.is_false(r.active)
    end)

    it("reports a failed run", function()
        local path = write_tasks({ "[[tasks]]", 'name="bad"', 'type="insp_fail"' })
        exec.run("bad", path)
        wait_status("bad", "failed")
        assert.equal("failed", snapshot_for("bad").result)
    end)

    it("reports a waiting run and excludes its dependency from primary", function()
        local path = write_tasks({
            "[[tasks]]", 'name="dep"', 'type="insp_block"', "",
            "[[tasks]]", 'name="top"', 'type="insp_ok"', 'depends_on=["dep"]',
        })
        exec.run("top", path)
        wait_until(function()
            local top, dep = snapshot_for("top"), snapshot_for("dep")
            return top ~= nil and dep ~= nil
                and top.state == "waiting" and dep.state == "running"
        end, "top never waited on its dependency")

        local top = snapshot_for("top")
        assert.equal("waiting", top.state)
        assert.is_true(top.active)
        assert.is_true(top.primary)
        assert.same({ "dep" }, top.waiting_for)

        local dep = snapshot_for("dep")
        assert.equal("running", dep.state)
        assert.is_false(dep.primary)
    end)

    it("orders runs by run id", function()
        local path = write_tasks({
            "[[tasks]]", 'name="a"', 'type="insp_block"', "",
            "[[tasks]]", 'name="b"', 'type="insp_block"',
        })
        exec.run("a", path)
        exec.run("b", path)
        wait_until(function()
            return snapshot_for("a") ~= nil and snapshot_for("b") ~= nil
        end)

        local runs = plugin.list_runs()
        assert.equal(2, #runs)
        assert.is_true(runs[1].run_id < runs[2].run_id)
        assert.same({ "a", "b" }, { runs[1].task_name, runs[2].task_name })
    end)

    it("omits runner internals", function()
        local path = write_tasks({ "[[tasks]]", 'name="block"', 'type="insp_block"' })
        exec.run("block", path)
        wait_status("block", "running")

        local r = snapshot_for("block")
        for _, key in ipairs({ "done", "cancel", "bufnrs", "reports", "stop_requested" }) do
            assert.is_nil(r[key], key .. " should not be exposed")
        end
    end)

    it("drops a disposed run", function()
        local path = write_tasks({ "[[tasks]]", 'name="ok"', 'type="insp_ok"' })
        exec.run("ok", path)
        wait_status("ok", "succeeded")

        local r = snapshot_for("ok")
        assert.is_true(exec.dispose(r.run_id))
        assert.is_nil(snapshot_for("ok"))
    end)

    it("is available through the runner wrapper", function()
        local path = write_tasks({ "[[tasks]]", 'name="ok"', 'type="insp_ok"' })
        exec.run("ok", path)
        wait_status("ok", "succeeded")
        assert.equal(1, #runner.list_runs())
    end)

    describe("caching", function()
        it("returns an independent outer array each call", function()
            local path = write_tasks({ "[[tasks]]", 'name="ok"', 'type="insp_ok"' })
            exec.run("ok", path)
            wait_status("ok", "succeeded")

            local first = plugin.list_runs()
            assert.equal(1, #first)
            table.remove(first)
            assert.equal(0, #first)
            assert.equal(1, #plugin.list_runs())
        end)

        it("reflects a run created after an earlier call", function()
            assert.same({}, plugin.list_runs())

            local path = write_tasks({ "[[tasks]]", 'name="block"', 'type="insp_block"' })
            exec.run("block", path)
            wait_status("block", "running")
            assert.equal("running", snapshot_for("block").state)
        end)

        it("reflects a completed transition", function()
            local path = write_tasks({ "[[tasks]]", 'name="block"', 'type="insp_block"' })
            exec.run("block", path)
            wait_status("block", "running")
            wait_cancellable("block")
            assert.equal("running", snapshot_for("block").state)

            exec.stop("block")
            wait_status("block", "stopped")

            local r = snapshot_for("block")
            assert.equal("complete", r.state)
            assert.equal("stopped", r.result)
            assert.equal("stopped", r.status)
            assert.is_false(r.active)
        end)
    end)

    describe("change events", function()
        it("fires User NeotasksRunsChanged", function()
            local fired = false
            local id = vim.api.nvim_create_autocmd("User", {
                pattern = "NeotasksRunsChanged",
                callback = function() fired = true end,
            })

            local path = write_tasks({ "[[tasks]]", 'name="ok"', 'type="insp_ok"' })
            exec.run("ok", path)
            wait_status("ok", "succeeded")

            local seen = vim.wait(1000, function() return fired end, 10)
            vim.api.nvim_del_autocmd(id)
            assert.is_true(seen, "NeotasksRunsChanged never fired")
        end)
    end)
end)
