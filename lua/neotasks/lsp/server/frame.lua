-- Wire framing shared by thread_client.lua (main thread) and thread_server.lua
-- (uv worker thread): a 4-byte big-endian length prefix followed by a
-- vim.mpack-encoded payload. string.pack/unpack aren't available in
-- Neovim's bundled Lua, so the length is packed/unpacked by hand.
local M = {}

---@param n integer
---@return string
local function pack_u32(n)
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256
  )
end

---@param s   string
---@param pos integer
---@return integer
local function unpack_u32(s, pos)
  local b1, b2, b3, b4 = s:byte(pos, pos + 3)
  return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

---@param obj table
---@return string
function M.encode(obj)
  local payload = vim.mpack.encode(obj)
  return pack_u32(#payload) .. payload
end

-- Consumes as many complete frames as are present in `buf`, calling
-- `on_message(obj)` for each. Returns the leftover (possibly partial) bytes.
---@param buf string
---@param on_message fun(obj: table)
---@return string
function M.feed(buf, on_message)
  while #buf >= 4 do
    local len = unpack_u32(buf, 1)
    if #buf < 4 + len then break end
    local payload = buf:sub(5, 4 + len)
    buf = buf:sub(5 + len)
    local ok, msg = pcall(vim.mpack.decode, payload)
    if ok and type(msg) == "table" then
      on_message(msg)
    end
  end
  return buf
end

return M
