-- Hunk-by-hunk review of an inline result.
--
-- The proposed text is written into the buffer once so hunks can be read in
-- place. Rejecting restores that hunk's original lines; finishing collapses all
-- of it into one undo step. Each hunk is held by two extmarks, so deciding an
-- earlier hunk cannot shift a later one's coordinates.
local M = {}
local view_ns = vim.api.nvim_create_namespace("acp.inline.review.view")
local anchor_ns = vim.api.nvim_create_namespace("acp.inline.review.anchor")
local sessions = {}

local Session = {}
Session.__index = Session

---@param current integer 1-based
---@param total integer
---@return string
local function banner(current, total)
  return string.format(
    "[Hunk %d/%d] ga accept · gr reject · g2 all · g3 reject all · g1 always accept · q close",
    current,
    total
  )
end

---Current 0-based rows of one hunk, or nil after the buffer was replaced.
---@param hunk table
---@return integer|nil start_row
---@return integer|nil end_row
function Session:span(hunk)
  local start_pos = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, anchor_ns, hunk.start_mark, {})
  local end_pos = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, anchor_ns, hunk.end_mark, {})
  if #start_pos ~= 2 or #end_pos ~= 2 then
    return nil
  end
  -- A pure deletion's end sits one row above its start; extmarks need a real row.
  return start_pos[1], math.max(start_pos[1], end_pos[1])
end

---Like `span`, but the real end row (one above `start` for a pure deletion).
---@param hunk table
---@return integer|nil start_row
---@return integer|nil end_row
function Session:raw_span(hunk)
  local start_pos = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, anchor_ns, hunk.start_mark, {})
  local end_pos = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, anchor_ns, hunk.end_mark, {})
  if #start_pos ~= 2 or #end_pos ~= 2 then
    return nil
  end
  return start_pos[1], end_pos[1]
end

function Session:render(index)
  if not self.hunks[index] then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, self.bufnr, view_ns, 0, -1)
  local total = #self.hunks
  for i, hunk in ipairs(self.hunks) do
    if not hunk.decided then
      local first, last = self:span(hunk)
      if first then
        pcall(vim.api.nvim_buf_set_extmark, self.bufnr, view_ns, first, 0, {
          end_row = last,
          end_col = 0,
          hl_group = i == index and "AcpInlineCurrent" or "AcpInlinePending",
          hl_eol = true,
        })
        if i == index then
          pcall(vim.api.nvim_buf_set_extmark, self.bufnr, view_ns, first, 0, {
            virt_lines_above = true,
            virt_lines = { { { banner(index, total), "AcpInlineBanner" } } },
          })
        end
      end
    end
  end
  self.index = index
  local win = self.win
  local first = select(1, self:span(self.hunks[index]))
  if win and vim.api.nvim_win_is_valid(win) and first then
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(first + 1, vim.api.nvim_buf_line_count(self.bufnr)), 0 })
    pcall(vim.api.nvim_win_call, win, function()
      pcall(vim.cmd, "normal! zz")
    end)
  end
  if self.on_status then
    self.on_status(index, total)
  end
end

---Restore one hunk's original lines.
---@param hunk table
function Session:revert(hunk)
  local first = self:raw_span(hunk)
  if not first then
    return
  end
  -- Trust the hunk's own width: a pure deletion has no new lines and must
  -- insert without removing the following line.
  local last = first + #hunk.new_lines - 1
  pcall(vim.api.nvim_buf_set_lines, self.bufnr, first, last + 1, false, hunk.original)
end

---@param index integer
function Session:decide(index)
  local hunk = self.hunks[index]
  if not hunk or hunk.decided then
    return
  end
  hunk.decided = true
  if not hunk.accepted then
    self:revert(hunk)
    hunk.reverted = true
  end
  local next_index
  for i = index + 1, #self.hunks do
    if not self.hunks[i].decided then
      next_index = i
      break
    end
  end
  if not next_index then
    for i = 1, index - 1 do
      if not self.hunks[i].decided then
        next_index = i
        break
      end
    end
  end
  if next_index then
    self:render(next_index)
  else
    self:finish()
  end
