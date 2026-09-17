---@brief The single split that shows a run's buffer, used when dock.nvim is not
---installed.
---
---A run registers its log buffer and every buffer its task type spawns here
---under its own group. One window is reused for all of them: registering a
---buffer swaps the occupant rather than opening a second split. There is no tab
---bar — `neotasks.ui.runview` hands the tabbed presentation to dock.nvim when
---it is available.
---
---The window is ours only while it holds one of those buffers, the way a window
---is the quickfix window only while it holds the quickfix buffer: switch it to
---anything else and it is the user's, and the next buffer opens a fresh split.
---
---What the window holds is the newest group's best buffer, mirroring the tab
---dock would raise: a group is ranked first by how recently it was registered
---into, then by priority among its own buffers. Priority alone cannot say both
---"show the run I just started" and "within a run, output beats the log" — with
---one ranking, a run that fails before spawning anything leaves its log, ranked
---below every task buffer, stuck behind an unrelated run's terminal.

local fixedwin      = require("neotasks.util.fixedwin")
local _ui_util      = require("neotasks.util.ui")

---@class neotasks.ui.output_win
local M             = {}

---One buffer registered for display.
---@class neotasks.ui.output_win.Entry
---@field bufnr      integer
---@field group      string   the run this buffer belongs to
---@field background boolean  never takes the window from another group
---@field priority   integer  rank among the buffers of the same group
---@field seq        integer  registration order; breaks ties toward the newest

---@type neotasks.ui.output_win.Entry[]
local _entries      = {}
local _seq          = 0

---@type integer?
local _win          = nil
---fixedwin's autocmd group for `_win`, torn down when the window stops being
---ours so it no longer holds the user's window to our height.
---@type integer?
local _fixed_group  = nil
---@type integer?
local _shown        = nil
---The buffer the window held when it was closed, live only for the tick of the
---close: nvim closes the window before announcing the buffer's deletion, so this
---is how `refresh` tells that close apart from the user closing the window.
---@type integer?
local _closed_with  = nil
---@type number?
local _ratio        = nil

local _HEIGHT_RATIO = 0.22
local _MIN_HEIGHT   = 6

local _augroup      = vim.api.nvim_create_augroup("neotasks.output_win", { clear = true })

---Drop `bufnr`, plus any entry whose buffer is already gone. Buffer numbers are
---reused, so a stale entry eventually names an unrelated buffer.
---@param bufnr? integer  a buffer being deleted, still valid at this point
local function _prune(bufnr)
    for i = #_entries, 1, -1 do
        local b = _entries[i].bufnr
        if b == bufnr or not vim.api.nvim_buf_is_valid(b) then
            table.remove(_entries, i)
        end
    end
end

---The buffer the window should hold: from the group registered into most
---recently, its highest-priority buffer — the newest of those on a tie. A
---background group only wins when every group is one.
---@return integer?  bufnr
local function _target()
    ---@type table<string, integer>
    local recency = {}
    for _, e in ipairs(_entries) do
        if not recency[e.group] or e.seq > recency[e.group] then
            recency[e.group] = e.seq
        end
    end

    ---@param e    neotasks.ui.output_win.Entry
    ---@param best neotasks.ui.output_win.Entry
    ---@return boolean
    local function outranks(e, best)
        if e.background ~= best.background then return best.background end
        if recency[e.group] ~= recency[best.group] then
            return recency[e.group] > recency[best.group]
        end
        if e.priority ~= best.priority then return e.priority > best.priority end
        return e.seq > best.seq
    end

    local best ---@type neotasks.ui.output_win.Entry?
    for _, e in ipairs(_entries) do
        if not best or outranks(e, best) then best = e end
    end
    return best and best.bufnr
end

---@param bufnr integer
---@return boolean  whether the buffer is one of ours
local function _is_registered(bufnr)
    for _, e in ipairs(_entries) do
        if e.bufnr == bufnr then return true end
    end
    return false
end

---Give the window back to the user, Like a quickfix window turned ordinary
local function _disown()
    local win = _win
    _win, _shown = nil, nil
    if win and vim.api.nvim_win_is_valid(win) then
        -- fixedwin may have moved the pin to the width (window moved to the side)
        if vim.wo[win].winfixwidth then
            _ratio = vim.api.nvim_win_get_width(win) / vim.o.columns
        elseif vim.wo[win].winfixheight then
            _ratio = vim.api.nvim_win_get_height(win) / vim.o.lines
        end
        _ui_util.win_setlocal(win, "spell", nil)
        _ui_util.win_setlocal(win, "winfixheight", nil)
        _ui_util.win_setlocal(win, "winfixwidth", nil)
    end
    if _fixed_group then
        vim.api.nvim_del_augroup_by_id(_fixed_group)
        _fixed_group = nil
    end
end

