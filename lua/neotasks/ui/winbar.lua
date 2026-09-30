---@brief Builds the output panel's winbar: a flat, numbered list of tabs that
---fits a given width.
---
---The bar is assembled as a list of items so overflow can be measured before the
---string is produced.
---@class neotasks.ui.winbar
local M = {}

-- Each item is `{ kind, text, tab }`:
--   kind 1: croppable visible text (group and page labels)
--   kind 2: fixed visible text (icons, numbers, punctuation)
--   kind 3: zero-width escapes (highlight groups, click regions)
-- Only kinds 1 and 2 occupy columns, so `%#Group#` / `%N@fn@` runs never skew
-- the width budget.

local _CROP, _FIXED, _ZERO = 1, 2, 3

--- Shortest a cropped label may become before the cropper gives up on it.
local _MIN_LABEL = 2

---@class neotasks.ui.winbar.Page
---@field num     integer  global jump number
---@field label   string
---@field current boolean  currently displayed in the panel
---@field unread  boolean  gained lines while not visible

---@class neotasks.ui.winbar.Tab
---@field num     integer? global jump number for the group's own tab; nil once it
---                       draws page tabs, which carry the numbers instead
---@field label   string
---@field icon    string?  glyph before the label; the tab draws none when nil
---@field icon_hl string?  highlight for `icon`
---@field active  boolean  this group owns the displayed buffer
---@field unread  boolean  unseen output somewhere in the group; only set when it draws no page tabs
---@field pages   neotasks.ui.winbar.Page[]  page tabs; empty when the group has a single page

---@class neotasks.ui.winbar.Opts
---@field separator  string   between adjacent group tabs
---@field unread     string   marker for a page tab with unseen output
---@field numbers    boolean  prefix tabs with their jump number
---@field click      string   vimscript function ref for `%N@…@` click regions
---@field empty_text string   rendered when there are no tabs at all

