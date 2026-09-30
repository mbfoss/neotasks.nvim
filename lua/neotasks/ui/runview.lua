---@brief The presentation layer for task runs.
---
---Every run gets its own scratch log buffer holding its timestamped progress
---report, plus whatever buffers its task type spawns (terminals, output), all
---shown in the built-in output panel (see
---[panel.lua](lua/neotasks/ui/panel.lua)): the run becomes a numbered tab with a
---status badge, and its log and task buffers become the tab's pages. The panel
---owns the window, the tab bar and the numbering.
---
---This module is the only subscriber to the runner's signals; it is loaded with
---the user command, so a run is captured whether or not the view is on screen.

local exec   = require("neotasks.runner.exec")
local panel  = require("neotasks.ui.panel")
local uiutil = require("neotasks.util.ui")

---@class neotasks.ui.runview
local M      = {}

---Cap on a log buffer's line count; `_append` trims oldest lines past this.
local _MAX_LOG_LINES = 10000

---One run's view: its log buffer, its panel group, and the task buffers already
---registered for display.
---@class neotasks.ui.runview.View
---@field run_id  string
---@field log_buf integer
---@field group   neotasks.ui.Group
---@field bufs    table<integer, true>  task buffers already shown

---@type table<string, neotasks.ui.runview.View>
local _views     = {}

-- Badges are constant per state: the panel compares them by identity, so reusing
-- the same table keeps a no-op `set_badge` from redrawing the tab bar.
---@type table<neotasks.TaskState, neotasks.ui.Badge>
local _BADGE     = {
    running = { icon = "▶", hl = "NeotasksBadgeHint" },
    waiting = { icon = "⧗", hl = "NeotasksBadgeHint" },
    ok      = { icon = "✓", hl = "NeotasksBadgeOk" },
    failed  = { icon = "✗", hl = "NeotasksBadgeErr" },
    stopped = { icon = "✗", hl = "NeotasksBadgeWarn" },
    idle    = { icon = "●", hl = "NeotasksBadgeMuted" },
}

---Whether a run is still going. Mirrored onto the group's `busy` flag, which is
---presentation only - the panel prefers a working tab when picking what to show.
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

    -- The run the user asked for takes the panel even while they work inside it
    -- (the panel's default focus lets a restart lose it); a dependency never
    -- takes it, so a failure leaves them on the task they ran.
    local group = panel.get():group({
        id    = run_id,
        label = entry.task_name,
        badge = _BADGE[entry.state] or _BADGE.idle,
        busy  = _is_active(entry.state),
        focus = entry.primary and "always" or "never",
    })
    -- Ranked below every task buffer so the run's own output wins the panel as
    -- soon as there is any; until then the log is what there is to show.
    group:page({ buf = log_buf, label = "log", priority = -1 })

    view = { run_id = run_id, log_buf = log_buf, group = group, bufs = {} }
    _views[run_id] = view
    return view
end

---@param run_id string
---@param entry  neotasks.RunEntry
local function _on_state_change(run_id, entry)
    local view = _ensure_view(run_id, entry)

    if not view.group:is_removed() then
        view.group:set_badge(_BADGE[entry.state] or _BADGE.idle)
        view.group:set_busy(_is_active(entry.state))
    end

    for _, be in ipairs(entry.bufnrs) do
        if not view.bufs[be.bufnr] and vim.api.nvim_buf_is_valid(be.bufnr) then
            view.bufs[be.bufnr] = true
            if not view.group:is_removed() then
                view.group:page({ buf = be.bufnr, label = be.label, priority = be.priority })
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

    if not view.group:is_removed() then
        view.group:remove()
    end
    if vim.api.nvim_buf_is_valid(view.log_buf) then
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

---Show the panel without taking the cursor.
function M.open()
    panel.open()
end

---Toggle the panel, focusing it when it opens.
function M.toggle()
    panel.toggle({ enter = true })
end

return M
