-- Newline-delimited framing for ACP's stdio transport.
local M = {}

---@class AcpDecoder
---@field parts string[] pending chunks of an incomplete line
---@field max integer
---@field failed boolean
---@field failed_size integer|nil size of the message that hit the limit
local Decoder = {}
Decoder.__index = Decoder

---Hook for reporting a failing `on_line` handler. Overridable so this module
---stays free of a hard dependency on the logger.
---@param err any
function M.on_handler_error(err)
  -- Default: re-raise as a plain message so it shows up in the log without
  -- aborting the read loop.
  pcall(function()
    require("acp.log").error("protocol line handler failed: %s", tostring(err))
  end)
end

---@param max integer|nil maximum buffered bytes for an incomplete message
---@return AcpDecoder
function M.new_decoder(max)
  return setmetatable({
    parts = {},
    buffered = 0,
    max = max or 8 * 1024 * 1024,
    failed = false,
  }, Decoder)
end

---Feed raw bytes, invoking `on_line` for every complete line.
---
---Chunks are buffered in a list rather than concatenated into one growing
---string: a multi-megabyte message arriving in many small reads used to copy
---the whole buffer on every chunk (O(n²)).
---@param chunk string
---@param on_line fun(line: string)
---@return boolean ok
function Decoder:feed(chunk, on_line)
  if self.failed then
    return false
  end
  if chunk == "" then
    return true
  end

  -- Fast path: a chunk without a newline is just appended. Concatenating the
  -- pending fragments only happens once a line actually completes, so a large
  -- message arriving in many reads costs O(n) instead of O(n²).
  if not chunk:find("\n", 1, true) then
    self.parts[#self.parts + 1] = chunk
    self.buffered = self.buffered + #chunk
    if self.buffered > self.max then
      self.failed, self.failed_size = true, self.buffered
      self.parts = {}
      self.buffered = 0
      return false
    end
    return true
  end

  local pending
  if #self.parts == 0 then
    pending = chunk
  else
    self.parts[#self.parts + 1] = chunk
    pending = table.concat(self.parts)
    self.parts = {}
  end
  self.buffered = 0

  local start = 1
  while true do
    local nl = pending:find("\n", start, true)
    if not nl then
      break
    end
    -- Check before allocating/decoding the complete line too, not only the
    -- unterminated tail. A single read may contain an oversized whole message.
    local size = nl - start
    if pending:sub(nl - 1, nl - 1) == "\r" then
      size = size - 1
    end
    if size > self.max then
      self.failed, self.failed_size = true, size
      self.parts, self.buffered = {}, 0
      return false
    end
    local line = pending:sub(start, nl - 1)
    start = nl + 1
    if #line > 0 then
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end
      if #line > 0 then
        -- A raising handler must not prevent the remaining lines from being
        -- committed: without this the buffer stayed at the old offset and the
        -- same lines were replayed on the next chunk.
        local ok, err = pcall(on_line, line)
        if not ok then
          M.on_handler_error(err)
        end
      end
    end
  end
  local rest = pending:sub(start)
  if #rest > 0 then
    self.parts[1] = rest
    self.buffered = #rest
  end
  if self.buffered > self.max then
    self.failed, self.failed_size = true, self.buffered
    self.parts = {}
    self.buffered = 0
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
