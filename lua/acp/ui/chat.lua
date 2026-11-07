-- The transcript window: renders session blocks into a read-only buffer.
local blocks = require("acp.ui.blocks")

local M = {}

local ns = vim.api.nvim_create_namespace("acp_chat")

---@class AcpChatView
---@field buf integer
---@field win integer|nil
---@field meta table<integer, table>
---@field line_starts table<string, integer>
---@field cache table<string, {sig: string, lines: table[]}>
local Chat = {}
Chat.__index = Chat

---@param opts {config: table}
---@return AcpChatView
function M.new(opts)
  local self = setmetatable({
    config = opts.config,
    buf = nil,
    win = nil,
    meta = {},
    line_starts = {},
    cache = {},
    follow = opts.config.ui.follow_output,
    pending_new = false,
    width = 80,
    show_thoughts = opts.config.ui.show_thoughts,
    icons = blocks.icon_set(opts.config.ui.icons),
    session = nil,
    dirty = false,
  }, Chat)

  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "hide"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].modifiable = false
  vim.bo[self.buf].filetype = "acp_chat"
  vim.bo[self.buf].buflisted = false
  vim.bo[self.buf].undolevels = -1

  local group = vim.api.nvim_create_augroup("AcpChat" .. self.buf, { clear = true })
  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
    group = group,
    buffer = self.buf,
    callback = function()
      self:on_enter()
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      self:schedule_render()
    end,
  })

  return self
end

---@param session AcpSessionState|nil
function Chat:set_session(session)
  if self.session == session then
    return
  end
  self.session = session
  self.cache = {}
  self.line_starts = {}
  self.meta = {}
  self.pending_new = false
  self.follow = self.config.ui.follow_output
  self:render()
end

function Chat:on_enter()
  if not self.session then
    return
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(self.buf)
  self.follow = cursor[1] >= line_count - 1
end

function Chat:schedule_render()
  if self.dirty then
    return
  end
  self.dirty = true
  vim.defer_fn(function()
    self.dirty = false
    self:render()
  end, 40)
end

