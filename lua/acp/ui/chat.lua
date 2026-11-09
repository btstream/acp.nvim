-- The transcript window: renders session blocks into a read-only buffer.
local blocks = require("acp.ui.blocks")
local session_state = require("acp.session.state")

local M = {}

local ns = vim.api.nvim_create_namespace("acp_chat")
-- Line-wide backgrounds (code blocks, tool cards) live in their own namespace
-- so they can be repainted per rewritten range without touching the many
-- inline highlight extmarks.
local ns_bg = vim.api.nvim_create_namespace("acp_chat_bg")

---@class AcpChatView
---@field buf integer
---@field win integer|nil
---@field meta table<integer, table>
---@field line_starts table<string, integer>
---@field cache table<string, {sig: string, lines: table[]}>
local Chat = {}
Chat.__index = Chat

---Collect contiguous runs of lines sharing the same background group.
---
---Comparing these runs is how `render` decides whether the painted backgrounds
---need repainting at all: streaming text inside a card changes lines but not
---the layout, so the common tick does no extmark work.
---@param meta table[]
---@return {s: integer, e: integer, group: string}[] runs, using 0-based rows
local function background_runs(meta)
  local runs = {}
  local row = 0
  while row < #meta do
    local bg = meta[row + 1] and meta[row + 1].bg
    if bg then
      local stop = row
      while
        stop + 1 < #meta
        and meta[stop + 2]
        and meta[stop + 2].bg == bg
        and meta[stop + 2].block_id == meta[row + 1].block_id
      do
        stop = stop + 1
      end
      runs[#runs + 1] = { s = row, e = stop + 1, group = bg }
      row = stop + 1
    else
      row = row + 1
    end
  end
  return runs
end

---Paint (or repaint) every line background.
---
---`nvim_buf_clear_namespace` only drops extmarks whose *start* falls inside the
---given range, so a mark spanning several rows survives a partial clear and
---would paint stale rows. Backgrounds are therefore always cleared and redrawn
---as a whole; callers avoid the work when the runs did not change.
---@param buf integer
---@param runs {s: integer, e: integer, group: string}[]
local function paint_backgrounds(buf, runs)
  vim.api.nvim_buf_clear_namespace(buf, ns_bg, 0, -1)
  for _, run in ipairs(runs) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns_bg, run.s, 0, {
      end_row = run.e,
      end_col = 0,
      hl_group = run.group,
      hl_eol = true,
      hl_mode = "combine",
      priority = 50,
      end_right_gravity = false,
    })
  end
end

---@param a {s: integer, e: integer, group: string}[]|nil
---@param b {s: integer, e: integer, group: string}[]
---@return boolean
local function runs_equal(a, b)
  if not a or #a ~= #b then
    return false
  end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if x.s ~= y.s or x.e ~= y.e or x.group ~= y.group then
      return false
    end
  end
  return true
end

