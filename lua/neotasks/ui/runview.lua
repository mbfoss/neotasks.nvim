---@brief The presentation layer for task runs.
---
---Every run gets its own scratch log buffer holding its timestamped progress
---report, plus whatever buffers its task type spawns (terminals, output). Where
---those buffers are shown depends on what is installed:
---
---  * [dock.nvim](https://github.com/mbfoss/dock.nvim) — each run becomes a dock
---    group (a tab) with the log buffer and the task's buffers as its pages, and
---    dock owns the window, the tab bar and the numbering.
---  * otherwise — a single bottom split
---    ([output_win](lua/neotasks/ui/output_win.lua)) holding the
---    highest-priority buffer of whatever is running.
---
---This module is the only subscriber to the runner's signals; it is loaded with
---the user command, so a run is captured whether or not the view is on screen.

local exec       = require("neotasks.runner.exec")
local output_win = require("neotasks.ui.output_win")
local uiutil     = require("neotasks.util.ui")

---@class neotasks.ui.runview
local M          = {}

-- dock.nvim is optional, so its own types are not resolvable from this plugin
-- alone. These declare the slice of its API used here; dock.nvim documents the
-- full contract (its Source, Group and Badge types).
---@class neotasks.ui.DockBadge
---@field icon string
---@field hl   string

---@class neotasks.ui.DockGroup
---@field page       fun(self, spec: { buf: integer, label?: string, priority?: integer })
---@field set_badge  fun(self, badge: neotasks.ui.DockBadge?)
---@field set_busy   fun(self, busy: boolean)
---@field is_removed fun(self): boolean
---@field remove     fun(self)

---@class neotasks.ui.DockSource
---@field group fun(self, spec: table): neotasks.ui.DockGroup

---Cap on a log buffer's line count; `_append` trims oldest lines past this.
local _MAX_LOG_LINES = 10000

---One run's view: its log buffer, the dock group when dock.nvim is present, and
---the task buffers already registered for display.
---@class neotasks.ui.runview.View
---@field run_id  string
---@field log_buf integer
---@field group   neotasks.ui.DockGroup?
---@field bufs    table<integer, true>  task buffers already shown

---@type table<string, neotasks.ui.runview.View>
local _views     = {}

-- dock.nvim backend

---@type neotasks.ui.DockSource?
local _source    = nil

---The dock source, or nil when dock.nvim is not installed. Resolved once and
---kept: a plugin that appears mid-session is picked up on the next new run.
---@return neotasks.ui.DockSource?
local function _dock_source()
    if _source then return _source end
    local ok, dock = pcall(require, "dock")
    if not ok or type(dock) ~= "table" or type(dock.source) ~= "function" then
        return nil
    end
    _source = dock.source("neotasks")
    return _source
end

---@return table? dock  the dock module, when installed
local function _dock()
    if _source then return require("dock") end
    local ok, dock = pcall(require, "dock")
    return ok and dock or nil
end

-- Badges are constant per state: dock compares them by identity, so reusing the
-- same table keeps a no-op `set_badge` from redrawing the tab bar.
---@type table<neotasks.TaskState, neotasks.ui.DockBadge>
local _BADGE     = {
    running = { icon = "▶", hl = "DockBadgeHint" },
    waiting = { icon = "⧗", hl = "DockBadgeHint" },
    ok      = { icon = "✓", hl = "DockBadgeOk" },
    failed  = { icon = "✗", hl = "DockBadgeErr" },
    stopped = { icon = "✗", hl = "DockBadgeWarn" },
    idle    = { icon = "●", hl = "DockBadgeMuted" },
}

---Whether a run is still going. Mirrored onto the group's `busy` flag, which is
---presentation only — dock prefers a working tab when picking what to show. Its
---disposal gate is `can_dispose`, answered by the runner itself.
---@param state neotasks.TaskState
---@return boolean
local function _is_active(state)
    return state == "running" or state == "waiting"
end

-- Log buffer

---@param run_id string
---@return integer bufnr
local function _create_log_buf(run_id)
    local buf = uiutil.create_scratch_buffer(true, {
        bufhidden  = "hide",
        modifiable = false,
    })
    -- Listed and named after its run the way nvim names a terminal, no slash to
    -- read as a path: `neotasks://build#1:log`. Run ids are unique and the
    -- buffer dies with its run, so the name is free.
    pcall(vim.api.nvim_buf_set_name, buf, "neotasks://" .. run_id .. ":log")
    return buf
end

---A scratch buffer always holds at least one line, so emptiness is that single
---line being blank.
---@param buf integer
---@return boolean
local function _buf_empty(buf)
    return vim.api.nvim_buf_line_count(buf) == 1
        and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

---Append lines to a log buffer, trimming the oldest past `_MAX_LOG_LINES` so it
---never grows unbounded, and keeping any window parked on the last line there.
---@param buf   integer
---@param lines string[]
local function _append(buf, lines)
    if #lines == 0 or not vim.api.nvim_buf_is_valid(buf) then return end

    local before           = vim.api.nvim_buf_line_count(buf)
    local empty            = _buf_empty(buf)

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, empty and 0 or -1, -1, false, lines)
    local overflow = vim.api.nvim_buf_line_count(buf) - _MAX_LOG_LINES
    if overflow > 0 then
        vim.api.nvim_buf_set_lines(buf, 0, overflow, false, {})
    end
    vim.bo[buf].modifiable = false

    -- Follow the tail only for a window already sitting on it, so a user who
    -- scrolled back keeps their place.
    local last = vim.api.nvim_buf_line_count(buf)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf
            and vim.api.nvim_win_get_cursor(win)[1] >= before then
            pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
        end
    end