---@param block AcpBlock
---@return string
local function block_signature(block)
  return table.concat({
    block.kind or "",
    block.status or "",
    block.expanded and "1" or "0",
    tostring(#(block.text or "")),
    tostring(#(block.title or "")),
    tostring(#(block.detail or "")),
    tostring(block.entries and #block.entries or 0),
    tostring(block.attachments and #block.attachments or 0),
    tostring(block.severity or ""),
    tostring(block.child and block.child.title or ""),
    tostring(block.locations and #block.locations or 0),
  }, "|")
end

---Render all blocks, reusing cached per-block output where unchanged.
---@param force boolean|nil
function Chat:render(force)
  if not self.session then
    return
  end
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  local win = self.win
  if win and vim.api.nvim_win_is_valid(win) then
    local w = math.max(20, vim.api.nvim_win_get_width(win) - 2)
    if w ~= self.width then
      self.width = w
      force = true
    end
  end

  local ctx = {
    icons = self.icons,
    width = self.width,
    cwd = self.session.cwd,
    show_thoughts = self.show_thoughts,
  }

  if force then
    self.cache = {}
  end

  local lines = {}
  local meta = {}
  local starts = {}
  local seen = {}
  local new_cache = {}

  for _, block in ipairs(self.session.blocks) do
    seen[block.id] = true
    local sig = block_signature(block)
    local entry = self.cache[block.id]
    if not entry or entry.sig ~= sig then
      entry = { sig = sig, lines = blocks.render_block(block, ctx) }
    end
    new_cache[block.id] = entry
    starts[block.id] = #lines + 1
    for _, line in ipairs(entry.lines) do
      lines[#lines + 1] = line.text or ""
      meta[#meta + 1] = {
        block_id = block.id,
        kind = block.kind,
        status = block.status,
        location = line.location,
        segments = line.segments,
      }
    end
  end

  -- Drop cache entries for removed blocks.
  for id in pairs(self.cache) do
    if not seen[id] then
      new_cache[id] = nil
    end
  end
  self.cache = new_cache

  if #lines == 0 then
    lines = { "Start a conversation with the agent." }
    meta = { { kind = "empty" } }
  end

  -- A buffer line cannot contain a newline. Agent supplied text may, so make
  -- sure every line is a single line before writing it.
  for i, line in ipairs(lines) do
    if type(line) ~= "string" or line:find("[\r\n]") then
      lines[i] = (type(line) == "string" and line or tostring(line or "")):gsub("[\r\n]", " ")
    end
  end

  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  for i, entry in ipairs(meta) do
    if entry.segments then
      self:apply_line_highlights(i, entry.segments, lines[i])
    end
  end

  self.meta = meta
  self.lines_cache = lines
  self.line_starts = starts

  if self.follow then
    self:scroll_to_bottom()
  elseif self:is_visible() then
    if not self.pending_new then
      self.pending_new = true
      if self.on_pending_new then
        self.on_pending_new(true)
      end
    end
  end
end

---@param index integer
---@param segments table[]
---@param text string
function Chat:apply_line_highlights(index, segments, text)
  local byte_len = #text
  for _, seg in ipairs(segments) do
    local s = math.max(0, math.min(seg.s or 0, byte_len))
    local e = seg.e
    if e == nil or e < 0 or e > byte_len then
      e = byte_len
    end
    if e > s then
      pcall(vim.api.nvim_buf_set_extmark, self.buf, ns, index - 1, s, {
        end_col = e,
        hl_group = seg.group,
        priority = 100,
      })
    end
  end
end

function Chat:scroll_to_bottom()
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    self.follow = true
    self.pending_new = false
    return
  end
  local count = vim.api.nvim_buf_line_count(self.buf)
  pcall(vim.api.nvim_win_set_cursor, win, { count, 0 })
  self.follow = true
  if self.pending_new then
    self.pending_new = false
    if self.on_pending_new then
      self.on_pending_new(false)
    end
  end
end

function Chat:scroll_to_top()
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  self.follow = false
end

---Block under the cursor.
---@return table|nil block
function Chat:block_at_cursor()
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= self.buf then
      return nil
    end
  end
  local idx = vim.api.nvim_win_get_cursor(win)[1]
  local entry = self.meta[idx]
  if not entry or not entry.block_id or not self.session then
    return nil
  end
  for _, block in ipairs(self.session.blocks) do
    if block.id == entry.block_id then
      return block
    end
  end
  return nil
end

---Toggle the block under the cursor if it supports expansion.
---@return boolean
function Chat:toggle_current()
  local block = self:block_at_cursor()
  if not block then
    return false
  end
  if block.kind == "tool" or block.kind == "compaction" then
    block.expanded = not block.expanded
    self:schedule_render()
    return true
  end
  return false
end

---Whether new output arrived while the user was reading history.
---@return boolean
function Chat:has_new_output()
  return self.pending_new == true
end

---Follow new output again from this point on.
function Chat:resume_follow()
  self:scroll_to_bottom()
end

---Location metadata on the current line, if any.
---@return table|nil
function Chat:location_at_cursor()
  local win = self.win
  if not win or vim.api.nvim_win_is_valid(win) then
    if vim.api.nvim_win_get_buf(win) == self.buf then
      local idx = vim.api.nvim_win_get_cursor(win)[1]
      local entry = self.meta[idx]
      if entry and entry.location then
        return entry.location
      end
    end
  end
  return nil
end

function Chat:set_show_thoughts(value)
  if self.show_thoughts == value then
    return
  end
  self.show_thoughts = value
  self:render(true)
end

---Move to the next or previous block header.
---@param direction integer
function Chat:jump_block(direction)
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local starts = {}
  for _, s in pairs(self.line_starts) do
    starts[#starts + 1] = s
  end
  table.sort(starts)
  local target
  if direction > 0 then
    for _, s in ipairs(starts) do
      if s > cur then
        target = s
        break
      end
    end
  else
    for i = #starts, 1, -1 do
      if starts[i] < cur then
        target = starts[i]
        break
      end
    end
  end
  if target then
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    self.follow = false
  end
end

function Chat:is_visible()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---Copy the full transcript as plain text.
---@return string
function Chat:transcript()
  if self.lines_cache and #self.lines_cache > 0 then
    return table.concat(self.lines_cache, "\n")
  end
  if vim.api.nvim_buf_is_valid(self.buf) then
    return table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
  end
  return ""
end

return M
