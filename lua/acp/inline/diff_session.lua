-- Inline review session.
--
-- Native mode uses real windows in their own tabpage (Vim diff mode), so
-- alignment, filler, folds, scroll binding and syntax highlighting come from
-- Neovim. The fallback mode reuses the transcript's card diff renderer, which
-- needs far less width.
--
-- In both modes the decision model is identical: hunks are pending, accepted or
-- rejected; the source buffer is only written once, after every decision.
local M = {}
local result = require("acp.inline.result")
local apply = require("acp.inline.apply")
local layout = require("acp.inline.review.layout")
local align = require("acp.inline.review.align")
local card = require("acp.inline.review.card")
local anchor = require("acp.inline.anchor")

local sessions = {}
local ns = vim.api.nvim_create_namespace("acp.inline.review")
local Session = {}
Session.__index = Session

local function window_opts(cfg)
  return (cfg and cfg.inline and cfg.inline.window) or {}
end

local function review_opts(cfg)
  return window_opts(cfg).review or {}
end

---Hunks still waiting for a decision.
---@param hunks table[]
---@return integer
local function pending_count(hunks)
  local count = 0
  for _, hunk in ipairs(hunks) do
    if not hunk.decided then
      count = count + 1
    end
  end
  return count
end

---Display rows a hunk occupies. Every column is padded to the same rows, so
---this is the same in all of them.
---@param index integer
---@return integer from, integer to
function Session:hunk_rows(index)
  return align.span(self.model, index)
end

---The hunk at a display row, if any. Valid in any column.
---@param row integer
---@return integer|nil
function Session:hunk_at(row)
  return self.model and align.hunk_at(self.model, row) or nil
end

---Panes shown, with their buffers.
---@return {pane: string, buf: integer}[]
function Session:shown_panes()
  local out = {}
  for _, pane in ipairs({ "original", "result", "proposal" }) do
    local buf = self.buffers and self.buffers[pane]
    if buf and vim.api.nvim_buf_is_valid(buf) then
      out[#out + 1] = { pane = pane, buf = buf }
    end
  end
  return out
end

---Width of the line-number gutter, shared by every column so they line up.
---@return integer
function Session:gutter_width()
  local most = math.max(#self.original, #self.edited, 1)
  return math.max(3, #tostring(most))
end

---Refresh the native layout: result text, gutters, decorations and winbar.
function Session:refresh_native()
  local view = align.pane(self.model, "result", self.hunks)
  local ok, err = layout.write(self.buffers.result, view.lines)
  if not ok then
    vim.notify("acp.nvim: " .. tostring(err), vim.log.levels.WARN)
  end
  self.views.result = view
  layout.set_gutter(self.buffers.result, { lnums = view.lnums })
  self:place_decorations()
  self:update_title()
  if self.on_status then
    self.on_status()
  end
end

---Glyph in the state bar: the first row of a decided hunk says how it was
---decided, every other row is a plain bar.
local STATE_GLYPH = {
  Accepted = "✓",
  Rejected = "✗",
}

-- Filler hatch. Wider than any window; the overlay is clipped at the edge.
local HATCH = string.rep("╱", 512)

---Paint every column.
---
---All of it is decoration: the buffer text, and therefore the alignment, stay
---untouched. See `align.decorations` for what each column shows per state.
function Session:place_decorations()
  if not self.native or not self.buffers then
    return
  end
  local current = self:selected()
  self.decorated_current = current
  -- One state bar per display row, shared by every column.
  local bars = {}
  for index, hunk in ipairs(self.hunks) do
    local state = align.state(hunk, index, current)
    local first, last = align.span(self.model, index)
    for row = first, last do
      bars[row] = {
        group = "AcpReviewState" .. state,
        glyph = (row == first and STATE_GLYPH[state]) or "▎",
      }
    end
  end
  for _, entry in ipairs(self:shown_panes()) do
    local buf, pane = entry.buf, entry.pane
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    layout.set_gutter(buf, { bars = bars })
    local view = self.views[pane]
    local lines = view.lines
    for _, deco in ipairs(align.decorations(self.model, pane, self.hunks, view.filler)) do
      local r = deco.row - 1
      if deco.filler then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, r, 0, {
          line_hl_group = deco.line,
          virt_text = { { HATCH, deco.line } },
          virt_text_pos = "overlay",
          priority = 190,
        })
      else
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, r, 0, {
          end_row = r + 1,
          end_col = 0,
          hl_group = deco.line,
          hl_eol = true,
          priority = 190,
        })
        local text = lines[deco.row] or ""
        for _, range in ipairs(deco.chars or {}) do
          local s_col, e_col = math.min(range[1], #text), math.min(range[2], #text)
          if e_col > s_col then
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, r, s_col, {
              end_col = e_col,
              hl_group = range[3],
              priority = 195,
            })
          end
        end
      end
    end
    -- Key hints on the hunk under the cursor, in the column decisions apply to.
    if pane == "result" and current and review_opts(self.config).hints ~= false then
      local first = align.span(self.model, current)
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, first - 1, 0, {
        virt_text = { { "  ga accept · gr reject · ]c next", "AcpReviewHint" } },
        virt_text_pos = "eol",
        priority = 200,
      })
    end
  end
  -- The gutter is drawn from `set_gutter`; ask for a redraw of the columns.
  if self.layout then
    for _, win in ipairs(self.layout.windows) do
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim__redraw, { win = win, statuscolumn = true })
      end
    end
  end
  self:update_winbar()
