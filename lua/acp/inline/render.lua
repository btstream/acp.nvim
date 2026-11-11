-- Rows for the inline diff review.
--
-- The primary layout is a two-column, whole-file view: the original text on the
-- left and the agent's proposal on the right, aligned line by line. Unchanged
-- lines appear on both sides; changed lines carry a `-`/`+` sign, and a side
-- without a line is left blank so the columns stay in step.
--
-- Two fallbacks exist:
--
--   hunks   the whole file would exceed `max_rows`; each change block is shown
--           with `context` unchanged lines around it and a `@@ Hunk i/n @@` header
--   unified the window is too narrow for two columns; the historical -/+ list
--
-- Everything here is pure. The window module only writes `lines` into a buffer,
-- applies `spans`, and uses `row_hunk`/`rows` for selection and navigation.
local M = {}

local STATUS_GROUP = {
  pending = "AcpInlinePending",
  accepted = "AcpInlineApplied",
  rejected = "AcpMuted",
}

---Width of the status gutter: a marker glyph and one space.
local GUTTER = 2

---@param hunk table|nil
---@return string
function M.status(hunk)
  if not hunk or not hunk.decided then
    return "pending"
  end
  return hunk.accepted and "accepted" or "rejected"
end

---Gutter marker for a hunk's decision. Kept ASCII-free of width ambiguity by
---padding to exactly GUTTER cells.
---@param hunk table|nil
---@param current boolean
---@return string, string
local function gutter(hunk, current)
  if hunk then
    local status = M.status(hunk)
    if status == "accepted" then
      return "✓ ", "AcpInlineAccepted"
    elseif status == "rejected" then
      return "✗ ", "AcpInlineRejected"
    end
  end
  if current then
    return "▸ ", "AcpInlineCurrent"
  end
  return "  ", "AcpInlineDiffGutter"
end

