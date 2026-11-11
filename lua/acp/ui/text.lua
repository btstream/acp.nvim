-- Text layout engine for transcript content.
--
-- This module turns markdown-ish source into display rows: fenced code,
-- tables, headings, inline markup and the incremental streaming cache. It does
-- not know about ACP block kinds; `acp.ui.blocks` dispatches blocks to it.

local M = {}

---@class AcpRenderedLine
---@field text string
---@field segments {s: integer, e: integer, group: string}[]|nil
---@field bg string|nil highlight group painted behind the whole line
---@field location table|nil jump target when the line is a file location
---@field source integer|nil byte offset into the source text (for reflow anchors)
---@field decorations table[]|nil deferred syntax sources and row/column projections

local Markdown = require("acp.ui.markdown")
local CodeHL = require("acp.ui.code_hl")
local Table = require("acp.ui.table")
local decoration = require("acp.ui.decoration")

-- Fenced code blocks are drawn as a background only: no border characters.
-- A small left gutter keeps the text off the surface's edge.
local CODE_GUTTER = "  "
local CODE_GUTTER_LEN = #CODE_GUTTER

local cell_width = function(s)
  return vim.api.nvim_strwidth(s)
end

---Collapse text into a single line.
---
---Agent supplied strings (titles, plan entries, notices) may contain newlines.
---A buffer line cannot contain a newline, so such text is folded into one
---line before it reaches the buffer.
---@param text any
---@return string
function M.one_line(text)
  if type(text) ~= "string" then
    return text == nil and "" or tostring(text)
  end
  if not text:find("[\r\n]") then
    return text
  end
  return (text:gsub("\r\n", " "):gsub("[\r\n]", " "))
end

