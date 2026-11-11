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
      new_start = new_count == 0 and to_start or to_start - 1,
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
  local delta = 0
  for _, hunk in ipairs(kept) do
    hunk.new_start = hunk.start + delta
    delta = delta + #hunk.new_lines - #hunk.old_lines
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
  return #out == 0 and { "" } or out
end

---Whether the buffer still matches the captured selection.
---@param selection AcpInlineSelection
---@return boolean ok
---@return string|nil reason
function M.verify(selection)
  if not vim.api.nvim_buf_is_valid(selection.bufnr) then
    return false, "the buffer was closed"
  end
  if
    not vim.api.nvim_buf_is_loaded(selection.bufnr)
    or not vim.bo[selection.bufnr].modifiable
    or vim.bo[selection.bufnr].readonly
  then
    return false, "the source buffer is not editable"
  end
  if selection.path and vim.api.nvim_buf_get_name(selection.bufnr) ~= selection.path then
    return false, "the source buffer's filename changed"
  end
  if selection.fileformat and vim.bo[selection.bufnr].fileformat ~= selection.fileformat then
    return false, "the buffer's line ending format changed"
  end
  if selection.eol ~= nil and vim.bo[selection.bufnr].endofline ~= selection.eol then
    return false, "the buffer's final newline changed"
  end
  local lines = vim.api.nvim_buf_get_lines(selection.bufnr, 0, -1, false)
  if vim.deep_equal(lines, selection.original) then
    return true
  end
  return false, "the buffer changed while the agent was working"
end

-- For exact/rectangular selections, refine same-line changes into UTF-8
-- character edits; changing another column on the same row is not permitted.
local function offsets(lines)
  local starts, n = {}, 0
  for i, line in ipairs(lines) do
    starts[i] = n
    n = n + #line + 1
  end
  return starts
end

local function permitted(selection, first, last, starts)
  for _, range in ipairs(selection.ranges) do
    local a = starts[range.start_row + 1] + range.start_col
    local b = starts[range.end_row + 1] + range.end_col
    if first >= a and last <= b then
      return true
    end
  end
  return false
end

local function trim_edit(old, new, start)
  local prefix = 0
  while prefix < math.min(#old, #new) and old:byte(prefix + 1) == new:byte(prefix + 1) do
    prefix = prefix + 1
  end
  while prefix > 0 and old:byte(prefix + 1) and old:byte(prefix + 1) >= 128 and old:byte(prefix + 1) < 192 do
    prefix = prefix - 1
  end
  local suffix = 0
  while suffix < math.min(#old, #new) - prefix and old:byte(#old - suffix) == new:byte(#new - suffix) do
    suffix = suffix + 1
  end
  while suffix > 0 and old:byte(#old - suffix + 1) >= 128 and old:byte(#old - suffix + 1) < 192 do
    suffix = suffix - 1
  end
  return { first = start + prefix, last = start + #old - suffix, text = new:sub(prefix + 1, #new - suffix) }
end

function M.plan(selection, edited)
  local original = selection.original
  local hunks = M.hunks(original, edited)
  -- Normal-mode requests have no preselected range; the user's request decides
  -- what changes. Only snapshot/newline checks apply, so keep every hunk.
  if selection.free then
    local lines = #edited == 0 and { "" } or vim.deepcopy(edited)
    return { lines = lines, hunks = M.hunks(original, lines), dropped = 0 }
  end
  if selection.linewise then
    local split = {}
    for _, h in ipairs(hunks) do
      if #h.old_lines == #h.new_lines then
        for i = 1, #h.old_lines do
          split[#split + 1] =
            { start = h.start + i - 1, old_lines = { h.old_lines[i] }, new_lines = { h.new_lines[i] } }
        end
      else
        split[#split + 1] = h
      end
    end
    local kept, dropped = M.keep_editable(selection, split)
    local lines = M.apply_hunks(original, kept)
    return { lines = lines, hunks = M.hunks(original, lines), dropped = dropped }
  end
  local starts, edits, dropped = offsets(original), {}, 0
  local function add(edit)
    if permitted(selection, edit.first, edit.last, starts) then
      edits[#edits + 1] = edit
    else
      dropped = dropped + 1
    end
  end
  for _, h in ipairs(hunks) do
    if #h.old_lines == #h.new_lines then
      for i, old in ipairs(h.old_lines) do
        local new = h.new_lines[i]
        if old ~= new then
          -- Huge ambiguous single-line rewrites fail closed rather than
          -- allocating an unbounded per-character diff.
          if #old + #new > 256 * 1024 then
            add(trim_edit(old, new, starts[h.start + i]))
          else
            local a, b = vim.fn.split(old, "\\zs"), vim.fn.split(new, "\\zs")
            local ao, bo = { 0 }, { 0 }
            for j, char in ipairs(a) do
              ao[j + 1] = ao[j] + #char
            end
            for j, char in ipairs(b) do
              bo[j + 1] = bo[j] + #char
            end
            local changes = vim.diff(
              table.concat(a, "\n") .. (#a > 0 and "\n" or ""),
              table.concat(b, "\n") .. (#b > 0 and "\n" or ""),
              { result_type = "indices", algorithm = "minimal" }
            )
            for _, c in ipairs(changes) do
              local x = c[2] == 0 and c[1] or c[1] - 1
              local y = c[4] == 0 and c[3] or c[3] - 1
              if c[2] == c[4] then
                for j = 1, c[2] do
                  add({
                    first = starts[h.start + i] + ao[x + j],
                    last = starts[h.start + i] + ao[x + j + 1],
                    text = b[y + j],
                  })
                end
              else
                add({
                  first = starts[h.start + i] + (ao[x + 1] or 0),
                  last = starts[h.start + i] + (ao[x + c[2] + 1] or #old),
                  text = new:sub((bo[y + 1] or 0) + 1, bo[y + c[4] + 1] or #new),
                })
              end
            end
          end
        end
      end
    else
      local start = starts[h.start + 1] or (#table.concat(original, "\n") + 1)
      local old = #h.old_lines > 0 and (table.concat(h.old_lines, "\n") .. "\n") or ""
      local new = #h.new_lines > 0 and (table.concat(h.new_lines, "\n") .. "\n") or ""
      add(trim_edit(old, new, start))
    end
  end
  local text = table.concat(original, "\n") .. "\n"
  table.sort(edits, function(a, b)
    return a.first > b.first
  end)
  for _, e in ipairs(edits) do
    text = text:sub(1, e.first) .. e.text .. text:sub(e.last + 1)
  end
  -- The final delimiter is an implementation detail of the line diff.
  if text:sub(-1) == "\n" then
    text = text:sub(1, -2)
  end
  local lines = vim.split(text, "\n", { plain = true })
  return { lines = lines, hunks = M.hunks(original, lines), dropped = dropped }
end

---The range a hunk occupies in the current buffer, given the new content.
---@param hunk table
---@return integer start_row, integer start_col, integer end_row, integer end_col
function M.hunk_range(hunk)
  local start_row = hunk.new_start
  return start_row, 0, start_row + #hunk.new_lines - 1, 0
end

return M
