---@class neotasks.QfItem
---@field filename string
---@field lnum     integer
---@field col      integer
---@field text     string?
---@field type     string?

---@alias neotasks.QfMatcher fun(line: string, context: table): neotasks.QfItem?

---@param file string
---@param lnum integer|string
---@param col  integer|string
---@param text string?
---@param type string?
---@return neotasks.QfItem
local function _item(file, lnum, col, text, type)
    return { filename = file, lnum = tonumber(lnum) or 1, col = tonumber(col) or 1, text = text, type = type or "E" }
end

--- GCC / Clang: file:line:col: severity: message
---@type neotasks.QfMatcher
local function _gcc(line, context)
    -- Template/instantiation diagnostics: GCC reports the error in a deep header
    -- and prints the triggering user-code location on a trailing "required from
    -- here" line. Remember it so the next diagnostic points at the real source.
    local rf_file, rf_lnum, rf_col = line:match("^(.+):(%d+):(%d+):%s+required from here%s*$")
    if rf_file then
        context.required_from = { file = rf_file, lnum = rf_lnum, col = rf_col }
        return nil
    end

    local file, lnum, col, sev, msg = line:match("^(.+):(%d+):(%d+):%s+([%a%s]+):%s+(.+)$")
    if file then
        local t = sev == "warning" and "W" or sev == "note" and "I" or "E"
        local rf = context.required_from
        if rf and sev ~= "note" then
            -- Consume the captured context for this diagnostic only, keeping the
            -- header location visible in the message text.
            context.required_from = nil
            return _item(rf.file, rf.lnum, rf.col,
                msg .. " [in " .. file .. ":" .. lnum .. ":" .. col .. "]", t)
        end
        return _item(file, lnum, col, msg, t)
    end
    local obj, msg2 = line:match("^(.+):%(%.[^%)]+%)%+?[^:]*:%s+(.+)$")
    if obj then return _item(obj, 1, 1, msg2, "E") end
    local sym = line:match("undefined reference to [`']([^'`']+)[`']")
    if sym then return _item("", 1, 1, "undefined reference to `" .. sym .. "`", "E") end
    return nil
end

--- TypeScript / tsc: file(line,col): message
---@type neotasks.QfMatcher
local function _tsc(line, _)
    local file, lnum, col, msg = line:match("^(.+)%((%d+),(%d+)%):%s+(.+)$")
    if file then return _item(file, lnum, col, msg, "E") end
    return nil
end

--- Python tracebacks: File "file", line N
---@type neotasks.QfMatcher
local function _python(line, _)
    local file, lnum = line:match('File "([^"]+)", line (%d+)')
    if file then return _item(file, lnum, 1, "Python Traceback", "E") end
    return nil
end

--- Go compiler: file:line:col: message  or  file:line: message
---@type neotasks.QfMatcher
local function _go(line, _)
    local file, lnum, col, msg = line:match("^([^%s:]+):(%d+):(%d+):%s+(.+)$")
    if file then return _item(file, lnum, col, msg, "E") end
    local file2, lnum2, msg2 = line:match("^([^%s:]+):(%d+):%s+(.+)$")
    if file2 then return _item(file2, lnum2, 1, msg2, "E") end
    return nil
end

--- Pytest / unittest: file.py:line: message
---@type neotasks.QfMatcher
local function _pytest(line, _)
    local file, lnum, msg = line:match("^([^%s:]+%.py):(%d+):%s+(.+)$")
    if file then return _item(file, lnum, 1, msg, "E") end
    return nil
end

--- Rust / Cargo: --> src/file.rs:line:col
---@type neotasks.QfMatcher
local function _cargo(line, _)
    local file, lnum, col = line:match("^%s*-->%s+([^%s:]+):(%d+):(%d+)")
    if file then return _item(file, lnum, col, "Rust error", "E") end
    local file2, lnum2, col2 = line:match("panicked at '.-',%s+([^%s:]+):(%d+):(%d+)")
    if file2 then return _item(file2, lnum2, col2, "Panic", "E") end
    return nil
