-- The transcript window: owns the buffer, follow/scroll behaviour and cursor
-- mapping. Layout comes from `acp.ui.transcript`; buffer writes, highlights and
-- backgrounds come from `acp.ui.buffer_renderer`.
local blocks = require("acp.ui.blocks")
local transcript = require("acp.ui.transcript")
local renderer = require("acp.ui.buffer_renderer")
local viewport = require("acp.ui.viewport")

local RESIZE_DELAY = 100

local function stop_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local M = {}

---@class AcpChatView
---@field buf integer
---@field win integer|nil
---@field meta table<integer, table>
---@field line_starts table<string, integer>
---@field cache table<string, {sig: string, lines: table[]}>
local Chat = {}
Chat.__index = Chat

-- Exposed for the test suite; not part of the public API.
M._background_runs = renderer.background_runs
M._runs_equal = renderer.runs_equal

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
    bg_runs = nil,
    follow = opts.config.ui.follow_output,
    pending_new = false,
    width = 80,
    show_thoughts = opts.config.ui.show_thoughts,
    thoughts = opts.config.ui.thoughts,
    diff = opts.config.ui.diff,
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
  self.augroup = group
  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
    group = group,
    buffer = self.buf,
    callback = function()
      self:on_enter()
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      self:on_resize()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local win = tonumber(args.match)
      if win == self.win or win == self.resize_win then
        self:cancel_resize()
        self.needs_render = true
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      self.needs_force = true
      self:schedule_render("layout")
    end,
  })

  return self
end

---@param session AcpSessionState|nil
function Chat:set_session(session)
  if self.session == session then
    return
  end
  self:cancel_resize()
  self.session = session
  self.render_version = nil
  self.row_starts, self.turn_counts, self.render_order = {}, {}, {}
  self.cache = {}
  self.line_starts = {}
  self.meta = {}
  -- The buffer still holds the previous session's transcript while
  -- `lines_cache` is now empty. The incremental writer diffs against that
  -- cache, so it must be told to replace the whole buffer instead: otherwise
  -- it inserts the new lines at the top and leaves the old ones behind.
  self.lines_cache = {}
  self.bg_runs = nil
  self.full_rewrite = true
  self.pending_new = false
  self.follow = self.config.ui.follow_output
  self:render()
end

---Update only the dirty block and the suffix whose row coordinates may move.
---Stable prefixes keep their strings, metadata tables and extmarks unchanged.
function Chat:render_dirty(first_block)
  local session = self.session
  local layout = transcript.dirty(session, self, first_block)
  renderer.write_suffix(self.buf, layout.lines, layout.meta, self.lines_cache, self.meta, layout.offset)

  local offset = layout.offset
  for i, text in ipairs(layout.lines) do
    self.lines_cache[offset + i], self.meta[offset + i] = text, layout.meta[i]
  end
  for i = #self.lines_cache, offset + #layout.lines + 1, -1 do
    self.lines_cache[i], self.meta[i] = nil, nil
  end

  self.render_version, self.render_turns = session.version, layout.turns
  self.bg_runs = nil -- rebuilt if a full/fallback render is requested
  if self.keep_block then
    local row = self.line_starts[self.keep_block]
    self.keep_block = nil
    if row and self:is_visible() then
      pcall(vim.api.nvim_win_set_cursor, self.win, { row, 0 })
    end
  elseif self.follow then
    self:scroll_to_bottom()
  elseif self:is_visible() and not self.pending_new then
    self.pending_new = true
    if self.on_pending_new then
      self.on_pending_new(true)
    end
  end
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

function Chat:cancel_resize()
  stop_timer(self.resize_timer)
  self.resize_timer, self.resize_win, self.resize_width = nil, nil, nil
end

---React only to this view's actual geometry. Event window lists differ between
---VimResized, WinResized and layout backends; comparing width is cheap and also
---filters unrelated window events and height-only changes.
function Chat:on_resize()
  if self.destroyed or not self:is_visible() then
    return
  end
  local width = math.max(20, vim.api.nvim_win_get_width(self.win) - 2)
  local height = vim.api.nvim_win_get_height(self.win)
  if width == self.width then
    self:cancel_resize()
    if self.height ~= height and self.follow then
      self:scroll_to_bottom()
    end
    self.height = height
    return
  end
  self.height = height
  if self.resize_timer and self.resize_width == width then
    return -- an unrelated window event must not postpone an already queued width
  end
  self:cancel_resize()
  self.resize_win, self.resize_width = self.win, width
  local timer
  timer = vim.defer_fn(function()
    if self.destroyed or self.resize_timer ~= timer then
      return
    end
    self.resize_timer, self.resize_win, self.resize_width = nil, nil, nil
    if not self:is_visible() then
      self.needs_render = true
      return
    end
    self:render(nil, "layout")
  end, RESIZE_DELAY)
  self.resize_timer = timer
end

function Chat:schedule_render(reason)
  if self.destroyed then
    return
  end
  -- A coalesced layout refresh must not hide a genuine content update.
  reason = reason or "content"
  if reason == "content" or not self.render_reason then
    self.render_reason = reason
  end
  if self.dirty then
    return
  end
  self.dirty = true
  local timer
  timer = vim.defer_fn(function()
    if self.destroyed or self.render_timer ~= timer then
      return
    end
    self.render_timer = nil
    self.dirty = false
    local pending_reason = self.render_reason
    self.render_reason = nil
    -- While the panel is hidden, collapse any number of stream ticks into a
    -- single render when it becomes visible again.
    if not self:is_visible() then
      self.needs_render = true
      return
    end
    self:render(nil, pending_reason)
  end, 40)
  self.render_timer = timer