--- Longest prefix of `text` that fits in `cols` display cells, with an ellipsis
--- when anything had to go. Cropping counts cells, not characters: a label may
--- hold double-width glyphs, and one column of budget is not one character of
--- text, so cropping by character lets the bar run past the width it budgeted.
---@param text string
---@param cols integer
---@return string
local function _crop(text, cols)
    if vim.fn.strdisplaywidth(text) <= cols then return text end

    local budget = cols - vim.fn.strdisplaywidth("…")
    local kept, used = {}, 0
    for _, char in ipairs(vim.fn.split(text, "\\zs")) do
        local w = vim.fn.strdisplaywidth(char)
        if used + w > budget then break end
        kept[#kept + 1] = char
        used           = used + w
    end
    return table.concat(kept) .. "…"
end

---@param items {[1]: integer, [2]: string, [3]: integer?}[]  kind, text, and the tab the item belongs to
---@param width integer
---@param nums  table<integer, integer>  jump numbers each tab contributes
---@return string
local function _flatten(items, width, nums)
    local widths = {} ---@type table<integer, integer>  final width of each visible item
    local total  = 0

    --- Measure every item, then shave the widest croppable labels until the bar
    --- fits `width` or every label is down to the floor, whichever comes first.
    --- Shaving one column at a time off the widest costs a pass per overflowing
    --- column, but keeps short labels legible instead of charging every label an
    --- equal share of the overflow.
    ---@param room integer
    local function fit(room)
        local croppable = {} ---@type integer[]
        widths, total = {}, 0
        for i, it in ipairs(items) do
            if it[1] ~= _ZERO then
                local w = vim.fn.strdisplaywidth(it[2])
                widths[i] = w
                total = total + w
                if it[1] == _CROP then croppable[#croppable + 1] = i end
            end
        end

        while total > room do
            local widest, widest_w = nil, _MIN_LABEL
            for _, i in ipairs(croppable) do
                if widths[i] > widest_w then widest, widest_w = i, widths[i] end
            end
            if not widest then break end
            widths[widest] = widths[widest] - 1
            total = total - 1
        end
    end

    fit(width)

    -- Where each tab's run of items ends, now that the labels have been shaved.
    -- This is the floor width of every prefix, which is what decides whether
    -- dropping a tab can make room at all. The last tab index counts the tabs.
    local end_at, last, seen = {}, 0, 0
    for i, it in ipairs(items) do
        if it[1] ~= _ZERO then seen = seen + widths[i] end
        if it[3] then
            end_at[it[3]] = seen
            last          = it[3]
        end
    end

    -- Every label is at the floor and the bar is still too wide, so cropping has
    -- nothing left to give: Neovim would clip the tail and the newest tabs would
    -- simply not be there, which is a state the user cannot tell from "there is
    -- nothing more". Drop those tabs instead -- they are the ones already past
    -- the edge -- and spend the room on a count of the numbers that went. Trimmed
    -- to fit the marker is visible; left to overflow, it would be clipped too.
    if total > width and last > 1 then
        for dropped = 1, last - 1 do
            local keep = last - dropped
            local gone = 0
            for t = keep + 1, last do gone = gone + (nums[t] or 0) end

            local marker = "+" .. gone
            -- The floor width of what stays has to leave room for the marker:
            -- if it does, no shaving was going to save these tabs.
            if end_at[keep] + vim.fn.strdisplaywidth(marker) <= width then
                for i = #items, 1, -1 do
                    if items[i][3] and items[i][3] > keep then table.remove(items, i) end
                end
                items[#items + 1] = { _ZERO, "%#NeotasksBadgeMuted#" }
                items[#items + 1] = { _FIXED, marker }
                -- Room for labels again: shave afresh rather than keeping the
                -- floor widths the first pass squeezed them to, so a bar with
                -- tabs to spare shows full labels and only counts what it lost.
                fit(width)
                break
            end
        end
    end

    local out = {}
    for i, it in ipairs(items) do
        out[#out + 1] = it[1] == _CROP and _crop(it[2], widths[i]) or it[2]
    end
    return table.concat(out)
end

--- Render the winbar for a set of group tabs, cropping labels to fit `width`.
---@param tabs  neotasks.ui.winbar.Tab[]
---@param width integer
---@param opts  neotasks.ui.winbar.Opts
---@return string
function M.build(tabs, width, opts)
    if #tabs == 0 then
        return "%#WinBar# %#NeotasksBadgeMuted#" .. opts.empty_text .. "%#WinBar#"
    end

    local items = {} ---@type {[1]: integer, [2]: string, [3]: integer?}[]
    -- Every item is tagged with the tab it was drawn for, so a bar too narrow to
    -- hold them all can drop whole tabs rather than clip mid-label (see _flatten).
    local function push(kind, text, tab) items[#items + 1] = { kind, text, tab } end

    ---@param num integer
    ---@param tab integer
    local function open_click(num, tab)
        push(_ZERO, string.format("%%%d@%s@", num, opts.click), tab)
    end
    ---@param tab integer
    local function close_click(tab)
        push(_ZERO, "%X", tab)
    end

    ---@param num integer
    ---@return string
    local function prefix(num)
        return opts.numbers and (num .. ":") or ""
    end

    for ti, tab in ipairs(tabs) do
        local tab_hl = tab.active and "%#NeotasksActiveTab#" or "%#WinBar#"

        if ti > 1 then
            push(_ZERO, "%#NeotasksBadgeMuted#", ti)
            push(_FIXED, opts.separator, ti)
        end
        push(_FIXED, " ", ti)

        -- A group drawing page tabs has no number of its own: the bracketed
        -- numbers are the ones worth reading, and with every page directly
        -- selectable the group tab has nothing left to select. It reads as a
        -- heading for them, so it is not clickable either.
        if tab.num then open_click(tab.num, ti) end
        if tab.icon then
            push(_ZERO, "%#" .. (tab.icon_hl or "WinBar") .. "#", ti)
            push(_FIXED, tab.icon .. " ", ti)
        end
        push(_ZERO, tab_hl, ti)
        if tab.num then push(_FIXED, prefix(tab.num), ti) end
        push(_CROP, tab.label, ti)
        if tab.unread then
            push(_ZERO, "%#NeotasksUnread#", ti)
            push(_FIXED, opts.unread, ti)
        end
        if tab.num then close_click(ti) end

        if #tab.pages > 0 then
            push(_FIXED, " [", ti)
            for pi, page in ipairs(tab.pages) do
                if pi > 1 then
                    push(_ZERO, "%#NeotasksBadgeMuted#", ti)
                    push(_FIXED, "|", ti)
                end
                open_click(page.num, ti)
                -- A page that is neither current nor part of the active group is
                -- muted, so the eye lands on what is actually on screen.
                push(_ZERO, page.current and tab_hl or "%#NeotasksBadgeMuted#", ti)
                push(_FIXED, prefix(page.num), ti)
                push(_CROP, page.label, ti)
                if page.unread then
                    push(_ZERO, "%#NeotasksUnread#", ti)
                    push(_FIXED, opts.unread, ti)
                end
                close_click(ti)
            end
            push(_ZERO, tab_hl, ti)
            push(_FIXED, "]", ti)
        end

        push(_ZERO, "%#WinBar#", ti)
        push(_FIXED, " ", ti)
    end

    -- How many jump numbers each tab is worth: a group drawing page tabs
    -- contributes one per page, since those are the numbers in the bar.
    local nums = {} ---@type table<integer, integer>
    for ti, tab in ipairs(tabs) do
        nums[ti] = tab.num and 1 or #tab.pages
    end

    return _flatten(items, width, nums)
end

return M
