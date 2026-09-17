local M = {}

local fsutil = require("neotasks.util.fsutil")

local _preview_ns = vim.api.nvim_create_namespace("neotasks_preview")

local function _file_preview(data, callback)
    local _max_size = 10124 * 10124
    local _filepath = data.filepath
    if not _filepath or _filepath == "" then
        callback({})
        return
    end
    if not fsutil.file_exists(_filepath) then
        callback({ error_msg = "Invalid file path: " .. tostring(_filepath) })
        return
    end
    local _cancelled = false
    local _cancel_fn
    vim.uv.fs_stat(_filepath, vim.schedule_wrap(function(stat_err, stat)
        if _cancelled then return end
        if stat_err or not stat then
            callback({ error_msg = stat_err })
            return
        end
        if stat.size > _max_size then
            callback({ error_msg = "Maximum file size exceeded" })
            return
        end
        _cancel_fn = fsutil.async_load_text_file(_filepath, { timeout = 3000 },
            function(load_err, content)
                callback({
                    content   = content,
                    filepath  = _filepath,
                    pos       = data.lnum and { data.lnum, data.col or 0 } or nil,
                    error_msg = load_err,
                })
            end)
    end))
    return function()
        _cancelled = true
        if _cancel_fn then _cancel_fn() end
    end
end

---Returns a preview_item handler that updates a shared scratch buffer in-place.
---Cancels any in-flight async load when the selection changes.
---@param buf integer
---@return fun(item: any): { buf: integer, pos: integer[]? }
local function _make_preview_item(buf)
    local _cancel
    return function(item)
        if _cancel then
            _cancel(); _cancel = nil
        end

        local p = type(item) == "table" and item.preview
        if not p then
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
            return { buf = buf }
        end

        if p.content then
            local lines = type(p.content) == "table"
                and p.content
                or vim.split(p.content, "\n", { plain = true })
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            if p.filetype and p.filetype ~= "" then vim.bo[buf].filetype = p.filetype end
            return { buf = buf }
        end

        if not p.filepath then
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
            return { buf = buf }
        end

        _cancel = _file_preview(p, function(result)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
            _cancel = nil
            if not vim.api.nvim_buf_is_valid(buf) then return end
            if result.error_msg or not result.content then
                vim.api.nvim_buf_set_lines(buf, 0, -1, false,
                    result.error_msg and { result.error_msg } or {})
                return
            end
            local lines = type(result.content) == "table"
                and result.content
                or vim.split(result.content, "\n", { plain = true })
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            local ft = vim.filetype.match({ filename = p.filepath }) or ""
            if ft ~= "" then vim.bo[buf].filetype = ft end

            if p.lnum then
                vim.api.nvim_buf_clear_namespace(buf, _preview_ns, 0, -1)
                vim.api.nvim_buf_set_extmark(buf, _preview_ns, p.lnum - 1, 0, { line_hl_group = "Visual" })
                vim.schedule(function()
                    local win = vim.fn.bufwinid(buf)
                    if win ~= -1 then
                        vim.api.nvim_win_set_cursor(win, { p.lnum, 0 })
                        vim.api.nvim_win_call(win, function() vim.cmd.normal({ args = { "zz" }, bang = true }) end)
                    end
                end)
            end
        end)

        return { buf = buf }
    end
end

---Wraps vim.ui.select and injects a preview_item handler when items carry a
---`.preview = { filepath, lnum }` field. A single scratch buffer is shared
---across all preview calls and deleted when on_choice is invoked.
---@param items     any[]
---@param opts      table
---@param on_choice fun(item: any?, idx: integer?)
function M.select(items, opts, on_choice)
    local first = items[1]
    if not opts.preview_item and type(first) == "table" and type(first.preview) == "table" then
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].bufhidden = "hide"

        opts = vim.tbl_extend("force", opts, {
            preview_item = _make_preview_item(buf),
        })

        local _orig = on_choice
        on_choice = function(item, idx)
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
            _orig(item, idx)
        end
    end
    vim.ui.select(items, opts, on_choice)
end

return M
