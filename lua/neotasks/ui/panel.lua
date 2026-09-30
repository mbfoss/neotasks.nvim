---@brief The task-output panel: a fixed split whose winbar is a flat, numbered
---list of every run's tab.
---
---Ported from dock.nvim's Panel, minus the multi-source layer: neotasks is the
---only producer, so groups are created directly here (`Panel:group`) rather than
---through a Source. Groups belong to the panel instance, not to its window:
---closing the panel only tears down that window, so re-opening restores every
---tab exactly as it was.
---
---There is one panel for the whole editor, shared by every Neovim tabpage: the
---same groups, the same tab bar, the same page on screen. A window is what is
---per-tabpage: each tab can show or hide the panel on its own, and every open
---one is a view of the same panel.

local config_mod = require("neotasks.config")
local config     = config_mod.current
local fixedwin   = require("neotasks.util.fixedwin")
local highlight  = require("neotasks.ui.highlight")
local throttle   = require("neotasks.util.throttle")
local uiutil     = require("neotasks.util.ui")
local winbar     = require("neotasks.ui.winbar")
local Group      = require("neotasks.ui.group")

---@class neotasks.ui.panel
---@field _wins        table<integer, integer>  tabpage handle -> that tab's panel window
---@field _pending     table<integer, true>       tabpages to (re)open in when the user next enters them
---@field _augroup     integer?                   panel-wide autocmds, created with the instance
---@field _groups      neotasks.ui.Group[]
---@field _by_id       table<string, neotasks.ui.Group>
---@field _seq         integer                    id counter for groups created without an id
---@field _active      neotasks.ui.Group?
---@field _active_page integer                    index into _active.pages; 0 when the group has none
---@field _shown_buf   integer?                   buffer currently in the panel windows
---@field _closing_buf integer?                   buffer on screen when a window last closed, for one tick
---@field _closing_tabs table<integer, true>?     tabpages whose window closed in that same tick
---@field _ratio       number?                    last-known size ratio, persisted across open/close
---@field _targets     neotasks.ui.panel.Target[] jump number -> what it selects; rebuilt on every render
---@field _follow      neotasks.ui.Group?         group allowed to take over even while the panel is focused
---@field _attached    table<integer, true>       buffers nvim_buf_attach has been called on
---@field _unread      table<integer, true>       buffers that gained lines while not on screen
---@field _placeholder integer?
---@field _placeholder_ns   integer?               namespace the placeholder's text is drawn in
---@field _placeholder_text string?                text that namespace currently draws
---@field _throttled_winbar fun()             coalesces the winbar redraws driven by buffer output
local Panel        = {}
Panel.__index      = Panel

---@class neotasks.ui.panel.Target
---@field group neotasks.ui.Group
---@field page  integer  1-based page index, or 0 meaning "the group's best page"

local _instance = nil ---@type neotasks.ui.panel?

--- The panel. Not to be built twice: `_setup_autocmds` claims the `NeotasksPanel`
--- augroup with `clear`, so a second instance would quietly take over the first
--- one's autocmds while both stayed in use. `Panel.get()` is the way in.
---@return neotasks.ui.panel
function Panel.new()
    assert(not _instance, "neotasks: Panel is a singleton; use Panel.get()")
    local self = setmetatable({
        _wins        = {},
        _pending     = {},
        _groups      = {},
        _by_id       = {},
        _seq         = 0,
        _active_page = 0,
        _targets     = {},
        _attached    = {},
        _unread      = {},
    }, Panel)
    self._throttled_winbar = throttle.throttle_wrap(100, function()
        vim.schedule(function() self:_refresh_winbar() end)
    end)
    self:_setup_autocmds()
    return self
end

--- The shared panel every run draws into, and every tabpage shows.
---@return neotasks.ui.panel
function Panel.get()
    if not _instance then _instance = Panel.new() end
    return _instance
end

-- Window lifecycle

-- Undo every option `open()` sets, handing a window back as an ordinary one.
local _RESET_OPTS = "setlocal winbar< winfixheight< winfixwidth< winfixbuf< "
    .. "number< relativenumber< signcolumn< spell< wrap<"

