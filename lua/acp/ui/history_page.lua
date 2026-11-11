-- A contiguous materialised range into the existing Session, not another model.
local M = {}
local Page = {}
Page.__index = Page

local function cost(block)
  return block._bytes or (type(block.text) == "string" and #block.text or 0)
end

function M.new(cfg)
  return setmetatable({ cfg = cfg }, Page)
end

local function edge(blocks, start, direction, cfg)
  local stop, bytes = start, 0
  for i = start, direction < 0 and 1 or #blocks, direction do
    local size = cost(blocks[i])
    if math.abs(i - start) >= cfg.page_blocks or (bytes > 0 and bytes + size > cfg.page_bytes) then
      break
    end
    stop, bytes = i, bytes + size
  end
  return stop
end

function Page:set(blocks, first, last)
  self.first, self.last = first, last
  self.first_id = blocks[first] and blocks[first].id
  self.last_id = blocks[last] and blocks[last].id
end

function Page:sync(session, follow)
  local blocks, n = session.blocks, #session.blocks
  if n == 0 then
    self:set(blocks, 1, 0)
    return 1, 0
  end
  local first, last
  for i, block in ipairs(blocks) do
    if block.id == self.first_id then
      first = i
    end
    if block.id == self.last_id then
      last = i
    end
  end
  if not first or not last or follow then
    last = follow and n or last or n
    first = edge(blocks, last, -1, self.cfg)
  end
  self:set(blocks, first, last)
  return first, last
end

function Page:load(session, direction, pins)
  self:sync(session, false)
  local blocks, first, last = session.blocks, self.first, self.last
  if #blocks == 0 then
    return false
  end
  if direction < 0 then
    if first == 1 then
      return false
    end
    first = edge(blocks, first - 1, -1, self.cfg)
  else
    if last == #blocks then
      return false
    end
    last = edge(blocks, last + 1, 1, self.cfg)
  end
  local bytes = 0
  for i = first, last do
    bytes = bytes + cost(blocks[i])
  end
  local max_bytes = self.cfg.page_bytes * math.ceil(self.cfg.max_blocks / self.cfg.page_blocks)
  local over = last - first + 1 > self.cfg.max_blocks or bytes > max_bytes
  local low_blocks = math.max(self.cfg.page_blocks, math.floor(self.cfg.max_blocks * 0.9))
  local low_bytes = math.max(self.cfg.page_bytes, math.floor(max_bytes * 0.9))
  while over and last > first and (last - first + 1 > low_blocks or bytes > low_bytes) do
    local index = direction < 0 and last or first
    if pins and index >= pins.first and index <= pins.last then
      break
    end
    bytes = bytes - cost(blocks[index])
    if direction < 0 then
      last = last - 1
    else
      first = first + 1
    end
  end
  self:set(blocks, first, last)
  return true
end

function Page:beginning(session)
  local blocks = session.blocks
  self:set(blocks, 1, #blocks == 0 and 0 or edge(blocks, 1, 1, self.cfg))
end

function M.selected(view)
  if vim.api.nvim_get_current_buf() ~= view.buf then
    return false
  end
  local mode = vim.fn.mode()
  return mode == "v" or mode == "V" or mode == "\22" or mode == "s" or mode == "S" or mode == "\19"
end

function M.release(block)
  for key in pairs(block) do
    if type(key) == "string" and (key:match("^_md_") or key == "_diff_cache") then
      block[key] = nil
    end
  end
end

function M.evict(old, current)
  for id, entry in pairs(old) do
    if not current[id] then
      M.release(entry.block)
    end
  end
end

return M
