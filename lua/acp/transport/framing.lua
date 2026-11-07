-- Newline-delimited framing for ACP's stdio transport.
local M = {}

---@class AcpDecoder
---@field buf string
---@field max integer
---@field failed boolean
local Decoder = {}
Decoder.__index = Decoder

---@param max integer|nil maximum buffered bytes for an incomplete message
---@return AcpDecoder
function M.new_decoder(max)
  return setmetatable({
    buf = "",
    max = max or 8 * 1024 * 1024,
    failed = false,
  }, Decoder)
end

---Feed raw bytes, invoking `on_line` for every complete line.
---@param chunk string
---@param on_line fun(line: string)
---@return boolean ok
function Decoder:feed(chunk, on_line)
  if self.failed then
    return false
  end
  self.buf = self.buf .. chunk
  local start = 1
  while true do
    local nl = self.buf:find("\n", start, true)
    if not nl then
      break
    end
    local line = self.buf:sub(start, nl - 1)
    start = nl + 1
    if #line > 0 then
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end
      if #line > 0 then
        on_line(line)
      end
    end
  end
  self.buf = self.buf:sub(start)
  if #self.buf > self.max then
    self.failed = true
    self.buf = ""
    return false
  end
  return true
end

---Encode a payload as a single protocol line.
---@param obj table
---@return string
function M.encode(obj)
  return vim.json.encode(obj) .. "\n"
end

return M