--- Every live panel window, keyed by tabpage. Stale entries (window closed with
--- its tabpage, say) are dropped on the way past.
---@return table<integer, integer>  tabpage handle -> window id
function Panel:wins()
    local out = {}
    for tab, win in pairs(self._wins) do
        if vim.api.nvim_tabpage_is_valid(tab) and vim.api.nvim_win_is_valid(win) then
            out[tab] = win
        else
            self._wins[tab] = nil
        end
    end
    return out
end

--- The panel window of a tabpage, the current one unless `tab` says otherwise.
---@param tab? integer  tabpage handle
---@return integer?
function Panel:win(tab)
    tab = tab or vim.api.nvim_get_current_tabpage()
    local win = self._wins[tab]
    if win and vim.api.nvim_win_is_valid(win) then return win end
    self._wins[tab] = nil
    return nil
end

--- Whether this tabpage is showing the panel.
---@param tab? integer
---@return boolean
function Panel:is_open(tab)
    return self:win(tab) ~= nil
end

--- Whether any tabpage at all is showing the panel.
---@return boolean
function Panel:is_open_anywhere()
    return next(self:wins()) ~= nil
end

---@param win integer
---@return boolean
function Panel:_owns_win(win)
    for _, w in pairs(self:wins()) do
        if w == win then return true end
    end
    return false
end

--- True while the user has a panel window focused. Auto-takeover is suppressed in
--- that case, so background activity never yanks the view out from under someone
--- working inside the panel.
---@return boolean
function Panel:_is_focused()
    return self:_owns_win(vim.api.nvim_get_current_win())
end

--- Panel-wide autocmds. These outlive any one window, so they are registered
--- with the instance rather than per open().
function Panel:_setup_autocmds()
    local group = vim.api.nvim_create_augroup("NeotasksPanel", { clear = true })
    self._augroup = group

    vim.api.nvim_create_autocmd({ "TabEnter", "TabNew" }, {
        group    = group,
        callback = function()
            local tab = vim.api.nvim_get_current_tabpage()
            if self._pending[tab] then
                self._pending[tab] = nil
                self:open()
            end
        end,
    })

    -- A tabpage can close before the user ever enters it, and `_pending` is keyed
    -- by handle: drop the dead ones rather than carry them for the session.
    -- (<afile> on TabClosed is the tab *number*, so the handles are checked
    -- directly instead of translated.)
    vim.api.nvim_create_autocmd("TabClosed", {
        group    = group,
        callback = function()
            for tab in pairs(self._pending) do
                if not vim.api.nvim_tabpage_is_valid(tab) then self._pending[tab] = nil end
            end
        end,
    })

    vim.api.nvim_create_autocmd("WinNew", {
        group    = group,
        callback = function()
            -- Window options are copied onto a window made from another one, so
            -- splitting a panel window (or carrying it off with `:wincmd T`,
            -- which really means "new window over there, close this one")
            -- leaves a stray carrying our click regions that no render ever
            -- updates. The click handler in 'winbar' is the giveaway; it is
            -- there regardless of how the bar was cropped for its width.
            local new_win = vim.api.nvim_get_current_win()
            if not self:_owns_win(new_win)
                and vim.wo[new_win].winbar:find("__neotasks_panel_click", 1, true) then
                vim.api.nvim_win_call(new_win, function() vim.cmd(_RESET_OPTS) end)
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "WinResized", "ColorScheme" }, {
        group    = group,
        callback = function()
            if self:is_open_anywhere() then
                highlight.setup()
                self:_refresh_winbar()
            end
        end,
    })
end

