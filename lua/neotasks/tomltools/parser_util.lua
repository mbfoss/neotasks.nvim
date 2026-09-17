local M = {}

local days_in_month = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local invalid_utf_seq_msg = "invalid UTF-8 sequence"

local function is_leap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

---@param y integer
---@param mo integer
---@param d integer
---@return string|nil
function M.validate_date(y, mo, d)
    if mo < 1 or mo > 12 then return "month out of range" end
    local max_d = days_in_month[mo]
    if mo == 2 and is_leap(y) then max_d = 29 end
    if d < 1 or d > max_d then return "day out of range" end
end

---@param h integer
---@param mi integer
---@param sec number
---@return string|nil
function M.validate_time(h, mi, sec)
    if h < 0 or h > 23 then return "hour out of range" end
    if mi < 0 or mi > 59 then return "minute out of range" end
    if sec < 0 or sec > 60 then return "second out of range" end
end

---@param h integer
---@param mi integer
---@return string|nil
function M.validate_offset(h, mi)
    if h < 0 or h > 23 then return "timezone hour out of range" end
    if mi < 0 or mi > 59 then return "timezone minute out of range" end
end

---Validates a raw decimal number string (with optional sign and underscores).
---Hex/oct/bin prefixed numbers are not passed here.
---@param s string
---@return string|nil
function M.validate_number_raw(s)
    local i = 1
    local n = #s
    local function cur() return i <= n and s:sub(i, i) or nil end
    local function is_digit(c) return c ~= nil and c >= "0" and c <= "9" end
    local function adv() i = i + 1 end

    if cur() == "+" or cur() == "-" then adv() end
    if cur() == nil then return "empty number" end
    if cur() == "." then return "leading decimal point" end
    if not is_digit(cur()) then return "invalid number" end

    if cur() == "0" then
        adv()
        if is_digit(cur()) then return "leading zero" end
    else
        adv()
        while cur() do
            if is_digit(cur()) then adv()
            elseif cur() == "_" then
                adv()
                if not is_digit(cur()) then return "invalid underscore in number" end
                adv()
            else break end
        end
    end

    if cur() == "." then
        adv()
        if not is_digit(cur()) then return "trailing decimal point" end
        adv()
        while cur() do
            if is_digit(cur()) then adv()
            elseif cur() == "_" then
                adv()
                if not is_digit(cur()) then return "invalid underscore in fraction" end
                adv()
            else break end
        end
    end

    if cur() ~= nil and cur():lower() == "e" then
        adv()
        if cur() == "+" or cur() == "-" then adv() end
        if not is_digit(cur()) then return "invalid exponent" end
        adv()
        while cur() do
            if is_digit(cur()) then adv()
            elseif cur() == "_" then
                adv()
                if not is_digit(cur()) then return "invalid underscore in exponent" end
                adv()
            else break end
        end
    end

    if i <= n then return "unexpected character in number" end
end

---@param s string
---@return boolean
function M.validate_utf8(s)
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        if b < 0x80 then
            i = i + 1
        elseif b < 0xC2 then
            break
        elseif b < 0xE0 then
            if i + 1 > #s then break end
            local b2 = s:byte(i + 1)
            if b2 < 0x80 or b2 > 0xBF then break end
            i = i + 2
        elseif b < 0xF0 then
            if i + 2 > #s then break end
            local b2, b3 = s:byte(i + 1), s:byte(i + 2)
            if b2 < 0x80 or b2 > 0xBF then break end
            if b3 < 0x80 or b3 > 0xBF then break end
            if b == 0xE0 and b2 < 0xA0 then break end
            if b == 0xED and b2 >= 0xA0 then break end
            i = i + 3
        elseif b <= 0xF4 then
            if i + 3 > #s then break end
            local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
            if b2 < 0x80 or b2 > 0xBF then break end
            if b3 < 0x80 or b3 > 0xBF then break end
            if b4 < 0x80 or b4 > 0xBF then break end
            if b == 0xF0 and b2 < 0x90 then break end
            if b == 0xF4 and b2 > 0x8F then break end
            i = i + 4
        else
            break
        end
    end
    return i > #s
end

---@param y number
---@param mo number
---@param d number
---@param h number?
---@param mi number?
---@param sec number?
---@param zone number?
---@return string
function M.format_date_str(y, mo, d, h, mi, sec, zone)
    local s = string.format("%04d-%02d-%02d", y, mo, d)
    if h ~= nil then
        local si = math.floor(sec or 0)
        local sf = (sec or 0) - si
        s = s .. "T" .. string.format("%02d:%02d:%02d", h, mi, si)
        if sf > 0 then s = s .. tostring(sf):sub(2) end
        if zone ~= nil then
            if zone == 0 then
                s = s .. "Z"
            else
                s = s .. string.format("%+03d:00", zone)
            end
        end
    end
    return s
end

---@param h number
---@param mi number
---@param sec number
---@return string
function M.format_time_str(h, mi, sec)
    local si = math.floor(sec or 0)
    local sf = (sec or 0) - si
    local s = string.format("%02d:%02d:%02d", h, mi, si)
    if sf > 0 then s = s .. tostring(sf):sub(2) end
    return s
end

---@param cp integer
---@return string
function M.utf8_encode(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp % 4096 / 64), 0x80 + cp % 64)
    else
        return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp % 262144 / 4096),
            0x80 + math.floor(cp % 4096 / 64), 0x80 + cp % 64)
    end
end

return M
