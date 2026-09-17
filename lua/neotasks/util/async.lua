---@class neotasks.async
local M = {}

--- Drive `fn` as a coroutine, calling `on_done(ok, result)` when it finishes or
--- errors. Each yield must yield a `setup(waker)` function, called at once with
--- the resume path, handing it to whoever will wake the coroutine.
---@param fn     fun(...): any
---@param on_done fun(ok: boolean, result: any)
---@param ...    any  arguments forwarded to fn
function M.go(fn, on_done, ...)
    local args = { ... }
    local co = coroutine.create(function()
        return fn(unpack(args))
    end)
    local function step(...)
        local ok, val = coroutine.resume(co, ...)
        local status = coroutine.status(co)
        if not ok then
            on_done(false, val)
        elseif status == "dead" then
            on_done(true, val)
        elseif type(val) == "function" then
            val(step)
        else
            on_done(false, "unexpected yield value: " .. type(val))
        end
    end
    step()
end

--- Yield the calling coroutine until `sig` emits once.
--- Must be called from within a coroutine (started with async.go).
---@param sig neotasks.util.Signal<fun()>
function M.wait_signal(sig)
    coroutine.yield(function(waker)
        local handler
        handler = function()
            sig:unsubscribe(handler)
            waker()
        end
        sig:subscribe(handler)
    end)
end

--- Run fn as a sub-coroutine and yield until it completes.
--- Must be called from within a coroutine (started with async.go).
---@param fn fun(): any
---@return { ok: boolean, result: any }
function M.wait_one(fn)
    return coroutine.yield(function(waker)
        M.go(fn, function(ok, result)
            waker({ ok = ok, result = result })
        end)
    end)
end

--- Run all fns as parallel coroutines and yield until all complete.
--- Must be called from within a coroutine (started with async.go).
--- Returns an array of { ok: boolean, result: any } in the same order as fns.
---@param fns (fun(): any)[]
---@return { ok: boolean, result: any }[]
function M.wait_all(fns)
    if #fns == 0 then return {} end
    return coroutine.yield(function(waker)
        local results = {}
        local pending = #fns
        for i, fn in ipairs(fns) do
            M.go(fn, function(ok, result)
                results[i] = { ok = ok, result = result }
                pending = pending - 1
                if pending == 0 then
                    waker(results)
                end
            end)
        end
    end)
end

return M