--- Show the panel in the current tabpage. Other tabpages are left alone: they
--- are views of this same panel, each opened and closed on its own.
---@param opts? { enter?: boolean }
---@return boolean ok, string? error  false when there is no room for the split
function Panel:open(opts)
    opts = opts or {}
    local tab      = vim.api.nvim_get_current_tabpage()
    local existing = self:win(tab)
    if existing then
        if opts.enter then vim.api.nvim_set_current_win(existing) end
        return true
    end
    self._pending[tab] = nil

    highlight.setup()

    local axis, pos = config_mod.split_spec()
    -- fixedwin owns the split creation, the fixed-size pinning, layout-change
    -- recovery, and the close lifecycle; on_delete hands back the last-known
    -- ratio (shared by every tab's panel, so a drag in one sizes the next) and
    -- runs our teardown.
    -- `win` is an upvalue of on_delete so the teardown knows which window it is
    -- reporting; it is assigned long before any close can fire.
    local win ---@type integer?
    local err ---@type string?
    -- the page buffer is swapped in below; start on the current one. fixedwin
    -- keeps its own augroup and deletes it when the window closes, so there is
    -- nothing here to hold on to.
    win, _, err = fixedwin.create_fixed_win(0, {
        axis  = axis,
        ratio = self._ratio or config.panel.size,
        min   = config.panel.min_size,
        pos   = pos,
        enter = opts.enter,
        on_delete = function(ratio)
            self._ratio = ratio
            if win then self:_on_win_closed(win) end
        end,
    })
    -- Too small an editor to hold a second window: nothing was created, so
    -- leave the panel exactly as it was rather than recording a window that
    -- does not exist.
    if not win then return false, err end

    self._wins[tab] = win

    uiutil.win_setlocal(win, "winfixbuf", true)
    uiutil.win_setlocal(win, "number", false)
    uiutil.win_setlocal(win, "relativenumber", false)
    uiutil.win_setlocal(win, "signcolumn", "no")
    uiutil.win_setlocal(win, "spell", false)
    uiutil.win_setlocal(win, "wrap", false)

    if not self._active or self._active:is_removed() then
        -- prefer the oldest still-working group, else the newest tab
        local pick = self._groups[#self._groups]
        for _, group in ipairs(self._groups) do
            if group:is_busy() then
                pick = group
                break
            end
        end
        self:_set_active(pick)
    end

    -- A panel already open elsewhere is showing a page; join it rather than
    -- re-deriving one, so every view stays on the same buffer.
    if self._shown_buf and vim.api.nvim_buf_is_valid(self._shown_buf) then
        self:_set_win_buf(self._shown_buf, win)
    else
        self:_show_active()
    end
    self:_refresh_winbar()
    return true
end

--- Hide the panel in the current tabpage; `{ all = true }` hides it everywhere.
--- Groups are untouched either way: a closed panel still has all its tabs.
---@param opts? { all?: boolean }
function Panel:close(opts)
    if opts and opts.all then
        self._pending = {}
        -- fixedwin's on_delete saves the ratio and calls _on_win_closed.
        for _, win in pairs(self:wins()) do
            pcall(vim.api.nvim_win_close, win, false)
        end
        return
    end

    local tab          = vim.api.nvim_get_current_tabpage()
    self._pending[tab] = nil
    local win          = self:win(tab)
    if win then pcall(vim.api.nvim_win_close, win, false) end
end

---@param opts? { enter?: boolean }
---@return boolean ok, string? error
function Panel:toggle(opts)
    if self:is_open() then
        self:close()
        return true
    end
    return self:open(opts)
end

---@param win integer  the window that closed
function Panel:_on_win_closed(win)
    local closed_tab
    for tab, w in pairs(self._wins) do
        if w == win then
            closed_tab      = tab
            self._wins[tab] = nil
        end
    end

    -- Deleting a buffer closes every window showing it, and Neovim emits
    -- WinClosed *before* any BufUnload/BufWipeout autocmd, and there is no hook
    -- early enough to move the panel off the doomed buffer first. So record what
    -- was on screen and where; if that exact buffer unloads in this same tick,
    -- the close was collateral damage from the delete and _attach_buf reopens
    -- the panel in every tab that lost it.
    self._closing_buf  = self._shown_buf
    self._closing_tabs = self._closing_tabs or {}
    if closed_tab then self._closing_tabs[closed_tab] = true end
    vim.schedule(function()
        self._closing_buf  = nil
        self._closing_tabs = nil
    end)

    if not self:is_open_anywhere() then
        self._shown_buf = nil
    end
end

-- Buffer display

---@return integer bufnr
function Panel:_placeholder_buf()
    if not self._placeholder or not vim.api.nvim_buf_is_valid(self._placeholder) then
        self._placeholder    = uiutil.create_scratch_buffer(false, { bufhidden = "hide", buflisted = false })
        self._placeholder_ns = vim.api.nvim_create_namespace("NeotasksPanelPlaceholder")
        vim.bo[self._placeholder].modifiable = true
        vim.api.nvim_buf_set_lines(self._placeholder, 0, -1, false, { "" })
        vim.bo[self._placeholder].modifiable = false
    end

    -- The text is a virt_text rather than buffer content, so nothing re-renders
    -- it on its own: a `panel.empty_text` set after the buffer was made has to
    -- repaint it here or the old text stands for the rest of the session.
    if self._placeholder_text ~= config.panel.empty_text then
        vim.api.nvim_buf_clear_namespace(self._placeholder, self._placeholder_ns, 0, -1)
        vim.api.nvim_buf_set_extmark(self._placeholder, self._placeholder_ns, 0, 0, {
            virt_text     = { { config.panel.empty_text, "Comment" } },
            virt_text_pos = "overlay",
        })
        self._placeholder_text = config.panel.empty_text
    end
    return self._placeholder
end

---@param bufnr integer
function Panel:_attach_buf(bufnr)
    if self._attached[bufnr] then return end
    self._attached[bufnr] = true

    -- Drop the page when its buffer goes away. No augroup, so this outlives
    -- panel open/close cycles the way the buffer does. `BufWipeout` as well as
    -- `BufUnload`: a buffer is valid before it is loaded, and wiping one that
    -- was never loaded unloads nothing, so the unload would never come.
    vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
        buffer   = bufnr,
        once     = true,
        callback = function()
            self._attached[bufnr] = nil
            local took_tabpages_down = self._closing_buf == bufnr
                and vim.tbl_keys(self._closing_tabs or {}) or {}

            for _, group in ipairs(vim.list_slice(self._groups)) do
                group:remove_page(bufnr)
            end

            -- Restore the panels Neovim closed out from under us (see
            -- _on_win_closed), but only if there is still something to show:
            -- reopening an empty panel over a wiped last tab is just noise.
            if #took_tabpages_down > 0 and #self._groups > 0 then
                vim.schedule(function() self:_reopen_in(took_tabpages_down) end)
            end
        end,
    })

    self:_watch_buf(bufnr)
