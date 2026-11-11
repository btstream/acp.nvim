-- The transcript window: owns the buffer, follow/scroll behaviour and cursor
-- mapping. Layout comes from `acp.ui.transcript`; buffer writes, highlights and
-- backgrounds come from `acp.ui.buffer_renderer`.
local blocks = require("acp.ui.blocks")
local transcript = require("acp.ui.transcript")
local renderer = require("acp.ui.buffer_renderer")
local viewport = require("acp.ui.viewport")
local decoration = require("acp.ui.decoration")
local metrics = require("acp.ui.render_metrics")
local HistoryPage = require("acp.ui.history_page")
local CodeHL = require("acp.ui.code_hl")
local work = require("acp.ui.work_scheduler")

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

  -- Insert mode in a read-only transcript only swallows keys (and even errors
  -- with E21 for some entry commands). Keep the view in normal mode; `i` is
  -- separately bound to the composer by the default chat keymaps.
  for _, key in ipairs({ "i", "I", "a", "A", "o", "O", "s", "S", "c", "C", "R", "gR", "gi", "gI" }) do
    vim.keymap.set("n", key, "<Nop>", {
      buffer = self.buf,
      desc = "acp: keep the transcript in normal mode",
    })
  end

  local group = vim.api.nvim_create_augroup("AcpChat" .. self.buf, { clear = true })
  self.augroup = group
  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
    group = group,
    buffer = self.buf,
    callback = function()
      self:on_enter()
    end,
  })
  -- Switching windows/buffers while already inserting does not fire InsertEnter.
  -- Cover direct focus changes too, without affecting the composer or editors.
  local leave_insert = vim.api.nvim_replace_termcodes(
    "<Cmd>lua if vim.api.nvim_get_current_buf() == " .. self.buf .. " then vim.cmd('stopinsert') end<CR>",
    true,
    false,
    true
  )
  vim.api.nvim_create_autocmd({ "InsertEnter", "WinEnter", "BufEnter", "BufWinEnter" }, {
    group = group,
    buffer = self.buf,
    callback = function(args)
      if vim.api.nvim_get_current_buf() == self.buf then
        vim.cmd("stopinsert")
        if args.event == "InsertEnter" then
          -- InsertEnter runs before insert mode is fully established; its
          -- stopinsert can be overwritten by :startinsert. Put a guarded command
          -- ahead of typeahead so it runs once entry has actually completed.
          vim.api.nvim_feedkeys(leave_insert, "ni", false)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      self:on_resize()
    end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      decoration.schedule(self)
      self:on_scroll()
    end,
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    buffer = self.buf,
    callback = function()
      if self.needs_render and not HistoryPage.selected(self) then
        self:schedule_render()
      end
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
  decoration.cancel(self)
  viewport.clear_tail(self)
  self.tail_follow_pending, self.tail_clamp_pending = nil, nil
  if self.buf then
    work.shared:cancel(function(job)
      return job.key == self.buf
    end)
  end
  if self.commit_job and self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(function()
      vim.bo[self.buf].modifiable = false
    end)
  end
  self.commit_job = nil
  self.layout_epoch = (self.layout_epoch or 0) + 1
  self.layout_job = nil
  self.page_target = nil
  local paging = self.config.ui.render and self.config.ui.render.pagination
  self.page = paging and paging.enabled and HistoryPage.new(paging) or nil
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
  self.first_paint = metrics.start(self)
  if self.page then
    renderer.replace(self.buf, { "Loading conversation…" }, {}, true)
    vim.api.nvim_buf_clear_namespace(self.buf, decoration.ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.buf, renderer.ns_bg, 0, -1)
  end
  self:render()
end

---Update only the dirty block and the suffix whose row coordinates may move.
---Stable prefixes keep their strings, metadata tables and extmarks unchanged.
function Chat:render_dirty(first_block)
  local session = self.session
  local saved_view = not self.follow and viewport.capture(self) or nil
  local started = metrics.start(self)
  local layout = transcript.dirty(session, self, first_block)
  metrics.record(self, "layout", started)
  self:apply_dirty(layout, saved_view)
end

function Chat:apply_dirty(layout, saved_view)
  local session = self.session
  decoration.clear(self)
  local started = metrics.start(self)
  renderer.write_suffix(self.buf, layout.lines, layout.meta, self.lines_cache, self.meta, layout.offset)
  metrics.record(self, "write", started)

  local offset = layout.offset
  for i, text in ipairs(layout.lines) do
    self.lines_cache[offset + i], self.meta[offset + i] = text, layout.meta[i]
  end
  for i = #self.lines_cache, offset + #layout.lines + 1, -1 do
    self.lines_cache[i], self.meta[i] = nil, nil
  end

  self.render_version, self.render_turns = session.version, layout.turns
  if not self.follow then
    viewport.refresh_tail(self)
  end
  self.bg_runs = nil -- rebuilt if a full/fallback render is requested
  if self.keep_block then
    local row = self.line_starts[self.keep_block]
    self.keep_block = nil
    if row and self:is_visible() then
      pcall(vim.api.nvim_win_set_cursor, self.win, { row, 0 })
    end
  elseif self.follow then
    self.committing = true
    self:scroll_to_bottom()
    self.committing = nil
  elseif self:is_visible() then
    viewport.restore(self, saved_view)
    if not self.pending_new then
      self.pending_new = true
      if self.on_pending_new then
        self.on_pending_new(true)
      end
    end
  end
  decoration.schedule(self)
end

function Chat:on_enter()
  if not self.session or self.render_version == nil or self.layout_job or self.commit_job then
    return
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(self.buf)
  self.follow = cursor[1] >= line_count - 1 and (not self.page or self.page.last == #self.session.blocks)
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
  if self.commit_job then
    self.needs_render = true
    self.needs_force = self.needs_force or force
    return
  end
  if self.page and HistoryPage.selected(self) then
    self.needs_render = true
    self.needs_force = self.needs_force or force
    return
  end
  if not self.session then
    -- No session: clear the transcript instead of leaving the previous
    -- conversation on screen (e.g. right after deleting the active session).
    -- The `buf_cleared` flag matters because `set_session` empties
    -- `lines_cache` before rendering, so it cannot be used as the "is the
    -- buffer already empty" test.
    if not self.buf_cleared then
      self.layout_epoch = (self.layout_epoch or 0) + 1
      self.layout_job = nil
      self.buf_cleared = true
      self.cache = {}
      self.lines_cache = {}
      self.bg_runs = nil
      self.meta = {}
      self.line_starts = {}
      renderer.replace(self.buf, { "" }, {}, true)
      vim.api.nvim_buf_clear_namespace(self.buf, renderer.ns_bg, 0, -1)
      vim.api.nvim_buf_clear_namespace(self.buf, decoration.ns, 0, -1)
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

  if self.page then
    return self:render_async(force, layout_only)
  end

  if self.session.tracked and self.render_version ~= nil and not force and not self.full_rewrite then
    local first = self.session:changed_since(self.render_version)
    if not first then
      return
    end
    return self:render_dirty(first)
  end

  local started = metrics.start(self)
  local layout = transcript.full(self.session, self, { force = force })
  metrics.record(self, "layout", started)

  self:apply_layout(layout, layout_only, saved_view)
end

---Commit only completed, current layouts. Shared by eager and batched paths.
function Chat:apply_layout(layout, layout_only, saved_view)
  decoration.clear(self)
  local old = self.lines_cache or {}
  local full_rewrite = self.full_rewrite == true
  if full_rewrite then
    old = {}
    self.full_rewrite = false
  end
  local render = self.config.ui.render
  local rows = math.max(#layout.lines, #old)
  local limit = render and render.commit_rows
  if limit and limit > 0 and rows > limit then
    return self:commit_layout_async(layout, layout_only, saved_view, limit, old, full_rewrite)
  end
  local started = metrics.start(self)
  local changed = renderer.write(self.buf, layout.lines, layout.meta, old, full_rewrite)
  self.bg_runs = renderer.sync_backgrounds(self.buf, self.bg_runs, layout.meta, changed)
  metrics.record(self, "write", started, { rows = rows })
  self:finish_layout(layout, layout_only, saved_view)
end

---A first paint or page swap can be tens of thousands of rows. Write it in
---bounded slices instead of freezing the loop for the whole buffer.
function Chat:commit_layout_async(layout, layout_only, saved_view, chunk_rows, old, full)
  local epoch, buf, session = (self.layout_epoch or 0) + 1, self.buf, self.session
  local version = session and session.version
  self.layout_epoch = epoch
  local job = { epoch = epoch, version = version }
  self.commit_job = job
  local win, width, generation, thoughts = self.win, self.width, CodeHL.generation, self.show_thoughts
  local started = metrics.start(self)
  local co = renderer.write_chunked(buf, layout.lines, layout.meta, old or {}, full, chunk_rows)
  local function current()
    return not self.destroyed
      and self.layout_epoch == epoch
      and self.buf == buf
      and vim.api.nvim_buf_is_valid(buf)
      and self.session == session
      and session.version == version
      and self.commit_job == job
      and self:is_visible()
      and self.win == win
      and vim.api.nvim_win_get_buf(win) == buf
      and self.width == width
      and math.max(20, vim.api.nvim_win_get_width(win) - 2) == width
      and CodeHL.generation == generation
      and self.show_thoughts == thoughts
  end
  local function abandon()
    if self.commit_job ~= job then
      return
    end
    pcall(function()
      vim.bo[buf].modifiable = false
    end)
    self.commit_job = nil
    -- Half a layout on screen is not a valid base for the incremental writer.
    self.full_rewrite = true
    self.needs_force = true
    self.needs_render = true
    if not self.destroyed then
      self:schedule_render()
    end
  end
  local function step()
    if not current() then
      abandon()
      return false
    end
    if self.page and HistoryPage.selected(self) then
      abandon()
      return false
    end
    local ok, err = coroutine.resume(co)
    if not ok then
      abandon()
      self.keep_block = nil
      require("acp.log").error("transcript commit failed: %s", tostring(err))
      return false
    end
    if coroutine.status(co) ~= "dead" then
      return true
    end
    if not current() then
      abandon()
      return false
    end
    self.commit_job = nil
    metrics.record(self, "write", started, { rows = #layout.lines, chunked = true })
    self.bg_runs = renderer.sync_backgrounds(buf, nil, layout.meta, true)
    self:finish_layout(layout, layout_only, saved_view)
    if self.needs_render then
      self:schedule_render()
    end
    return false
  end
  work.shared:enqueue("ui", step, { key = buf, label = "commit" })
end

function Chat:finish_layout(layout, layout_only, saved_view)
  self.meta = layout.meta
  self.lines_cache = layout.lines
  self.line_starts = layout.starts
  self.row_starts, self.turn_counts, self.render_order = layout.row_starts, layout.turn_counts, layout.render_order
  if self.page then
    HistoryPage.evict(self.cache, layout.cache)
  end
  self.cache = layout.cache
  self.render_version, self.render_turns = self.session.version, layout.turns
  if not self.follow then
    viewport.refresh_tail(self)
  end
  metrics.record(self, "first_paint", self.first_paint)
  self.first_paint = nil

  -- A block that was just toggled keeps the cursor: expanding or collapsing it
  -- is a deliberate action, not new output to follow.
  if self.keep_block then
    local row = layout.starts[self.keep_block]
    self.keep_block = nil
    if row and self:is_visible() then
      pcall(vim.api.nvim_win_set_cursor, self.win, { row, 0 })
    end
  elseif self.follow then
    self.committing = true
    self:scroll_to_bottom()
    self.committing = nil
  elseif self:is_visible() then
    viewport.restore(self, saved_view)
    if not layout_only and not self.pending_new then
      self.pending_new = true
      if self.on_pending_new then
        self.on_pending_new(true)
      end
    end
  end
  decoration.schedule(self)
  if self.page_target then
    local target = self.page_target
    self.page_target = nil
    local row = target == "first"
        and self.line_starts[self.session.blocks[self.page.first] and self.session.blocks[self.page.first].id]
      or target == "last" and #self.lines_cache
      or self.line_starts[target]
    if row and self:is_visible() then
      vim.api.nvim_win_set_cursor(self.win, { row, 0 })
    end
  end
end

---Cooperative block-level layout; no worker thread or parser in redraw hooks.
function Chat:render_async(force, layout_only)
  if not self:is_visible() then
    self.needs_render = true
    self.layout_epoch = (self.layout_epoch or 0) + 1
    self.layout_job = nil
    return
  end
  local session, version, width, generation = self.session, self.session.version, self.width, CodeHL.generation
  local win = self.win
  local first, last = 1, #session.blocks
  if self.page then
    first, last = self.page:sync(session, self.follow)
  end
  local previous = self.layout_job
  if
    previous
    and previous.session == session
    and previous.version == version
    and previous.width == width
    and previous.first == first
    and previous.last == last
    and previous.generation == generation
    and not force
  then
    return
  end
  self.layout_epoch = (self.layout_epoch or 0) + 1
  local job = {
    epoch = self.layout_epoch,
    session = session,
    version = version,
    width = width,
    started = metrics.start(self),
    first = first,
    last = last,
    generation = generation,
  }
  self.layout_job = job
  local co = coroutine.create(function()
    return transcript.full(session, self, { force = force, first = first, last = last, checkpoint = coroutine.yield })
  end)
  local function current()
    return not self.destroyed
      and self:is_visible()
      and self.win == win
      and vim.api.nvim_win_get_buf(win) == self.buf
      and self.session == session
      and session.version == version
      and self.width == width
      and self.layout_epoch == job.epoch
      and CodeHL.generation == generation
  end
  local function step()
    if not current() then
      if self.layout_job == job then
        self.layout_job = nil
        self.needs_render = true
      end
      return
    end
    if self.page and HistoryPage.selected(self) then
      self.layout_job, self.needs_render = nil, true
      return
    end
    local started = metrics.start(self)
    local ok, result = coroutine.resume(co)
    if not ok then
      self.layout_job = nil
      require("acp.log").error("transcript layout failed: %s", tostring(result))
      return
    end
    metrics.record(self, "layout_slice", started)
    if coroutine.status(co) ~= "dead" then
      return true
    end
    if current() then
      self.layout_job = nil
      metrics.record(self, "layout", job.started)
      local saved = not self.follow and viewport.capture(self) or nil
      self:apply_layout(result, layout_only, saved)
    end
    return false
  end
  work.shared:enqueue("layout", step, { key = self.buf, label = "layout" })
end

function Chat:page_pins()
  local first, last
  if not self:is_visible() then
    return nil
  end
  local rows = vim.api.nvim_win_call(self.win, function()
    return { vim.fn.line("w0"), vim.fn.line("w$") }
  end)
  local ids = {}
  for row = rows[1], rows[2] do
    local entry = self.meta[row]
    if entry and entry.block_id then
      ids[entry.block_id] = true
    end
  end
  if self.keep_block then
    ids[self.keep_block] = true
  end
  for index, block in ipairs(self.session.blocks) do
    if ids[block.id] then
      first, last = first or index, index
    end
  end
  return first and { first = first, last = last } or nil
end

function Chat:load_page(direction, target)
  if self.commit_job or not self.page or not self.session or HistoryPage.selected(self) then
    return false
  end
  if not self.page:load(self.session, direction, self:page_pins()) then
    return false
  end
  self.follow = false
  self.page_target = target
  self:render(nil, "layout")
  return true
end

---Only the older boundary is paged; the newest block is always materialised, so
---new output appears automatically without any "load newer" step.
function Chat:activate_page()
  if self.commit_job or not self.page or not self:is_visible() then
    return false
  end
  local entry = self.meta[vim.api.nvim_win_get_cursor(self.win)[1]]
  return entry and entry.page and entry.page < 0 and self:load_page(entry.page) or false
end

function Chat:on_scroll()
  if
    self.destroyed
    or self.layout_job
    or self.commit_job
    or self.resize_timer
    or not self:is_visible()
    or self.render_version == nil
    or vim.api.nvim_win_get_buf(self.win) ~= self.buf
    or math.max(20, vim.api.nvim_win_get_width(self.win) - 2) ~= self.width
  then
    return
  end
  if viewport.clamp_tail(self) and not self.tail_clamp_pending then
    -- Neovim can overwrite a viewport adjustment made inside WinScrolled when
    -- it finishes handling the wheel event. Recheck once in normal loop context.
    local win, session = self.win, self.session
    local request = {}
    self.tail_clamp_pending = request
    vim.schedule(function()
      if self.tail_clamp_pending ~= request then
        return
      end
      self.tail_clamp_pending = nil
      if
        not self.destroyed
        and self.win == win
        and self.session == session
        and not self.commit_job
        and not self.layout_job
      then
        viewport.clamp_tail(self)
      end
    end)
  end
  local rows = vim.api.nvim_win_call(self.win, function()
    return { vim.fn.line("w0"), vim.fn.line("w$") }
  end)
  if rows[2] < #self.lines_cache or vim.api.nvim_win_get_cursor(self.win)[1] < #self.lines_cache - 1 then
    self.follow = false
  end
  if not self.page then
    return
  end
  if not self.follow and rows[1] <= 2 and self.page.first > 1 then
    self:load_page(-1)
  end
end

function Chat:scroll_to_bottom()
  if self.page and self.session and not self.committing then
    self.follow = true
    self.page:trim(self.session)
    self.page_target = "last"
    self:render(nil, "layout")
    return
  end
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    self.follow = true
    self.pending_new = false
    return
  end
  viewport.follow_tail(self)
  if not self.tail_follow_pending then
    local win, session = self.win, self.session
    local request = {}
    self.tail_follow_pending = request
    -- Recheck after the next redraw, not in the same scheduled callback batch:
    -- screenpos/skipcol for a non-current wrapped window can still be stale.
    vim.defer_fn(function()
      if self.tail_follow_pending ~= request then
        return
      end
      self.tail_follow_pending = nil
      if
        not self.destroyed
        and self.follow
        and self.win == win
        and self.session == session
        and not self.commit_job
        and not self.layout_job
        and not self.keep_block
      then
        viewport.clamp_tail(self)
      end
    end, 1)
  end
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
  if self.page and self.session and #self.session.blocks > 0 then
    self.follow = false
    self.page:beginning(self.session)
    self.page_target = "first"
    self:render(nil, "layout")
    return
  end
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  self.follow = false
end

---Block under the cursor.
---@return table|nil block
function Chat:block_at_cursor()
  if self.commit_job or self.full_rewrite then
    return nil
  end
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
  if self:activate_page() then
    return true
  end
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
  if self.commit_job or self.full_rewrite then
    return nil
  end
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
  if self.commit_job then
    return
  end
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
  elseif self.page then
    local index = direction < 0 and self.page.first - 1 or self.page.last + 1
    local block = self.session.blocks[index]
    if block then
      self:load_page(direction, block.id)
    end
  end
end

---Tear down the view: drop its buffer and autocmd group.
function Chat:destroy()
  self.destroyed = true
  self.tail_follow_pending, self.tail_clamp_pending = nil, nil
  decoration.cancel(self)
  self.layout_epoch = (self.layout_epoch or 0) + 1
  self.layout_job = nil
  if self.buf then
    work.shared:cancel(function(job)
      return job.key == self.buf
    end)
  end
  self.commit_job = nil
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
  if self.page and self.session then
    -- Explicit full export remains complete; native selection/search still see
    -- only materialised rows. Avoid parsing syntax for this text-only operation.
    local view = setmetatable({
      cache = {},
      config = vim.tbl_deep_extend("force", {}, self.config, { ui = { render = { lazy_syntax = true } } }),
    }, { __index = self })
    local layout = transcript.full(self.session, view, { force = true })
    local out = {}
    for _, line in ipairs(layout.lines) do
      out[#out + 1] = line:gsub("%s+$", "")
    end
    HistoryPage.evict(layout.cache, self.cache)
    return table.concat(out, "\n")
  end
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

function Chat:render_stats()
  return {
    timings = vim.deepcopy(self.metrics or {}),
    rows = #(self.lines_cache or {}),
    cached_blocks = vim.tbl_count(self.cache),
    syntax_marks = self.buf
        and vim.api.nvim_buf_is_valid(self.buf)
        and #vim.api.nvim_buf_get_extmarks(self.buf, decoration.ns, 0, -1, {})
      or 0,
    layout_pending = self.layout_job ~= nil,
    commit_pending = self.commit_job ~= nil,
    decoration_pending = self.decoration_pending == true,
    slow_tasks = vim.deepcopy(self.slow_tasks or {}),
    range = self.page and { first = self.page.first, last = self.page.last } or nil,
  }
end

return M
