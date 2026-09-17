-- In-process alternative transport for vim.lsp.start(): instead of spawning
-- `nvim --headless -l server.lua` as a child process and speaking JSON-RPC
-- over its stdio, this spawns a real vim.uv.new_thread worker
-- (thread_server.lua) and speaks length-prefixed vim.mpack frames (frame.lua)
-- over a pair of anonymous pipes. Pass `require("neotasks.lsp.thread.thread_client").start`
-- as `cmd` in a vim.lsp.ClientConfig — see thread_init.lua for the wiring.
local frame = require("neotasks.lsp.server.frame")

local M = {}

local _this_file = debug.getinfo(1, "S").source:sub(2)

---@param dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.PublicClient
function M.start(dispatchers)
    local uv = vim.uv

    local to_worker   = assert(uv.pipe()) -- client writes requests   → worker reads
    local from_worker = assert(uv.pipe()) -- worker writes responses  → client reads

    local writer = assert(uv.new_pipe(false))
    writer:open(to_worker.write)
    local reader = assert(uv.new_pipe(false))
    reader:open(from_worker.read)

    ---@type table<integer, fun(err: table?, result: any)>
    local message_callbacks = {}
    local message_id        = 0
    local closing            = false

    local function write_frame(obj)
        if closing then return false end
        writer:write(frame.encode(obj))
        return true
    end

    -- reader:read_start's callback runs in a libuv "fast event context" where
    -- most vim.api calls are disallowed, and nothing schedules a function-cmd's
    -- `dispatchers` for us — so defer each here, under its own pcall.
    local function on_message(msg)
        if msg.id ~= nil and msg.method == nil then
            local cb = message_callbacks[msg.id]
            message_callbacks[msg.id] = nil
            local result = msg.result
            -- Callbacks must never see vim.NIL; handlers test `not result`.
            if result == vim.NIL then result = nil end
            -- Isolate consumer failures from transport errors.
            if cb then
                local ok, cb_err = pcall(cb, msg.error, result)
                if not ok then
                    vim.notify("[neotasks] lsp request callback error: " .. tostring(cb_err),
                        vim.log.levels.ERROR)
                end
            end
        elseif msg.method ~= nil then
            dispatchers.notification(msg.method, msg.params)
        end
    end

    local function safe_on_message(msg)
        vim.schedule(function()
            local ok, err = pcall(on_message, msg)
            if not ok then
                vim.notify("[neotasks] thread client message error: " .. tostring(err), vim.log.levels.ERROR)
            end
        end)
    end

    local _buf = ""
    reader:read_start(function(err, data)
        if err or not data then
            if not closing then
                closing = true
                vim.schedule(function() dispatchers.on_exit(0, 0) end)
            end
            return
        end
        _buf = frame.feed(_buf .. data, safe_on_message)
    end)

    local thread_main = require("neotasks.lsp.server.thread").thread_main
    ---@diagnostic disable-next-line: param-type-mismatch -- uv.new_thread(fn, ...) overload
    local thread = assert(uv.new_thread(thread_main, to_worker.read, from_worker.write))

    ---@type vim.lsp.rpc.PublicClient
    return {
        request = function(method, params, callback, notify_reply_callback)
            message_id = message_id + 1
            local id   = message_id
            message_callbacks[id] = callback
            local ok   = write_frame({ id = id, method = method, params = params })
            if ok and notify_reply_callback then notify_reply_callback(id) end
            return ok, id
        end,

        notify = function(method, params)
            return write_frame({ method = method, params = params })
        end,

        is_closing = function()
            return closing
        end,

        terminate = function()
            if closing then return end
            pcall(write_frame, { method = "exit" })
            closing = true
            pcall(function() writer:close() end)
            pcall(function() reader:read_stop(); reader:close() end)
            pcall(function() thread:join() end)
        end,
    }
end

return M
