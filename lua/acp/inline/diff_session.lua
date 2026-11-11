-- Review in a scratch buffer (a new tabpage by default) or a float.
--
-- The source buffer stays untouched until every hunk has a decision. Rejecting
-- or closing never rewinds undo and never overwrites user edits.
--
-- One hunk is selected by the cursor; in Visual mode every hunk touched by the
-- selection is decided at once. Decisions only change markers and colours, so
-- the file text on screen stays stable while reviewing.
local M = {}
local sessions = {}
local result = require("acp.inline.result")
local apply = require("acp.inline.apply")
local render = require("acp.inline.render")
local anchor = require("acp.inline.anchor")
local ns = vim.api.nvim_create_namespace("acp.inline.review")
local Session = {}
Session.__index = Session

local function window_opts(cfg)
  return (cfg and cfg.inline and cfg.inline.window) or {}
end

local function review_opts(cfg)
  return window_opts(cfg).review or {}
end

---@return table
function Session:current_view()
  return self.view
end

function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  sessions[self.bufnr] = nil
  if self.group then
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
  end
  local focused = vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_get_current_win() == self.win
  if self.target == "buffer" then
    -- The review owns its tabpage; closing the review leaves that scratch
    -- buffer behind otherwise.
    local tabpage = self.tabpage
    if vim.api.nvim_win_is_valid(self.win) then
      pcall(vim.api.nvim_win_close, self.win, true)
    end
    if vim.api.nvim_buf_is_valid(self.preview) then
      pcall(vim.api.nvim_buf_delete, self.preview, { force = true })
    end
    if tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
      pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tabpage))
    end
    if self.previous_tab and vim.api.nvim_tabpage_is_valid(self.previous_tab) then
      pcall(vim.api.nvim_set_current_tabpage, self.previous_tab)
    end
  else
    if vim.api.nvim_win_is_valid(self.win) then
      pcall(vim.api.nvim_win_close, self.win, true)
    end
    if vim.api.nvim_buf_is_valid(self.preview) then
      pcall(vim.api.nvim_buf_delete, self.preview, { force = true })
    end
    if focused and vim.api.nvim_win_is_valid(self.source_win) then
      vim.api.nvim_set_current_win(self.source_win)
    end
  end
end