end

--- Whether `bufnr` gained lines with nobody watching. Not "is the panel showing
--- it": the panel is editor-wide, so it can be showing a buffer in a tabpage the
--- user is not in, and it can be closed entirely, neither of which leaves the
--- output on screen. What is on screen is a window of the *current* tabpage, and
--- the panel's own window there counts like any other.
---@param bufnr integer
---@return boolean
function Panel:_is_unseen(bufnr)
    -- fast path: the page this tabpage's own panel is showing
    if self._shown_buf == bufnr and self:is_open() then return false end

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == bufnr then return false end
    end
    return true
end

--- Watch a buffer for lines gained off screen. A buffer that is valid but not
--- loaded cannot be watched yet: `nvim_buf_attach` reports nothing and installs
--- nothing for one, so the watch is deferred to the read that loads it rather
--- than recorded as done.
---@param bufnr integer
function Panel:_watch_buf(bufnr)
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
            buffer   = bufnr,
            once     = true,
            callback = function() self:_watch_buf(bufnr) end,
        })
        return
    end

    vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = function()
            if self:_is_unseen(bufnr) then
                self._unread[bufnr] = true
                self._throttled_winbar()
            end
        end,
        on_detach = function()
            self._attached[bufnr] = nil
            self._unread[bufnr]   = nil
        end,
    })
end

--- Re-show the panel in each of `tabs`. Only the current tabpage can be split
--- into directly; the rest wait for the user to enter them.
---@param tabs integer[]
function Panel:_reopen_in(tabs)
    local cur = vim.api.nvim_get_current_tabpage()
    for _, tab in ipairs(tabs) do
        if vim.api.nvim_tabpage_is_valid(tab) and not self:is_open(tab) then
            if tab == cur then
                self:open()
            else
                self._pending[tab] = true
            end
        end
    end
end

--- Put a buffer in the panel windows, every one of them by default, since all
--- tabs are views of the same panel.
---@param bufnr integer
---@param only? integer  restrict to this window
function Panel:_set_win_buf(bufnr, only)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    local shown = false
    for _, win in pairs(self:wins()) do
        if not only or win == only then
            uiutil.win_setlocal(win, "winfixbuf", false)
            vim.api.nvim_win_set_buf(win, bufnr)
            uiutil.win_setlocal(win, "winfixbuf", true)
            if vim.bo[bufnr].buftype == "terminal" then
                local last = vim.api.nvim_buf_line_count(bufnr)
                pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
            end
            shown = true
        end
    end
    if not shown then return end

    self._unread[bufnr] = nil
    self._shown_buf     = bufnr