---The window while it is still ours: valid, and holding one of our buffers. The
---user switching it to a buffer of their own hands it over, so a later `open`
---splits a new one rather than taking theirs.
---@return integer?  the window, when open
local function _open_win()
    if not _win then return nil end
    if vim.api.nvim_win_is_valid(_win) then
        local bufnr = vim.api.nvim_win_get_buf(_win)
        if bufnr == _shown or _is_registered(bufnr) then
            _shown = bufnr
            return _win
        end
    end
    _disown()
    return nil
end

-- Notice the handover as it happens: waiting for the next call into this module
-- would leave fixedwin pinning the height of a window that is no longer ours.
vim.api.nvim_create_autocmd("BufWinEnter", {
    group    = _augroup,
    callback = function() _open_win() end,
})

---@param win   integer  the window, already checked to be ours
---@param bufnr integer
local function _display(win, bufnr)
    if _shown == bufnr then return end
    vim.api.nvim_win_set_buf(win, bufnr)
    _shown = bufnr
    if vim.bo[bufnr].buftype == "terminal" then
        local last = vim.api.nvim_buf_line_count(bufnr)
        pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
    end
end

---Open the window (a no-op when already open) and show the target buffer.
---@param focus? boolean  leave the cursor in the window; default false
function M.open(focus)
    _prune()
    local bufnr = _target()
    if not bufnr then return end
    local win = _open_win()
    if win then
        if focus then vim.api.nvim_set_current_win(win) end
        _display(win, bufnr)
        return
    end
    -- fixedwin owns the split, its height pinning and the resize/ratio tracking;
    -- we only swap in the run's buffer. Its on_delete fires on WinClosed, so
    -- closing by any route — ours, `:q` — records the height and drops the state.
    _win, _fixed_group = fixedwin.create_fixed_win(bufnr, {
        axis = "height", ratio = _ratio or _HEIGHT_RATIO,
        min = _MIN_HEIGHT, enter = focus or false,
        on_delete = function(ratio)
            _ratio       = ratio
            _closed_with = _shown
            _win, _shown = nil, nil
            _fixed_group = nil
            -- Only a deletion of the buffer just closed with reopens the window,
            -- and only on this tick — a `:q` a moment earlier must not.
            vim.schedule(function() _closed_with = nil end)
        end,
    })

    _ui_util.win_setlocal(_win, "spell", false)

    _shown = nil
    _display(_win, bufnr)
end

---Close the window, keeping the registry — the next registered buffer (or an
---explicit `open`) brings it back at the height it was left at.
function M.close()
    local win = _open_win()
    if win then vim.api.nvim_win_close(win, true) end
    _win, _shown = nil, nil
end

---@param focus? boolean  leave the cursor in the window when opening
function M.toggle(focus)
    if _open_win() then M.close() else M.open(focus) end
end

---Bring the window in line with the registry: show the highest-priority live
---buffer, or close once the last buffer is gone. A buffer's deletion takes the
---window with it, so `deleted` reopens it for the next buffer in line.
---@param deleted? integer  a buffer being deleted, to forget before deciding
function M.refresh(deleted)
    _prune(deleted)
    local reopen = deleted ~= nil and deleted == _closed_with
    _closed_with = nil
    local bufnr  = _target()
    local win    = _open_win()
    if not bufnr then
        M.close()
    elseif win then
        _display(win, bufnr)
    elseif reopen then
        M.open(false)
    end
end

---Register a buffer for display. Registering makes its group the most recent, so
---the buffer takes the window unless one of its own group outranks it; the
---window opens on the first registration. `background` is the split's equivalent
---of dock's `focus = "never"`: the group is kept and reachable, but a run the
---user did not launch never pulls the window off the one they did.
---@param bufnr integer
---@param opts? { group?: string, priority?: integer, background?: boolean }
function M.add(bufnr, opts)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    opts        = opts or {}
    _seq        = _seq + 1
    local entry = {
        bufnr      = bufnr,
        group      = opts.group or ("buf:" .. bufnr),
        background = opts.background or false,
        priority   = opts.priority or 0,
        seq        = _seq,
    }

    -- Re-registering a buffer restates its rank rather than adding a second entry
    -- (and a second deletion autocmd) for the same buffer.
    local known = false
    for i, e in ipairs(_entries) do
        if e.bufnr == bufnr then
            _entries[i], known = entry, true
            break
        end
    end
    if not known then
        _entries[#_entries + 1] = entry
        vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
            group    = _augroup,
            buffer   = bufnr,
            once     = true,
            callback = function() M.refresh(bufnr) end,
        })
    end

    M.open(false)
end

---Drop a buffer from the registry without deleting it.
---@param bufnr integer
function M.remove(bufnr)
    M.refresh(bufnr)
end

---Whether any live buffer is registered, i.e. whether there is anything to open
---the window for.
---@return boolean
function M.has_content()
    _prune()
    return #_entries > 0
end

---@return boolean
function M.is_open()
    return _open_win() ~= nil
end

---@return integer? winid  the window, when open
function M.winid()
    return _open_win()
end

return M
