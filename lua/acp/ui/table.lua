-- GFM pipe-table parsing and layout.
--
-- Tables are the one block-level construct the transcript renders as more than
-- "one source line in, one display line out": column widths depend on every row,
-- so a table has to be collected in full before any of it can be drawn. The
-- state machine lives in `blocks.render_text`; this module only does the
-- measuring and the drawing.
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

---Render a parsed table into display lines.
---
---Columns are padded to their widest cell and joined with a vertical bar; the
---separator row under the header is drawn with box characters so it reads as a
---rule. Every row shares the code-block surface so a table reads as content
---rather than chrome.
---@param table_spec {header: string[], rows: string[][], align: string[], columns: integer}
---@param base_hl string|nil
---@param width integer
---@return AcpRenderedLine[]
function M.render(table_spec, base_hl, width)
  local columns, header, rows, align = table_spec.columns, table_spec.header, table_spec.rows, table_spec.align

  -- Natural width of each column: the widest cell in it.
  local widths = {}
  for c = 1, columns do
    widths[c] = vim.api.nvim_strwidth(header[c] or "")
  end
  for _, row in ipairs(rows) do
    for c = 1, columns do
      widths[c] = math.max(widths[c], vim.api.nvim_strwidth(row[c] or ""))
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
    -- Shrink the widest columns first until the table fits.
    while total > available do
      local widest, index = -1, 1
      for c = 1, columns do
        if widths[c] > widest then
          widest, index = widths[c], c
        end
      end
      if widest <= 1 then
        break
      end
      widths[index] = widest - 1
      total = total - 1
    end
  end

  local out = {}

  ---Place one cell's text inside its column, honouring alignment.
  ---@param text string
  ---@param column integer
  ---@return string
  local function fit(text, column)
    local cell_width = widths[column]
    local shown = text
    if vim.api.nvim_strwidth(shown) > cell_width then
      shown = M.truncate(shown, cell_width)
    end
    local pad = cell_width - vim.api.nvim_strwidth(shown)
    local mode = align[column] or "left"
    if mode == "right" then
      return string.rep(" ", pad) .. shown
    elseif mode == "center" then
      local left = math.floor(pad / 2)
      return string.rep(" ", left) .. shown .. string.rep(" ", pad - left)
    end
    return shown .. string.rep(" ", pad)
  end

  ---Build a row line and its cell segments.
  ---@param cells string[]
  ---@param hl string|nil
  ---@return AcpRenderedLine
  local function draw_row(cells, hl)
    local parts = { "│" }
    local segments = {}
    local column_start = 2 -- byte offset just past the leading bar
    for c = 1, columns do
      local cell_text = fit(cells[c] or "", c)
      local cell_start = column_start + 1 -- past the single space
      parts[#parts + 1] = " " .. cell_text .. " "
      if hl then
        segments[#segments + 1] = { s = cell_start, e = cell_start + #cell_text, group = hl }
      end
      parts[#parts + 1] = "│"
      column_start = column_start + #cell_text + 3
    end
    return { text = table.concat(parts), segments = segments, bg = "AcpCodeBlockBg", table = true }
  end

  out[#out + 1] = draw_row(header, "AcpTableHead")

  -- Header rule.
  local rule = {}
  rule[#rule + 1] = "├"
  for c = 1, columns do
    rule[#rule + 1] = string.rep("─", widths[c] + 2)
    rule[#rule + 1] = c < columns and "┼" or "┤"
  end
  out[#out + 1] = {
    text = table.concat(rule),
    segments = { { s = 0, e = -1, group = "AcpTableRule" } },
    bg = "AcpCodeBlockBg",
    table = true,
  }

  for _, row in ipairs(rows) do
    out[#out + 1] = draw_row(row, base_hl)
  end

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