end

--- Put the active group's active page in the panel windows, falling back to the
--- group's best page and then to the placeholder buffer.
function Panel:_show_active()
    if not self:is_open_anywhere() then return end

    local group = self._active
    local page  = group and group.pages[self._active_page] or nil

    if group and (not page or not vim.api.nvim_buf_is_valid(page.buf)) then
        self._active_page = self:_best_page(group)
        page              = group.pages[self._active_page]
    end

    if page and vim.api.nvim_buf_is_valid(page.buf) then
        self:_set_win_buf(page.buf)
    else
        self:_set_win_buf(self:_placeholder_buf())
    end
end

-- Active group / page selection

--- Index of the group's highest-priority page, or 0 when it has none.
---@param group neotasks.ui.Group
---@return integer
function Panel:_best_page(group)
    local best_idx, best_pri = 0, nil
    for i, page in ipairs(group.pages) do
        if best_pri == nil or page.priority > best_pri then
            best_idx, best_pri = i, page.priority
        end
    end
    return best_idx
end

---@param group neotasks.ui.Group?
---@param page_idx? integer
function Panel:_set_active(group, page_idx)
    -- Selecting anything but the followed group ends the follow.
    if group ~= self._follow then self._follow = nil end
    self._active      = group
    self._active_page = group and (page_idx or self:_best_page(group)) or 0
end

--- Advance to the active group's best page, but only when it outranks the page
--- already on screen, so a low-priority buffer appearing mid-run never pulls
--- the user off the output they are watching.
function Panel:_advance_best()
    local group = self._active
    if not group then return end
    local cur  = group.pages[self._active_page]
    local best = self:_best_page(group)
    if best == 0 then return end
    if not cur or group.pages[best].priority > cur.priority then
        self._active_page = best
    end
end

--- Whether background activity in `group` may change what is displayed: yes
--- unless the user is working inside the panel, and always for a followed group.
---@param group neotasks.ui.Group
---@return boolean
function Panel:_may_follow(group)
    return self._follow == group or not self:_is_focused()
end

---@param group neotasks.ui.Group
---@return boolean
function Panel:_should_takeover(group)
    -- "never" means never *steals*: with nothing on screen there is nothing to
    -- steal from, and an empty panel next to a populated winbar just looks broken.
    if not self._active or self._active:is_removed() then return true end
    if group.focus == "never" then return false end
    if group.focus == "always" then return true end
    return not self:_is_focused()
end

