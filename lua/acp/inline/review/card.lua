-- Card-style diff rows for the fallback view.
--
-- This reuses the transcript's own diff renderer (`acp.ui.diff`), so the
-- fallback looks exactly like a tool card: the same backgrounds, the same
-- syntax highlighting, the same line caps. It only adds the hunk header, the
-- status gutter and the row-to-hunk map the review needs.
local M = {}

local Diff = require("acp.ui.diff")

---Gutter marker for a hunk's decision.
---@param hunk table
---@return string
local function marker(hunk)
  if not hunk.decided then
    return "  "
  end
  return hunk.accepted and "✓ " or "✗ "
end

---Header for a hunk in the fallback view.
---@param hunk table
---@param index integer
---@param total integer
---@return string
function M.header(hunk, index, total)
  local status = not hunk.decided and "pending" or (hunk.accepted and "accepted" or "rejected")
  return string.format(
    "@@ Hunk %d/%d · %s @@ -%d,%d +%d,%d",
    index,
    total,
    status,
    hunk.start + 1,
    #hunk.old_lines,
    (hunk.new_start or hunk.start) + 1,
    #hunk.new_lines
  )
end

---Build rows for every hunk.
---@param opts {
---  hunks: table[],
---  original: string[],
---  edited: string[],
---  path: string,
---  width: integer,
---  context?: integer,
---  syntax?: boolean,
---  max_rows?: integer
---}
---@return {lines: string[], spans: table[], rows: table, row_hunk: table, rendered: integer}
function M.build(opts)
  local lines, spans, rows, row_hunk = {}, {}, {}, {}
  local emitted = 0
  local max_rows = opts.max_rows or 4000
  local rendered = 0
  local truncated = false

  -- Card rows carry their own margin; the review adds a status gutter in front
  -- of every row so the marker column stays aligned with the text.
  local gutter = 2
  for index, hunk in ipairs(opts.hunks) do
    -- Use identical surrounding original lines on both sides, so nearby hunks
    -- remain independent while this card still shows real context.
    local context = opts.context or 0
    local before = vim.list_slice(opts.original, math.max(1, hunk.start - context + 1), hunk.start)
    local after = vim.list_slice(
      opts.original,
      hunk.start + #hunk.old_lines + 1,
      math.min(#opts.original, hunk.start + #hunk.old_lines + context)
    )
    local function text(changed)
      local snapshot = vim.list_extend(vim.deepcopy(before), changed)
      vim.list_extend(snapshot, after)
      return #snapshot > 0 and (table.concat(snapshot, "\n") .. "\n") or ""
    end
    local old_text, new_text = text(hunk.old_lines), text(hunk.new_lines)
    local prefix = marker(hunk)
    local block = Diff.lines({
      { path = opts.path, oldText = old_text, newText = new_text },
    }, {
      context = opts.context or 0,
      max_lines = math.max(1, max_rows - emitted - 2),
      syntax = opts.syntax ~= false,
      summary = opts.path,
      width = math.max(1, opts.width - gutter),
    })
    local needed = #block + 2
    if emitted + needed > max_rows then
      truncated = true
      break
    end
    rendered = rendered + 1
    rows[index] = #lines + 1
    local header = M.header(hunk, index, #opts.hunks)
    lines[#lines + 1] = prefix .. header
    spans[#spans + 1] = { row = #lines - 1, start = 0, stop = -1, group = "AcpInlineBanner" }
    row_hunk[#lines] = index
    for _, row in ipairs(block) do
      lines[#lines + 1] = prefix .. row.text
      row_hunk[#lines] = index
      if row.bg then
        spans[#spans + 1] = { row = #lines - 1, start = 0, stop = -1, group = row.bg }
      end
      for _, segment in ipairs(row.segments or {}) do
        spans[#spans + 1] = {
          row = #lines - 1,
          start = #prefix + (segment.s or 0),
          stop = segment.e and segment.e >= 0 and (#prefix + segment.e) or -1,
          group = segment.group,
        }
      end
    end
    lines[#lines + 1] = ""
    row_hunk[#lines] = false
    emitted = emitted + needed
  end
  if truncated then
    local notice = string.format("… review truncated at inline.window.review.max_rows (%d)", max_rows)
    if #lines >= max_rows then
      lines[#lines] = notice
    else
      lines[#lines + 1] = notice
    end
    spans[#spans + 1] = { row = #lines - 1, start = 0, stop = -1, group = "AcpInlineBanner" }
    row_hunk[#lines] = false
  end
  return { lines = lines, spans = spans, rows = rows, row_hunk = row_hunk, rendered = rendered }
end

return M