---Expand tabs to real tab stops, stopping once `limit` display cells are
---reached so a minified line cannot turn this into an unbounded loop.
---@param line string
---@param tabstop integer
---@param limit integer|nil
---@return string
local function expand_tabs(line, tabstop, limit)
  if not line:find("\t", 1, true) then
    return line
  end
  local out, col = {}, 0
  for _, char in ipairs(vim.fn.split(line, "\\zs")) do
    if char == "\t" then
      local stop = tabstop - (col % tabstop)
      out[#out + 1] = string.rep(" ", stop)
      col = col + stop
    else
      out[#out + 1] = char
      col = col + vim.fn.strdisplaywidth(char)
    end
    if limit and col > limit then
      break
    end
  end
  return table.concat(out)
end

---Cut `text` to `width` display cells, marking the cut with an ellipsis.
---@param text string
---@param width integer
---@return string
local function fit(text, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width == 1 then
    return "…"
  end
  local out, used = {}, 0
  for _, char in ipairs(vim.fn.split(text, "\\zs")) do
    local w = vim.fn.strdisplaywidth(char)
    if used + w > width - 1 then
      break
    end
    out[#out + 1] = char
    used = used + w
  end
  return table.concat(out) .. "…"
end

---@param text string
---@param width integer
---@return string
local function pad(text, width)
  return text .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
end

---Column widths for the two-column layout.
---@param original string[]
---@param edited string[]
---@param width integer
---@return {old_num: integer, new_num: integer, old: integer, new: integer}|nil
function M.widths(original, edited, width)
  local old_num = math.max(3, #tostring(math.max(1, #original)))
  local new_num = math.max(3, #tostring(math.max(1, #edited)))
  -- Per side: gutter, number and its space, sign, content and its trailing
  -- space. Plus the "│ " divider between them.
  local fixed = GUTTER + old_num + 1 + 2 + 1 + 2 + new_num + 1 + 2
  local usable = width - fixed
  if usable < 8 then
    return nil
  end
  local old = math.floor(usable / 2)
  local new = usable - old
  if old < 4 or new < 4 then
    return nil
  end
  return { old_num = old_num, new_num = new_num, old = old, new = new }
end

---Split both files into aligned segments: identical runs and change blocks.
---@param original string[]
---@param edited string[]
---@param hunks table[]
---@return table[]
local function segments(original, edited, hunks)
  local out = {}
  local old_i, new_i = 0, 0
  for index, hunk in ipairs(hunks) do
    if hunk.start > old_i then
      local count = hunk.start - old_i
      out[#out + 1] = { kind = "same", old_start = old_i, new_start = new_i, count = count }
      old_i = old_i + count
      new_i = new_i + count
    end
    local new_start = hunk.new_start or old_i
    out[#out + 1] = {
      kind = "change",
      index = index,
      old_start = old_i,
      old_count = #hunk.old_lines,
      new_start = new_start,
      new_count = #hunk.new_lines,
    }
    old_i = old_i + #hunk.old_lines
    new_i = new_start + #hunk.new_lines
  end
  if old_i < #original then
    out[#out + 1] = { kind = "same", old_start = old_i, new_start = new_i, count = #original - old_i }
  end
  return out
end

---Rows for one unchanged segment between offsets `from` and `to`.
---@param segment table
---@param original string[]
---@param edited string[]
---@param from integer
---@param to integer
---@return table[]
local function same_rows(segment, original, edited, from, to)
  local rows = {}
  for offset = from, to - 1 do
    local old_no = segment.old_start + offset + 1
    local new_no = segment.new_start + offset + 1
    rows[#rows + 1] = {
      kind = "same",
      old_no = old_no,
      old_text = original[old_no] or "",
      new_no = new_no,
      new_text = edited[new_no] or "",
    }
  end
  return rows
end

---Rows for a change segment, pairing as many lines as both sides provide.
---@param segment table
---@param original string[]
---@param edited string[]
---@return table[]
local function change_rows(segment, original, edited)
  local rows = {}
  local count = math.max(segment.old_count, segment.new_count)
  for slot = 0, count - 1 do
    local old_no = slot < segment.old_count and (segment.old_start + slot + 1) or nil
    local new_no = slot < segment.new_count and (segment.new_start + slot + 1) or nil
    rows[#rows + 1] = {
      kind = "change",
      hunk = segment.index,
      old_no = old_no,
      old_text = old_no and original[old_no] or nil,
      new_no = new_no,
      new_text = new_no and edited[new_no] or nil,
    }
  end
  return rows
end

---Header text for a hunk in the `hunks` fallback.
---@param hunk table
---@param index integer
---@param total integer
---@return string
function M.header(hunk, index, total)
  return string.format(
    "@@ Hunk %d/%d · %s @@ -%d,%d +%d,%d",
    index,
    total,
    M.status(hunk),
    hunk.start + 1,
    #hunk.old_lines,
    (hunk.new_start or hunk.start) + 1,
    #hunk.new_lines
  )
end

---Whole-file rows, unchanged lines included.
---@param original string[]
---@param edited string[]
---@param hunks table[]
---@return table[]
local function rows_full(original, edited, hunks)
  local rows = {}
  for _, segment in ipairs(segments(original, edited, hunks)) do
    if segment.kind == "same" then
      vim.list_extend(rows, same_rows(segment, original, edited, 0, segment.count))
    else
      vim.list_extend(rows, change_rows(segment, original, edited))
    end
  end
  return rows
end

---Rows for each change block plus `context` unchanged lines around it.
---@param original string[]
---@param edited string[]
---@param hunks table[]
---@param context integer
---@return table[]
local function rows_hunks(original, edited, hunks, context)
  local rows = {}
  local list = segments(original, edited, hunks)
  for position, segment in ipairs(list) do
    if segment.kind == "change" then
      rows[#rows + 1] = {
        kind = "header",
        hunk = segment.index,
        header = M.header(hunks[segment.index], segment.index, #hunks),
      }
      local before = list[position - 1]
      if before and before.kind == "same" then
        vim.list_extend(rows, same_rows(before, original, edited, math.max(0, before.count - context), before.count))
      end
      vim.list_extend(rows, change_rows(segment, original, edited))
      local after = list[position + 1]
      if after and after.kind == "same" then
        vim.list_extend(rows, same_rows(after, original, edited, 0, math.min(context, after.count)))
      end
      rows[#rows + 1] = { kind = "separator" }
    end
  end
  return rows
end

---Format rows into two columns.
---@param rows table[]
---@param cols table
---@param opts {tabstop?: integer, max_rows?: integer, hunks?: table[]}
---@return table
local function format_split(rows, cols, opts)
  local tabstop = math.max(1, opts.tabstop or 8)
  local max_rows = opts.max_rows or 4000
  local hunks = opts.hunks or {}
  local lines, spans, row_hunk, hunk_rows = {}, {}, {}, {}
  local truncated = false
  for _, row in ipairs(rows) do
    if #lines >= max_rows then
      truncated = true
      break
    end
    local line_index = #lines
    if row.kind == "header" then
      if row.hunk then
        hunk_rows[row.hunk] = hunk_rows[row.hunk] or (#lines + 1)
      end
      lines[#lines + 1] = row.header
      spans[#spans + 1] = { row = line_index, start = 0, stop = -1, group = "AcpInlineBanner" }
      local status = M.status(hunks[row.hunk])
      local at = row.header:find(status, 1, true)
      if at then
        spans[#spans + 1] = {
          row = line_index,
          start = at - 1,
          stop = at - 1 + #status,
          group = STATUS_GROUP[status] or "AcpInlinePending",
        }
      end
      -- The header belongs to its hunk, so the cursor can select it directly.
      row_hunk[#lines] = row.hunk or false
    elseif row.kind == "separator" then
      lines[#lines + 1] = ""
      row_hunk[#lines] = false
    else
      local hunk_index = row.hunk
      row_hunk[#lines + 1] = hunk_index or false
      if hunk_index then
        hunk_rows[hunk_index] = hunk_rows[hunk_index] or (#lines + 1)
      end
      local changed = row.kind == "change"
      local old_text = row.old_text and expand_tabs(row.old_text, tabstop, cols.old) or ""
      local new_text = row.new_text and expand_tabs(row.new_text, tabstop, cols.new) or ""
      local marker, marker_group = gutter(hunk_index and hunks[hunk_index] or nil, false)
      local old_sign, new_sign = "  ", "  "
      if changed then
        old_sign = row.old_text and "- " or "  "
        new_sign = row.new_text and "+ " or "  "
      end
      local cells, cursor = {}, 0
      local function cell(text, group)
        local start = cursor
        cells[#cells + 1] = text
        cursor = cursor + #text
        if group then
          spans[#spans + 1] = { row = line_index, start = start, stop = cursor, group = group }
        end
      end
      cell(pad(marker, GUTTER), marker_group)
      cell(pad(row.old_no and tostring(row.old_no) or "", cols.old_num) .. " ", "AcpInlineDiffNum")
      cell(old_sign, changed and "AcpInlineDiffOldSign" or "AcpInlineDiffContext")
      cell(pad(fit(old_text, cols.old), cols.old) .. " ", changed and "AcpInlineDiffOld" or "AcpInlineDiffContext")
      cell("│ ", "AcpInlineDiffDivider")
      cell(pad(row.new_no and tostring(row.new_no) or "", cols.new_num) .. " ", "AcpInlineDiffNum")
      cell(new_sign, changed and "AcpInlineDiffNewSign" or "AcpInlineDiffContext")
      cell(pad(fit(new_text, cols.new), cols.new), changed and "AcpInlineDiffNew" or "AcpInlineDiffContext")
      lines[#lines + 1] = table.concat(cells)
    end
  end
  if truncated then
    -- Keep the notice inside the row budget so callers can trust `max_rows`.
    local notice = string.format("… review truncated at inline.window.review.max_rows (%d)", max_rows)
    if lines[#lines] == "" or #lines >= max_rows then
      lines[#lines] = notice
    else
      lines[#lines + 1] = notice
    end
    spans[#spans + 1] = { row = #lines - 1, start = 0, stop = -1, group = "AcpInlineBanner" }
    row_hunk[#lines] = false
  end
  return {
    lines = lines,
    spans = spans,
    rows = hunk_rows,
    row_hunk = row_hunk,
    cols = cols,
    rendered = vim.tbl_count(hunk_rows),
  }
end

---Single-column `-`/`+` layout, used when the window cannot fit two columns.
---@param hunks table[]
---@param opts {max_rows?: integer}
---@return table
function M.unified(hunks, opts)
  local max_rows = (opts and opts.max_rows) or 4000
  local lines, spans, hunk_rows, row_hunk = {}, {}, {}, {}
  local truncated = false
  for index, hunk in ipairs(hunks) do
    local needed = #hunk.old_lines + #hunk.new_lines + 2
    if #lines + needed > max_rows then
      truncated = true
      break
    end
    hunk_rows[index] = #lines + 1
    local header = M.header(hunk, index, #hunks)
    lines[#lines + 1] = header
    spans[#spans + 1] = { row = #lines - 1, start = 0, stop = -1, group = "AcpInlineBanner" }
    row_hunk[#lines] = index
    for _, line in ipairs(hunk.old_lines) do
      lines[#lines + 1] = "- " .. line
      spans[#spans + 1] = { row = #lines - 1, start = 0, stop = -1, group = "AcpInlineDiffOld" }
      row_hunk[#lines] = index
    end
    for _, line in ipairs(hunk.new_lines) do
      lines[#lines + 1] = "+ " .. line
      spans[#spans + 1] = { row = #lines - 1, start = 0, stop = -1, group = "AcpInlineDiffNew" }
      row_hunk[#lines] = index
    end
    lines[#lines + 1] = ""
    row_hunk[#lines] = false
  end
  if truncated then
    local notice = string.format("… review truncated at inline.window.review.max_rows (%d)", max_rows)
    if lines[#lines] == "" or #lines >= max_rows then
      lines[#lines] = notice
    else
      lines[#lines + 1] = notice
    end
    spans[#spans + 1] = { row = #lines - 1, start = 0, stop = -1, group = "AcpInlineBanner" }
    row_hunk[#lines] = false
  end
  for row = 1, #lines do
    if row_hunk[row] == nil then
      row_hunk[row] = false
    end
  end
  return { lines = lines, spans = spans, rows = hunk_rows, row_hunk = row_hunk, rendered = vim.tbl_count(hunk_rows) }
end

---Build the review view.
---@param opts {
---  original: string[],
---  edited: string[],
---  hunks: table[],
---  width: integer,
---  layout?: "split2"|"hunks"|"unified",
---  tabstop?: integer,
---  max_rows?: integer,
---  context?: integer,
---  min_split_width?: integer
---}
---@return table
function M.build(opts)
  local width = math.max(1, opts.width)
  local layout = opts.layout or "split2"
  local cols = M.widths(opts.original, opts.edited, width)
  if layout ~= "unified" and cols and width >= (opts.min_split_width or 40) then
    if layout == "split2" then
      local full = rows_full(opts.original, opts.edited, opts.hunks)
      if #full <= (opts.max_rows or 4000) then
        local view = format_split(full, cols, opts)
        view.layout = "split2"
        return view
      end
    end
    local list = rows_hunks(opts.original, opts.edited, opts.hunks, math.max(0, opts.context or 3))
    local view = format_split(list, cols, opts)
    view.layout = "hunks"
    return view
  end
  local view = M.unified(opts.hunks, opts)
  view.layout = "unified"
  return view
end

---Hunk indices intersecting a 1-based inclusive row range.
---@param view table
---@param from integer
---@param to integer
---@return integer[]
function M.selected(view, from, to)
  local seen, out = {}, {}
  local map = view.row_hunk or {}
  for row = math.max(1, from), math.min(to, #map) do
    local hunk = map[row]
    if hunk and not seen[hunk] then
      seen[hunk] = true
      out[#out + 1] = hunk
    end
  end
  table.sort(out)
  return out
end

---The hunk occupying a 1-based row, if any.
---@param view table
---@param row integer
---@return integer|nil
function M.hunk_at(view, row)
  local hunk = view.row_hunk and view.row_hunk[row]
  return hunk or nil
end

---First and last row of a hunk in the view.
---@param view table
---@param index integer
---@return integer from, integer to
function M.hunk_range(view, index)
  local first = view.rows and view.rows[index]
  if not first then
    return math.max(1, #view.lines), #view.lines
  end
  local next_row = view.rows[index + 1]
  local last = next_row and (next_row - 1) or #view.lines
  return first, math.max(first, last)
end

return M