---Byte offsets where each UTF-8 codepoint starts (1-based, plus #s+1).
---@param s string
---@return integer[]
local function char_starts(s)
  local starts = { 1 }
  local i = 1
  local len = #s
  while i <= len do
    local byte = s:byte(i)
    local width = 1
    if byte >= 0xF0 then
      width = 4
    elseif byte >= 0xE0 then
      width = 3
    elseif byte >= 0xC0 then
      width = 2
    end
    i = i + width
    starts[#starts + 1] = i
  end
  return starts
end

---Longest prefix of `s` that fits in `max` display cells.
---@param s string
---@param max integer
---@return string
function M.truncate_width(s, max)
  if max <= 0 then
    return ""
  end
  if cell_width(s) <= max then
    return s
  end
  local starts = char_starts(s)
  local lo, hi = 1, #starts - 1
  local best = 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if cell_width(s:sub(1, starts[mid + 1] - 1)) <= max then
      best = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return s:sub(1, starts[best + 1] - 1)
end

---Pad `text` with spaces to `width` display cells.
---Padding is real text because an extmark cannot colour past the end of a line.
---@param text string
---@param width integer
---@return string
function M.pad_to(text, width)
  local current = cell_width(text)
  if current >= width then
    return text
  end
  return text .. string.rep(" ", width - current)
end

---Render one markdown-ish line, toggling fenced-code state in `state`.
---@param raw string
---@param base_hl string
---@param state {in_fence: boolean, fence_lang: string|nil, fence_start: integer|nil, fence_code: string[]|nil}
---@return AcpRenderedLine|nil line, or nil when the source line produces no row
---@return string|nil flag "code_close" when a fence just closed
local function render_line(raw, base_hl, state)
  local line = raw:gsub("\r$", "")
  local fence = line:match("^```(%S*)")
  if fence then
    if state.in_fence then
      -- Closing fence: the code follows, so keep the language available until
      -- the caller has produced the highlighted segments. No row is emitted:
      -- the surface ends with the last code line, and a blank line here would
      -- be one the source text did not have.
      state.in_fence = false
      return nil, "code_close"
    end
    state.in_fence = true
    state.fence_lang = fence
    state.fence_code = {}
    return {
      -- The language label sits on the block's top row and acts as padding.
      text = fence ~= "" and fence or "",
      segments = { { s = 0, e = -1, group = "AcpCodeLang" } },
      bg = "AcpCodeBlockBg",
      code_open = true,
    }
  end
  if state.in_fence then
    if state.fence_code then
      state.fence_code[#state.fence_code + 1] = line
    end
    return {
      text = CODE_GUTTER .. line,
      segments = nil,
      bg = "AcpCodeBlockBg",
      code = true,
    }
  end
  local base = base_hl
  local heading_level, heading_text = line:match("^(#+)%s+(.*)")
  if heading_level then
    line = heading_text
    -- Levels 1..4 get their own group; deeper headings reuse the last one.
    base = "AcpH" .. math.min(#heading_level, 4)
  elseif line:match("^>%s?") then
    line = line:gsub("^>%s?", "")
    base = "AcpQuote"
  elseif line:match("^[%-%*]%s+") or line:match("^%d+[%.%)]%s+") then
    line = line:gsub("^([%-%*])%s+", "• "):gsub("^(%d+[%.%)])%s+", "%1 ")
  end
  -- Inline markup. The text keeps its delimiters; they are concealed later, so
  -- the byte offsets stay identical to `line`.
  return { text = line, segments = Markdown.parse_inline(line, base) }
end

---Render markdown-ish text into lines with simple inline highlighting.
---
---Streaming agents append to the same block many times per second. When a
---`cache` table is supplied, successive calls reuse the lines already rendered
---and only process the new tail, turning per-turn O(L²) work into O(L).
---
---The returned lines are owned by the cache: callers must not mutate them
---(they are reused verbatim on the next call).
---@param text string
---@param base_hl string
---@param width integer
---@param cache {text: string, lines: AcpRenderedLine[], in_fence: boolean, fence_lang: string|nil, fence_code: string[]|nil, fence_start: integer|nil, done: integer, final: integer}|nil
---@return AcpRenderedLine[]
function M.render_text(text, base_hl, width, cache)
  -- Blocks that contain a fence are always re-rendered in full.
  --
  -- Highlighting needs the complete fence body, and a streaming block crosses
  -- several states (open fence, closed fence, text appending after it). Making
  -- every one of those transitions agree with an incremental prefix is where
  -- stale and duplicated segments came from, so correctness wins: fenced blocks
  -- are a minority and the parse result is cached on the block.
  local has_fence = text:find("```", 1, true) ~= nil

  local lines
  local pos = 1
  local mark = { in_fence = false, fence_lang = nil, fence_code = nil, fence_start = nil }
  local previous_fences = cache and cache.code_fences or {}
  local fences = {}

  local resume = not has_fence
    and cache ~= nil
    and type(cache.text) == "string"
    and #text >= #cache.text
    and (cache.append_base == cache.text or text:sub(1, #cache.text) == cache.text)

  if resume then
    lines = cache.lines
    -- Drop the trailing partial line rendered last time; it is re-rendered.
    for i = #lines, (cache.final or 0) + 1, -1 do
      lines[i] = nil
    end
    mark.in_fence = cache.in_fence
    mark.fence_lang = cache.fence_lang
    mark.fence_code = cache.fence_code
    mark.fence_start = cache.fence_start
    pos = cache.done + 1
  else
    lines = {}
  end

  ---Apply syntax highlighting to the code rows emitted for the fence that just
  ---closed. The fence is only parsed once it is complete, so a streaming block
  ---never pays for a partial parse.
  local function close_fence()
    local lang = mark.fence_lang
    local body = mark.fence_code
    local start = mark.fence_start
    if not lang or not body or not start or #body == 0 then
      return
    end
    local code = table.concat(body, "\n")
    if cache and cache.lazy_syntax then
      local source = { code = code, lang = lang }
      for row = 0, #body - 1 do
        local line = lines[start + row]
        if line then
          line.decorations = { { source = source, row = row, offset = CODE_GUTTER_LEN } }
        end
      end
      return
    end
    local saved = previous_fences[#fences + 1]
    local ranges, ok
    if saved and saved.code == code and saved.lang == lang and saved.ok and saved.generation == CodeHL.generation then
      ranges, ok = saved.ranges, true
    else
      ranges, ok = CodeHL.highlight(code, lang)
    end
    fences[#fences + 1] = { code = code, lang = lang, ranges = ranges, ok = ok, generation = CodeHL.generation }
    if not ok or not ranges then
      return
    end
    -- Group the ranges by code row.
    local by_row = {}
    for _, r in ipairs(ranges) do
      by_row[r.row] = by_row[r.row] or {}
      table.insert(by_row[r.row], r)
    end
    for row, list in pairs(by_row) do
      local line = lines[start + row]
      if line then
        -- Rebuild the segment list from scratch: a streaming render reuses the
        -- cached line table, so appending would stack duplicate ranges on every
        -- tick where the fence happens to be closed.
        local kept = {}
        for _, seg in ipairs(line.segments or {}) do
          if not seg.syntax then
            kept[#kept + 1] = seg
          end
        end
        local byte_len = #line.text
        for _, r in ipairs(list) do
          local s = math.min(CODE_GUTTER_LEN + r.s, byte_len)
          local e = r.e and math.min(CODE_GUTTER_LEN + r.e, byte_len) or byte_len
          if e > s then
            kept[#kept + 1] = { s = s, e = e, group = r.group, syntax = true }
          end
        end
        line.segments = kept
      end
    end
  end

  ---Draw the rows collected for a table (if it really is one) and reset state.
  ---A lone line containing a pipe is prose, so it is rendered normally instead.
  ---@param out AcpRenderedLine[]
  ---@param st table
  ---@param hl string|nil
  ---@param w integer
  local function flush_table(out, st, hl, w)
    local rows = st.table_rows
    local source_start = st.table_start
    st.table_rows = nil
    st.table_start, st.table_final = nil, nil
    if not rows or #rows == 0 then
      return
    end
    if Table.is_table(rows) then
      local offsets, offset = {}, source_start
      for i, raw in ipairs(rows) do
        offsets[i] = offset
        if offset then
          offset = offset + #raw + 1
        end
      end
      for _, line in ipairs(Table.render(Table.parse(rows), hl, w)) do
        line.source = offsets[line.table_row or 1]
        out[#out + 1] = line
      end
      return
    end
    -- Not a table after all: render the collected lines as ordinary text.
    for _, raw in ipairs(rows) do
      local line = render_line(raw, hl, st)
      if line then
        out[#out + 1] = line
        line.code_open = nil
        line.code = nil
      end
    end
  end

  local search = pos
  while true do
    local nl = text:find("\n", search, true)
    if not nl then
      break
    end
    local raw_start = search
    local raw = text:sub(search, nl - 1)
    search = nl + 1

    -- Table rows are collected first and drawn once, because column widths
    -- depend on every row.
    if mark.table_rows then
      if raw:find("|", 1, true) then
        mark.table_rows[#mark.table_rows + 1] = raw
        goto continue
      end
      flush_table(lines, mark, base_hl, width)
    end
    if not mark.in_fence and raw:find("|", 1, true) then
      mark.table_rows = { raw }
      mark.table_start, mark.table_final = raw_start, #lines
      goto continue
    end

    do
      local line, flag = render_line(raw, base_hl, mark)
      if flag == "code_close" then
        -- The closing fence emits no row of its own.
        close_fence()
        mark.fence_code = nil
        mark.fence_lang = nil
        mark.fence_start = nil
      elseif line then
        line.source = raw_start
        lines[#lines + 1] = line
        if line.code_open then
          -- The fence marker itself is the last pushed line; code starts after it.
          mark.fence_start = #lines + 1
        end
        -- `code_open`/`code` are transient routing flags that must not leak into
        -- the cached line table.
        line.code_open = nil
        line.code = nil
      end
    end
    ::continue::
  end

  if cache then
    -- Snapshot the state *before* the trailing fragment, which is rendered
    -- again from scratch once more text arrives.
    cache.text = text
    cache.append_base = nil
    cache.code_fences = fences
    cache.lines = lines
    cache.in_fence = mark.in_fence
    cache.fence_lang = mark.fence_lang
    cache.fence_code = mark.fence_code
    cache.fence_start = mark.fence_start
    -- An unfinished table is one layout unit: later rows can change every
    -- column width. Its collected source rows have not been committed to the
    -- stable prefix yet. Resume at its first row, not at the last newline.
    cache.done = (mark.table_start or search) - 1
    cache.final = mark.table_final or #lines
  end

  -- The final fragment has no trailing newline. It still has to go through the
  -- table collector: a table at the end of the text would otherwise render its
  -- first rows and lose the last one.
  local tail = text:sub(search)
  if tail ~= "" then
    local in_table = mark.table_rows ~= nil or (not mark.in_fence and tail:find("|", 1, true) ~= nil)
    if in_table then
      if mark.table_rows then
        mark.table_rows[#mark.table_rows + 1] = tail
      else
        mark.table_rows = { tail }
      end
      flush_table(lines, mark, base_hl, width)
    else
      local line, flag = render_line(tail, base_hl, mark)
      if flag == "code_close" then
        close_fence()
        mark.fence_code = nil
        mark.fence_lang = nil
        mark.fence_start = nil
      elseif line then
        line.source = search
        lines[#lines + 1] = line
        if line.code_open then
          mark.fence_start = #lines + 1
        end
        line.code_open = nil
        line.code = nil
      end
    end
  end
  -- A table whose last row had no trailing newline is closed here.
  if mark.table_rows then
    flush_table(lines, mark, base_hl, width)
  end

  return lines
end

---Copy rendered lines, prepending `prefix` to every line and shifting the
---highlight segments to match. Needed because cached lines must stay pristine.
---@param lines AcpRenderedLine[]
---@param prefix string
---@param first_prefix string|nil text replacing the prefix on the first line
---@return AcpRenderedLine[]
function M.indent_lines(lines, prefix, first_prefix)
  local out = {}
  for i, line in ipairs(lines) do
    local head = (i == 1 and first_prefix ~= nil) and first_prefix or prefix
    local segs = {}
    for _, seg in ipairs(line.segments or {}) do
      segs[#segs + 1] = {
        s = seg.s + #head,
        e = seg.e >= 0 and (seg.e + #head) or seg.e,
        group = seg.group,
        -- Conceal must survive indentation or markup delimiters reappear.
        conceal = seg.conceal,
      }
    end
    out[#out + 1] = {
      text = head .. line.text,
      segments = segs,
      -- Background is line-wide, so it survives indentation unchanged.
      bg = line.bg,
      location = line.location,
      table = line.table,
      source = line.source,
      decorations = decoration.shift(line.decorations, #head),
    }
  end
  return out
end

return M