end

function Session:accept()
  self.hunks[self.index].accepted = true
  self:decide(self.index)
end

function Session:reject()
  self.hunks[self.index].accepted = false
  self:decide(self.index)
end

function Session:accept_all()
  for i, hunk in ipairs(self.hunks) do
    if not hunk.decided then
      hunk.accepted = true
      hunk.decided = true
    end
  end
  self:finish()
end

function Session:reject_all()
  for _, hunk in ipairs(self.hunks) do
    if not hunk.decided then
      hunk.decided = true
    end
  end
  self:finish()
end

function Session:finish()
  for _, hunk in ipairs(self.hunks) do
    if not hunk.accepted and not hunk.reverted then
      self:revert(hunk)
      hunk.reverted = true
    end
  end
  pcall(vim.api.nvim_buf_clear_namespace, self.bufnr, view_ns, 0, -1)
  pcall(vim.api.nvim_buf_clear_namespace, self.bufnr, anchor_ns, 0, -1)
  for _, lhs in ipairs({ "ga", "gr", "g2", "g3", "g1", "]h", "[h", "q" }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = self.bufnr })
  end
  sessions[self.bufnr] = nil
  require("acp.inline.apply").collapse_undo(self.bufnr, self.undo_seq)
  local accepted = 0
  for _, hunk in ipairs(self.hunks) do
    if hunk.accepted then
      accepted = accepted + 1
    end
  end
  if self.on_finish then
    self.on_finish(accepted, #self.hunks)
  end
end

---Open a review. Each hunk must carry `start_row`/`end_row` in the new content
---and its `original` lines.
---@param opts {bufnr: integer, lines: string[], hunks: table[],
---  on_finish: fun(accepted: integer, total: integer),
---  on_status: fun(index: integer, total: integer)|nil}
---@return boolean
function M.open(opts)
  local apply = require("acp.inline.apply")
  local seq = apply.begin(opts.bufnr)
  if not apply.set_lines(opts.bufnr, opts.lines) then
    return false
  end
  local session = setmetatable({
    bufnr = opts.bufnr,
    win = vim.fn.bufwinid(opts.bufnr),
    hunks = opts.hunks,
    index = 1,
    undo_seq = seq,
    on_finish = opts.on_finish,
    on_status = opts.on_status,
  }, Session)
  sessions[opts.bufnr] = session

  for _, hunk in ipairs(opts.hunks) do
    local end_row = math.max(hunk.start_row, hunk.end_row)
    local end_col = #(opts.lines[end_row + 1] or "")
    hunk.start_mark = vim.api.nvim_buf_set_extmark(opts.bufnr, anchor_ns, hunk.start_row, 0, { right_gravity = true })
    hunk.end_mark = vim.api.nvim_buf_set_extmark(opts.bufnr, anchor_ns, end_row, end_col, {
      right_gravity = false,
    })
  end

  local map = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = opts.bufnr, nowait = true, desc = "ACP inline review" })
  end
  map("ga", function()
    session:accept()
  end)
  map("gr", function()
    session:reject()
  end)
  map("g2", function()
    session:accept_all()
  end)
  map("g3", function()
    session:reject_all()
  end)
  map("g1", function()
    require("acp.inline.review").always_accept(opts.bufnr)
    session:accept_all()
  end)
  map("]h", function()
    for i = session.index + 1, #session.hunks do
      if not session.hunks[i].decided then
        return session:render(i)
      end
    end
  end)
  map("[h", function()
    for i = session.index - 1, 1, -1 do
      if not session.hunks[i].decided then
        return session:render(i)
      end
    end
  end)
  map("q", function()
    session:reject_all()
  end)

  session:render(1)
  return true
end

---Whether a buffer is currently under review.
---@param bufnr integer
---@return boolean
function M.active(bufnr)
  return sessions[bufnr] ~= nil
end

return M