end

---Render one progress event: a timestamp on the first line, its continuation
---lines indented to match.
---@param event neotasks.ProgressEvent
---@return string[]
local function _event_lines(event)
    local prefix = "[" .. os.date("%H:%M:%S", event.time) .. "] "
    local out    = {}
    for i, line in ipairs(vim.split(event.message, "\n", { plain = true })) do
        out[#out + 1] = (i == 1 and prefix or string.rep(" ", #prefix)) .. line
    end
    return out
end

-- Views

---@param run_id string
---@param entry  neotasks.RunEntry
---@return neotasks.ui.runview.View
local function _ensure_view(run_id, entry)
    local view = _views[run_id]
    if view and vim.api.nvim_buf_is_valid(view.log_buf) then return view end

    local log_buf = _create_log_buf(run_id)
    -- Replay whatever the run reported before this view existed.
    local lines   = {}
    for _, event in ipairs(entry.reports) do
        vim.list_extend(lines, _event_lines(event))
    end
    _append(log_buf, lines)

    view = { run_id = run_id, log_buf = log_buf, bufs = {} }

    local source = _dock_source()
    if source then
        -- `:Dock clean` asks the tab to shed itself; the answer is the runner's,
        -- since it owns the run. A finished run is disposed — which deletes its
        -- buffers and comes back as the dispose signal that drops this group and
        -- the log — and a running one simply keeps its tab.
        view.group = source:group({
            id       = run_id,
            label    = entry.task_name,
            badge    = _BADGE[entry.state] or _BADGE.idle,
            busy     = _is_active(entry.state),
            -- The run the user asked for takes the panel even while they work
            -- inside it (dock's default lets a restart lose it); a dependency
            -- never takes it, so a failure leaves them on the task they ran.
            focus    = entry.primary and "always" or "never",
            on_clean = function(group)
                local ok = exec.dispose(run_id)
                -- A tab whose run the runner has already forgotten has nothing
                -- left to tear down; it is stale rather than kept, so it goes.
                if not ok and not exec.get_all()[run_id] then group:remove() end
            end,
        })
        -- Ranked below every task buffer so the run's own output wins the panel
        -- as soon as there is any; until then the log is what there is to show.
        view.group:page({ buf = log_buf, label = "log", priority = -1 })
    else
        -- The split's counterpart of the group above: same run, same ranking,
        -- and the same rule that a dependency never takes it over.
        output_win.add(log_buf, {
            group      = run_id,
            priority   = -1,
            background = not entry.primary,
        })
    end

    _views[run_id] = view
    return view
end

---@param run_id string
---@param entry  neotasks.RunEntry
local function _on_state_change(run_id, entry)
    local view = _ensure_view(run_id, entry)

    if view.group and not view.group:is_removed() then
        view.group:set_badge(_BADGE[entry.state] or _BADGE.idle)
        view.group:set_busy(_is_active(entry.state))
    end

    for _, be in ipairs(entry.bufnrs) do
        if not view.bufs[be.bufnr] and vim.api.nvim_buf_is_valid(be.bufnr) then
            view.bufs[be.bufnr] = true
            -- A view built on a dock group stays on dock even once the group is
            -- gone; falling back to the split here would mix the two backends.
            if view.group then
                if not view.group:is_removed() then
                    view.group:page({ buf = be.bufnr, label = be.label, priority = be.priority })
                end
            else
                output_win.add(be.bufnr, {
                    group      = run_id,
                    priority   = be.priority,
                    background = not entry.primary,
                })
            end
        end
    end
end

---@param run_id string
---@param event  neotasks.ProgressEvent
local function _on_report(run_id, event)
    local view = _views[run_id]
    if not view then return end
    _append(view.log_buf, _event_lines(event))
end

---The run is gone: drop its tab before its buffers are deleted (the runner
---deletes them right after this), then wipe the log buffer it owns.
---@param run_id string
local function _on_dispose(run_id)
    local view = _views[run_id]
    if not view then return end
    _views[run_id] = nil

    if view.group and not view.group:is_removed() then
        view.group:remove()
    end
    if vim.api.nvim_buf_is_valid(view.log_buf) then
        if not view.group then output_win.remove(view.log_buf) end
        pcall(vim.api.nvim_buf_delete, view.log_buf, { force = true })
    end
end

local _subscribed = false

---Start following the runner. Idempotent, and called by `commands.register`, so
---every run is captured whether or not the view is on screen.
function M.setup()
    if _subscribed then return end
    _subscribed = true
    exec.on_state_change(_on_state_change)
    exec.on_report(_on_report)
    exec.on_dispose(_on_dispose)
end

-- Public API

---Show the view without taking the cursor.
function M.open()
    local dock = _dock()
    if dock then
        dock.open()
    else
        output_win.open(false)
    end
end

---Toggle the view, focusing it when it opens.
function M.toggle()
    local dock = _dock()
    if dock then
        dock.toggle({ enter = true })
        return
    end
    -- The plain split has no placeholder to show, so an empty one would just be
    -- a blank window the user has to close again.
    if not output_win.is_open() and not output_win.has_content() then
        require("neotasks.ui").notify_warning("no task output yet")
        return
    end
    output_win.toggle(true)
end

return M
