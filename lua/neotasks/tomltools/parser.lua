---@alias tomltools.Range {[1]: integer, [2]: integer, [3]: integer, [4]: integer}

---@class tomltools.ParseError
---@field message string
---@field range tomltools.Range

---@class tomltools.ParseResult
---@field ok     boolean
---@field cst    tomltools.Cst
---@field errors tomltools.ParseError[]

local M    = {}
local Cst  = require("neotasks.tomltools.Cst")
local util = require("neotasks.tomltools.parser_util")
local K    = Cst.Kind

---@param text string
---@return tomltools.ParseResult
function M.parse(text)
    local errors   = {}
    local cst      = Cst.new()
    local cursor   = 1
    local row, col = 0, 0

    if not util.validate_utf8(text) then
        table.insert(errors, { message = "Invalid UTF sequence", range = { 0, 0, 0, 0 } })
        return { ok = false, cst = cst, errors = errors }
    end

    local function add_err(msg, r)
        table.insert(errors, { message = msg, range = r or { row, col, row, col } })
    end

    local function char(off)
        local i = cursor + (off or 0)
        return i <= #text and text:sub(i, i) or ""
    end

    local function ahead(n, off)
        local s = cursor + (off or 0)
        return text:sub(s, s + n - 1)
    end

    local function bounds() return cursor <= #text end

    local function step(n)
        n = n or 1
        for _ = 1, n do
            if cursor <= #text then
                local c = text:byte(cursor)
                if c == 10 then row = row + 1; col = 0
                elseif c ~= 13 then col = col + 1 end
            end
            cursor = cursor + 1
        end
    end

    local function is_ws()  local c = char(); return c == " " or c == "\t" end
    local function is_nl()  return char() == "\n" or (char() == "\r" and char(1) == "\n") end
    local function is_comment_ctrl()
        local b = char():byte()
        return b and (b < 0x09 or (b > 0x09 and b < 0x20) or b == 0x7F)
    end

    local function skip_nl()
        if char() == "\r" then step() end
        if char() == "\n" then step() end
    end

    -- ===== trivia emitters =====

    local function emit_ws(pid)
        if not is_ws() then return end
        local sr, sc = row, col
        while bounds() and is_ws() do step() end
        cst:token(pid, K.Whitespace, nil, nil, sr, sc, row, col)
    end

    local function emit_nl(pid)
        if not is_nl() then return end
        local sr, sc = row, col
        skip_nl()
        cst:token(pid, K.Newline, nil, nil, sr, sc, sr, sc)
    end

    local function emit_comment(pid)
        if char() ~= "#" then return end
        local sr, sc = row, col
        local buf = {}
        while bounds() and not is_nl() do
            if is_comment_ctrl() then add_err("Control character in comment") end
            table.insert(buf, char()); step()
        end
        cst:token(pid, K.Comment, table.concat(buf), nil, sr, sc, row, col)
    end

    local function emit_trivia(pid)
        while bounds() do
            if is_ws() then emit_ws(pid)
            elseif is_nl() then emit_nl(pid)
            elseif char() == "#" then emit_comment(pid)
            else break end
        end
    end

    local function emit_inline_ws(pid)
        if is_ws() then emit_ws(pid) end
    end

    -- ===== key parsers =====

    -- Parse a quoted key (single or double), emit QuotedKey token, return decoded value.
    local function parse_quoted_key(pid)
        local sr, sc = row, col
        local bs     = cursor
        local q      = char()
        if char(1) == q and char(2) == q then
            add_err("Multiline strings are not allowed as keys")
        end
        step()
        local buf, closed = {}, false
        local esc = { b="\b", t="\t", n="\n", f="\f", r="\r", e="\x1b", ['"']='"', ["\\"]= "\\" }
        while bounds() do
            if char() == q then step(); closed = true; break end
            if is_nl() then add_err("Newline in key string"); break end
            if q == '"' and char() == "\\" then
                local nc = char(1)
                if esc[nc] then
                    table.insert(buf, esc[nc]); step(2)
                elseif nc == "u" or nc == "U" or nc == "x" then
                    local len = nc == "u" and 4 or (nc == "U" and 8 or 2)
                    step(2)
                    local hex_str = ahead(len); step(len)
                    if #hex_str == len and hex_str:match("^[0-9A-Fa-f]+$") then
                        local cp = tonumber(hex_str, 16)
                        if cp >= 0xD800 and cp <= 0xDFFF then
                            add_err("Invalid Unicode escape: surrogate codepoint")
                        elseif cp <= 0x10FFFF then
                            table.insert(buf, util.utf8_encode(cp))
                        else
                            add_err("Invalid Unicode escape: codepoint out of range")
                        end
                    else
                        add_err("Invalid escape sequence: bad hex digits")
                    end
                else
                    add_err("Invalid escape: \\" .. nc); step()
                end
            else
                table.insert(buf, char()); step()
            end
        end
        if not closed then add_err("Unterminated string key") end
        local er, ec = row, col
        local raw = text:sub(bs, cursor - 1)
        local val = table.concat(buf)
        cst:token(pid, K.QuotedKey, raw, val, sr, sc, er, ec)
        return val
    end

    -- Parse a bare or quoted key token, emit it, return decoded key string.
    -- Returns "" if no valid key chars are present.
    local function parse_key_token(pid)
        local c = char()
        if c == '"' or c == "'" then return parse_quoted_key(pid) end
        local sr, sc = row, col
        local buf = {}
        while bounds() and char():match("[%w%-_]") do
            table.insert(buf, char()); step()
        end
        local val = table.concat(buf)
        if val ~= "" then
            cst:token(pid, K.BareKey, val, val, sr, sc, row, col)
        end
        return val
    end

    -- Parse `key (. key)*`, emitting key + dot tokens under pid.
    -- Returns array of decoded key strings.
    local function parse_dotted_keys(pid)
        local keys = {}
        while bounds() do
            emit_inline_ws(pid)
            local c = char()
            local is_quote    = (c == '"' or c == "'")
            local is_bare_ch  = c:match("[%w%-_]") ~= nil
            if not is_quote and not is_bare_ch then
                if #keys > 0 then add_err("Trailing dot in key") end
                break
            end
            local val = parse_key_token(pid)
            if val == "" and not is_quote then
                if #keys == 0 then add_err("Empty key segment") end
                break
            end
            table.insert(keys, val)
            emit_inline_ws(pid)
            if char() == "." then
                local dr, dc = row, col
                step()
                cst:token(pid, K.Dot, ".", nil, dr, dc, row, col)
            else
                break
            end
        end
        return keys
    end

    -- ===== value parsers =====
    local parse_value -- forward decl

    local function parse_string(pid)
        local sr, sc = row, col
        local bs     = cursor
        local q      = char()
        local ml     = char(1) == q and char(2) == q
        step(ml and 3 or 1)
        local buf, closed = {}, false
        local esc = { b="\b", t="\t", n="\n", f="\f", r="\r", e="\x1b", ['"']='"', ["\\"]= "\\" }

        while bounds() do
            if ml and #buf == 0 and is_nl() then skip_nl() end
            if char() == q then
                if ml then
                    if char(1) == q and char(2) == q then
                        if char(3) == q then
                            table.insert(buf, q)
                            if char(4) == q then table.insert(buf, q); step(5) else step(4) end
                        else step(3) end
                        closed = true; break
                    end
                else step(); closed = true; break end
            end
            if not ml and is_nl() then add_err("Newline in single-line string"); break end
            if q == '"' and char() == "\\" then
                local nc = char(1)
                local j  = 1
                while char(j) == " " or char(j) == "\t" do j = j + 1 end
                if ml and (char(j) == "\n" or (char(j) == "\r" and char(j + 1) == "\n")) then
                    step(j); skip_nl()
                    while bounds() do
                        if is_ws() then step()
                        elseif is_nl() then skip_nl()
                        else break end
                    end
                else
                    if esc[nc] then
                        table.insert(buf, esc[nc]); step(2)
                    elseif nc == "u" or nc == "U" or nc == "x" then
                        local len = nc == "u" and 4 or (nc == "U" and 8 or 2)
                        step(2)
                        local hex_str = ahead(len); step(len)
                        if #hex_str ~= len or not hex_str:match("^[0-9A-Fa-f]+$") then
                            add_err("Invalid escape sequence: bad hex digits")
                        else
                            local cp = tonumber(hex_str, 16)
                            if cp >= 0xD800 and cp <= 0xDFFF then
                                add_err("Invalid Unicode escape: surrogate codepoint")
                            elseif cp > 0x10FFFF then
                                add_err("Invalid Unicode escape: codepoint out of range")
                            else
                                table.insert(buf, util.utf8_encode(cp))
                            end
                        end
                    else add_err("Invalid escape: \\" .. nc); step() end
                end
            else
                local b = char():byte()
                if b ~= nil and (b == 0x7F or (b < 0x20 and b ~= 0x09 and
                        not (ml and (b == 0x0A or (b == 0x0D and char(1) == "\n"))))) then
                    add_err("Control character in string")
                end
                table.insert(buf, char()); step()
            end
        end
        if not closed then add_err("Unterminated string") end
        local er, ec = row, col
        cst:token(pid, K.String, text:sub(bs, cursor - 1), table.concat(buf), sr, sc, er, ec)
    end

    local function is_datetime_start() return ahead(10):match("^%d%d%d%d%-%d%d%-%d%d") ~= nil end
    local function is_time_start()     return ahead(5):match("^%d%d:%d%d") ~= nil end

    local function parse_datetime(pid)
        local sr, sc = row, col
        local bs     = cursor
        local y = tonumber(ahead(4)); step(5)
        local mo = tonumber(ahead(2)); step(3)
        local d  = tonumber(ahead(2)); step(2)
        local h, mi, sec, zone
        assert(y and mo and d)
        if bounds() and (char():lower() == "t" or (char() == " " and ahead(3, 1):match("^%d%d:"))) then
            step()
            if not ahead(2):match("^%d%d$") then
                add_err("Expected time component after date separator")
            else
                h = tonumber(ahead(2)); step(3)
                mi = tonumber(ahead(2)); step(2)
                assert(mi)
                sec = 0
                if bounds() and char() == ":" then
                    step()
                    local ss = {}
                    while bounds() and char():match("[%d%.]") do table.insert(ss, char()); step() end
                    local sec_str = table.concat(ss)
                    if sec_str:match("%.$") then add_err("Invalid seconds: trailing dot") end
                    sec = tonumber(sec_str) or 0
                end
                if bounds() and char():lower() == "z" then
                    zone = 0; step()
                elseif bounds() and (char() == "+" or char() == "-") then
                    local sign = char() == "+" and 1 or -1; step()
                    if not ahead(2):match("^%d%d$") then
                        add_err("Invalid timezone offset: expected 2-digit hour"); zone = 0
                    else
                        local oh = tonumber(ahead(2)) or 0; step(2)
                        if char() ~= ":" then
                            add_err("Invalid timezone offset: expected ':'"); zone = sign * oh
                        else
                            step()
                            if not ahead(2):match("^%d%d$") then
                                add_err("Invalid timezone offset: expected 2-digit minute"); zone = sign * oh
                            else
                                local om = tonumber(ahead(2)) or 0; step(2)
                                local tz_err = util.validate_offset(oh, om)
                                if tz_err then add_err(tz_err) end
                                zone = sign * oh
                            end
                        end
                    end
                end
            end
        end
        local date_err = util.validate_date(y, mo, d)
        if date_err then add_err(date_err) end
        if h ~= nil then
            local time_err = util.validate_time(h, mi, sec)
            if time_err then add_err(time_err) end
        end
        local er, ec   = row, col
        local lkind    = h ~= nil and (zone ~= nil and "datetime" or "datetime-local") or "date-local"
        local ck       = lkind == "datetime" and K.Datetime
                      or lkind == "datetime-local" and K.DatetimeLocal
                      or K.DateLocal
        cst:token(pid, ck, text:sub(bs, cursor - 1), util.format_date_str(y, mo, d, h, mi, sec, zone), sr, sc, er, ec)
    end

    local function parse_time(pid)
        local sr, sc = row, col
        local bs     = cursor
        local h  = tonumber(ahead(2)); step(3)
        local mi = tonumber(ahead(2)); step(2)
        assert(h and mi)
        local sec = 0
        if bounds() and char() == ":" then
            step()
            local ss = {}
            while bounds() and char():match("[%d%.]") do table.insert(ss, char()); step() end
            local sec_str = table.concat(ss)
            if sec_str:match("%.$") then add_err("Invalid seconds: trailing dot") end
            local int_part = sec_str:match("^(%d+)") or ""
            if #int_part < 2 then add_err("Seconds must have at least 2 digits") end
            sec = tonumber(sec_str) or 0
        end
        local time_err = util.validate_time(h, mi, sec)
        if time_err then add_err(time_err) end
        local er, ec = row, col
        cst:token(pid, K.TimeLocal, text:sub(bs, cursor - 1), util.format_time_str(h, mi, sec), sr, sc, er, ec)
    end

    local function is_num_term()
        if not bounds() then return true end
        local c = char()
        return c==" " or c=="\t" or c=="\n" or c=="\r" or c=="#" or c=="," or c=="]" or c=="}"
    end

    local function parse_number(pid)
        local sr, sc = row, col
        local bs     = cursor
        local s_buf, raw_buf = {}, {}
        if char() == "+" or char() == "-" then
            table.insert(s_buf, char()); table.insert(raw_buf, char()); step()
        end
        if char() == "0" and (char(1) == "x" or char(1) == "o" or char(1) == "b") then
            local pfx = char(1)
            if #s_buf > 0 then add_err("Sign not allowed on based integer") end
            table.insert(raw_buf, ahead(2)); step(2)
            local bases    = { x=16, o=8, b=2 }
            local valid_re = { x="^[0-9A-Fa-f]$", o="^[0-7]$", b="^[01]$" }
            local dig_buf  = {}
            local last_c   = nil
            while bounds() and not is_num_term() do
                local c = char(); table.insert(raw_buf, c)
                if c == "_" then
                    if last_c == nil or last_c == "_" then add_err("Invalid underscore in based integer") end
                else
                    if not c:match(valid_re[pfx]) then
                        add_err("Invalid digit for base-" .. bases[pfx] .. " integer: " .. c)
                    end
                    table.insert(dig_buf, c)
                end
                last_c = c; step()
            end
            if last_c == "_" then add_err("Trailing underscore in based integer") end
            if #dig_buf == 0 then add_err("Empty based number") end
            local er, ec = row, col
            local v = tonumber(table.concat(dig_buf), bases[pfx]) or 0
            cst:token(pid, K.Integer, text:sub(bs, cursor - 1), v, sr, sc, er, ec)
            return
        end
        while bounds() and not is_num_term() do
            local c = char(); table.insert(raw_buf, c)
            if c == "." or c:match("%d") then
                table.insert(s_buf, c); step()
            elseif c:lower() == "e" then
                table.insert(s_buf, c); step()
                if bounds() and (char() == "+" or char() == "-") then
                    table.insert(s_buf, char()); table.insert(raw_buf, char()); step()
                end
            elseif c == "_" then step()
            else break end
        end
        local num_err = util.validate_number_raw(table.concat(raw_buf))
        if num_err then add_err(num_err) end
        local er, ec = row, col
        local s      = table.concat(s_buf)
        local lkind  = s:find("[%.eE]") and "float" or "integer"
        local v      = tonumber(s) or 0
        if lkind == "integer" and v == 0 then v = 0 end  -- normalize -0
        cst:token(pid, lkind == "float" and K.Float or K.Integer, text:sub(bs, cursor - 1), v, sr, sc, er, ec)
    end

    local function parse_bool_special(pid)
        local sr, sc = row, col
        local bs     = cursor
        local matches = {
            ["false"] = { false,       5, K.Bool  },
            ["true"]  = { true,        4, K.Bool  },
            ["+inf"]  = { math.huge,   4, K.Float },
            ["-inf"]  = { -math.huge,  4, K.Float },
            ["inf"]   = { math.huge,   3, K.Float },
            ["+nan"]  = { 0/0,         4, K.Float },
            ["-nan"]  = { 0/0,         4, K.Float },
            ["nan"]   = { 0/0,         3, K.Float },
        }
        for kw, v in pairs(matches) do
            if ahead(#kw) == kw then
                step(v[2])
                local er, ec = row, col
                cst:token(pid, v[3], text:sub(bs, cursor - 1), v[1], sr, sc, er, ec)
                return
            end
        end
        add_err("Unexpected value near: " .. ahead(8))
        while bounds() and not is_num_term() do step() end
        local er, ec = row, col
        cst:token(pid, K.Error, text:sub(bs, cursor - 1), nil, sr, sc, er, ec)
    end

    local function parse_array(pid)
        local sr, sc = row, col
        local arr_id = cst:open(pid, K.Array, sr, sc)
        local lb_r, lb_c = row, col; step()
        cst:token(arr_id, K.LBracket, "[", nil, lb_r, lb_c, row, col)

        while bounds() do
            emit_trivia(arr_id)
            if char() == "]" then break end
            local before = cursor
            parse_value(arr_id)
            if cursor == before then
                local er, ec = row, col
                add_err("Unexpected character in array: " .. char())
                cst:token(arr_id, K.Error, char(), nil, er, ec, er, ec)
                step()
            else
                emit_trivia(arr_id)
                if char() == "," then
                    local cr, cc = row, col; step()
                    cst:token(arr_id, K.Comma, ",", nil, cr, cc, row, col)
                elseif char() ~= "]" then
                    add_err("Missing , between array elements")
                end
            end
        end

        if char() ~= "]" then
            add_err("Missing ] in array")
        else
            local cr, cc = row, col; step()
            cst:token(arr_id, K.RBracket, "]", nil, cr, cc, row, col)
        end
        cst:close(arr_id, row, col)
    end

    -- Parse a KVP (key = value) and attach it under pid.
    local function parse_kvp(pid)
        local sr, sc = row, col
        local kvp_id = cst:open(pid, K.KeyValuePair, sr, sc)
        local keys   = parse_dotted_keys(kvp_id)
        emit_inline_ws(kvp_id)

        if #keys == 0 then
            add_err("Empty key segment")
            while bounds() and not is_nl() do
                local er, ec = row, col
                cst:token(kvp_id, K.Error, char(), nil, er, ec, er, ec); step()
            end
            cst:close(kvp_id, row, col)
            return
        end

        if char() ~= "=" then
            add_err("Expected = after key")
            while bounds() and not is_nl() do
                local er, ec = row, col
                cst:token(kvp_id, K.Error, char(), nil, er, ec, er, ec); step()
            end
            cst:close(kvp_id, row, col)
            return
        end

        local eq_r, eq_c = row, col; step()
        cst:token(kvp_id, K.Equals, "=", nil, eq_r, eq_c, row, col)
        emit_inline_ws(kvp_id)

        if bounds() and not is_nl() and char() ~= "#" then
            parse_value(kvp_id)
        else
            add_err("Expected value after =")
        end

        emit_inline_ws(kvp_id)
        if char() == "#" then emit_comment(kvp_id) end

        if bounds() and not is_nl() then
            add_err("Expected newline after key-value pair")
            while bounds() and not is_nl() do step() end
        end
        cst:close(kvp_id, row, col)
    end

    local function parse_inline_table(pid)
        local sr, sc = row, col
        local tbl_id = cst:open(pid, K.InlineTable, sr, sc)
        local lb_r, lb_c = row, col; step()
        cst:token(tbl_id, K.LBrace, "{", nil, lb_r, lb_c, row, col)

        while bounds() do
            emit_trivia(tbl_id)
            if char() == "}" or char() == "]" then break end

            local kvp_sr, kvp_sc = row, col
            local kvp_id = cst:open(tbl_id, K.KeyValuePair, kvp_sr, kvp_sc)
            local keys   = parse_dotted_keys(kvp_id)
            emit_inline_ws(kvp_id)

            if #keys == 0 then
                add_err("Empty key in inline table")
                cst:close(kvp_id, row, col)
                break
            end

            if char() ~= "=" then
                add_err("Expected = in inline table")
                cst:close(kvp_id, row, col)
                -- cursor is on the newline; emit_trivia at loop top will consume it
                -- and the next iteration picks up the following key = value
            else
                local eq_r, eq_c = row, col; step()
                cst:token(kvp_id, K.Equals, "=", nil, eq_r, eq_c, row, col)
                emit_trivia(kvp_id)

                if bounds() and char() ~= "," and char() ~= "}" then
                    parse_value(kvp_id)
                end
                cst:close(kvp_id, row, col)

                emit_trivia(tbl_id)
                if char() == "," then
                    local cr, cc = row, col; step()
                    cst:token(tbl_id, K.Comma, ",", nil, cr, cc, row, col)
                elseif char() == "}" then
                    break
                else
                    break
                end
            end
        end

        if char() ~= "}" then
            add_err("Missing } in inline table")
        else
            local cr, cc = row, col; step()
            cst:token(tbl_id, K.RBrace, "}", nil, cr, cc, row, col)
        end
        cst:close(tbl_id, row, col)
    end

    function parse_value(pid)
        if not bounds() then return end
        local c = char()
        if c == '"' or c == "'" then parse_string(pid); return end
        if is_datetime_start() then parse_datetime(pid); return end
        if is_time_start() then parse_time(pid); return end
        if c == "[" then parse_array(pid); return end
        if c == "{" then parse_inline_table(pid); return end
        if c:match("[%+%-0-9]") then
            local a4 = ahead(4)
            if a4 == "+inf" or a4 == "-inf" or a4 == "+nan" or a4 == "-nan" then
                parse_bool_special(pid); return
            end
            parse_number(pid); return
        end
        parse_bool_special(pid)
    end

    -- ===== document loop =====

    local doc_id            = cst:root_id()
    local current_section   = nil  -- nil = document root level

    while bounds() do
        local parent = current_section or doc_id
        emit_trivia(parent)
        if not bounds() then break end

        if char() == "[" then
            -- close previous section
            if current_section then cst:close(current_section, row, col) end

            local sec_sr, sec_sc = row, col
            step()  -- first [
            local is_aot = char() == "["
            if is_aot then step() end

            local sec_kind = is_aot and K.AotSection   or K.TableSection
            local hdr_kind = is_aot and K.AotHeader    or K.TableHeader

            local sec_id = cst:open(doc_id, sec_kind, sec_sr, sec_sc)
            local hdr_id = cst:open(sec_id, hdr_kind, sec_sr, sec_sc)

            -- emit opening bracket(s) into header
            cst:token(hdr_id, K.LBracket, "[", nil, sec_sr, sec_sc, row, col)
            if is_aot then
                local b2r, b2c = row, col
                cst:token(hdr_id, K.LBracket, "[", nil, b2r, b2c, row, col)
            end

            -- parse header keys
            local key_count = 0
            local valid     = true
            while bounds() and char() ~= "]" and not is_nl() do
                emit_inline_ws(hdr_id)
                if char() == "]" then break end
                local c    = char()
                local is_q = (c == '"' or c == "'")
                local is_b = c:match("[%w%-_]") ~= nil
                if not is_q and not is_b then
                    add_err("Unexpected character in section header: " .. c)
                    cst:token(hdr_id, K.Error, c, nil, row, col, row, col); step()
                    valid = false
                else
                    local val = parse_key_token(hdr_id)
                    if val == "" and not is_q then
                        add_err("Empty key in section header"); valid = false; break
                    end
                    key_count = key_count + 1
                    emit_inline_ws(hdr_id)
                    if char() == "." then
                        local dr, dc = row, col; step()
                        cst:token(hdr_id, K.Dot, ".", nil, dr, dc, row, col)
                        if char() == "]" or not bounds() or is_nl() then
                            add_err("Trailing dot in section header"); valid = false; break
                        end
                    elseif char() ~= "]" and bounds() and not is_nl() then
                        add_err("Unexpected character in section header, expected '.' or ']'")
                        valid = false
                        while bounds() and not is_nl() and char() ~= "]" do step() end
                        break
                    end
                end
            end

            if key_count == 0 and valid then
                add_err("Empty section header"); valid = false
            end
            _ = valid  -- referenced for correctness; errors already added

            -- closing bracket(s)
            if char() ~= "]" then
                add_err("Missing ] in section header")
            else
                local cr, cc = row, col; step()
                cst:token(hdr_id, K.RBracket, "]", nil, cr, cc, row, col)
            end
            if is_aot then
                if char() ~= "]" then
                    add_err("Missing ]] in array-of-tables header")
                else
                    local cr, cc = row, col; step()
                    cst:token(hdr_id, K.RBracket, "]", nil, cr, cc, row, col)
                end
            end

            emit_inline_ws(hdr_id)
            if char() == "#" then emit_comment(hdr_id) end
            cst:close(hdr_id, row, col)

            if bounds() and not is_nl() and char() ~= "#" then
                add_err("Unexpected content after section header")
                while bounds() and not is_nl() do step() end
            end
            if bounds() and is_nl() then emit_nl(sec_id) end

            current_section = sec_id
        else
            parse_kvp(current_section or doc_id)
            if bounds() and is_nl() then emit_nl(current_section or doc_id) end
        end
    end

    -- close last section and document
    if current_section then cst:close(current_section, row, col) end
    cst:close(doc_id, row, col)

    return { ok = #errors == 0, cst = cst, errors = errors }
end

return M
