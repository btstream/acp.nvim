-- GFM pipe-table parsing and layout.
--
-- Tables are the one block-level construct the transcript renders as more than
-- "one source line in, one display line out": column widths depend on every row,
-- so a table has to be collected in full before any of it can be drawn. The
-- state machine lives in `text.render_text`; this module only does the
-- measuring and the drawing.
local Markdown = require("acp.ui.markdown")

local M = {}

---Split a table row into cells, honouring `\|` escapes.
---@param row string
---@return string[]
local function split_cells(row)
  local trimmed = row:gsub("^%s*|", ""):gsub("|%s*$", "")
  local cells = {}
  local current = {}
  local i = 1
  while i <= #trimmed do
    local ch = trimmed:sub(i, i)
    if ch == "\\" and trimmed:sub(i + 1, i + 1) == "|" then
      current[#current + 1] = "|"
      i = i + 2
    elseif ch == "|" then
      cells[#cells + 1] = table.concat(current)
      current = {}
      i = i + 1
    else
      current[#current + 1] = ch
      i = i + 1
    end
  end
  cells[#cells + 1] = table.concat(current)
  for index, cell in ipairs(cells) do
    cells[index] = vim.trim(cell)
  end
  return cells
end

---Whether `line` looks like a table row (contains an unescaped pipe).
---@param line string
---@return boolean
function M.is_row(line)
  if not line:find("|", 1, true) then
    return false
  end
  -- A row must start and end with a pipe, or at least contain a separator that
  -- is not the only character.
  return line:find("|", 1, true) ~= nil
end

---Whether `line` is the `|---|:--:|` separator under a header row.
---@param line string
---@return boolean
function M.is_separator(line)
  local trimmed = vim.trim(line)
  if not trimmed:find("|", 1, true) then
    return false
  end
  local body = trimmed:gsub("^%s*|", ""):gsub("|%s*$", "")
  if body == "" then
    return false
  end
  for piece in (body .. "|"):gmatch("([^|]*)|") do
    if not vim.trim(piece):match("^:?%-+:?$") then
      return false
    end
  end
  return true
end

---Column alignments from a separator row: "left", "center" or "right".
---@param line string
---@return string[]
function M.alignments(line)
  local body = vim.trim(line):gsub("^%s*|", ""):gsub("|%s*$", "")
  local out = {}
  for piece in (body .. "|"):gmatch("([^|]*)|") do
    local cell = vim.trim(piece)
    local left = cell:sub(1, 1) == ":"
    local right = cell:sub(-1) == ":"
    if left and right then
      out[#out + 1] = "center"
    elseif right then
      out[#out + 1] = "right"
    else
      out[#out + 1] = "left"
    end
  end
  return out
end

---Parse a collected table into its parts.
---@param rows string[] raw source lines, header first, separator second
---@return {header: string[], rows: string[][], align: string[], columns: integer}
function M.parse(rows)
  local header = split_cells(rows[1] or "")
  local align = M.alignments(rows[2] or "")
  local body = {}
  for i = 3, #rows do
    body[#body + 1] = split_cells(rows[i])
  end
  local columns = #header
  for _, row in ipairs(body) do
    columns = math.max(columns, #row)
  end
  -- Pad short rows so drawing never indexes a missing cell.
  for _, row in ipairs(body) do
    for c = #row + 1, columns do
      row[c] = ""
    end
  end
  for c = #header + 1, columns do
    header[c] = ""
  end
  for c = #align + 1, columns do
    align[c] = "left"
  end
  return { header = header, rows = body, align = align, columns = columns }
end

---Whether a completed table has the shape of a real table.
--- A header plus a separator is the minimum; a lone row containing a pipe is
--- just prose that happens to have one.
---@param rows string[]
---@return boolean
function M.is_table(rows)
  return #rows >= 2 and M.is_separator(rows[2])
end

---Byte length of the UTF-8 codepoint starting at `i`.
---@param text string
---@param i integer
---@return integer
local function char_size(text, i)
  local byte = text:byte(i)
  if byte >= 0xF0 then
    return 4
  elseif byte >= 0xE0 then
    return 3
  elseif byte >= 0xC0 then
    return 2
  end
  return 1
end

---Wrap `text` into lines of at most `width` display cells.
---
---Agent output is often CJK, which has no spaces to break on, so the wrap works
---on display width. A Latin word that would be split is moved to the next line
---instead of being cut mid-word, which is what makes long identifiers readable.
---@param text string
---@param width integer
---@return string[]
local function wrap_cell(text, width)
  if width <= 0 then
    return { "" }
  end
  if vim.api.nvim_strwidth(text) <= width then
    return { vim.trim(text) }
  end

  -- Split into break opportunities: every space, and every CJK character.
  local chunks = {}
  local i = 1
  while i <= #text do
    local size = char_size(text, i)
    local ch = text:sub(i, i + size - 1)
    local cells = vim.api.nvim_strwidth(ch)
    if ch == " " then
      chunks[#chunks + 1] = { text = " ", cells = 1, space = true }
    elseif cells > 1 then
      -- Wide glyph: its own break opportunity.
      chunks[#chunks + 1] = { text = ch, cells = cells }
    elseif #chunks > 0 and not chunks[#chunks].space and chunks[#chunks].cells < width then
      -- Accumulate ASCII runs into words.
      local last = chunks[#chunks]
      last.text = last.text .. ch
      last.cells = last.cells + cells
    else
      chunks[#chunks + 1] = { text = ch, cells = cells }
    end
    i = i + size
  end

  local lines = {}
  local current = {}
  local used = 0
  for _, chunk in ipairs(chunks) do
    local skip = false
    if used + chunk.cells > width and used > 0 then
      lines[#lines + 1] = table.concat(current)
      current = {}
      used = 0
      -- Do not start a line with the space that caused the break.
      skip = chunk.space
    end
    if not skip then
      if chunk.cells > width then
        -- A single chunk wider than the column has to be split regardless.
        local piece = {}
        local piece_cells = 0
        local j = 1
        while j <= #chunk.text do
          local size = char_size(chunk.text, j)
          local ch = chunk.text:sub(j, j + size - 1)
          local cells = vim.api.nvim_strwidth(ch)
          if piece_cells + cells > width and piece_cells > 0 then
            lines[#lines + 1] = table.concat(piece)
            piece = {}
            piece_cells = 0
          end
          piece[#piece + 1] = ch
          piece_cells = piece_cells + cells
          j = j + size
        end
        current[#current + 1] = table.concat(piece)
        used = used + piece_cells
      else
        current[#current + 1] = chunk.text
        used = used + chunk.cells
      end
    end
  end
  if #current > 0 then
    lines[#lines + 1] = table.concat(current)
  end
  if #lines == 0 then
    lines[1] = ""
  end
  for index, line in ipairs(lines) do
    lines[index] = vim.trim(line)
  end
  return lines
end

---Materialise a cell's visible text and project styling to its new byte offsets.
---Unlike prose, table cells contain no Markdown delimiters in the buffer: layout
---must measure visible text, and must never conceal it a second time.
local function inline_cell(text, hl)
  local segments = Markdown.parse_inline(text, hl)
  local hidden = {}
  for _, seg in ipairs(segments) do
    if seg.conceal then
      for i = seg.s + 1, seg.e >= 0 and seg.e or #text do
        hidden[i] = true
      end
    end
  end

  -- Boundary map: source byte boundary -> visible byte boundary. It also maps
  -- ranges spanning hidden delimiters (e.g. a base highlight over a whole cell).
  local visible, boundary, size = {}, { [0] = 0 }, 0
  for i = 1, #text do
    if not hidden[i] then
      size = size + 1
      visible[#visible + 1] = text:sub(i, i)
    end
    boundary[i] = size
  end
  local projected = {}
  for _, seg in ipairs(segments) do
    if not seg.conceal and seg.group then
      local s = boundary[seg.s]
      local e = boundary[seg.e >= 0 and seg.e or #text]
      if e > s then
        projected[#projected + 1] = { s = s, e = e, group = seg.group }
      end
    end
  end
  return { text = table.concat(visible), segments = projected }
end

---Render a parsed table into display lines.
---
---No background is painted: a table is text, not a surface, so it reads like the
---prose around it. Cells wrap instead of being truncated, and every border
---character uses `AcpTableBorder` so the frame is one consistent colour.
---@param table_spec {header: string[], rows: string[][], align: string[], columns: integer}
---@param base_hl string|nil
---@param width integer
---@return AcpRenderedLine[]
function M.render(table_spec, base_hl, width)
  local columns, header, rows, align = table_spec.columns, table_spec.header, table_spec.rows, table_spec.align

  -- Parse inline markup once per cell, before measuring or wrapping. Source
  -- delimiters and link targets must not consume the column's display budget.
  local prepared_header, prepared_rows = {}, {}
  for c = 1, columns do
    prepared_header[c] = inline_cell(header[c] or "", "AcpTableHead")
  end
  for _, row in ipairs(rows) do
    local prepared = {}
    for c = 1, columns do
      prepared[c] = inline_cell(row[c] or "", base_hl)
    end
    prepared_rows[#prepared_rows + 1] = prepared
  end

  -- Natural width of each column: the widest visible cell in it.
  local widths = {}
  for c = 1, columns do
    widths[c] = vim.api.nvim_strwidth(prepared_header[c].text)
  end
  for _, row in ipairs(prepared_rows) do
    for c = 1, columns do
      widths[c] = math.max(widths[c], vim.api.nvim_strwidth(row[c].text))
    end
  end

  -- Borders and padding: "│ " + cell + " " per column, plus a closing "│".
  local overhead = columns * 3 + 1
  local available = math.max(columns, width - overhead)
  local total = 0
  for c = 1, columns do
    total = total + widths[c]
  end
  if total > available then
    -- Water-fill by a common ceiling, instead of shrinking a megabyte-long
    -- cell one display cell at a time. O(columns * log(max natural width)).
    local natural = vim.list_slice(widths)
    local lo, hi, cap = 4, 4, 4
    for c = 1, columns do
      hi = math.max(hi, widths[c])
    end
    while lo <= hi do
      local mid, sum = math.floor((lo + hi) / 2), 0
      for c = 1, columns do
        sum = sum + math.min(natural[c], mid)
      end
      if sum <= available then
        cap, lo = mid, mid + 1
      else
        hi = mid - 1
      end
    end
    total = 0
    for c = 1, columns do
      widths[c] = math.min(natural[c], cap)
      total = total + widths[c]
    end
    -- Match the original tie break: later columns keep the spare cells.
    for c = columns, 1, -1 do
      if total >= available then
        break
      end
      if widths[c] < natural[c] then
        widths[c], total = widths[c] + 1, total + 1
      end
    end
  end

  local out = {}

  ---Pad `text` to `column`'s width, honouring its alignment.
  ---@param text string
  ---@param column integer
  ---@return string padded
  ---@return integer left_pad number of bytes of leading padding
  local function fit(text, column)
    local cell_width = widths[column]
    local shown = text
    if vim.api.nvim_strwidth(shown) > cell_width then
      shown = M.truncate(shown, cell_width)
    end
    local pad = cell_width - vim.api.nvim_strwidth(shown)
    local mode = align[column] or "left"
    if mode == "right" then
      return string.rep(" ", pad) .. shown, pad
    elseif mode == "center" then
      local left = math.floor(pad / 2)
      return string.rep(" ", left) .. shown .. string.rep(" ", pad - left), left
    end
    return shown .. string.rep(" ", pad), 0
  end

  ---Split a cell into one entry per wrapped line, with its inline segments.
  ---
  ---Markup is parsed *before* wrapping so a construct spanning a line break keeps
  ---its styling. Wrapping then works on the visible text: the delimiters are
  ---removed, so counting them would break lines in the wrong place and leave
  ---ragged columns.
  ---@param cell {text: string, segments: table[]}
  ---@param width integer
  ---@return {text: string, segments: table[]}[]
  local function wrap_with_markup(cell, width)
    local text, segments = cell.text, cell.segments
    if text == "" then
      return { { text = "", segments = {} } }
    end
    local wrapped = wrap_cell(text, width)
    local lines = {}
    local cursor = 1 -- visible byte offset, including spaces dropped by wrapping
    for _, piece in ipairs(wrapped) do
      -- wrap_cell trims leading/trailing spaces. Locate the actual source slice
      -- instead of assuming all previous bytes were emitted to the buffer.
      local first_byte = text:find(piece, cursor, true) or cursor
      local start, stop = first_byte - 1, first_byte - 1 + #piece
      local line_segments = {}
      for _, seg in ipairs(segments) do
        local from = math.max(seg.s, start)
        local to = math.min(seg.e, stop)
        if to > from then
          line_segments[#line_segments + 1] = {
            s = from - start,
            e = to - start,
            group = seg.group,
          }
        end
      end
      lines[#lines + 1] = { text = piece, segments = line_segments }
      cursor = stop + 1
    end
    return lines
  end

  ---Draw one logical row, wrapping each cell and emitting as many display lines
  ---as the tallest cell needs.
  ---@param cells {text: string, segments: table[]}[]
  local function draw_row(cells)
    local wrapped = {}
    local height = 1
    for c = 1, columns do
      wrapped[c] = wrap_with_markup(cells[c], widths[c])
      height = math.max(height, #wrapped[c])
    end
    for line_index = 1, height do
      local pieces = {}
      local segments = {}
      local offset = 0
      for c = 1, columns do
        local chunk = wrapped[c][line_index] or { text = "", segments = {} }
        local cell_text, left_pad = fit(chunk.text, c)
        -- "│" is three bytes in UTF-8 plus the one-byte space before the cell.
        pieces[#pieces + 1] = "│ " .. cell_text .. " "
        segments[#segments + 1] = { s = offset, e = offset + #"│", group = "AcpTableBorder" }
        local cell_origin = offset + 4 + left_pad
        for _, seg in ipairs(chunk.segments) do
          local stop = math.min(seg.e, #cell_text - left_pad)
          if stop > seg.s then
            segments[#segments + 1] = {
              s = cell_origin + seg.s,
              e = cell_origin + stop,
              group = seg.group,
            }
          end
        end
        offset = offset + 4 + #cell_text + 1
      end
      pieces[#pieces + 1] = "│"
      segments[#segments + 1] = { s = offset, e = offset + #"│", group = "AcpTableBorder" }
      local line_text = table.concat(pieces)
      out[#out + 1] = { text = line_text, segments = segments, table = true }
    end
  end

  ---Build a horizontal rule across all columns.
  ---@param left string
  ---@param middle string
  ---@param right string
  ---@return AcpRenderedLine
  local function draw_rule(left, middle, right)
    local parts = { left }
    for c = 1, columns do
      parts[#parts + 1] = string.rep("─", widths[c] + 2)
      parts[#parts + 1] = c < columns and middle or right
    end
    local text = table.concat(parts)
    return {
      text = text,
      segments = { { s = 0, e = #text, group = "AcpTableBorder" } },
      table = true,
    }
  end

  -- Full grid: every row is fenced on all sides, matching how the agent itself
  -- draws tables.
  out[#out + 1] = draw_rule("┌", "┬", "┐")
  draw_row(prepared_header)
  out[#out + 1] = draw_rule("├", "┼", "┤")
  for index, row in ipairs(prepared_rows) do
    draw_row(row)
    if index < #prepared_rows then
      out[#out + 1] = draw_rule("├", "┼", "┤")
    end
  end
  out[#out + 1] = draw_rule("└", "┴", "┘")

  return out
end

---Truncate `text` to `limit` display cells, appending an ellipsis.
---@param text string
---@param limit integer
---@return string
function M.truncate(text, limit)
  if limit <= 0 then
    return ""
  end
  if vim.api.nvim_strwidth(text) <= limit then
    return text
  end
  if limit <= 1 then
    return ""
  end
  local kept = {}
  local used = 0
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    local width
    if byte >= 0xF0 then
      width = 4
    elseif byte >= 0xE0 then
      width = 3
    elseif byte >= 0xC0 then
      width = 2
    else
      width = 1
    end
    local ch = text:sub(i, i + width - 1)
    local cells = vim.api.nvim_strwidth(ch)
    if used + cells > limit - 1 then
      break
    end
    kept[#kept + 1] = ch
    used = used + cells
    i = i + width
  end
  return table.concat(kept) .. "…"
end

M.split_cells = split_cells

return M
