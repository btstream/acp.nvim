-- Turn an edited copy into a hunk plan that stays inside the selection.
--
-- The agent is told not to leave the copy, but instruction-following is not a
-- guarantee. Every returned line change is checked against the editable ranges;
-- hunks completely outside are reverted and reported rather than applied.
local M = {}

---Line hunks between two snapshots. Insertions use the line they follow.
---@param original string[]
---@param edited string[]
---@return {start: integer, old_lines: string[], new_lines: string[]}[]
function M.hunks(original, edited)
  local from = table.concat(original, "\n") .. "\n"
  local to = table.concat(edited, "\n") .. "\n"
  local indices = vim.diff(from, to, {
    result_type = "indices",
    algorithm = "histogram",
    ctxlen = 0,
    indent_heuristic = true,
  })
  local out = {}
  for _, index in ipairs(indices) do
    local start, old_count, to_start, new_count = unpack(index)
    out[#out + 1] = {
      -- vim.diff counts from 1; an insertion's start is the line it follows,
      -- so it needs no off-by-one adjustment.
      start = old_count == 0 and start or start - 1,
      old_lines = vim.list_slice(original, start, start + old_count - 1),
      new_lines = vim.list_slice(edited, to_start, to_start + new_count - 1),
      new_start = to_start - 1,
    }
  end
  return out
end

---@param selection AcpInlineSelection
---@param hunk table
---@return boolean
local function editable(selection, hunk)
  if #selection.ranges == 0 then
    return false
  end
  local start, stop = hunk.start, hunk.start + #hunk.old_lines
  -- Insertions sit between lines; require the insertion point to be inside.
  if #hunk.old_lines == 0 then
    for _, range in ipairs(selection.ranges) do
      if start >= range.start_row and start <= range.end_row + 1 then
        return true
      end
    end
    return false
  end
  for _, range in ipairs(selection.ranges) do
    if start >= range.start_row and stop <= range.end_row + 1 then
      return true
    end
  end
  return false
end

---Filter hunks outside the editable ranges.
---@param selection AcpInlineSelection
---@param hunks table[]
---@return table[] kept
---@return integer dropped
function M.keep_editable(selection, hunks)
  local kept, dropped = {}, 0
  for _, hunk in ipairs(hunks) do
    if editable(selection, hunk) then
      kept[#kept + 1] = hunk
    else
      dropped = dropped + 1
    end
  end
  return kept, dropped
end

---Build the final lines for a set of hunks applied to `original`.
---@param original string[]
---@param hunks table[]
---@return string[]
function M.apply_hunks(original, hunks)
  local ordered = vim.deepcopy(hunks)
  table.sort(ordered, function(a, b)
    return a.start < b.start
  end)
  local out, cursor = {}, 0
  for _, hunk in ipairs(ordered) do
    for i = cursor, hunk.start - 1 do
      out[#out + 1] = original[i + 1] or ""
    end
    for _, line in ipairs(hunk.new_lines) do
      out[#out + 1] = line
    end
    cursor = hunk.start + #hunk.old_lines
  end
  for i = cursor, #original - 1 do
    out[#out + 1] = original[i + 1] or ""
  end
  return out
end

---Whether the buffer still matches the captured selection.
---@param selection AcpInlineSelection
---@return boolean ok
---@return string|nil reason
function M.verify(selection)
  if not vim.api.nvim_buf_is_valid(selection.bufnr) then
    return false, "the buffer was closed"
  end
  if vim.api.nvim_buf_get_changedtick(selection.bufnr) == selection.changedtick then
    return true
  end
  local lines = vim.api.nvim_buf_get_lines(selection.bufnr, 0, -1, false)
  if vim.deep_equal(lines, selection.original) then
    return true
  end
  return false, "the buffer changed while the agent was working"
end

---The range a hunk occupies in the current buffer, given the new content.
---@param hunk table
---@return integer start_row, integer start_col, integer end_row, integer end_col
function M.hunk_range(hunk)
  local start_row = hunk.new_start
  return start_row, 0, start_row + #hunk.new_lines - 1, 0
end

return M