---@param group neotasks.ui.Group
---@param page? neotasks.ui.Group.Page|integer
---@param buf?  integer
---@return integer? page index
function Panel:_resolve_page(group, page, buf)
    if buf then
        for i, p in ipairs(group.pages) do
            if p.buf == buf then return i end
        end
        return nil
    end
    if type(page) == "number" then
        return (page >= 1 and page <= #group.pages) and page or nil
    end
    if type(page) == "table" then
        for i, p in ipairs(group.pages) do
            if p == page then return i end
        end
    end
    return nil
end

--- Show a group, opening the panel in this tabpage if it is closed.
---@param group neotasks.ui.Group
---@param opts? neotasks.ui.Group.ActivateOpts
function Panel:activate(group, opts)
    opts = opts or {}
    self:open()
    self:_set_active(group, self:_resolve_page(group, opts.page, opts.buf))
    self:_show_active()
    self:_refresh_winbar()
    local win = opts.enter and self:win() or nil
    if win then vim.api.nvim_set_current_win(win) end
end

-- Group notifications

---@param group neotasks.ui.Group
function Panel:_group_added(group)
    self._groups[#self._groups + 1] = group

    local takeover = self:_should_takeover(group)

    if not self:is_open() then
        -- open() picks an active group itself when there is none; setting ours
        -- first keeps that choice consistent with the takeover decision.
        if takeover then self:_set_active(group) end
        self:open()
    end

    if takeover then
        self:_set_active(group)
        if group.focus == "always" then self._follow = group end
        self:_show_active()
    end
    self:_refresh_winbar()
end

---@param group neotasks.ui.Group
function Panel:_group_changed(group)
    -- A followed group stops overriding the focus guard once it finishes, so its
    -- final update does not disturb someone working in the panel.
    if self._follow == group and not group:is_busy() then
        self._follow = nil
    end
    self:_refresh_winbar()
end

---@param group neotasks.ui.Group
function Panel:_group_removed(group)
    local idx
    for i, g in ipairs(self._groups) do
        if g == group then
            idx = i
            break
        end
    end
    if not idx then return end

    table.remove(self._groups, idx)
    self._by_id[group.id] = nil
    if self._follow == group then self._follow = nil end
    for _, page in ipairs(group.pages) do
        self._unread[page.buf] = nil
    end

    if self._active == group then
        -- Prefer the tab that slid into this slot, the way closing a tab works
        -- everywhere else; fall back to the newest.
        self:_set_active(self._groups[idx] or self._groups[#self._groups])
        -- Synchronous: the windows must leave the buffer before a caller that is
        -- cleaning this group deletes it.
        self:_show_active()
    end
    self:_refresh_winbar()
end

---@param group neotasks.ui.Group
---@param page  neotasks.ui.Group.Page
---@param force boolean  caller insists this page goes on screen
function Panel:_page_added(group, page, force)
    self:_attach_buf(page.buf)

    if force then
        self:activate(group, { page = page })
        return
    end
    if group == self._active and self:_may_follow(group) then
        self:_advance_best()
        self:_show_active()
    end
    self:_refresh_winbar()
end

---@param group neotasks.ui.Group
---@param page  neotasks.ui.Group.Page
function Panel:_page_removed(group, page)
    self._unread[page.buf] = nil

    if group == self._active then
        if self._active_page > #group.pages then
            self._active_page = #group.pages
        end
        self:_show_active()
    end

    if group.remove_when_empty and #group.pages == 0 then
        group:remove()
        return
    end
    self:_refresh_winbar()
end

-- Creating groups

--- Create a tab in the panel.
---
--- Reusing an existing `id` returns that group instead of creating a second one,
--- so a caller can call this idempotently for a long-lived tab.
---@param spec? neotasks.ui.GroupSpec
---@return neotasks.ui.Group
function Panel:group(spec)
    spec = spec or {}
    if spec.id and self._by_id[spec.id] then
        return self._by_id[spec.id]
    end

    if not spec.id then
        self._seq = self._seq + 1
        spec = vim.tbl_extend("force", spec, {
            id = string.format("neotasks#%d", self._seq),
        })
    end

    local group = Group.new(self, spec)
    self._by_id[group.id] = group
    self:_group_added(group)
    return group
end

-- Rendering

---@return neotasks.ui.winbar.Tab[], neotasks.ui.panel.Target[]
function Panel:_build_tabs()
    local tabs, targets = {}, {}

    for _, group in ipairs(self._groups) do
        local badge  = group.badge

        local unread = false
        for _, page in ipairs(group.pages) do
            if self._unread[page.buf] then unread = true end
        end

        ---@type neotasks.ui.winbar.Tab
        local tab = {
            label   = group.label,
            icon    = badge and badge.icon,
            icon_hl = badge and badge.hl,
            active  = group == self._active,
            unread  = unread,
            pages   = {},
        }

        -- A single page needs no page tab: the group tab already selects it, and
        -- takes the number. Once there are page tabs they are what you select,
        -- so the group tab is a heading: no number, and nothing to click.
        if #group.pages > 1 then
            for pi, page in ipairs(group.pages) do
                local page_num    = #targets + 1
                targets[page_num] = { group = group, page = pi }
                tab.pages[#tab.pages + 1] = {
                    num     = page_num,
                    label   = page.label,
                    current = tab.active and pi == self._active_page,
                    unread  = self._unread[page.buf] or false,
                }
            end
            -- page tabs carry the unread markers; don't double up on the group tab
            tab.unread = false
        else
            local tab_num    = #targets + 1
            targets[tab_num] = { group = group, page = 0 }
            tab.num          = tab_num
        end

        tabs[#tabs + 1] = tab
    end

    return tabs, targets
end

function Panel:_refresh_winbar()
    local wins = self:wins()
    if next(wins) == nil then return end

    local tabs, targets = self:_build_tabs()
    self._targets       = targets

    -- One tab bar, rendered per window: the content is shared, but the width to
    -- crop it to is whatever that tabpage's panel happens to be.
    for _, win in pairs(wins) do
        local text = winbar.build(tabs, vim.api.nvim_win_get_width(win), {
            separator  = config.panel.winbar.separator,
            unread     = config.panel.winbar.unread,
            numbers    = config.panel.winbar.numbers,
            click      = "v:lua.__neotasks_panel_click",
            empty_text = config.panel.empty_text,
        })

        -- 'winbar' is global-local: `vim.wo[win].winbar = …` would also write the
        -- hidden global value, and every window without a local winbar would start
        -- rendering the panel's. Keep it local.
        uiutil.win_setlocal(win, "winbar", text)
    end
end

-- Navigation

--- Select the nth tab. Numbering is flat across the whole winbar: one
--- sequential number per selectable tab, which is the group tab for a
--- single-page group and each page tab for a group with several.
---@param n     integer
---@param opts? { enter?: boolean }
---@return boolean ok
function Panel:jump(n, opts)
    self:open()
    local _, targets = self:_build_tabs()
    self._targets    = targets

    local target = targets[n]
    if not target then return false end

    self:_set_active(target.group, target.page ~= 0 and target.page or nil)
    self:_show_active()
    self:_refresh_winbar()
    local win = opts and opts.enter and self:win() or nil
    if win then vim.api.nvim_set_current_win(win) end
    return true
end

--- Step through the flat tab numbering, wrapping at both ends.
---@param delta integer
---@param opts? { enter?: boolean }
function Panel:cycle(delta, opts)
    self:open()
    local _, targets = self:_build_tabs()
    self._targets    = targets
    if #targets == 0 then return end

    local cur = 1
    for i, t in ipairs(targets) do
        if t.group == self._active and (t.page == self._active_page or t.page == 0) then
            cur = i
            -- an exact page match beats the group-tab fallback
            if t.page == self._active_page then break end
        end
    end

    self:jump((cur - 1 + delta) % #targets + 1, opts)
end

-- Queries

--- Every registered group, oldest first.
---@return neotasks.ui.Group[]
function Panel:groups()
    return vim.list_slice(self._groups)
end

---@return neotasks.ui.Group?
function Panel:active()
    return self._active
end

--- The group a winbar number selects, for commands that act on one tab.
---@param n integer
---@return neotasks.ui.Group?
function Panel:group_at(n)
    local _, targets = self:_build_tabs()
    local target     = targets[n]
    return target and target.group or nil
end

-- Winbar click handler. The `%N@fn@` syntax needs a global, and there is exactly
-- one panel, so a single global is enough.
---@param num integer
function _G.__neotasks_panel_click(num)
    Panel.get():jump(num)
end

-- Public facade: the handful of entry points callers outside this module use.

local M = {}

---@return neotasks.ui.panel
function M.get()
    return Panel.get()
end

--- Show the panel in the current tabpage.
---@param opts? { enter?: boolean }
---@return boolean ok  false when the editor has no room for the split
function M.open(opts)
    local ok, err = Panel.get():open(opts)
    if not ok then
        require("neotasks.ui").notify_warning("cannot open panel: " .. (err or "not enough room"))
    end
    return ok
end

--- Hide the panel in the current tabpage; `{ all = true }` hides it in every one.
---@param opts? { all?: boolean }
function M.close(opts)
    Panel.get():close(opts)
end

---@param opts? { enter?: boolean }
---@return boolean ok  false when opening was asked for and there was no room
function M.toggle(opts)
    local ok, err = Panel.get():toggle(opts)
    if not ok then
        require("neotasks.ui").notify_warning("cannot open panel: " .. (err or "not enough room"))
    end
    return ok
end

--- Select the nth tab (see `Panel:jump`).
---@param n     integer
---@param opts? { enter?: boolean }
---@return boolean ok
function M.jump(n, opts)
    return Panel.get():jump(n, opts)
end

--- Step through the flat tab numbering, wrapping at both ends.
---@param delta integer
---@param opts? { enter?: boolean }
function M.cycle(delta, opts)
    Panel.get():cycle(delta, opts)
end

return M