function Session:finish()
  local accepted = {}
  for _, h in ipairs(self.hunks) do
    if h.accepted then
      accepted[#accepted + 1] = h
    end
  end
  if #accepted > 0 then
    local valid, reason = result.verify(self.snapshot)
    if not valid then
      vim.notify("acp.nvim: " .. reason .. "; review was not applied", vim.log.levels.WARN)
      return false
    end
    local ok, err = apply.hunks(self.bufnr, self.original, accepted)
    if not ok then
      vim.notify("acp.nvim: " .. tostring(err) .. "; review was not applied", vim.log.levels.WARN)
      return false
    end
  end
  self:close()
  if self.on_finish then
    self.on_finish(#accepted, #self.hunks)
  end
  return true
end

---Row where a hunk starts in the current view, falling back to the notice row
---when `max_rows` cut it.
---@param index integer
---@return integer
function Session:row_of(index)
  local view = self.view
  return (view.rows and view.rows[index]) or math.max(1, #view.lines)
end

---The hunk under the cursor, or nil on an unchanged line.
---@return integer|nil
function Session:selected()
  if not vim.api.nvim_win_is_valid(self.win) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(self.win)[1]
  return render.hunk_at(self.view, row)
end

---Hunks touched by the current Visual selection.
---@return integer[]
function Session:selected_range()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    local index = self:selected()
    return index and { index } or {}
  end
  local p1, p2 = vim.fn.getpos("v"), vim.fn.getpos(".")
  local first, last = p1[2], p2[2]
  if first > last then
    first, last = last, first
  end
  return render.selected(self.view, first, last)
end

---Update markers and borders without moving the cursor or rebuilding the text.
function Session:refresh()
  local view = self.view
  vim.api.nvim_buf_clear_namespace(self.preview, ns, 0, -1)
  for _, span in ipairs(view.spans) do
    local line = view.lines[span.row + 1] or ""
    local start = math.min(span.start or 0, #line)
    local stop = span.stop == -1 and #line or math.min(span.stop or #line, #line)
    vim.api.nvim_buf_set_extmark(self.preview, ns, span.row, start, {
      end_col = stop,
      hl_group = span.group,
      priority = 1,
    })
  end
  -- The current hunk gets a background so `]c`/`ga` have an unambiguous target.
  -- Only the hunk's own rows are shaded; unchanged context between hunks is not
  -- part of it.
  local index = self:selected() or self.index
  if index then
    for row = 1, #view.lines do
      if view.row_hunk[row] == index then
        vim.api.nvim_buf_set_extmark(self.preview, ns, row - 1, 0, {
          line_hl_group = "AcpInlineCurrent",
          priority = 0,
        })
      end
    end
  end
  self:update_title()
end

function Session:update_title()
  local total, accepted, rejected, pending = #self.hunks, 0, 0, 0
  for _, h in ipairs(self.hunks) do
    if not h.decided then
      pending = pending + 1
    elseif h.accepted then
      accepted = accepted + 1
    else
      rejected = rejected + 1
    end
  end
  local index = self:selected()
  local title = string.format(
    " ACP Inline · %s · ✓%d ✗%d · %d pending · ga/gr · ]c/[c · q discard ",
    index and string.format("hunk %d/%d", index, total) or (pending > 0 and "select a hunk" or "done"),
    accepted,
    rejected,
    pending
  )
  if self.target == "buffer" then
    pcall(vim.api.nvim_set_option_value, "winbar", title, { win = self.win })
  else
    pcall(vim.api.nvim_win_set_config, self.win, { title = title, title_pos = self.appearance.title_pos or "left" })
  end
end

---Apply a decision to a set of hunks.
---@param indices integer[]
---@param accepted boolean
---@return boolean
function Session:decide(indices, accepted)
  if #indices == 0 then
    vim.notify("acp.nvim: put the cursor on a changed line first", vim.log.levels.WARN)
    return false
  end
  if accepted then
    local ok, err = result.verify(self.snapshot)
    if not ok then
      vim.notify("acp.nvim: " .. err .. "; discard or regenerate", vim.log.levels.WARN)
      return false
    end
  end
  for _, index in ipairs(indices) do
    local h = self.hunks[index]
    if h then
      h.decided, h.accepted = true, accepted
    end
  end
  -- Apply as soon as nothing is left pending, like the previous per-hunk flow.
  local pending = false
  for _, h in ipairs(self.hunks) do
    if not h.decided then
      pending = true
      break
    end
  end
  if not pending then
    self:finish()
    return true
  end
  local from = self:selected()
  self:render({ anchor = from, advance_from = from })
  if self.on_status then
    self.on_status()
  end
  return true
end

---Leave Visual mode before redrawing the review buffer.
local function leave_visual()
  if vim.fn.mode():match("[vV\22]") then
    vim.cmd("normal! \27")
  end
end

function Session:accept()
  local indices = self:selected_range()
  leave_visual()
  self:decide(indices, true)
end
function Session:reject()
  local indices = self:selected_range()
  leave_visual()
  self:decide(indices, false)
end
function Session:accept_all()
  local ok, err = result.verify(self.snapshot)
  if not ok then
    vim.notify("acp.nvim: " .. err .. "; discard or regenerate", vim.log.levels.WARN)
    return false
  end
  for _, h in ipairs(self.hunks) do
    if not h.decided then
      h.decided, h.accepted = true, true
    end
  end
  return self:finish()
end
function Session:reject_all()
  for _, h in ipairs(self.hunks) do
    if not h.decided then
      h.decided, h.accepted = true, false
    end
  end
  if not self:finish() then
    self:close()
  end
end

---Clear the decision of the hunk under the cursor.
function Session:undo_decision()
  local index = self:selected()
  if not index then
    return
  end
  local h = self.hunks[index]
  h.decided, h.accepted = false, nil
  self:render({ anchor = index })
end

---Next pending hunk after `index`, wrapping to the first one.
---@param index integer|nil
---@return integer|nil
function Session:next_pending(index)
  local total = #self.hunks
  local start = (index or 0) + 1
  for step = 0, total - 1 do
    local candidate = ((start + step - 1) % total) + 1
    if not self.hunks[candidate].decided then
      return candidate
    end
  end
end

---Move the cursor to a hunk.
---@param index integer|nil
function Session:jump_to(index)
  if not index or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local row = self:row_of(index)
  if row >= 1 and row <= #self.view.lines then
    pcall(vim.api.nvim_win_set_cursor, self.win, { row, 0 })
    self.index = index
    self:refresh()
  end
end

function Session:jump(step)
  local total = #self.hunks
  if total == 0 then
    return
  end
  local current = self:selected() or self.index or 1
  local target = ((current - 1 + step) % total) + 1
  self:jump_to(target)
end

---Render the view. `opts.anchor` keeps the cursor on a hunk across a redraw.
---@param opts {anchor?: integer|nil}|nil
function Session:render(opts)
  opts = opts or {}
  local review = review_opts(self.config)
  local width = math.max(1, vim.api.nvim_win_get_width(self.win))
  local view = render.build({
    original = self.original,
    edited = self.edited,
    hunks = self.hunks,
    width = width,
    layout = review.layout,
    tabstop = self.tabstop,
    max_rows = review.max_rows,
    context = review.context,
    min_split_width = review.min_split_width,
  })
  self.view = view
  vim.bo[self.preview].modifiable = true
  vim.api.nvim_buf_set_lines(self.preview, 0, -1, false, view.lines)
  vim.bo[self.preview].modifiable = false
  local anchor_index = opts.anchor or self.index
  self.index = anchor_index
  -- Move first, then refresh: the current-hunk highlight follows the cursor.
  if anchor_index then
    local row = self:row_of(anchor_index)
    if row >= 1 and row <= #view.lines then
      pcall(vim.api.nvim_win_set_cursor, self.win, { row, 0 })
    end
  end
  self:refresh()
  if review.advance and opts.advance_from then
    local target = self:next_pending(opts.advance_from)
    if target then
      self:jump_to(target)
    end
  end
end

---Review window geometry, clamped to the current screen.
---@param config table|nil
---@param source_win integer
---@return table
local function review_geometry(config, source_win)
  local review = review_opts(config)
  local columns = math.max(1, vim.o.columns)
  local width = math.max(1, math.min(math.floor(review.width or 140), columns - 2))
  local height = math.max(1, math.min(math.floor(review.height or 25), math.max(3, vim.o.lines - 4)))
  if (review.placement or "center") == "cursor" then
    local placed = anchor.place({ source = source_win, placement = "cursor", width = width, height = height })
    if placed then
      return { row = placed.row, col = placed.col, width = placed.width, height = placed.height }
    end
  end
  return {
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((columns - width) / 2)),
    width = width,
    height = height,
  }
end

---Create the scratch buffer shared by both targets.
---@param opts table
---@return integer
local function create_buffer(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "acp_inline_review"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  return buf
end

---Open the review window/buffer and wire up the session.
---@param opts table
---@return boolean ok
---@return string|nil reason
function M.open(opts)
  if sessions[opts.bufnr] then
    return false, "a review is already open"
  end
  local original = opts.original or vim.api.nvim_buf_get_lines(opts.bufnr, 0, -1, false)
  local snapshot = vim.deepcopy(opts.selection or {
    bufnr = opts.bufnr,
    original = original,
    path = vim.api.nvim_buf_get_name(opts.bufnr),
    fileformat = vim.bo[opts.bufnr].fileformat,
    eol = vim.bo[opts.bufnr].endofline,
  })
  local valid, reason = result.verify(snapshot)
  if not valid then
    return false, reason
  end
  local edited = opts.lines
  local hunks = result.hunks(original, edited)
  if #hunks == 0 then
    return false, "no changes"
  end
  local config = opts.config
  local review = review_opts(config)
  local appearance = window_opts(config)
  local target = review.target or "buffer"
  local source_win = vim.api.nvim_get_current_win()
  local buf = create_buffer({ original = original })

  local win, tabpage, previous_tab
  if target == "buffer" then
    previous_tab = vim.api.nvim_get_current_tabpage()
    local ok, err = pcall(vim.cmd, "tabnew")
    if not ok then
      vim.api.nvim_buf_delete(buf, { force = true })
      return false, tostring(err)
    end
    tabpage = vim.api.nvim_get_current_tabpage()
    win = vim.api.nvim_get_current_win()
    local placeholder = vim.api.nvim_win_get_buf(win)
    pcall(vim.api.nvim_win_set_buf, win, buf)
    if placeholder ~= buf and vim.api.nvim_buf_is_valid(placeholder) then
      pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
    end
  else
    local geometry = review_geometry(config, source_win)
    local ok, opened = pcall(vim.api.nvim_open_win, buf, true, {
      relative = "editor",
      row = geometry.row,
      col = geometry.col,
      width = geometry.width,
      height = geometry.height,
      style = (appearance.style == "default") and nil or "minimal",
      border = appearance.border or "rounded",
      title = " ACP Inline ",
      title_pos = appearance.title_pos or "left",
    })
    if not ok then
      vim.api.nvim_buf_delete(buf, { force = true })
      return false, tostring(opened)
    end
    win = opened
  end

  vim.cmd("stopinsert")
  local groups = appearance.highlights or {}
  vim.wo[win].winhighlight = table.concat({
    "Normal:" .. (groups.normal or "AcpInlinePrompt"),
    "NormalNC:" .. (groups.normal or "AcpInlinePrompt"),
    "FloatBorder:" .. (groups.border or "AcpInlineBorder"),
    "FloatTitle:" .. (groups.title or "AcpInlineTitle"),
  }, ",")
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"

  local s = setmetatable({
    bufnr = opts.bufnr,
    config = config,
    appearance = appearance,
    preview = buf,
    win = win,
    target = target,
    tabpage = tabpage,
    previous_tab = previous_tab,
    source_win = source_win,
    original = vim.deepcopy(original),
    edited = edited,
    hunks = hunks,
    snapshot = snapshot,
    index = 1,
    tabstop = vim.bo[opts.bufnr].tabstop > 0 and vim.bo[opts.bufnr].tabstop or 8,
    on_finish = opts.on_finish,
    on_status = opts.on_status,
  }, Session)
  sessions[opts.bufnr] = s
  s.group = vim.api.nvim_create_augroup("AcpInlineReview" .. buf, { clear = true })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = s.group,
    buffer = opts.bufnr,
    callback = function()
      s:close()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = s.group,
    pattern = tostring(win),
    callback = function()
      if not s.closed then
        s:reject_all()
      end
    end,
  })
  -- Keep the selected hunk in sync with the cursor without redrawing text.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = s.group,
    buffer = buf,
    callback = function()
      local index = s:selected()
      if index ~= s.index then
        s.index = index
        s:refresh()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = s.group,
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then
        return
      end
      if target == "float" then
        pcall(vim.api.nvim_win_set_config, win, review_geometry(s.config, s.source_win))
      end
      s:render()
    end,
  })

  local function map(modes, key, fn, desc)
    vim.keymap.set(modes, key, fn, { buffer = buf, nowait = true, desc = "ACP inline review: " .. desc })
  end
  map({ "n", "x" }, "ga", function()
    s:accept()
  end, "accept hunk")
  map({ "n", "x" }, "gr", function()
    s:reject()
  end, "reject hunk")
  map("n", "g2", function()
    s:accept_all()
  end, "accept all")
  map("n", "g3", function()
    s:reject_all()
  end, "reject all")
  map("n", "g1", function()
    if s:accept_all() then
      require("acp.inline.review").always_accept(opts.bufnr)
    end
  end, "always accept")
  map({ "n", "x" }, "q", function()
    s:reject_all()
  end, "discard remaining")
  -- `<Esc>` only in Normal mode: in Visual mode it must cancel the selection,
  -- not throw away every pending hunk.
  map("n", "<Esc>", function()
    s:reject_all()
  end, "discard remaining")
  map("n", "]c", function()
    s:jump(1)
  end, "next hunk")
  map("n", "[c", function()
    s:jump(-1)
  end, "previous hunk")
  map("n", "]h", function()
    s:jump(1)
  end, "next hunk")
  map("n", "[h", function()
    s:jump(-1)
  end, "previous hunk")
  map("n", "u", function()
    s:undo_decision()
  end, "undo a decision")

  s:render()
  s:update_title()
  return true
end

function M.active(buf)
  return sessions[buf] ~= nil
end
function M.close_all()
  local list = vim.tbl_values(sessions)
  for _, s in ipairs(list) do
    s:close()
  end
end
return M
