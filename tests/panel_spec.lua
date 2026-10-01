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
-- did. Such a window is not the panel's (`self._win`), so no render ever touches
-- it and the copy would stand for good. Every bar the renderer builds ends with a
-- zero-width click region on the panel's own handler; that signature is what
-- the guard looks for in a window it does not own.
--
-- What a window's bar comes out as is what Neovim's own drawing would make of
-- it, so the specs ask Neovim to build it the same way.
--
-- The panel is also one window for the whole editor rather than one per Neovim
-- tabpage: switching tabpages leaves it where it is, and asking for it in
-- another one brings it over. Those specs live in the nested `describe` at the
-- end.

local panel = require("neotasks.panel")

-- The tail every bar the panel draws carries (see `winbar.build`).
local MARK = "%0@v:lua._neotasks_panel_click@%X"

describe("panel", function()
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
        p    = panel
        bufs = {}
    end)

    after_each(function()
        p:close()
        for _, g in ipairs(p:groups()) do g:remove() end
        for _, buf in ipairs(bufs) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
        vim.cmd("silent! tabonly")
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

    -- One window for the whole editor, rather than one per tabpage, all of them
    -- views of the same panel. It stays in the tabpage it was opened in: entering
    -- another one leaves it behind, and what brings it over is asking for it
    -- there -- which is what a run starting, or any `:Neotasks panel` command,
    -- does.
    describe("across tabpages", function()
        it("stays where it is when the user enters another tabpage", function()
            local log = make_buf({ "run output" })
            p:group({ id = "g1", label = "build" }):page({ buf = log, label = "log", priority = 1 })
            p:jump(1)

            local win   = p:win()
            local first = vim.api.nvim_get_current_tabpage()
            assert.is_truthy(win)

            vim.cmd("tabnew")

            -- still open, still in the tabpage it was opened in -- just not here
            assert.is_nil(p:win())
            assert.is_false(p:is_open())
            assert.equals(win, p:_any_win())
            assert.equals(first, vim.api.nvim_win_get_tabpage(win))
        end)

        it("comes over when the user asks for it here", function()
            local log = make_buf({ "run output" })
            p:group({ id = "g1", label = "build" }):page({ buf = log, label = "log", priority = 1 })
            p:jump(1)

            local win   = p:win()
            local first = vim.api.nvim_get_current_tabpage()
            vim.cmd("tabnew")
            p:open()

            -- here now, buffer and all, and the window it left is gone
            local moved = p:win()
            assert.is_truthy(moved)
            assert.equals(vim.api.nvim_get_current_tabpage(), vim.api.nvim_win_get_tabpage(moved))
            assert.equals(log, vim.api.nvim_win_get_buf(moved))
            assert.is_false(vim.api.nvim_win_is_valid(win))
            assert.equals(1, #vim.api.nvim_tabpage_list_wins(first))
        end)

        it("comes over when a run starts here", function()
            p:open()
            local win = p:win()
            vim.cmd("tabnew")

            -- a run opening its tab is a request for the panel, like any other
            local out = make_buf({ "run output" })
            p:group({ id = "g1", label = "build" }):page({ buf = out, label = "out", priority = 1 })

            local moved = p:win()
            assert.is_truthy(moved)
            assert.is_false(vim.api.nvim_win_is_valid(win))
            assert.equals(out, vim.api.nvim_win_get_buf(moved))
        end)

        it("is one window, wherever the user has been", function()
            p:open()
            local first = p:win()
            vim.cmd("tabnew")
            vim.cmd("tabnew")
            p:open()
            assert.is_false(vim.api.nvim_win_is_valid(first))

            -- one window holding a bar of the panel's, and it is the current one
            local holding = {}
            for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
                for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
                    if signed(w) then holding[#holding + 1] = w end
                end
            end
            assert.same({ p:win() }, holding)
        end)

        it("closes when the tabpage it is in closes", function()
            p:open()
            vim.cmd("tabnew")
            p:open()
            local win = p:win()
            assert.is_truthy(win)

            vim.cmd("tabclose")  -- takes the panel's tabpage, and so the panel

            assert.is_false(p:is_open())
            assert.is_false(vim.api.nvim_win_is_valid(win))
            -- and it does not come back in the tabpage landed in
            assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))
        end)

        it("leaves no tabpage behind when it was its tabpage's only window", function()
            local log = make_buf({ "run output" })
            p:group({ id = "g1", label = "build" }):page({ buf = log, label = "log", priority = 1 })
            p:jump(1)

            -- Close the window the panel was split off, leaving it alone in its
            -- tabpage: the one it is rebuilt out of when the panel comes over.
            local first = p:win()
            vim.cmd("close")
            assert.same({ first }, vim.api.nvim_tabpage_list_wins(0))

            vim.cmd("tabnew")
            p:open()

            local win = p:win()
            assert.is_truthy(win)
            assert.is_not_equal(first, win)
            assert.equals(log, vim.api.nvim_win_get_buf(win))
            -- the tabpage the old window emptied went with it
            assert.equals(1, vim.fn.tabpagenr("$"))
        end)
    end)
end)