end

-- Backwards-compatible name.
Session.place_signs = Session.place_decorations

---Per-pane header: a badge naming the side, and on the result column the
---decision count and the hunk under the cursor.
---
---Mirrors how a three-way comparison labels its columns: the badge is the only
---thing that distinguishes "what was", "what is" and "what is proposed", so it
---carries its own colour and the label stays quiet. The count is shown once.
---@param pane string
---@param status string|nil
---@return string
local function pane_winbar(pane, status)
  local badge, badge_group, label
  if pane == "original" then
    badge, badge_group, label = " A ", "AcpReviewBadgeOriginal", "before"
  elseif pane == "proposal" then
    badge, badge_group, label = " B ", "AcpReviewBadgeProposal", "proposal"
  else
    badge, badge_group, label = " → ", "AcpReviewBadgeResult", "result"
  end
  local parts = {
    "%#" .. badge_group .. "#" .. badge .. "%*",
    "%#AcpReviewPath# " .. label .. " %*",
  }
  if status then
    parts[#parts + 1] = "%=%#AcpReviewVersion#" .. status .. " %*"
  end
  return table.concat(parts)
end

---Refresh every pane's winbar with the current decision counts.
function Session:update_winbar()
  if not self.native or not self.layout then
    return
  end
  local accepted, rejected, pending = 0, 0, 0
  for _, hunk in ipairs(self.hunks) do
    if not hunk.decided then
      pending = pending + 1
    elseif hunk.accepted then
      accepted = accepted + 1
    else
      rejected = rejected + 1
    end
  end
  local index = self.decorated_current
  local status = string.format(
    "%s✓%d ✗%d · %d pending",
    index and string.format("hunk %d/%d · ", index, #self.hunks) or "",
    accepted,
    rejected,
    pending
  )
  local panes = self.panes
  for i, win in ipairs(self.layout.windows) do
    local pane = panes[i] or "result"
    pcall(vim.api.nvim_set_option_value, "winbar", pane_winbar(pane, pane == "result" and status or nil), { win = win })
  end
end

function Session:update_title()
  if self.native then
    self:update_winbar()
    return
  end
  local total, accepted, rejected = #self.hunks, 0, 0
  for _, hunk in ipairs(self.hunks) do
    if hunk.decided then
      if hunk.accepted then
        accepted = accepted + 1
      else
        rejected = rejected + 1
      end
    end
  end
  local index = self:selected()
  local text = string.format(
    " ACP Inline · %s · ✓%d ✗%d · %d pending · ga/gr · ]c/[c · q discard ",
    index and string.format("hunk %d/%d", index, total) or (pending_count(self.hunks) > 0 and "select a hunk" or "done"),
    accepted,
    rejected,
    pending_count(self.hunks)
  )
  if self.container == "buffer" then
    pcall(vim.api.nvim_set_option_value, "winbar", text, { win = self.win })
  else
    pcall(vim.api.nvim_win_set_config, self.win, {
      title = text,
      title_pos = (self.appearance.title_pos or "left"),
    })
  end
end

---Refresh the card fallback: rebuild rows, then repaint spans.
function Session:refresh_card()
  local review = review_opts(self.config)
  local view = card.build({
    hunks = self.hunks,
    original = self.original,
    edited = self.edited,
    path = self.path,
    width = math.max(1, vim.api.nvim_win_get_width(self.win) - 2),
    context = review.context,
    syntax = review.syntax,
    max_rows = review.max_rows,
  })
  self.view = view
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, view.lines)
  vim.bo[self.buf].modifiable = false
  vim.bo[self.buf].modified = false
  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  for _, span in ipairs(view.spans) do
    local line = view.lines[span.row + 1] or ""
    local start = math.min(span.start or 0, #line)
    local stop = span.stop == -1 and #line or math.min(span.stop or #line, #line)
    if stop > start then
      vim.api.nvim_buf_set_extmark(self.buf, ns, span.row, start, {
        end_col = stop,
        hl_group = span.group,
        priority = 100,
      })
    end
  end
  self:update_title()
end

function Session:refresh()
  if self.native then
    self:refresh_native()
  else
    self:refresh_card()
  end
end

---The hunk under the cursor, if the cursor sits on changed lines.
---
---In the native layout every column is padded to the same display rows, so
---the cursor selects a hunk from any of them.
---@return integer|nil
function Session:selected()
  local win = self:current_win()
  if not win then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  if self.native then
    return self:hunk_at(row)
  end
  local hunk = self.view and self.view.row_hunk and self.view.row_hunk[row]
  return hunk or nil
end

---Hunks touched by the current Visual selection, or the current hunk.
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
  local seen, out = {}, {}
  if self.native then
    for row = first, last do
      local index = self:hunk_at(row)
      if index and not seen[index] then
        seen[index] = true
        out[#out + 1] = index
      end
    end
  else
    for row = first, last do
      local index = self.view and self.view.row_hunk and self.view.row_hunk[row]
      if index and not seen[index] then
        seen[index] = true
        out[#out + 1] = index
      end
    end
  end
  table.sort(out)
  return out
end

local function leave_visual()
  if vim.fn.mode():match("[vV\22]") then
    vim.cmd("normal! \27")
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
    local hunk = self.hunks[index]
    if hunk then
      hunk.decided, hunk.accepted = true, accepted
    end
  end
  self:refresh()
  if pending_count(self.hunks) == 0 then
    self:finish()
    return true
  end
  if review_opts(self.config).advance then
    local target = self:next_pending(indices[#indices])
    if target then
      self:jump_to(target)
    end
  end
  return true
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
  for _, hunk in ipairs(self.hunks) do
    if not hunk.decided then
      hunk.decided, hunk.accepted = true, true
    end
  end
  return self:finish()
end
function Session:reject_all()
  for _, hunk in ipairs(self.hunks) do
    if not hunk.decided then
      hunk.decided, hunk.accepted = true, false
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
  local hunk = self.hunks[index]
  hunk.decided, hunk.accepted = false, nil
  self:refresh()
end

---Next pending hunk after `index`, wrapping around.
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

---Window that currently hosts the review cursor.
---@return integer|nil
function Session:current_win()
  if self.native then
    for _, win in ipairs(self.layout.windows) do
      if vim.api.nvim_get_current_win() == win then
        return win
      end
    end
    return self.layout.windows[self.layout.focus]
  end
  return self.win
end

---Move the cursor to a hunk.
---@param index integer|nil
function Session:jump_to(index)
  if not index then
    return
  end
  local win = self:current_win()
  if not win then
    return
  end
  local row
  if self.native then
    -- Rows are aligned, so the cursor stays in whichever column it is in.
    row = self:hunk_rows(index)
  else
    row = self.view and self.view.rows and self.view.rows[index]
  end
  if row and row >= 1 then
    vim.api.nvim_set_current_win(win)
    pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! zv")
    end)
    self.index = index
  end
  if not self.native then
    self:refresh_card()
  else
    self:place_decorations()
  end
end

---Navigate the stable review hunks, not Vim's changing multi-buffer diff blocks.
---Decided hunks remain reachable for `u`; `advance` separately skips them.
---@param step integer
function Session:jump(step)
  local win = self:current_win()
  if not win then
    return
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local positions, current = {}, nil
  for index = 1, #self.hunks do
    local first, last
    if self.native then
      first, last = self:hunk_rows(index)
    else
      first = self.view and self.view.rows[index]
      if self.view and self.view.row_hunk[row] == index then
        current = #positions + 1
      end
      last = first
    end
    if first then
      positions[#positions + 1] = { index = index, row = first }
      if self.native and row >= first and row <= last then
        current = #positions
      end
    end
  end
  if #positions == 0 then
    return
  end
  if current then
    self:jump_to(positions[((current - 1 + step) % #positions) + 1].index)
    return
  end
  -- On an unchanged line use its actual position, not a stale last-hunk index.
  for offset = 1, #positions do
    local position = positions[step > 0 and offset or (#positions - offset + 1)]
    if (step > 0 and position.row > row) or (step < 0 and position.row < row) then
      self:jump_to(position.index)
      return
    end
  end
  self:jump_to(positions[step > 0 and 1 or #positions].index)
end

function Session:finish()
  local accepted = {}
  for _, hunk in ipairs(self.hunks) do
    if hunk.accepted then
      accepted[#accepted + 1] = hunk
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

function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  sessions[self.bufnr] = nil
  if self.group then
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
  end
  if self.native then
    layout.close({
      tabpage = self.layout.tabpage,
      previous_tab = self.layout.previous_tab,
      buffers = self.buffers.all,
    })
    return
  end
  local focused = vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_get_current_win() == self.win
  if self.container == "buffer" and self.tabpage then
    if vim.api.nvim_win_is_valid(self.win) then
      pcall(vim.api.nvim_win_close, self.win, true)
    end
    if vim.api.nvim_buf_is_valid(self.buf) then
      pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
    end
    if vim.api.nvim_tabpage_is_valid(self.tabpage) then
      pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(self.tabpage))
    end
    if self.previous_tab and vim.api.nvim_tabpage_is_valid(self.previous_tab) then
      pcall(vim.api.nvim_set_current_tabpage, self.previous_tab)
    end
    return
  end
  if vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  if vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  if focused and vim.api.nvim_win_is_valid(self.source_win) then
    vim.api.nvim_set_current_win(self.source_win)
  end
end

---Geometry for a floating card review.
---@param config table|nil
---@param source_win integer
---@return table
local function float_geometry(config, source_win)
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

---Wire up the review keymaps and the cursor sync for either container.
---@param s table
---@param buf integer
local function attach_navigation(s, buf)
  for key, step in pairs({ ["]c"] = 1, ["[c"] = -1, ["]h"] = 1, ["[h"] = -1 }) do
    vim.keymap.set("n", key, function()
      s:jump(step)
    end, { buffer = buf, nowait = true, desc = "ACP inline review: navigate hunks" })
  end
end

local function attach(s, buf)
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
      require("acp.inline.review").always_accept(s.bufnr)
    end
  end, "always accept")
  map({ "n", "x" }, "q", function()
    s:reject_all()
  end, "discard remaining")
  map("n", "<Esc>", function()
    if vim.fn.mode() ~= "n" then
      return
    end
    s:reject_all()
  end, "discard remaining")
  attach_navigation(s, buf)
  map("n", "u", function()
    s:undo_decision()
  end, "undo a decision")

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = s.group,
    buffer = buf,
    callback = function()
      if s.native then
        if s:selected() ~= s.decorated_current then
          s:place_decorations()
        end
      else
        s:update_title()
      end
    end,
  })
end

---@param opts {bufnr: integer, original: string[], lines: string[], selection: table|nil,
---  config: table|nil, on_finish: fun(accepted: integer, total: integer)|nil,
---  on_status: fun()|nil}
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
  local filetype = vim.bo[opts.bufnr].filetype
  local source_win = vim.api.nvim_get_current_win()
  local columns = math.max(1, vim.o.columns)
  -- Native diff needs one window per column, so a narrow screen or an explicit
  -- float request uses the card renderer instead.
  local native = target == "buffer" and columns >= (review.min_split_width or 90)

  local s = setmetatable({
    bufnr = opts.bufnr,
    config = config,
    appearance = appearance,
    source_win = source_win,
    original = vim.deepcopy(original),
    edited = edited,
    hunks = hunks,
    snapshot = snapshot,
    path = vim.api.nvim_buf_get_name(opts.bufnr),
    filetype = filetype,
    native = native,
    on_finish = opts.on_finish,
    on_status = opts.on_status,
    index = 1,
  }, Session)
  sessions[opts.bufnr] = s
  s.group = vim.api.nvim_create_augroup("AcpInlineReview" .. opts.bufnr, { clear = true })

  -- Editing or closing the source buffer invalidates every hunk, in both
  -- containers. Dropping the review here keeps the session from outliving what
  -- it refers to.
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = s.group,
    buffer = opts.bufnr,
    callback = function()
      s:close()
    end,
  })

  if native then
    -- Inline submissions start in insert mode; the review buffer expects
    -- normal-mode keys.
    vim.cmd("stopinsert")
    local two = review.layout == "2-column"
    -- Every column is padded to the same display rows; see `review.align`.
    s.model = align.build(s.original, edited, hunks)
    s.views = {
      original = align.pane(s.model, "original", hunks),
      result = align.pane(s.model, "result", hunks),
      proposal = align.pane(s.model, "proposal", hunks),
    }
    local buffers = {
      layout.scratch(s.views.original.lines, filetype, false),
      -- The result column only displays the outcome of the decisions; a manual
      -- edit would be overwritten by the next accept/reject.
      layout.scratch(s.views.result.lines, filetype, false),
      layout.scratch(s.views.proposal.lines, filetype, false),
    }
    local width = s:gutter_width()
    local folds = align.fold_levels(s.model, review.context or 3)
    for i, pane in ipairs({ "original", "result", "proposal" }) do
      layout.set_gutter(buffers[i], {
        lnums = s.views[pane].lnums,
        folds = folds,
        width = width,
        relative = review.relative_number == true,
      })
    end
    local selected = two and { buffers[2], buffers[3] } or buffers
    local panes = two and { "result", "proposal" } or { "original", "result", "proposal" }
    if two then
      -- The original column is not displayed; do not keep an unused buffer.
      pcall(vim.api.nvim_buf_delete, buffers[1], { force = true })
    end
    local ok, opened = pcall(layout.open, {
      buffers = selected,
      panes = panes,
      fold = review.fold,
      sync_scroll = review.sync_scroll,
      relative_number = review.relative_number,
      foldcolumn = review.foldcolumn,
    })
    if not ok then
      for _, buf in ipairs(buffers) do
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      sessions[opts.bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_id, s.group)
      return false, tostring(opened)
    end
    s.layout = opened
    s.panes = panes
    s.buffers = {
      result = buffers[2],
      proposal = buffers[3],
      original = two and nil or buffers[1],
      all = two and { buffers[2], buffers[3] } or buffers,
    }
    ---@type {win: integer, buf: integer, pane: string}[]
    s.pane_windows = {}
    for index, win in ipairs(opened.windows) do
      s.pane_windows[index] = { win = win, buf = selected[index], pane = panes[index] }
    end
    ---Window options for one pane, as configured.
    ---@param pane string
    ---@return table
    local function pane_options(pane)
      return {
        fold = review.fold,
        sync_scroll = review.sync_scroll,
        relative_number = review.relative_number,
        foldcolumn = review.foldcolumn,
        pane = pane,
      }
    end
    -- Something replaced a pane's buffer (a plugin, or the user turned
    -- `winfixbuf` off and ran `:edit`): put the review buffer back and restore
    -- the pane's options instead of leaving a half-dead session behind.
    vim.api.nvim_create_autocmd("BufWinEnter", {
      group = s.group,
      callback = function()
        if s.closed then
          return
        end
        local stale = false
        for _, entry in ipairs(s.pane_windows) do
          if
            vim.api.nvim_win_is_valid(entry.win)
            and vim.api.nvim_buf_is_valid(entry.buf)
            and vim.api.nvim_win_get_buf(entry.win) ~= entry.buf
          then
            stale = true
            break
          end
        end
        if not stale then
          return
        end
        -- `:edit` fires this while it is still running; restoring in the event
        -- would be overwritten when the command finishes.
        vim.schedule(function()
          if s.closed or s.restoring then
            return
          end
          s.restoring = true
          for _, entry in ipairs(s.pane_windows) do
            if vim.api.nvim_win_is_valid(entry.win) and vim.api.nvim_buf_is_valid(entry.buf) then
              if vim.api.nvim_win_get_buf(entry.win) ~= entry.buf then
                pcall(vim.api.nvim_win_set_buf, entry.win, entry.buf)
              end
              layout.refresh_window(entry.win, pane_options(entry.pane))
            end
          end
          s.restoring = false
        end)
      end,
    })
    -- Rows are aligned, so every column takes the same keys and decisions.
    for _, buf in ipairs(selected) do
      attach(s, buf)
    end
    -- The review tab and windows belong to the user: closing any of them is
    -- treated like discarding the remaining hunks, not leaking a session.
    vim.api.nvim_create_autocmd("WinClosed", {
      group = s.group,
      callback = function()
        -- `:tabclose` closes several windows in a row, so the check has to run
        -- after the tab is gone; acting inside the event would try to close a
        -- tab that is already closing.
        vim.schedule(function()
          if s.closed then
            return
          end
          local gone = not vim.api.nvim_tabpage_is_valid(s.layout.tabpage)
          if not gone then
            for _, win in ipairs(s.layout.windows) do
              if not vim.api.nvim_win_is_valid(win) then
                gone = true
                break
              end
            end
          end
          if gone then
            s:reject_all()
          end
        end)
      end,
    })
    s:refresh_native()
    return true
  end

  -- Card renderer: same look as the transcript's tool cards. The buffer holds
  -- rendered rows, not source text, so it keeps the review filetype.
  local buf = layout.scratch({ "" }, "acp_inline_review", true)
  s.buf = buf
  s.container = target
  if target == "buffer" then
    s.previous_tab = vim.api.nvim_get_current_tabpage()
    local ok, err = pcall(vim.cmd, "tabnew")
    if not ok then
      vim.api.nvim_buf_delete(buf, { force = true })
      sessions[opts.bufnr] = nil
      return false, tostring(err)
    end
    s.tabpage = vim.api.nvim_get_current_tabpage()
    s.win = vim.api.nvim_get_current_win()
    local placeholder = vim.api.nvim_win_get_buf(s.win)
    pcall(vim.api.nvim_win_set_buf, s.win, buf)
    if placeholder ~= buf and vim.api.nvim_buf_is_valid(placeholder) then
      pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
    end
  else
    local geometry = float_geometry(config, source_win)
    local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
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
      sessions[opts.bufnr] = nil
      return false, tostring(win)
    end
    s.win = win
  end
  vim.cmd("stopinsert")
  local groups = appearance.highlights or {}
  vim.wo[s.win].winhighlight = table.concat({
    "Normal:" .. (groups.normal or "AcpInlinePrompt"),
    "NormalNC:" .. (groups.normal or "AcpInlinePrompt"),
    "FloatBorder:" .. (groups.border or "AcpInlineBorder"),
    "FloatTitle:" .. (groups.title or "AcpInlineTitle"),
  }, ",")
  vim.wo[s.win].wrap = false
  vim.wo[s.win].number = false
  vim.wo[s.win].relativenumber = false
  vim.wo[s.win].signcolumn = "no"
  vim.wo[s.win].foldcolumn = "0"

  vim.api.nvim_create_autocmd("WinClosed", {
    group = s.group,
    pattern = tostring(s.win),
    callback = function()
      if not s.closed then
        s:reject_all()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = s.group,
    callback = function()
      if not vim.api.nvim_win_is_valid(s.win) then
        return
      end
      if s.container == "float" then
        pcall(vim.api.nvim_win_set_config, s.win, float_geometry(s.config, s.source_win))
      end
      s:refresh_card()
    end,
  })
  attach(s, buf)
  s:refresh_card()
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
