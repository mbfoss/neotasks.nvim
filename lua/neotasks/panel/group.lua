---@brief One run's tab in the output panel.

---@class neotasks.panel.Badge
---@field icon  string    single-cell glyph shown before the tab label
---@field hl    string    highlight group for the glyph

--- A group is one tab in the panel: a label, an optional badge, and an ordered
--- list of pages (buffers). The panel mutates it through these methods; every
--- mutator notifies the panel so the winbar and the displayed buffer stay in
--- sync. A group outlives the panel window: closing the panel does not discard
--- it, and re-opening restores every tab.
---@class neotasks.panel.Group
---@field id                string
---@field label             string
---@field pages             neotasks.panel.Group.Page[]
---@field focus             "auto"|"never"|"always"
---@field badge             neotasks.panel.Badge?   glyph drawn before the tab label; none when nil
---@field busy              boolean               the group is still working
---@field remove_when_empty boolean               drop the tab once its last page goes away
---@field _panel            neotasks.panel.Panel
---@field _removed          boolean
local Group = {}
Group.__index = Group

---@class neotasks.panel.Group.Page
---@field buf      integer
---@field label    string
---@field priority integer  highest-priority page wins when the panel auto-advances

---@class neotasks.panel.GroupSpec
---@field id?                string                  stable id for panel:group(); defaults to a generated one
---@field label?             string                  tab text; defaults to the id
---@field badge?             neotasks.panel.Badge       glyph drawn before the tab label
---@field busy?              boolean                 the group is still working; default false
---@field focus?             "auto"|"never"|"always" how eagerly the tab takes over the panel; default "auto"
---@field remove_when_empty? boolean

--- A label is drawn in the winbar, and the winbar measures it with
--- `strdisplaywidth`, so anything but a string dies with E730 on the render path
--- -- long after, and far from, the call that passed it.
---@param what  string
---@param value any
local function assert_label(what, value)
    assert(type(value) == "string", ("neotasks: %s must be a string"):format(what))
end

---@param panel neotasks.panel.Panel
---@param spec  neotasks.panel.GroupSpec
---@return neotasks.panel.Group
function Group.new(panel, spec)
    if spec.label ~= nil then assert_label("group label", spec.label) end
    return setmetatable({
        id                = spec.id,
        label             = spec.label or spec.id,
        badge             = spec.badge,
        busy              = spec.busy or false,
        focus             = spec.focus or "auto",
        pages             = {},
        remove_when_empty = spec.remove_when_empty or false,
        _panel            = panel,
        _removed          = false,
    }, Group)
end

--- True while the group is still working. Presentation only: the panel prefers
--- a busy tab when it has to pick one to show.
---@return boolean
function Group:is_busy()
    return self.busy
end

---@param busy boolean
---@return neotasks.panel.Group self
function Group:set_busy(busy)
    busy = busy and true or false
    if self.busy ~= busy then
        self.busy = busy
        self._panel:_group_changed(self)
    end
    return self
end

---@return boolean
function Group:is_removed()
    return self._removed
end

---@class neotasks.panel.Group.PageSpec
---@field buf       integer
---@field label?    string   defaults to the buffer's basename, else "buf N"
---@field priority? integer  default 0
---@field activate? boolean  force this page on screen, bypassing the priority comparison

--- Append a page (buffer) to the group.
---
--- The panel advances to it only when it outranks whatever is on screen, so a
--- low-priority log buffer can be added without yanking the user off the output
--- they are reading. Pass `activate = true` to insist.
---@param spec neotasks.panel.Group.PageSpec
---@return neotasks.panel.Group.Page?
function Group:page(spec)
    if self._removed then return nil end
    assert(type(spec.buf) == "number", "neotasks: page requires a buffer number")
    if spec.label ~= nil then assert_label("page label", spec.label) end
    assert(spec.priority == nil or type(spec.priority) == "number",
        "neotasks: page priority must be a number")
    if not vim.api.nvim_buf_is_valid(spec.buf) then return nil end

    for _, p in ipairs(self.pages) do
        if p.buf == spec.buf then
            -- Re-adding a buffer the group already has keeps the existing page,
            -- but `activate` is a request to put it on screen: a duplicate is no
            -- reason to drop it.
            if spec.activate then self._panel:activate(self, { page = p }) end
            return p
        end
    end

    local name = vim.api.nvim_buf_get_name(spec.buf)
    ---@type neotasks.panel.Group.Page
    local page = {
        buf      = spec.buf,
        label    = spec.label
            or (name ~= "" and vim.fn.fnamemodify(name, ":t"))
            or ("buf " .. spec.buf),
        priority = spec.priority or 0,
    }
    self.pages[#self.pages + 1] = page
    self._panel:_page_added(self, page, spec.activate == true)
    return page
end

--- Remove a page. Never touches the buffer itself: buffers are owned by the
--- source that created them.
---@param page neotasks.panel.Group.Page|integer  a page, or the buffer number of one
---@return boolean removed
function Group:remove_page(page)
    local buf = type(page) == "number" and page or page.buf
    for i, p in ipairs(self.pages) do
        if p.buf == buf then
            table.remove(self.pages, i)
            self._panel:_page_removed(self, p)
            return true
        end
    end
    return false
end

---@param label string
---@return neotasks.panel.Group self
function Group:set_label(label)
    assert_label("group label", label)
    if self.label ~= label then
        self.label = label
        self._panel:_group_changed(self)
    end
    return self
end

---@param badge neotasks.panel.Badge?  nil draws the tab without a glyph
---@return neotasks.panel.Group self
function Group:set_badge(badge)
    if self.badge ~= badge then
        self.badge = badge
        self._panel:_group_changed(self)
    end
    return self
end

---@class neotasks.panel.Group.ActivateOpts
---@field page?  neotasks.panel.Group.Page|integer  a page, or its 1-based index; defaults to the group's best page
---@field buf?   integer                  select the page showing this buffer; takes precedence over `page`
---@field enter? boolean                  move the cursor into the panel window

--- Put this group on screen, opening the panel if needed.
---@param opts? neotasks.panel.Group.ActivateOpts
---@return neotasks.panel.Group self
function Group:activate(opts)
    if not self._removed then
        self._panel:activate(self, opts)
    end
    return self
end

--- Detach the group from the panel. Buffers are left alone: the run owns them.
function Group:remove()
    if self._removed then return end
    self._removed = true
    self._panel:_group_removed(self)
end

return Group
