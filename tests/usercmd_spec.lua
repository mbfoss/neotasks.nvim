local usercmd = require("neotasks.util.usercmd")

describe("usercmd.complete", function()
    before_each(function()
        vim.api.nvim_create_user_command("NeotasksSpec", function() end, { nargs = "*" })
    end)

    local function subcommand_for(seen)
        return function(cmd, rest, arg_lead)
            seen.cmd, seen.rest, seen.arg_lead = cmd, rest, arg_lead
            return {}
        end
    end

    it("keeps an escaped trailing space in the argument being completed", function()
        -- Regression: `a\ ` is one argument, not a completed argument plus a
        -- separator, so no parsed argument is context for the completion.
        local seen = {}
        usercmd.complete("a\\ ", "NeotasksSpec a\\ ", subcommand_for(seen))
        assert.same({}, seen.rest)
        assert.equals("a\\ ", seen.arg_lead)
    end)

    it("treats an in-progress argument as the one being completed", function()
        local seen = {}
        usercmd.complete("ru", "NeotasksSpec ru", subcommand_for(seen))
        assert.same({}, seen.rest)
        assert.equals("ru", seen.arg_lead)
    end)

    it("treats an unescaped trailing space as a new argument", function()
        local seen = {}
        usercmd.complete("", "NeotasksSpec a ", subcommand_for(seen))
        assert.same({ "a" }, seen.rest)
    end)
end)
