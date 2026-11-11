-- Review in a separate scratch window. The source remains untouched until all
-- decisions are made. Reject/close never rewinds undo or overwrites user edits.
local M = {}
local sessions = {}
local result = require("acp.inline.result")
local apply = require("acp.inline.apply")
local ns = vim.api.nvim_create_namespace("acp.inline.review")
local Session = {}
Session.__index = Session

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

function Session:render()
  local lines, rows, decorations = {}, {}, {}
  for i, h in ipairs(self.hunks) do
    rows[i] = #lines + 1
    lines[#lines + 1] = string.format(
      "@@ Hunk %d/%d · %s @@ -%d,%d +%d,%d",
      i,
      #self.hunks,
      h.decided and (h.accepted and "accept" or "reject") or "pending",
      h.start + 1,
      #h.old_lines,
      h.new_start + 1,
      #h.new_lines
    )
    for _, line in ipairs(h.old_lines) do
      lines[#lines + 1] = "- " .. line
      decorations[#decorations + 1] = { #lines - 1, "DiffDelete" }
    end
    for _, line in ipairs(h.new_lines) do
      lines[#lines + 1] = "+ " .. line
      decorations[#decorations + 1] = { #lines - 1, "DiffAdd" }
    end
    lines[#lines + 1] = ""
  end
  vim.bo[self.preview].modifiable = true
  vim.api.nvim_buf_set_lines(self.preview, 0, -1, false, lines)
  vim.bo[self.preview].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.preview, ns, 0, -1)
  for _, d in ipairs(decorations) do
    vim.api.nvim_buf_set_extmark(self.preview, ns, d[1], 0, { line_hl_group = d[2] })
  end
  vim.api.nvim_win_set_cursor(self.win, { rows[self.index], 0 })
  self.rows = rows
  if self.on_status then
    self.on_status(self.index, #self.hunks)
  end
end

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
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].swapfile = false
  local width = math.max(1, math.min(100, vim.o.columns - 4))
  local height = math.max(1, math.min(25, vim.o.lines - 6))
  local source_win = vim.api.nvim_get_current_win()
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 1,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " ACP Inline · ga/gr · g2/g3 · g1 always · q discard remaining ",
  })
  vim.cmd("stopinsert")
  local s = setmetatable({
    bufnr = opts.bufnr,
    preview = buf,
    win = win,
    source_win = source_win,
    hunks = hunks,
    original = vim.deepcopy(original),
    snapshot = snapshot,
    index = 1,
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
