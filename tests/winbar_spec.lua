---@diagnostic disable: undefined-global, undefined-field, need-check-nil
-- Unit tests for the output panel's winbar renderer (lua/neotasks/ui/winbar.lua).
-- build() is pure Lua over a tab list and a width -- the panel supplies the
-- numbers/active/page state -- so it can be exercised without a window. The
-- returned string carries `%#hl#` and `%N@fn@` escapes, so the assertions match
-- visible fragments rather than whole strings.

local winbar = require("neotasks.ui.winbar")

--- The options the panel passes to build().
---@param over? table
---@return table
local function opts(over)
    return vim.tbl_extend("force", {
        separator  = "│",
        unread     = "•",
        numbers    = true,
        click      = "v:lua.__neotasks_panel_click",
        empty_text = "No pages",
    }, over or {})
end

describe("empty", function()
    it("renders the placeholder text when there are no tabs", function()
        local bar = winbar.build({}, 80, opts())
        assert.is_truthy(bar:find("No pages", 1, true))
    end)

    it("honours a custom empty_text", function()
        local bar = winbar.build({}, 80, opts({ empty_text = "nothing here" }))
        assert.is_truthy(bar:find("nothing here", 1, true))
    end)
end)

describe("single page", function()
    it("numbers the group tab and shows its label", function()
        local tabs = { { num = 1, label = "build", active = true, pages = {} } }
        local bar  = winbar.build(tabs, 80, opts())
        assert.is_truthy(bar:find("1:", 1, true))
        assert.is_truthy(bar:find("build", 1, true))
    end)

    it("omits the number when numbers are off", function()
        local tabs = { { num = 1, label = "build", active = true, pages = {} } }
        local bar  = winbar.build(tabs, 80, opts({ numbers = false }))
        assert.is_nil(bar:find("1:", 1, true))
        assert.is_truthy(bar:find("build", 1, true))
    end)

    it("separates adjacent tabs", function()
        local tabs = {
            { num = 1, label = "build", active = true, pages = {} },
            { num = 2, label = "test", pages = {} },
        }
        local bar  = winbar.build(tabs, 80, opts())
        assert.is_truthy(bar:find("│", 1, true))
        assert.is_truthy(bar:find("test", 1, true))
    end)

    it("flags an unread group", function()
        local tabs = { { num = 1, label = "build", active = false, unread = true, pages = {} } }
        local bar  = winbar.build(tabs, 80, opts())
        assert.is_truthy(bar:find("•", 1, true))
    end)
end)

describe("multiple pages", function()
    it("draws bracketed page tabs and drops the group number", function()
        local tabs = { {
            label  = "test",
            active = true,
            pages  = {
                { num = 1, label = "log", current = false, unread = false },
                { num = 2, label = "out", current = true,  unread = false },
            },
        } }
        local bar = winbar.build(tabs, 80, opts())
        assert.is_truthy(bar:find("[", 1, true))
        assert.is_truthy(bar:find("log", 1, true))
        assert.is_truthy(bar:find("out", 1, true))
    end)

    it("flags an unread page", function()
        local tabs = { {
            label  = "test",
            active = true,
            pages  = {
                { num = 1, label = "log", current = true,  unread = false },
                { num = 2, label = "out", current = false, unread = true },
            },
        } }
        local bar = winbar.build(tabs, 80, opts())
        assert.is_truthy(bar:find("•", 1, true))
    end)
end)

describe("overflow", function()
    it("crops a long label with an ellipsis", function()
        local tabs = { { num = 1, label = string.rep("x", 60), active = true, pages = {} } }
        local bar  = winbar.build(tabs, 10, opts())
        assert.is_truthy(bar:find("…", 1, true))
    end)

    it("drops tabs and counts the numbers that went", function()
        local tabs = {}
        for i = 1, 6 do
            tabs[i] = { num = i, label = "aaaaaa", active = i == 1, pages = {} }
        end
        local bar = winbar.build(tabs, 12, opts())
        assert.is_truthy(bar:find("+", 1, true))
    end)
end)
