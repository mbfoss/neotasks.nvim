local M = {}

---@class neotasks.SaveBuffersConfig
---@field include_globs  string[]
---@field exclude_globs  string[]
---@field include_hidden boolean?

---@param root string
---@param path string
local function _is_inside_folder(root, path)
    if path == root then return true end
    for parent in vim.fs.parents(path) do
        if parent == root then return true end
    end
    return false
end

-- BSD st_flags bit for "hidden". libuv normalizes the Windows
-- FILE_ATTRIBUTE_HIDDEN and the macOS UF_HIDDEN flag onto this same bit, so a
-- single check covers both platforms.
local _UF_HIDDEN = 0x8000

--- True if the filesystem entry at `path` carries the OS hidden attribute
--- (Windows hidden, macOS UF_HIDDEN). Pure dot-prefix hiding is handled
--- separately, so a missing/unreadable entry is treated as not hidden.
---@param path string
---@return boolean
local function _has_hidden_attr(path)
    local st = vim.uv.fs_stat(path)
    return st ~= nil and type(st.flags) == "number" and bit.band(st.flags, _UF_HIDDEN) ~= 0
end

--- True if `path` is hidden: it or any directory between it and `root` is
--- dot-prefixed or carries the OS hidden attribute (Windows hidden, macOS
--- UF_HIDDEN). Assumes `path` is inside `root` and both use forward slashes.
---@param root string
---@param path string
---@return boolean
local function _is_hidden(root, path)
    if vim.fs.basename(path):sub(1, 1) == "." or _has_hidden_attr(path) then
        return true
    end
    for parent in vim.fs.parents(path) do
        if parent == root then break end
        if vim.fs.basename(parent):sub(1, 1) == "." or _has_hidden_attr(parent) then
            return true
        end
    end
    return false
end

---@param path string
---@param regexes vim.regex[]
---@return boolean
local function _matches_any(path, regexes)
    for _, re in ipairs(regexes) do
        if re:match_str(path) then return true end
    end
    return false
end

---@param globs string[]
---@return vim.regex[]
local function _compile_globs(globs)
    local out = {}
    for _, g in ipairs(globs) do
        out[#out + 1] = vim.regex(vim.fn.glob2regpat(g))
    end
    return out
end

--- Save all modified buffers under project_root, filtered by config globs. Hidden
--- files are skipped unless config.include_hidden is true. Empty include_globs
--- means include all; empty exclude_globs means exclude nothing. Buffers whose
--- write did not go through are returned in `failed`.
---@param project_root string
---@param config neotasks.SaveBuffersConfig
---@return integer saved, string[] paths, string[] failed
function M.save(project_root, config)
    local root = vim.fs.normalize(project_root)
    ---@diagnostic disable-next-line: undefined-field
    local real_root = vim.uv.fs_realpath(root)
    if not real_root then return 0, {}, {} end
    real_root = vim.fs.normalize(real_root) -- fs_realpath returns native separators

    local inc_re = _compile_globs(config.include_globs)
    local exc_re = _compile_globs(config.exclude_globs)
    local saved, saved_paths, failed_paths = 0, {}, {}

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if not vim.api.nvim_buf_is_loaded(bufnr)
            or not vim.bo[bufnr].buflisted
            or vim.bo[bufnr].buftype ~= ""
            or not vim.bo[bufnr].modified
        then
            goto continue
        end

        local bname = vim.api.nvim_buf_get_name(bufnr)
        if bname == "" then goto continue end

        local norm_path = vim.fs.normalize(vim.fn.fnamemodify(bname, ":p"))
        ---@diagnostic disable-next-line: undefined-field
        local real_path = vim.uv.fs_realpath(norm_path)
        if not real_path then goto continue end
        real_path = vim.fs.normalize(real_path) -- fs_realpath returns native separators

        if not _is_inside_folder(real_root, real_path) then goto continue end
        if not config.include_hidden and _is_hidden(real_root, real_path) then goto continue end

        if #inc_re > 0 and not _matches_any(norm_path, inc_re) then goto continue end
        if #exc_re > 0 and _matches_any(norm_path, exc_re) then goto continue end

        local ok = pcall(function()
            vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent update") end)
        end)
        -- An aborted write (a declined W12 "changed on disk" prompt, a BufWriteCmd
        -- that bailed) raises no error, so the modified flag is the real signal.
        if ok and not vim.bo[bufnr].modified then
            saved = saved + 1
            saved_paths[#saved_paths + 1] = vim.fs.basename(norm_path)
        else
            failed_paths[#failed_paths + 1] = vim.fs.basename(norm_path)
        end

        ::continue::
    end

    return saved, saved_paths, failed_paths
end

return M
