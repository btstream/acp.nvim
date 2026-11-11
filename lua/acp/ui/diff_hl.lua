-- Syntax highlighting for diff rows inside a tool card.
--
-- The visible rows of a diff are a window into a file that may be thousands of
-- lines long. Parsing the whole file just to colour a dozen rows costs 3 ms per
-- 200 lines and 90 ms at 5000 (measured), and the query walks every capture in
-- the file. Parsing only the rows that are actually drawn is 2 ms for 30 rows
-- and stays flat as the file grows, so that is what this module does.
--
-- Two fragments are parsed, one per side:
--
--   new side   context + added rows     (what the file looks like)
--   old side   context + removed rows   (what it looked like)
--
-- A row that appears on both sides is a context row. Keeping it in both
-- fragments is what makes the snippets parse correctly: a hunk that starts in
-- the middle of a function still sees the `end` below it.
local M = {}

local CodeHL = require("acp.ui.code_hl")

-- Beyond this many visible rows the colour is skipped and the diff stays plain.
-- At ~13 ms for 800 rows the cost is still bounded, but the return on a screen
-- full of diff is small and a slow first paint is very noticeable.
local DEFAULT_MAX_ROWS = 800

---Language of the file a diff belongs to.
---
---`vim.filetype.match` is the editor's own resolution, so a user's `ftdetect`
---rules apply. Fenced-code aliases are reused because a filetype is not a
---parser name (`sh` has no parser, `bash` does).
---@param path string
---@return string|nil
function M.language(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local ok, ft = pcall(vim.filetype.match, { filename = path })
  if not ok or type(ft) ~= "string" or ft == "" then
    return nil
  end
  return CodeHL.resolve_language(ft)
end

---Rows belonging to one side of the diff.
---@param lines AcpRenderedLine[]
---@param added boolean include added rows instead of removed ones
---@return {index: integer, text: string, offset: integer}[] rows
---@return string text fragment
local function side(lines, added)
  local rows, parts = {}, {}
  for index, line in ipairs(lines) do
    local first = (line.text or ""):sub(1, 2)
    local keep = first == "  "
    if added then
      keep = keep or first == "+ "
    else
      keep = keep or first == "- "
    end
    if keep then
      -- The card margin and the sign are not source text, so they are stripped
      -- before parsing and added back to the byte offsets afterwards.
      local offset = 2
      rows[#rows + 1] = { index = index, text = line.text:sub(offset + 1), offset = offset }
      parts[#parts + 1] = line.text:sub(offset + 1)
    end
  end
  return rows, table.concat(parts, "\n")
end

---Apply one side's syntax ranges to the rows that produced them.
---@param lines AcpRenderedLine[]
---@param rows {index: integer, offset: integer}[]
---@param ranges {row: integer, s: integer, e: integer, group: string}[]|nil
local function apply(lines, rows, ranges)
  if not ranges then
    return
  end
  -- Ranges are relative to the fragment; the fragment row order matches `rows`.
  local by_row = {}
  for _, range in ipairs(ranges) do
    by_row[range.row] = by_row[range.row] or {}
    table.insert(by_row[range.row], range)
  end
  for fragment_row, entry in ipairs(rows) do
    local line = lines[entry.index]
    if line then
      local kept = {}
      for _, seg in ipairs(line.segments or {}) do
        if not seg.syntax then
          kept[#kept + 1] = seg
        end
      end
      local byte_len = #line.text
      for _, range in ipairs(by_row[fragment_row - 1] or {}) do
        local s = math.min(entry.offset + range.s, byte_len)
        local e = range.e and math.min(entry.offset + range.e, byte_len) or byte_len
        if e > s then
          kept[#kept + 1] = { s = s, e = e, group = range.group, syntax = true }
        end
      end
      line.segments = kept
    end
  end
end

---Add syntax highlighting to a rendered diff.
---
---Mutates `lines` in place and returns them. Rows that already carry syntax
---segments are rebuilt first, so calling this twice is safe.
---@param lines AcpRenderedLine[]|nil
---@param path string|nil
---@param opts {enabled?: boolean, max_rows?: integer, deferred?: boolean}|nil
---@return AcpRenderedLine[]|nil
function M.attach(lines, path, opts)
  opts = opts or {}
  if opts.enabled == false or not lines or #lines == 0 then
    return lines
  end
  local max_rows = opts.max_rows or DEFAULT_MAX_ROWS
  if #lines > max_rows then
    return lines
  end
  local lang = M.language(path)
  if not lang then
    return lines
  end

  for _, added in ipairs({ true, false }) do
    local rows, text = side(lines, added)
    if #rows > 0 and text ~= "" then
      if opts.deferred then
        local source = { code = text, lang = lang }
        for row, entry in ipairs(rows) do
          local line = lines[entry.index]
          -- Match apply(): the later (old-side) syntax replaces context syntax.
          line.decorations = { { source = source, row = row - 1, offset = entry.offset } }
        end
      else
        local ranges, ok = CodeHL.highlight(text, lang)
        -- No parser installed: leave the diff as plain text rather than failing.
        if ok then
          apply(lines, rows, ranges)
        end
      end
    end
  end

  return lines
end

return M
