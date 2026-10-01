---@diagnostic disable: undefined-global, undefined-field, need-check-nil
-- Tests for the panel's winbar: the bar it draws, the signature it draws it
-- with, and the guard that takes the bar back off a window that was merely
-- handed it.
--
-- 'winbar' is a per-buffer window option (`:h w_onebuf_opt`): the value a window
-- sets is stored on the buffer it was showing and given to every window that
-- shows that buffer afterwards. The panel's bar therefore reaches windows it
-- never drew -- a window split off the panel, or any window that enters a run
-- buffer the panel has since left, including one that existed before the panel
-- did. Such a window is not in `self._wins`, so no render ever touches it and
-- the copy would stand for good. Every bar the renderer builds ends with a
-- zero-width click region on the panel's own handler; that signature is what
-- the guard looks for in a window it does not own.
--
-- What a window's bar comes out as is what Neovim's own drawing would make of
-- it, so the specs ask Neovim to build it the same way.

local panel = require("neotasks.ui.panel")

-- The tail every bar the panel draws carries (see `winbar.build`).
local MARK = "%0@v:lua._neotasks_panel_click@%X"

describe("winbar", function()
    local p
    ---@type integer[]  scratch buffers, deleted with the test that made them
    local bufs

    ---@param lines string[]
    ---@return integer
    local function make_buf(lines)
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        bufs[#bufs + 1] = buf
        return buf
    end

    --- The bar Neovim builds for a window, from the value that window holds.
    ---@param win integer
    ---@return string
    local function bar(win)
        local ok, res = pcall(vim.api.nvim_eval_statusline, vim.wo[win].winbar, {
            winid      = win,
            use_winbar = true,
        })
        assert.is_true(ok, ("window %d has no winbar to render"):format(win))
        return res.str
    end

    --- A panel with one two-page group, the shape a run has: `log` first.
    ---@return integer log, integer out
    local function run_group()
        local log = make_buf({ "run output" })
        local out = make_buf({ "run output (out)" })
        local g   = p:group({ id = "g1", label = "build" })
        g:page({ buf = log, label = "log", priority = 1 })
        g:page({ buf = out, label = "out", priority = 2 })
        return log, out
    end

    --- Whether a window holds a bar of the panel's, recognised by its signature.
    ---@param win integer
    ---@return boolean
    local function signed(win)
        return vim.wo[win].winbar:find(MARK, 1, true) ~= nil
    end

    before_each(function()
        p    = panel.get()
        bufs = {}
    end)

    after_each(function()
        p:close({ all = true })
        for _, g in ipairs(p:groups()) do g:remove() end
        for _, buf in ipairs(bufs) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
        vim.cmd("silent! only")
    end)

    it("draws the group's tabs in the panel's window", function()
        run_group()
        p:jump(1)

        local text = bar(p:win())
        assert.is_truthy(text:find("build", 1, true))
        assert.is_truthy(text:find("log", 1, true))
        assert.is_truthy(text:find("out", 1, true))
        -- The click regions around those tabs are escapes, and escapes the bar
        -- could not be built from would be showing up here as text.
        assert.is_nil(text:find("v:lua", 1, true))
    end)

    it("signs the bar it draws for a group", function()
        run_group()
        p:jump(1)
        assert.is_true(signed(p:win()))
    end)

    it("signs the placeholder it draws with nothing to show", function()
        -- The placeholder is the bar with no click regions of its own, and so
        -- the one bar the guard could not recognise without the signature.
        p:open()
        assert.equals(0, #p:groups())
        assert.is_truthy(bar(p:win()):find("No pages", 1, true))
        assert.is_true(signed(p:win()))
    end)

    it("keeps its own bar when its window changes page", function()
        local log = make_buf({ "run output" })
        p:group({ id = "g1", label = "build" }):page({ buf = log, label = "log", priority = 1 })
        p:jump(1)
        assert.is_true(signed(p:win()))

        local out = make_buf({ "run output (out)" })
        p:group({ id = "g2", label = "test" }):page({ buf = out, label = "out", priority = 1 })
        p:jump(2)  -- the panel's own window, entering another buffer

        assert.is_true(signed(p:win()))
        assert.is_truthy(bar(p:win()):find("build", 1, true))
        assert.is_truthy(bar(p:win()):find("test", 1, true))
    end)

    it("takes its bar back off a window that enters a run buffer it has left", function()
        -- The window exists before the panel does: it is created first, and the
        -- panel splits off it. It shows that run buffer later, from outside.
        vim.cmd("split")
        local win      = vim.api.nvim_get_current_win()
        local log, out = run_group()

        p:jump(1)
        p:jump(2)  -- the panel leaves `log`, which now carries its bar
        assert.equals(out, vim.api.nvim_win_get_buf(p:win()))

        vim.api.nvim_win_set_buf(win, log)

        assert.is_false(signed(win))
        assert.equals("", bar(win))
        -- ...and the panel keeps its own, which the guard has no business in.
        assert.is_true(signed(p:win()))
        assert.is_truthy(bar(p:win()):find("build", 1, true))
    end)

    it("takes its bar back off a window made by splitting a panel window", function()
        local log = make_buf({ "run output" })
        p:group({ id = "g1", label = "build" }):page({ buf = log, label = "log", priority = 1 })
        p:jump(1)
        assert.is_true(vim.wo[p:win()].winfixheight)

        vim.api.nvim_set_current_win(p:win())
        vim.cmd("split")
        local win = vim.api.nvim_get_current_win()

        assert.is_false(p:_owns_win(win))
        assert.is_false(signed(win))
        assert.equals("", bar(win))
        assert.is_false(vim.wo[win].winfixheight)
        assert.is_false(vim.wo[win].winfixwidth)
    end)

    it("leaves a window's own bar alone", function()
        -- The guard keys on the signature, so a bar the user set themselves --
        -- which may well hold click regions of its own -- is none of its
        -- business. (The event is fired directly: switching to another buffer
        -- would reset the window's bar itself, which is Neovim handing back the
        -- options a window holds for a buffer it has not shown before.)
        vim.cmd("split")
        local win = vim.api.nvim_get_current_win()
        local own = "%1@v:lua.SomeUserHandler@X%X"
        vim.api.nvim_set_option_value("winbar", own, { win = win, scope = "local" })

        vim.cmd("doautocmd BufWinEnter")

        assert.equals(own, vim.wo[win].winbar)
    end)
end)