end

---@param index integer
---@param segments table[]
---@param text string
function Chat:apply_line_highlights(index, segments, text)
  renderer.highlight_line(self.buf, index, segments, text)
end

---Render all blocks, reusing cached per-block output where unchanged.
---@param force boolean|nil
---@param reason "content"|"layout"|nil
function Chat:render(force, reason)
  if self.destroyed or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  self.needs_render = false
  force = force or self.needs_force
  self.needs_force = false
  if not self.session then
    -- No session: clear the transcript instead of leaving the previous
    -- conversation on screen (e.g. right after deleting the active session).
    -- The `buf_cleared` flag matters because `set_session` empties
    -- `lines_cache` before rendering, so it cannot be used as the "is the
    -- buffer already empty" test.
    if not self.buf_cleared then
      self.buf_cleared = true
      self.cache = {}
      self.lines_cache = {}
      self.bg_runs = nil
      self.meta = {}
      self.line_starts = {}
      renderer.replace(self.buf, { "" }, {}, true)
      vim.api.nvim_buf_clear_namespace(self.buf, renderer.ns_bg, 0, -1)
    end
    return
  end
  self.buf_cleared = false

  local win = self.win
  local width_changed = false
  if win and vim.api.nvim_win_is_valid(win) then
    self.height = vim.api.nvim_win_get_height(win)
    local w = math.max(20, vim.api.nvim_win_get_width(win) - 2)
    -- Stream ticks keep rendering at the last settled width while a drag is
    -- in progress. They are never delayed by resize debounce; the final layout
    -- pass uses the latest content and actual window width.
    if w ~= self.width and (not self.resize_timer or reason == "layout" or force or self.full_rewrite) then
      self.width = w
      force = true
      width_changed = true
      self:cancel_resize()
    end
  end

  local content_changed = self.render_version ~= nil and self.session.version ~= self.render_version
  local layout_only = (reason == "layout" or width_changed) and not content_changed and not self.full_rewrite
  local saved_view
  if (reason == "layout" or width_changed) and not self.follow then
    saved_view = viewport.capture(self)
  end

  if self.session.tracked and self.render_version ~= nil and not force and not self.full_rewrite then
    local first = self.session:changed_since(self.render_version)
    if not first then
      return
    end
    return self:render_dirty(first)
  end

  local layout = transcript.full(self.session, self, { force = force })

  local old = self.lines_cache or {}
  local full_rewrite = self.full_rewrite == true
  if full_rewrite then
    old = {}
    self.full_rewrite = false
  end
  local changed = renderer.write(self.buf, layout.lines, layout.meta, old, full_rewrite)

  self.bg_runs = renderer.sync_backgrounds(self.buf, self.bg_runs, layout.meta, changed)
  self.meta = layout.meta
  self.lines_cache = layout.lines
  self.line_starts = layout.starts
  self.row_starts, self.turn_counts, self.render_order = layout.row_starts, layout.turn_counts, layout.render_order
  self.cache = layout.cache
  self.render_version, self.render_turns = self.session.version, layout.turns

  -- A block that was just toggled keeps the cursor: expanding or collapsing it
  -- is a deliberate action, not new output to follow.
  if self.keep_block then
    local row = layout.starts[self.keep_block]
    self.keep_block = nil
    if row and self:is_visible() then
      pcall(vim.api.nvim_win_set_cursor, self.win, { row, 0 })
    end
  elseif self.follow then
    self:scroll_to_bottom()
  elseif self:is_visible() then
    viewport.restore(self, saved_view)
    if not layout_only and not self.pending_new then
      self.pending_new = true
      if self.on_pending_new then
        self.on_pending_new(true)
      end
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
  if block.kind == "tool" or block.kind == "compaction" or block.kind == "thought" then
    self.session:toggle(block)
    -- Expanding changes the transcript height. Without this the renderer would
    -- treat the view as "following output" and jump the cursor to the end of the
    -- buffer, which is disorienting when the user just opened a block to read it.
    self.keep_block = block.id
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
  if win and vim.api.nvim_win_is_valid(win) then
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
  -- Renders are grouped so windows can report multiple resizes; fold one
  -- pending render before touching line coordinates.
  if self.resize_timer then
    self:cancel_resize()
    self:render(nil, "layout")
  elseif self.needs_render then
    self:render()
  end
  -- `line_starts` is filled in block order, so its values are already sorted.
  local starts = {}
  for _, block in ipairs(self.session and self.session.blocks or {}) do
    local s = self.line_starts[block.id]
    if s then
      starts[#starts + 1] = s
    end
  end
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

---Tear down the view: drop its buffer and autocmd group.
function Chat:destroy()
  self.destroyed = true
  self:cancel_resize()
  stop_timer(self.render_timer)
  self.render_timer, self.render_reason, self.dirty = nil, nil, false
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  self.buf = nil
  self.win = nil
end

function Chat:is_visible()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---Copy the full transcript as plain text.
---
---Trailing padding is stripped: cards and code blocks pad their lines with real
---spaces (extmarks cannot colour past the end of a line), and those spaces are
---a rendering detail rather than content.
---@return string
function Chat:transcript()
  local lines = self.lines_cache
  if not lines or #lines == 0 then
    if not vim.api.nvim_buf_is_valid(self.buf) then
      return ""
    end
    lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = (line:gsub("%s+$", ""))
  end
  return table.concat(out, "\n")
end

return M
