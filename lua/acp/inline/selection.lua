-- Capture once, before opening any UI. Columns are UTF-8 byte boundaries,
-- ranges are zero-based/end-exclusive. Never widen a block to whole lines.
local M = {}

local function char_end(line, col)
  if col >= #line then
    return #line
  end
  local stop = col + 1
  while stop < #line do
    local byte = line:byte(stop + 1)
    if byte < 128 or byte >= 192 then
      break
    end
    stop = stop + 1
  end
  return stop
end

function M.capture(win, config, override)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil, "the source window is gone"
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
    return nil, "the source buffer is not editable"
  end
  if vim.bo[buf].filetype:match("^acp_") then
    return nil, "select a source buffer, not an ACP view"
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local size = #table.concat(lines, "\n")
  if size > config.inline.max_copy_bytes then
    return nil, "buffer exceeds inline.max_copy_bytes"
  end
  local mode = override and override.mode or vim.fn.mode()
  local visual = override ~= nil or mode == "v" or mode == "V" or mode == "\22"
  local ranges, linewise = {}, false
  if visual then
    if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
      return nil, "unsupported selection mode"
    end
    local p1 = override and override.pos1 or vim.fn.getpos("v")
    local p2 = override and override.pos2 or vim.fn.getpos(".")
    local exclusive = not override and vim.o.selection == "exclusive"
    local region
    if vim.fn.exists("*getregionpos") == 1 then
      local ok, value = pcall(vim.fn.getregionpos, p1, p2, { type = mode, exclusive = exclusive, eol = false })
      if not ok then
        return nil, tostring(value)
      end
      region = value
    else
      if mode == "\22" then
        return nil, "block selections require getregionpos() on this Neovim"
      end
      local a, b = p1, p2
      if a[2] > b[2] or (a[2] == b[2] and a[3] > b[3]) then
        a, b = b, a
      end
      local last = math.min(#lines, b[2])
      region = {}
      for row = math.max(1, a[2]), last do
        local first_col = row == a[2] and math.max(1, a[3]) or 1
        local end_col = row == b[2] and math.min(#lines[row], b[3]) or #lines[row]
        if exclusive and row == b[2] then
          end_col = end_col - 1
        end
        region[#region + 1] = { { buf, row, first_col, 0 }, { buf, row, end_col, 0 } }
      end
    end
    for _, pair in ipairs(region) do
      local a, b = pair[1], pair[2]
      if (a[4] or 0) ~= 0 or (b[4] or 0) ~= 0 then
        return nil, "selection splits a Tab/wide character or extends into virtual space"
      end
      local row = a[2] - 1
      local line = lines[row + 1] or ""
      local start = math.min(#line, math.max(0, a[3] - 1))
      local finish = b[3] > 0 and char_end(line, b[3] - 1) or 0
      ranges[#ranges + 1] = { start_row = row, start_col = start, end_row = row, end_col = finish }
    end
    if #ranges == 0 then
      return nil, "empty selection"
    end
    linewise = mode == "V" or (mode ~= "\22" and config.inline.expand_selection)
    if mode ~= "\22" then
      local first, last = ranges[1], ranges[#ranges]
      ranges = {
        {
          start_row = first.start_row,
          start_col = linewise and 0 or first.start_col,
          end_row = last.end_row,
          end_col = linewise and #lines[last.end_row + 1] or last.end_col,
        },
      }
    end
  else
    local p = vim.api.nvim_win_get_cursor(win)
    local row = p[1] - 1
    if config.inline.scope == "context" then
      local first, last, used = row, row, #lines[row + 1]
      while used < config.inline.context_bytes do
        local grew = false
        if first > 0 and used + #lines[first] + 1 <= config.inline.context_bytes then
          used, first, grew = used + #lines[first] + 1, first - 1, true
        end
        if last < #lines - 1 and used + #lines[last + 2] + 1 <= config.inline.context_bytes then
          used, last, grew = used + #lines[last + 2] + 1, last + 1, true
        end
        if not grew then
          break
        end
      end
      ranges[1] = { start_row = first, start_col = 0, end_row = last, end_col = #lines[last + 1] }
      linewise = true
    else
      ranges[1] = { start_row = row, start_col = p[2], end_row = row, end_col = p[2] }
    end
  end
  local texts, count = {}, 0
  for _, range in ipairs(ranges) do
    local parts = {}
    for row = range.start_row, range.end_row do
      local from = row == range.start_row and range.start_col or 0
      local to = row == range.end_row and range.end_col or #lines[row + 1]
      parts[#parts + 1] = lines[row + 1]:sub(from + 1, to)
      count = count + 1
    end
    texts[#texts + 1] = table.concat(parts, "\n")
  end
  local text = table.concat(texts, "\n")
  if count > config.context.max_selection_lines or #text > config.context.max_file_bytes then
    return nil, "selection is too large to edit inline"
  end
  return {
    bufnr = buf,
    win = win,
    ranges = ranges,
    mode = visual and mode or "v",
    linewise = linewise,
    insertion = not visual and not linewise,
    original = lines,
    text = text,
    first = ranges[1].start_row + 1,
    last = ranges[#ranges].end_row + 1,
    changedtick = vim.api.nvim_buf_get_changedtick(buf),
    filetype = vim.bo[buf].filetype,
    path = vim.api.nvim_buf_get_name(buf),
    fileformat = vim.bo[buf].fileformat,
    eol = vim.bo[buf].endofline,
  }
end

function M.text(selection)
  return selection.text
end
return M
