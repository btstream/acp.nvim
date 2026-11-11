-- Review rows for the inline diff window.
--
-- Two layouts share one hunk model:
--
--   side_by_side   old | result | new
--   unified        the historical - / + list
--
-- The middle column is a merge preview: it shows the line the buffer will
-- contain for that slot once the hunk's decision is applied. It is therefore
-- the agent's text while a hunk is pending or accepted, and the original text
-- once it is rejected.
--
-- Everything here is pure: rows, highlight spans and the hunk's first row are
-- returned, so the window module only writes them into a buffer.
local M = {}

local STATUS_GROUP = {
  pending = "AcpInlinePending",
  accepted = "AcpInlineApplied",
  rejected = "AcpMuted",
}

local STATUS_PREVIEW = {
  pending = "proposed",
  accepted = "applied",
  rejected = "original",
}

---Expand tabs to real tab stops, so columns line up even with mixed indentation.
---Iterates characters (not bytes) and stops once `limit` display cells are
---reached, so a minified line cannot turn this into an unbounded loop.
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

---Hunk state name used in headers and for the row highlight.
---@param hunk table
---@return string
function M.status(hunk)
  if not hunk.decided then
    return "pending"
  end
  return hunk.accepted and "accepted" or "rejected"
end

---Header text: position, status and, when the layout has a preview column, what
---the middle column currently shows.
---@param hunk table
---@param index integer
---@param total integer
---@param preview boolean|nil
---@return string
function M.header(hunk, index, total, preview)
  local status = M.status(hunk)
  local parts = { string.format("@@ Hunk %d/%d", index, total), status }
  if preview ~= false then
    parts[#parts + 1] = "preview: " .. (STATUS_PREVIEW[status] or "proposed")
  end
  return table.concat(parts, " · ")
    .. string.format(
      " @@ -%d,%d +%d,%d",
      hunk.start + 1,
      #hunk.old_lines,
      (hunk.new_start or hunk.start) + 1,
      #hunk.new_lines
    )
end

---Spans for a hunk header: muted text plus the status word, so the state reads
---at a glance without painting the whole row a diff colour.
---@param header string
---@param status string
---@return table[]
local function header_spans(header, status)
  local out = { { 0, -1, "AcpInlineBanner" } }
  local start = header:find(status, 1, true)
  if start then
    out[#out + 1] = { start - 1, start - 1 + #status, STATUS_GROUP[status] or "AcpInlinePending" }
  end
  return out
end

---Column widths for a side-by-side layout.
---@param hunks table[]
---@param width integer
---@return {old_num: integer, new_num: integer, old: integer, result: integer, new: integer}|nil
function M.widths(hunks, width)
  local old_max, new_max = 0, 0
  for _, hunk in ipairs(hunks) do
    old_max = math.max(old_max, hunk.start + #hunk.old_lines)
    new_max = math.max(new_max, (hunk.new_start or hunk.start) + #hunk.new_lines)
  end
  local old_num = math.max(3, #tostring(math.max(1, old_max)))
  local new_num = math.max(3, #tostring(math.max(1, new_max)))
  -- Two " │ " separators, and one space of padding inside each column.
  local fixed = old_num + new_num + 6 + 2
  local usable = width - fixed
  if usable < 12 then
    return nil
  end
  local old = math.floor(usable / 3)
  local new = math.floor(usable / 3)
  local result = usable - old - new
  if old < 4 or new < 4 or result < 4 then
    return nil
  end
  return { old_num = old_num, new_num = new_num, old = old, result = result, new = new }
end

---Side-by-side rows for every hunk.
---@param hunks table[]
---@param opts {width: integer, tabstop?: integer, max_rows?: integer, min_split_width?: integer}
---@return table|nil layout nil when the window is too narrow
function M.side_by_side(hunks, opts)
  local width = math.max(1, opts.width)
  if width < (opts.min_split_width or 60) then
    return nil
  end
  local cols = M.widths(hunks, width)
  if not cols then
    return nil
  end
  local tabstop = math.max(1, opts.tabstop or 8)
  local max_rows = opts.max_rows or 2000
  local lines, spans, rows = {}, {}, {}
  local function push(text, groups)
    if #lines >= max_rows then
      return false
    end
    lines[#lines + 1] = text
    for _, span in ipairs(groups or {}) do
      spans[#spans + 1] = { row = #lines - 1, start = span[1], stop = span[2], group = span[3] }
    end
    return true
  end
  local truncated = false
  for index, hunk in ipairs(hunks) do
    if #lines >= max_rows then
      truncated = true
      break
    end
    rows[index] = #lines + 1
    local status = M.status(hunk)
    local header = M.header(hunk, index, #hunks)
    local count = math.max(#hunk.old_lines, #hunk.new_lines)
    -- Reserve the whole hunk (header + rows + blank) before writing anything,
    -- so a truncated view never overwrites a real row with the notice.
    if #lines + count + 3 > max_rows then
      truncated = true
      rows[index] = nil
      break
    end
    push(header, header_spans(header, status))
    for slot = 1, count do
      local old = expand_tabs(hunk.old_lines[slot] or "", tabstop, cols.old)
      local new = expand_tabs(hunk.new_lines[slot] or "", tabstop, cols.new)
      -- The middle column is what the buffer will contain for this slot: the
      -- agent's text unless the hunk is rejected.
      local result = (status == "rejected") and old or new
      local old_no = hunk.old_lines[slot] ~= nil and tostring(hunk.start + slot) or ""
      local new_no = hunk.new_lines[slot] ~= nil and tostring((hunk.new_start or hunk.start) + slot) or ""
      local old_group = hunk.old_lines[slot] and "AcpInlineDiffOld" or "AcpMuted"
      local new_group = hunk.new_lines[slot] and "AcpInlineDiffNew" or "AcpMuted"
      local result_group = "AcpInlineDiffResult"
      if status == "rejected" and hunk.old_lines[slot] ~= nil then
        result_group = "AcpInlineDiffResultOld"
      elseif hunk.new_lines[slot] == nil then
        result_group = "AcpMuted"
      end
      local cells, cursor = {}, 0
      local function cell(text, group)
        local start = cursor
        cells[#cells + 1] = text
        cursor = cursor + #text
        if group then
          spans[#spans + 1] = { row = #lines, start = start, stop = cursor, group = group }
        end
      end
      cell(pad(old_no, cols.old_num) .. " ", "AcpInlineDiffNum")
      cell(pad(fit(old, cols.old), cols.old) .. " ", old_group)
      cell("│ ", "AcpInlineDiffDivider")
      cell(pad(fit(result, cols.result), cols.result) .. " ", result_group)
      cell("│ ", "AcpInlineDiffDivider")
      cell(pad(new_no, cols.new_num) .. " ", "AcpInlineDiffNum")
      cell(pad(fit(new, cols.new), cols.new), new_group)
      if not push(table.concat(cells)) then
        -- Removing the last span, because the row was not written.
        while #spans > 0 and spans[#spans].row == #lines do
          spans[#spans] = nil
        end
        truncated = true
        break
      end
    end
    if #lines < max_rows then
      push("", nil)
    end
  end
  if truncated then
    local notice = string.format("… review truncated at inline.window.review.max_rows (%d)", max_rows)
    if lines[#lines] == "" then
      lines[#lines] = notice
    else
      lines[#lines + 1] = notice
    end
    spans[#spans + 1] = { row = #lines - 1, start = 0, stop = -1, group = "AcpInlineBanner" }
  end
  return { lines = lines, spans = spans, rows = rows, cols = cols, rendered = #rows }
end

---The historical single-column layout.
---@param hunks table[]
---@param opts {max_rows?: integer}
---@return table
function M.unified(hunks, opts)
  local max_rows = (opts and opts.max_rows) or 2000
  local lines, spans, rows = {}, {}, {}
  local truncated = false
  local function push(text, groups)
    lines[#lines + 1] = text
    for _, span in ipairs(groups or {}) do
      spans[#spans + 1] = { row = #lines - 1, start = span[1], stop = span[2], group = span[3] }
    end
  end
  for index, hunk in ipairs(hunks) do
    local needed = #hunk.old_lines + #hunk.new_lines + 2
    if #lines + needed > max_rows then
      truncated = true
      break
    end
    rows[index] = #lines + 1
    local status = M.status(hunk)
    local header = M.header(hunk, index, #hunks, false)
    push(header, header_spans(header, status))
    for _, line in ipairs(hunk.old_lines) do
      push("- " .. line, { { 0, -1, "AcpInlineDiffOld" } })
    end
    for _, line in ipairs(hunk.new_lines) do
      push("+ " .. line, { { 0, -1, "AcpInlineDiffNew" } })
    end
    push("", nil)
  end
  if truncated then
    local notice = string.format("… review truncated at inline.window.review.max_rows (%d)", max_rows)
    if lines[#lines] == "" then
      lines[#lines] = notice
    else
      lines[#lines + 1] = notice
    end
    spans[#spans + 1] = { row = #lines - 1, start = 0, stop = -1, group = "AcpInlineBanner" }
  end
  return { lines = lines, spans = spans, rows = rows, rendered = #rows }
end

---Render hunks, falling back to `unified` when a split would not fit.
---@param hunks table[]
---@param opts {width: integer, layout?: string, tabstop?: integer, max_rows?: integer, min_split_width?: integer}
---@return table
function M.render(hunks, opts)
  if (opts.layout or "side_by_side") == "side_by_side" then
    local split = M.side_by_side(hunks, opts)
    if split then
      split.layout = "side_by_side"
      return split
    end
  end
  local unified = M.unified(hunks, opts)
  unified.layout = "unified"
  return unified
end

return M