end

--- Go test output: \t file_test.go:line: message
---@type neotasks.QfMatcher
local function _gotest(line, _)
    local file, lnum, msg = line:match("^%s+([^%s:]+_test%.go):(%d+):%s+(.+)$")
    if file then return _item(file, lnum, 1, msg, "E") end
    return nil
end

--- MSVC: file(line): error/warning CXXXX: message
---@type neotasks.QfMatcher
local function _msvc(line, _)
    local file, lnum, sev, msg = line:match("^(.-)%((%d+)%):%s+([%a]+)%s+[%a%d]+:%s+(.+)$")
    if file then
        local t = sev:lower() == "warning" and "W" or "E"
        return _item(file, lnum, 1, msg, t)
    end
    return nil
end

--- Generic linter (Pylint, ESLint, Flake8, Mypy): file:line:col: CODE: message
---@type neotasks.QfMatcher
local function _linter(line, _)
    local file, lnum, col, code, msg =
        line:match("^([^%s:]+):(%d+):(%d+):%s*([A-Z]%d+):%s*(.+)$")
    if file then
        local sev = code:sub(1, 1)
        local t = (sev == "E" or sev == "F") and "E" or sev == "W" and "W" or "I"
        return _item(file, lnum, col, msg .. " (" .. code .. ")", t)
    end
    local file2, lnum2, col2, label, msg2 =
        line:match("^([^%s:]+):(%d+):(%d+):%s*([^:]+):%s*(.+)$")
    if file2 then
        local lo = label:lower()
        local t = lo:find("warn") and "W" or (lo:find("info") or lo:find("note")) and "I" or "E"
        return _item(file2, lnum2, col2, msg2, t)
    end
    local file3, lnum3, col3, msg3 = line:match("^([^%s:]+):(%d+):(%d+):%s*(.+)$")
    if file3 then return _item(file3, lnum3, col3, msg3, "W") end
    return nil
end

--- Generic Unix format: file:line:col: message
---@type neotasks.QfMatcher
local function _unix(line, _)
    local file, lnum, col, msg = line:match("^([^%s:]+):(%d+):(%d+):%s*(.*)$")
    if not file then return nil end
    local lo = msg:lower()
    local t = (lo:find("warning") or lo:find("low")) and "W"
        or (lo:find("note") or lo:find("info")) and "I"
        or "E"
    return _item(file, lnum, col, msg, t)
end

--- Built-in matchers, keyed by name.
---@type table<string, neotasks.QfMatcher>
local _builtin = {
    gcc    = _gcc,
    tsc    = _tsc,
    python = _python,
    go     = _go,
    pytest = _pytest,
    cargo  = _cargo,
    gotest = _gotest,
    msvc   = _msvc,
    linter = _linter,
    unix   = _unix,
}

--- User-registered matchers (shadow a built-in of the same name).
---@type table<string, neotasks.QfMatcher>
local _user = {}

local M = {}

--- Register a custom quickfix matcher.
---@param name string
---@param fn   neotasks.QfMatcher
function M.register(name, fn)
    _user[name] = fn
end

--- Resolve a matcher by name, or nil if unknown. User matchers take precedence.
---@param name string
---@return neotasks.QfMatcher?
function M.get(name)
    return _user[name] or _builtin[name]
end

--- True if `name` was registered by the user rather than shipped built-in.
---@param name string
---@return boolean
function M.is_user(name)
    return _user[name] ~= nil
end

--- All known matcher names (built-in + user-registered), sorted and de-duplicated.
---@return string[]
function M.names()
    local seen, names = {}, {}
    for k in pairs(_builtin) do
        if not seen[k] then seen[k] = true; names[#names + 1] = k end
    end
    for k in pairs(_user) do
        if not seen[k] then seen[k] = true; names[#names + 1] = k end
    end
    table.sort(names)
    return names
end

return M