-- Exposed for the test suite; not part of the public API.
M._background_runs = background_runs
M._runs_equal = runs_equal

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
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      self:schedule_render()
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      self.needs_force = true
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
  local offset = first_block == 1 and 0 or ((self.row_starts[first_block] or (#self.lines_cache + 1)) - 1)
  local lines, meta, present = {}, {}, {}
  local turn = first_block == 1 and 0 or (self.turn_counts[first_block] or self.render_turns or 0)
  if first_block == 1 and session.trimmed then
    lines[1] = "Earlier messages omitted by local memory limits."
    meta[1] = { kind = "notice", segments = { { s = 0, e = -1, group = "AcpMuted" } } }
  end
  local ctx = {
    icons = self.icons,
    width = self.width,
    cwd = session.cwd,
    show_thoughts = self.show_thoughts,
    thoughts = self.thoughts,
  }
  local separator = self.config.ui.separator or {}
  local removed = {}
  for i = first_block, #self.render_order do
    removed[#removed + 1] = self.render_order[i]
  end
  for i = first_block, #session.blocks do
    local block = session.blocks[i]
    present[block.id] = true
    self.row_starts[i], self.turn_counts[i], self.render_order[i] = offset + #lines + 1, turn, block.id
    if block.kind == "user" then
      turn = turn + 1
      if separator.form ~= "off" and turn > 1 then
        for _, line in ipairs(blocks.render_separator(ctx, { form = separator.form, turn = turn })) do
          lines[#lines + 1] = line.text or ""
          meta[#meta + 1] = { kind = "separator", segments = line.segments, bg = line.bg }
        end
      end
    end
    local entry = self.cache[block.id]
    if not entry or entry.block ~= block or entry.revision ~= block._revision then
      session_state.block_text(block)
      entry = { block = block, revision = block._revision, lines = blocks.render_block(block, ctx) }
      self.cache[block.id] = entry
    end
    self.line_starts[block.id] = offset + #lines + 1
    for _, line in ipairs(entry.lines) do
      lines[#lines + 1] = (line.text or ""):gsub("[\r\n]", " ")
      meta[#meta + 1] = {
        block_id = block.id,
        kind = block.kind,
        status = block.status,
        location = line.location,
        segments = line.segments,
        bg = line.bg,
      }
    end
  end
  for _, id in ipairs(removed) do
    if not present[id] then
      self.cache[id], self.line_starts[id] = nil, nil
    end
  end
  for i = #self.render_order, #session.blocks + 1, -1 do
    self.render_order[i], self.row_starts[i], self.turn_counts[i] = nil, nil, nil
  end
  -- A zero-line thought-only session uses the normal empty hint path.
  if offset == 0 and #lines == 0 then
    lines, meta = { "Start a conversation with the agent." }, { { kind = "empty" } }
  end
  local old_count = #self.lines_cache
  local prefix, suffix = 0, 0
  local old_size = old_count - offset
  local function equal(old_row, new_row)
    return self.lines_cache[old_row] == lines[new_row]
      and vim.deep_equal(self.meta[old_row] and self.meta[old_row].segments, meta[new_row] and meta[new_row].segments)
  end
  while prefix < math.min(old_size, #lines) and equal(offset + prefix + 1, prefix + 1) do
    prefix = prefix + 1
  end
  while suffix < math.min(old_size, #lines) - prefix and equal(old_count - suffix, #lines - suffix) do
    suffix = suffix + 1
  end
  local last = #lines - suffix
  if prefix < last or old_size ~= #lines then
    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(
      self.buf,
      offset + prefix,
      old_count - suffix,
      false,
      vim.list_slice(lines, prefix + 1, last)
    )
    vim.bo[self.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(self.buf, ns, offset + prefix, offset + last)
    for i = prefix + 1, last do
      if meta[i].segments then
        self:apply_line_highlights(offset + i, meta[i].segments, lines[i])
      end
    end
  end
  for i, text in ipairs(lines) do
    self.lines_cache[offset + i], self.meta[offset + i] = text, meta[i]
  end
  for i = old_count, offset + #lines + 1, -1 do
    self.lines_cache[i], self.meta[i] = nil, nil
  end
  local runs, actual = background_runs(meta), {}
  -- Extmarks already move with edits. Reuse them when their actual post-edit
  -- geometry matches the new layout (e.g. prose streaming after a code fence).
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(self.buf, ns_bg, { offset, 0 }, -1, { details = true })) do
    actual[#actual + 1] = { s = mark[2] - offset, e = mark[4].end_row - offset, group = mark[4].hl_group }
  end
  if not runs_equal(actual, runs) then
    vim.api.nvim_buf_clear_namespace(self.buf, ns_bg, offset, -1)
    for _, run in ipairs(runs) do
      vim.api.nvim_buf_set_extmark(self.buf, ns_bg, offset + run.s, 0, {
        end_row = offset + run.e,
        end_col = 0,
        hl_group = run.group,
        hl_eol = true,
        hl_mode = "combine",
        priority = 50,
        end_right_gravity = false,
      })
    end
  end
  self.render_version, self.render_turns = session.version, turn
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

function Chat:schedule_render()
  if self.dirty then
    return
  end
  self.dirty = true
  vim.defer_fn(function()
    self.dirty = false
    -- While the panel is hidden, collapse any number of stream ticks into a
    -- single render when it becomes visible again.
    if not self:is_visible() then
      self.needs_render = true
      return
    end
    self:render()
  end, 40)
end

---Cheap change detector for a block.
---
---Replaces a signature string built with `table.concat` + `tostring` for every
---block on every render tick. Fields are compared directly instead, which
---avoids the allocations while staying just as precise.
---@param block AcpBlock
---@return table
local function block_signature(block)
  -- `raw_output` is only printed for failed tools; inspecting it on every tick
  -- for every block would cost more than the render itself.
  local raw_len = -1
  if block.raw_output ~= nil and block.status == "failed" then
    local dump = type(block.raw_output) == "string" and block.raw_output or vim.inspect(block.raw_output)
    raw_len = #dump
  end
  return {
    kind = block.kind,
    status = block.status,
    expanded = block.expanded,
    text_len = #(block.text or ""),
    title_len = #(block.title or ""),
    detail_len = #(block.detail or ""),
    name_len = #(block.name or ""),
    tool_kind = block.tool_kind,
    severity = block.severity,
    entries = block.entries and #block.entries or 0,
    attachments = block.attachments and #block.attachments or 0,
    locations = block.locations and #block.locations or 0,
    child_title = block.child and block.child.title or nil,
    raw_len = raw_len,
    -- Plan entries render both their text and their status, so a same-count
    -- update has to be detected.
    plan = block.entries and vim.inspect(block.entries) or nil,
  }
end

---Whether two signatures describe the same render output.
---@param a table|nil
---@param b table
---@return boolean
local function signature_equal(a, b)
  if not a then
    return false
  end
  for k, v in pairs(b) do
    if a[k] ~= v then
      return false
    end
  end
  return true
end

---Render all blocks, reusing cached per-block output where unchanged.
---@param force boolean|nil
function Chat:render(force)
  if not vim.api.nvim_buf_is_valid(self.buf) then
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
      vim.bo[self.buf].modifiable = true
      vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { "" })
      vim.bo[self.buf].modifiable = false
      vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
      vim.api.nvim_buf_clear_namespace(self.buf, ns_bg, 0, -1)
    end
    return
  end
  self.buf_cleared = false

  local win = self.win
  if win and vim.api.nvim_win_is_valid(win) then
    local w = math.max(20, vim.api.nvim_win_get_width(win) - 2)
    if w ~= self.width then
      self.width = w
      force = true
    end
  end

  if self.session.tracked and self.render_version ~= nil and not force and not self.full_rewrite then
    local first = self.session:changed_since(self.render_version)
    if not first then
      return
    end
    return self:render_dirty(first)
  end

  local ctx = {
    icons = self.icons,
    width = self.width,
    cwd = self.session.cwd,
    show_thoughts = self.show_thoughts,
    thoughts = self.thoughts,
  }

  if force then
    self.cache = {}
  end

  local lines = {}
  local meta = {}
  if self.session.trimmed then
    lines[1] = "Earlier messages omitted by local memory limits."
    meta[1] = { kind = "notice", segments = { { s = 0, e = -1, group = "AcpMuted" } } }
  end
  local starts = {}
  local seen = {}
  local new_cache = {}
  local separator = self.config.ui.separator or {}
  local show_separator = separator.form ~= "off"
  -- A user block opens a turn, so counting them numbers the turns even for a
  -- replayed session, where no `begin_turn` ran for the replayed messages.
  local turn = 0

  self.row_starts, self.turn_counts, self.render_order = {}, {}, {}
  for index, block in ipairs(self.session.blocks) do
    self.row_starts[index], self.turn_counts[index], self.render_order[index] = #lines + 1, turn, block.id
    seen[block.id] = true
    -- The divider belongs to the transcript, not to any block: it is inserted
    -- between two turns rather than appended to one of them, so it never shows
    -- up as a block the cursor can land on.
    if block.kind == "user" then
      turn = turn + 1
      if show_separator and turn > 1 then
        for _, line in ipairs(blocks.render_separator(ctx, { form = separator.form, turn = turn })) do
          lines[#lines + 1] = line.text or ""
          meta[#meta + 1] = { kind = "separator", segments = line.segments, bg = line.bg }
        end
      end
    end
    -- Join buffered stream chunks before measuring the signature.
    session_state.block_text(block)
    local sig = block_signature(block)
    local entry = self.cache[block.id]
    if
      not entry
      or entry.block ~= block
      or (self.session.tracked and entry.revision ~= block._revision)
      or not signature_equal(entry.sig, sig)
    then
      entry = { block = block, sig = sig, revision = block._revision, lines = blocks.render_block(block, ctx) }
      -- A buffer line cannot contain a newline. Agent supplied text may, so
      -- fold it once here; cached lines are already clean.
      for _, line in ipairs(entry.lines) do
        local text = line.text
        if type(text) ~= "string" or text:find("[\r\n]") then
          line.text = (type(text) == "string" and text or tostring(text or "")):gsub("[\r\n]", " ")
        end
      end
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
        bg = line.bg,
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

  -- Write only the region that actually changed. During streaming that is the
  -- tail, so a long transcript no longer gets memmoved on every chunk.
  --
  -- `lines_cache` mirrors the buffer, so it is only a valid diff base while it
  -- matches. After a session switch (or any full rewrite) it does not, and the
  -- whole buffer has to be replaced.
  local old = self.lines_cache or {}
  local full = self.full_rewrite == true
  if full then
    old = {}
    self.full_rewrite = false
  end
  local prefix = 0
  local max_prefix = math.min(#old, #lines)
  while prefix < max_prefix and old[prefix + 1] == lines[prefix + 1] do
    prefix = prefix + 1
  end
  local suffix = 0
  local max_suffix = math.min(#old, #lines) - prefix
  while suffix < max_suffix and old[#old - suffix] == lines[#lines - suffix] do
    suffix = suffix + 1
  end

  local first = prefix + 1
  local last = #lines - suffix -- inclusive, in new coordinates
  local changed = first <= last or #old ~= #lines

  if changed then
    vim.bo[self.buf].modifiable = true
    -- `#old - suffix` is the exclusive end in the *cache's* coordinates. With
    -- an empty cache that is 0, and `set_lines(buf, 0, 0, ...)` inserts instead
    -- of replacing, leaving the previous transcript in place. Use -1 ("end of
    -- buffer") for a full rewrite.
    local end_line = full and -1 or (#old - suffix)
    vim.api.nvim_buf_set_lines(self.buf, prefix, end_line, false, vim.list_slice(lines, first, last))
    vim.bo[self.buf].modifiable = false

    if full then
      vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
    else
      -- Clear the rewritten range in *new* buffer coordinates. Using the old
      -- end here was a bug: when a block changes height the buffer gets shorter
      -- or longer, so the old offset reaches past the rewritten region and
      -- wipes the extmarks of every line that shifted into it.
      vim.api.nvim_buf_clear_namespace(self.buf, ns, prefix, last)
    end
    for i = first, last do
      local entry = meta[i]
      if entry and entry.segments then
        self:apply_line_highlights(i, entry.segments, lines[i])
      end
    end
  end

  -- Backgrounds are repainted as a whole whenever their layout shifts. A card
  -- whose text streams in keeps the same layout, so the common tick does no
  -- extmark work here.
  local runs = background_runs(meta)
  local runs_changed = changed or not runs_equal(self.bg_runs, runs)
  if runs_changed then
    paint_backgrounds(self.buf, runs)
    self.bg_runs = runs
  end

  self.meta = meta
  self.lines_cache = lines
  self.line_starts = starts
  self.render_version, self.render_turns = self.session.version, turn

  -- A block that was just toggled keeps the cursor: expanding or collapsing it
  -- is a deliberate action, not new output to follow.
  if self.keep_block then
    local row = starts[self.keep_block]
    self.keep_block = nil
    if row and self:is_visible() then
      pcall(vim.api.nvim_win_set_cursor, self.win, { row, 0 })
    end
  elseif self.follow then
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
      if seg.conceal then
        -- Markup delimiters stay in the text so byte offsets remain stable;
        -- conceal hides them instead. Requires 'conceallevel' >= 2.
        pcall(vim.api.nvim_buf_set_extmark, self.buf, ns, index - 1, s, {
          end_col = e,
          conceal = "",
        })
      elseif seg.group then
        pcall(vim.api.nvim_buf_set_extmark, self.buf, ns, index - 1, s, {
          end_col = e,
          hl_group = seg.group,
          priority = 100,
        })
      end
      -- A segment without a group is intentionally left unhighlighted so it
      -- inherits whatever background is behind it (e.g. a card).
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
  if self.needs_render then
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
