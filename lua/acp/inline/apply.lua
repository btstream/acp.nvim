-- Shared buffer writes for inline results.
--
-- Both review modes end here, so undo grouping and cursor placement cannot
-- diverge: one write, one undo step, and the cursor on the first change.
local M = {}
local ns = vim.api.nvim_create_namespace("acp.inline.applied")

---Break the undo block and remember where a new one begins.
---@param bufnr integer
---@return integer seq
function M.begin(bufnr)
  return vim.api.nvim_buf_call(bufnr, function()
    vim.go.undolevels = vim.go.undolevels
    return vim.fn.undotree().seq_cur
  end)
end

---Replace every line in one undoable change.
---@param bufnr integer
---@param lines string[]
---@return boolean
function M.set_lines(bufnr, lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local ok = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
  return ok
end

---Collapse the history of a preview into a single undoable change.
---@param bufnr integer
---@param seq integer
function M.collapse_undo(bufnr, seq)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local final = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  vim.api.nvim_buf_call(bufnr, function()
    pcall(vim.cmd, "silent undo " .. seq)
  end)
  if not vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), final) then
    pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, final)
  end
end

---Highlight the rows a change just touched, long enough to notice.
---@param bufnr integer
---@param first integer 0-based first row
---@param last integer 0-based last row
function M.flash(bufnr, first, last)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local count = vim.api.nvim_buf_line_count(bufnr)
  first = math.max(0, math.min(first, count - 1))
  last = math.max(first, math.min(last, count - 1))
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, first, 0, {
    end_row = last,
    end_col = 0,
    hl_group = "AcpInlineApplied",
    hl_eol = true,
  })
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
    end
  end, 900)
end

---Write a whole result and put the cursor on its first changed line.
---@param bufnr integer
---@param lines string[]
---@param row integer 0-based target row
---@return boolean
function M.write(bufnr, lines, row)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local seq = M.begin(bufnr)
  if not M.set_lines(bufnr, lines) then
    return false
  end
  M.collapse_undo(bufnr, seq)
  row = math.max(0, math.min(row, vim.api.nvim_buf_line_count(bufnr) - 1))
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 and win ~= 0 and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { row + 1, 0 })
    pcall(vim.api.nvim_win_call, win, function()
      pcall(vim.cmd, "normal! zz")
    end)
  end
  M.flash(bufnr, row, row)
  return true
end

return M
