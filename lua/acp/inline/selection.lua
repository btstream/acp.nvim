-- Capture a visual selection or an insertion point for inline editing.
--
-- Capture happens in the mapping, while visual mode still owns the buffer, so
-- the opening float can move focus without losing the range. Ranges are stored
-- as 0-based, end-exclusive byte columns.
local M = {}

---@class AcpInlineSelection
---@field bufnr integer
---@field win integer
---@field mode "v"|"V"|"\22"
---@field ranges {start_row: integer, start_col: integer, end_row: integer, end_col: integer}[]
---@field first integer 1-based first row
---@field last integer 1-based last row
---@field original string[] full buffer lines at capture time
---@field filetype string
---@field path string|nil
---@field changedtick integer

---@param pos integer[]
---@return integer row, integer col 0-based, end-exclusive column
local function start_of(pos)
  return pos[2] - 1, math.max(0, pos[3] - 1)
end

---@param pos integer[]
---@return integer row, integer col
local function end_of(pos)
  -- `off` is non-zero when part of the final character is excluded.
  local row = pos[2] - 1
  if pos[4] and pos[4] ~= 0 then
    return row, math.max(0, pos[3] - 1)
  end
  return row, pos[3]
end

---@param lines string[]
---@param ranges {start_row: integer, start_col: integer, end_row: integer, end_col: integer}[]
---@return string[] texts
local function text_of(lines, ranges)
  local out = {}
  for _, range in ipairs(ranges) do
    local parts = {}
    for row = range.start_row, range.end_row do
      local line = lines[row + 1] or ""
      local from = row == range.start_row and range.start_col or 0
      local to = row == range.end_row and range.end_col or #line
      parts[#parts + 1] = line:sub(from + 1, to)
    end
    out[#out + 1] = table.concat(parts, "\n")
  end
  return out
end

---Merge overlapping or touching ranges from a continuous selection.
---@param ranges table[]
---@return table[]
local function merge(ranges)
  table.sort(ranges, function(a, b)
    if a.start_row ~= b.start_row then
      return a.start_row < b.start_row
    end
    return a.start_col < b.start_col
  end)
  local out = {}
  for _, range in ipairs(ranges) do
    local previous = out[#out]
    local touches = previous
      and (
        range.start_row < previous.end_row
        or (range.start_row == previous.end_row and range.start_col <= previous.end_col)
        or range.start_row == previous.end_row + 1
      )
    if touches then
      if
        range.end_row > previous.end_row or (range.end_row == previous.end_row and range.end_col > previous.end_col)
      then
        previous.end_row, previous.end_col = range.end_row, range.end_col
      end
    else
      out[#out + 1] = range
    end
  end
  return out
end

---Whether the current window hosts a visual selection worth capturing.
---@param win integer
---@return boolean
function M.available(win)
  return vim.api.nvim_win_is_valid(win) and vim.fn.mode():find("^[vV\22]") ~= nil
end

---Capture the current visual range or cursor position.
---
---With no visual mode the result is a single empty range at the cursor, which
---callers interpret as insertion.
---@param win integer
---@param config table
---@param override {mode: string, pos1: integer[], pos2: integer[]}|nil test hook
---@return AcpInlineSelection|nil selection
---@return string|nil err
function M.capture(win, config, override)
  if not vim.api.nvim_win_is_valid(win) then
    return nil, "the inline window is gone"
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local mode = override and override.mode or vim.fn.mode()
  local filetype = vim.bo[bufnr].filetype
  local visual = override ~= nil or mode:find("^[vV\22]") ~= nil
  local ranges = {}

  if visual then
    local pos1 = override and override.pos1 or vim.fn.getpos("v")
    local pos2 = override and override.pos2 or vim.fn.getpos(".")
    local region = vim.fn.getregionpos(pos1, pos2, { type = mode, exclusive = false, eol = false })
    for _, pair in ipairs(region) do
      local row1, col1 = start_of(pair[1])
      local row2, col2 = end_of(pair[2])
      if row1 == row2 then
        if col1 < col2 then
          ranges[#ranges + 1] = { start_row = row1, start_col = col1, end_row = row2, end_col = col2 }
        end
      elseif row1 < row2 then
        ranges[#ranges + 1] = { start_row = row1, start_col = col1, end_row = row2, end_col = col2 }
      end
    end
    if #ranges == 0 then
      return nil, "empty selection"
    end

    local block = mode == "\22"
    if not block and config.inline.expand_selection then
      -- Whole lines, matching the editors this is modelled on. A partial
      -- selection almost always starts or ends mid-token, and replacing a
      -- whole line keeps indentation and trailing comments intact.
      for _, range in ipairs(ranges) do
        range.start_col = 0
        range.end_col = #(lines[range.end_row + 1] or "")
      end
    end
    if not block then
      ranges = merge(ranges)
    end
  else
    local cursor = vim.api.nvim_win_get_cursor(win)
    local row = cursor[1] - 1
    if (config.inline.scope or "cursor") == "context" then
      -- A bounded window around the cursor; the agent may edit all of it.
      local radius = math.max(2, math.min(40, math.floor(config.inline.context_bytes / 2048)))
      local first = math.max(0, row - radius)
      local last = math.min(#lines - 1, row + radius)
      ranges[1] = { start_row = first, start_col = 0, end_row = last, end_col = #(lines[last + 1] or "") }
    else
      ranges[1] = { start_row = row, start_col = cursor[2], end_row = row, end_col = cursor[2] }
    end
  end

  local texts = text_of(lines, ranges)
  local bytes, count = 0, 0
  for _, text in ipairs(texts) do
    bytes = bytes + #text
    count = count + select(2, text:gsub("\n", "\n")) + 1
  end
  local limits = config.context or {}
  if count > (limits.max_selection_lines or 2000) then
    return nil, "selection is too large to edit inline"
  end
  if bytes > (limits.max_file_bytes or 512 * 1024) then
    return nil, "selection is too large to edit inline"
  end
  if bytes == 0 and #ranges > 0 and not visual then
    -- Insertion point: still valid, but there is nothing to replace.
  end

  local selection = {
    bufnr = bufnr,
    win = win,
    mode = visual and (mode == "V" and "V" or mode == "\22" and "\22" or "v") or "v",
    ranges = ranges,
    first = ranges[1].start_row + 1,
    last = ranges[#ranges].end_row + 1,
    original = lines,
    filetype = filetype,
    path = vim.api.nvim_buf_get_name(bufnr),
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    insertion = not visual and #texts[1] == 0 or false,
  }
  selection.text = table.concat(texts, "\n")
  return selection
end

---Text of a selection from a snapshot's lines.
---@param selection AcpInlineSelection
---@return string
function M.text(selection)
  return selection.text or ""
end

---Whether `[start_row, start_col]` sits inside any selected range.
---@param selection AcpInlineSelection
---@param row integer 0-based
---@param col integer
---@return boolean
function M.contains(selection, row, col)
  for _, range in ipairs(selection.ranges) do
    if row >= range.start_row and row <= range.end_row then
      if row > range.start_row and row < range.end_row then
        return true
      end
      local after_start = row > range.start_row or col >= range.start_col
      local before_end = row < range.end_row or col <= range.end_col
      if after_start and before_end then
        return true
      end
    end
  end
  return false
end

return M
