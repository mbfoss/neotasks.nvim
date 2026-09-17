---@class neotasks.util.throttle
local M = {}

local _uv = vim.uv

---@return boolean
local function _is_exiting()
    return vim.v.exiting ~= vim.NIL
end

---Create a throttled wrapper around a function.
---
---The wrapped function executes immediately on the first call, then
---suppresses subsequent calls until the throttle window has elapsed.
---If calls occur during the cooldown period, exactly one trailing
---execution is scheduled.
---
---  - Leading execution: yes
---  - Trailing execution: yes (single queued run)
---  - Re-entrant calls during cooldown are ignored once a timer exists
---
---Used by the output panel to coalesce the winbar redraws driven by buffer
---output, so a task printing in a tight loop does not repaint the tab bar on
---every line.
---@param ms number Throttle interval in milliseconds.
---@param fn function Function to throttle.
---@return function wrapped Throttled wrapper function.
function M.throttle_wrap(ms, fn)
    local timer = nil
    local last_exec = 0

    return function()
        local now = _uv.now()

        local function run()
            last_exec = _uv.now()
            if not _is_exiting() then
                fn()
            end
        end
        if last_exec == 0 or now - last_exec >= ms then
            run()
            return
        end
        if timer then
            return
        end
        local delay = ms - (now - last_exec)
        timer = _uv.new_timer()
        assert(timer)
        timer:start(delay, 0, function()
            vim.schedule(function()
                if timer:is_active() then timer:stop() end
                if not timer:is_closing() then timer:close() end
                timer = nil
                run()
            end)
        end)
    end
end

return M
