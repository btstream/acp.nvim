-- Review in a separate scratch window. The source remains untouched until all
-- decisions are made. Reject/close never rewinds undo or overwrites user edits.
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

---Review window size and position, clamped to the current screen. Reused by
---the resize handler so a shrunken UI cannot leave the float off-screen.
---@param config table|nil
---@param source_win integer
---@return table
local function review_geometry(config, source_win)
  local review = window_opts(config).review or {}
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

function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  sessions[self.bufnr] = nil
  if self.group then
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
  end
  local focus = vim.api.nvim_get_current_win() == self.win
  if vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  if vim.api.nvim_buf_is_valid(self.preview) then
    pcall(vim.api.nvim_buf_delete, self.preview, { force = true })
  end
  if focus and vim.api.nvim_win_is_valid(self.source_win) then
    vim.api.nvim_set_current_win(self.source_win)
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

function Session:decide(accepted)
  if accepted then
    local ok, err = result.verify(self.snapshot)
    if not ok then
      vim.notify("acp.nvim: " .. err .. "; discard or regenerate", vim.log.levels.WARN)
      return
    end
  end
  local h = self.hunks[self.index]
  h.decided, h.accepted = true, accepted
  for i = 1, #self.hunks do
    if not self.hunks[i].decided then
      self.index = i
      self:render()
      return
    end
  end
  self:finish()
end

function Session:accept()
  self:decide(true)
end
function Session:reject()
  self:decide(false)
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
  -- If even accepted hunks now conflict, close without changing the source.
  if not self:finish() then
    self:close()
  end
end

---Line range of one hunk in the rendered view (1-based, inclusive).
---@param view table
---@param index integer
---@param fallback integer
---@return integer from, integer to
local function hunk_rows(view, index, fallback)
  local from = view.rows[index]
  if not from then
    -- The hunk was cut by `max_rows`; anchor the highlight on the notice row
    -- instead of pretending it starts at the top.
    return fallback, fallback
  end
  local next_row = view.rows[index + 1]
  -- The row before the next header is the blank separator, which is not part of
  -- this hunk.
  local to = next_row and (next_row - 2) or #view.lines
  return from, math.max(from, to)
end

function Session:render()
  local opts = window_opts(self.config)
  local review = opts.review or {}
  local view = render.render(self.hunks, {
    width = math.max(1, vim.api.nvim_win_get_width(self.win)),
    layout = review.layout,
    tabstop = self.tabstop,
    max_rows = review.max_rows,
    min_split_width = review.min_split_width,
  })
  vim.bo[self.preview].modifiable = true
  vim.api.nvim_buf_set_lines(self.preview, 0, -1, false, view.lines)
  vim.bo[self.preview].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.preview, ns, 0, -1)
  for _, span in ipairs(view.spans) do
    local line = view.lines[span.row + 1] or ""
    local start = math.min(span.start, #line)
    local stop = span.stop == -1 and #line or math.min(span.stop, #line)
    vim.api.nvim_buf_set_extmark(self.preview, ns, span.row, start, {
      end_col = stop,
      hl_group = span.group,
      priority = 1,
    })
  end
  -- The current hunk gets a background so `[h`/`]h` and `ga`/`gr` have an
  -- unambiguous target even when several hunks are visible at once.
  local from, to = hunk_rows(view, self.index, math.max(1, #view.lines))
  for row = from, math.min(to, #view.lines) do
    vim.api.nvim_buf_set_extmark(self.preview, ns, row - 1, 0, {
      line_hl_group = "AcpInlineCurrent",
      priority = 0,
    })
  end
  local first = view.rows[self.index] or #view.lines
  if first > 0 and first <= #view.lines then
    pcall(vim.api.nvim_win_set_cursor, self.win, { first, 0 })
  end
  self.rows = view.rows
  self.layout = view.layout
  self.rendered = view.rendered
  if self.on_status then
    self.on_status(self.index, #self.hunks, view.layout)
  end
end

---@param opts {bufnr: integer, original: string[], lines: string[], selection: table|nil,
---  config: table|nil, on_finish: fun(accepted: integer, total: integer)|nil,
---  on_status: fun(index: integer, total: integer, layout: string)|nil}
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
  local hunks = result.hunks(original, opts.lines)
  if #hunks == 0 then
    return false, "no changes"
  end
  local config = opts.config
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "acp_inline_review"
  vim.bo[buf].swapfile = false
  local source_win = vim.api.nvim_get_current_win()
  local geometry = review_geometry(config, source_win)
  local appearance = window_opts(config)
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    row = geometry.row,
    col = geometry.col,
    width = geometry.width,
    height = geometry.height,
    style = (appearance.style == "default") and nil or "minimal",
    border = appearance.border or "rounded",
    title = " ACP Inline · ga/gr · g2/g3 · g1 always · q discard remaining ",
    title_pos = appearance.title_pos or "left",
  })
  if not ok then
    vim.api.nvim_buf_delete(buf, { force = true })
    return false, tostring(win)
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
  local s = setmetatable({
    bufnr = opts.bufnr,
    config = config,
    preview = buf,
    win = win,
    source_win = source_win,
    hunks = hunks,
    original = vim.deepcopy(original),
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
      s:reject_all()
    end,
  })
  -- A narrower screen falls back to `unified`, so a resize changes layout and,
  -- for centre/cursor placement, has to move the window back inside the screen.
  vim.api.nvim_create_autocmd("VimResized", {
    group = s.group,
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then
        return
      end
      pcall(vim.api.nvim_win_set_config, win, review_geometry(s.config, s.source_win))
      s:render()
    end,
  })
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, desc = "ACP inline review" })
  end
  map("ga", function()
    s:accept()
  end)
  map("gr", function()
    s:reject()
  end)
  map("g2", function()
    s:accept_all()
  end)
  map("g3", function()
    s:reject_all()
  end)
  map("g1", function()
    if s:accept_all() then
      require("acp.inline.review").always_accept(opts.bufnr)
    end
  end)
  map("q", function()
    s:reject_all()
  end)
  map("<Esc>", function()
    s:reject_all()
  end)
  map("]h", function()
    s.index = math.min(#s.hunks, s.index + 1)
    s:render()
  end)
  map("[h", function()
    s.index = math.max(1, s.index - 1)
    s:render()
  end)
  s:render()
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
