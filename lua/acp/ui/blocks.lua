-- Turning session blocks into display lines.

local M = {}

---@class AcpRenderedLine
---@field text string
---@field segments {s: integer, e: integer, group: string}[]|nil
---@field bg string|nil highlight group painted behind the whole line
---@field location table|nil jump target when the line is a file location

local Icons = require("acp.ui.icons")
local session_state = require("acp.session.state")
local Markdown = require("acp.ui.markdown")
local CodeHL = require("acp.ui.code_hl")
local Table = require("acp.ui.table")

-- Prefix drawn in front of every line inside a fenced block.
-- Markdown body lines are indented by this many cells under the message header.
local BODY_INDENT = 2

-- Fenced code blocks are drawn as a background only: no border characters.
-- A small left gutter keeps the text off the surface's edge.
local CODE_GUTTER = "  "
local CODE_GUTTER_LEN = #CODE_GUTTER

---Heading groups produced by the Markdown scanner.
---
---A heading that opens an assistant turn names that turn, so it is restyled as
---`AcpAssistantTitle`; headings later in the body keep their level.
local HEADING_GROUPS = {
  AcpH1 = true,
  AcpH2 = true,
  AcpH3 = true,
  AcpH4 = true,
}

---Resolve the icon set used for rendering.
---@param use_icons boolean
---@return table<string,string>
function M.icon_set(use_icons)
  return Icons.get(use_icons)
end

---Collapse text into a single line.
---
---Agent supplied strings (titles, plan entries, notices) may contain newlines.
---A buffer line cannot contain a newline, so such text is folded into one
---line before it reaches the buffer.
---@param text any
---@return string
local function one_line(text)
  if type(text) ~= "string" then
    return text == nil and "" or tostring(text)
  end
  if not text:find("[\r\n]") then
    return text
  end
  return (text:gsub("\r\n", " "):gsub("[\r\n]", " "))
end

M.one_line = one_line

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
  if vim.api.nvim_strwidth(s) <= max then
    return s
  end
  local starts = char_starts(s)
  local lo, hi = 1, #starts - 1
  local best = 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if vim.api.nvim_strwidth(s:sub(1, starts[mid + 1] - 1)) <= max then
      best = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return s:sub(1, starts[best + 1] - 1)
end

local function tool_status_label(status)
  if status == "completed" then
    return "done"
  elseif status == "failed" then
    return "failed"
  elseif status == "cancelled" then
    return "cancelled"
  elseif status == "in_progress" then
    return "running"
  elseif status == "pending" then
    return "pending"
  end
  return ""
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

  local resume = not has_fence
    and cache ~= nil
    and type(cache.text) == "string"
    and #text >= #cache.text
    and text:sub(1, #cache.text) == cache.text

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
    local ranges, ok = CodeHL.highlight(table.concat(body, "\n"), lang)
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
    st.table_rows = nil
    if not rows or #rows == 0 then
      return
    end
    if Table.is_table(rows) then
      for _, line in ipairs(Table.render(Table.parse(rows), hl, w)) do
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
    cache.lines = lines
    cache.in_fence = mark.in_fence
    cache.fence_lang = mark.fence_lang
    cache.fence_code = mark.fence_code
    cache.fence_start = mark.fence_start
    cache.done = search - 1
    cache.final = #lines
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
    }
  end
  return out
end

local function render_user(block, ctx)
  local ic = ctx.icons
  local chips = {}
  if block.attachments then
    for _, att in ipairs(block.attachments) do
      chips[#chips + 1] = "[" .. one_line(att.label or att.path or "?") .. "]"
    end
  end
  -- The glyph and the name are separate regions: the icon marks who is
  -- speaking, the label names the turn, so they can be coloured apart.
  local label = "You"
  local header = ic.user .. " " .. label
  if #chips > 0 then
    header = header .. "  " .. table.concat(chips, " ")
  end
  local segments = {
    { s = 0, e = #ic.user, group = "AcpUserIcon" },
    { s = #ic.user + 1, e = #ic.user + 1 + #label, group = "AcpUserTitle" },
  }
  if #chips > 0 then
    -- Attachment chips keep the plain user colour rather than the title colour.
    segments[#segments + 1] = { s = #ic.user + 1 + #label, e = -1, group = "AcpUser" }
  end
  local out = {
    { text = header, segments = segments },
  }
  block._md_user = block._md_user or {}
  local body = M.indent_lines(M.render_text(block.text or "", "AcpUser", ctx.width, block._md_user), "  ")
  for _, line in ipairs(body) do
    out[#out + 1] = line
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

local function render_assistant(block, ctx)
  local ic = ctx.icons
  local prefix = block.child and (ic.child .. " ") or ""
  local head = prefix .. ic.assistant .. " "
  block._md_agent = block._md_agent or {}
  -- Body lines are indented by two cells, so a table has to fit in what remains.
  -- One extra cell is left spare so a full-width table does not sit against the
  -- window edge.
  local body_width = math.max(20, ctx.width - BODY_INDENT - 1)
  local body = M.render_text(block.text or "", "AcpAssistant", body_width, block._md_agent)

  -- A table cannot share a line with the header glyph: the icon would shift only
  -- the first row and break the columns. In that case the glyph gets its own
  -- line and the table starts below it.
  local starts_with_table = body[1] and body[1].table
  local out = {}
  if starts_with_table then
    out[1] = { text = prefix .. ic.assistant, segments = { { s = 0, e = -1, group = "AcpAssistantIcon" } } }
    for _, line in ipairs(M.indent_lines(body, string.rep(" ", BODY_INDENT))) do
      out[#out + 1] = line
    end
  else
    out = M.indent_lines(body, string.rep(" ", BODY_INDENT), head)
    -- The header glyph belongs to the assistant highlight on the first line.
    if #out > 0 then
      out[1].segments =
        vim.list_extend({ { s = 0, e = #prefix + #ic.assistant, group = "AcpAssistantIcon" } }, out[1].segments)
      -- When the turn opens with a heading, that line names it: style it as the
      -- block title instead of a generic heading, so it can be themed apart
      -- from headings in the body.
      for _, seg in ipairs(out[1].segments) do
        if seg.group and HEADING_GROUPS[seg.group] then
          seg.group = "AcpAssistantTitle"
        end
      end
    else
      out[1] = { text = prefix .. ic.assistant, segments = { { s = 0, e = -1, group = "AcpAssistantIcon" } } }
    end
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

local function render_thought(block, ctx)
  local ic = ctx.icons
  local thoughts = ctx.thoughts or {}
  -- A block that was never toggled follows the configured default; an explicit
  -- toggle always wins, so a user's choice is never overridden by a re-render.
  local expanded
  if block.expanded ~= nil then
    expanded = block.expanded == true
  else
    expanded = thoughts.default_expanded == true
  end
  local caret = expanded and ic.chevron_down or ic.chevron_right
  -- The header is always drawn when thoughts are enabled: without it there is
  -- nothing for the user to expand.
  --
  -- Only the icon and the label are highlighted; the disclosure caret keeps its
  -- own colour, so the header does not read as a solid block of search colour.
  local icon_start = #caret + 1
  local header = {
    text = caret .. " " .. ic.thought .. " Thinking",
    segments = {
      { s = 0, e = #caret, group = "AcpSeparator" },
      { s = icon_start, e = -1, group = "AcpThought" },
    },
  }
  if not expanded then
    return { header, { text = "", segments = nil } }
  end

  block._md_thought = block._md_thought or {}
  -- Expanded reasoning sits on the same surface as an expanded tool card, so the
  -- two read as the same kind of content. The body sets no highlight group of
  -- its own; it inherits the card background.
  local body = M.render_text(block.text or "", nil, ctx.width - 2, block._md_thought)
  local out = { header }
  out[#out + 1] = { text = "  ", segments = nil, bg = "AcpCardBg" }
  for _, line in ipairs(body) do
    out[#out + 1] = {
      text = "  " .. line.text,
      segments = vim.tbl_map(function(seg)
        return {
          s = seg.s + 2,
          e = seg.e >= 0 and seg.e + 2 or seg.e,
          group = seg.group,
          -- Conceal must survive the indent shift or markup markers reappear.
          conceal = seg.conceal,
        }
      end, line.segments or {}),
      bg = "AcpCardBg",
    }
  end
  out[#out + 1] = { text = "  ", segments = nil, bg = "AcpCardBg" }
  out[#out + 1] = { text = "", segments = nil }
  return out
end

local function tool_icon(block, ic)
  if block.status == "completed" then
    return ic.tool_ok, "AcpToolSuccess"
  elseif block.status == "failed" then
    return ic.tool_fail, "AcpToolError"
  elseif block.status == "cancelled" then
    return ic.tool_fail, "AcpToolCancelled"
  elseif block.status == "in_progress" then
    return ic.tool_run, "AcpToolRunning"
  end
  return ic.tool_pending, "AcpToolRunning"
end

-- Human-readable label for a tool call, derived from the ACP tool kind. Falls
-- back to the tool name so unknown kinds still say something useful.
local TOOL_LABELS = {
  execute = "Run Command",
  edit = "Write",
  write = "Write",
  read = "Read",
  search = "Search",
  fetch = "Fetch",
  think = "Thinking",
  delete = "Delete",
  move = "Move",
  switch_mode = "Switch Mode",
}

---@param block AcpBlock
---@return string
local function tool_label(block)
  local kind = block.tool_kind
  if type(kind) == "string" and TOOL_LABELS[kind] then
    return TOOL_LABELS[kind]
  end
  if type(kind) == "string" and kind ~= "" then
    -- Unknown kind: present it like the known ones.
    return (kind:gsub("_", " "):gsub("^%l", string.upper))
  end
  -- No kind at all: the agent's own title is the best label available.
  return "Tool"
end

---Secondary descriptor shown after the label: the agent's own summary of what
---the call does, which is usually more specific than the kind.
---@param block AcpBlock
---@return string
local function tool_title(block)
  local title = block.title
  if type(title) == "string" and title ~= "" then
    return one_line(title)
  end
  if block.name and block.name ~= "" then
    return one_line(block.name)
  end
  return ""
end

---Pad `text` with spaces to `width` display cells.
---Padding is real text because an extmark cannot colour past the end of a line.
---@param text string
---@param width integer
---@return string
function M.pad_to(text, width)
  local current = vim.api.nvim_strwidth(text)
  if current >= width then
    return text
  end
  return text .. string.rep(" ", width - current)
end

local function render_tool(block, ctx)
  local ic = ctx.icons
  local glyph, glyph_hl = tool_icon(block, ic)
  local caret = block.expanded and ic.chevron_down or ic.chevron_right
  local tag = tool_label(block)
  local title = tool_title(block)
  local status = tool_status_label(block.status)
  -- `Run Command · grep ... · done`. A title that merely repeats the label is
  -- dropped, and a title that starts with it keeps only the remainder, so
  -- `Read` + `Read src/auth.lua` reads as `Read · src/auth.lua` rather than
  -- losing the filename.
  local parts = { tag }
  if title ~= "" then
    local lower_tag = tag:lower()
    local lower_title = title:lower()
    if lower_title == lower_tag then
      -- Identical: keep just the label.
    elseif lower_title:sub(1, #lower_tag + 1) == lower_tag .. " " then
      parts[#parts + 1] = title:sub(#tag + 2)
    else
      parts[#parts + 1] = title
    end
  end

  local label = string.format("%s %s %s", caret, glyph, table.concat(parts, " · "))

  -- The suffix is built before the label is truncated, so the label leaves room
  -- for what is actually there rather than for a guess: a fixed reserve either
  -- overflows on a long subagent title or truncates the label for space that
  -- was never used.
  --
  -- The title is agent supplied and unbounded, so it is fitted to what the row
  -- leaves over and shrinks instead of pushing the header past the panel.
  local function build_suffix(child_title_)
    local meta = {}
    if child_title_ then
      meta[#meta + 1] = "subagent: " .. child_title_
    end
    if status ~= "" then
      meta[#meta + 1] = status
    end
    return #meta > 0 and ("  " .. table.concat(meta, " · ")) or ""
  end

  local child_title = block.child and block.child.title and one_line(block.child.title) or nil
  local suffix = build_suffix(child_title)
  if child_title then
    -- Shrink the title until the whole row fits. Measuring the assembled row
    -- rather than predicting its width keeps this correct for any combination
    -- of icon widths, separators and status text.
    local function row_width()
      return vim.api.nvim_strwidth(label) + vim.api.nvim_strwidth(suffix)
    end
    for _ = 1, 8 do
      if row_width() <= ctx.width then
        break
      end
      local current = vim.api.nvim_strwidth(child_title)
      if current <= 4 then
        break
      end
      local excess = row_width() - ctx.width
      child_title = M.truncate_width(child_title, math.max(3, current - excess - 1)) .. ic.more
      suffix = build_suffix(child_title)
    end
  end

  -- A shell command can be hundreds of columns long. The header is a summary;
  -- the full text is in the card body, so truncate to exactly what the panel
  -- leaves once the suffix is accounted for. Clamping to a fixed floor here
  -- would let a narrow panel be overflowed by the floor itself.
  local max_label = ctx.width - vim.api.nvim_strwidth(suffix)
  if vim.api.nvim_strwidth(label) > max_label then
    label = M.truncate_width(label, math.max(1, max_label - 1)) .. ic.more
  end

  local caret_end = #caret
  local glyph_start = caret_end + 1
  local glyph_end = glyph_start + #glyph
  local tag_start = glyph_end + 1
  local segments = {
    { s = 0, e = caret_end, group = "AcpSeparator" },
    { s = glyph_start, e = glyph_end, group = glyph_hl },
    -- Quiet by default: the header names the call, it is not the important part
    -- of the transcript. `AcpToolTitle` is a muted tone rather than a link to
    -- `Function`, which used to make long commands glare.
    { s = tag_start, e = -1, group = "AcpToolTag" },
  }
  if #parts > 1 then
    local shown_title = parts[2]
    local title_offset = #caret + 1 + #glyph + 1 + #tag + 3
    local available = #label - title_offset
    if available > 0 then
      local end_col = title_offset + math.min(#shown_title, available)
      segments[#segments + 1] = { s = title_offset, e = end_col, group = "AcpToolTitle" }
    end
  end

  if suffix ~= "" then
    segments[#segments + 1] = { s = #label, e = -1, group = "AcpMuted" }
  end
  local out = {
    { text = label .. suffix, segments = segments },
  }

  -- Card body: only when expanded and there is something to show.
  local body_lines = {}
  if block.detail and block.detail ~= "" then
    block._md_detail = block._md_detail or {}
    -- No base highlight group: card body text must inherit the card's own
    -- background. Any group carrying a background would repaint over it.
    for _, line in ipairs(M.render_text(block.detail, nil, ctx.width - 4, block._md_detail)) do
      body_lines[#body_lines + 1] = line
    end
  end
  if block.status == "failed" and block.raw_output then
    local dump = type(block.raw_output) == "string" and block.raw_output or vim.inspect(block.raw_output)
    for _, line in ipairs(M.render_text(dump, "AcpToolError", ctx.width - 4)) do
      body_lines[#body_lines + 1] = line
    end
  end

  if block.expanded and (#body_lines > 0 or (block.locations and #block.locations > 0)) then
    -- The card is padded so the background forms a solid block rather than
    -- hugging the text. Width is the panel width minus nothing: `hl_eol` fills
    -- the remaining cells, so the padding only needs to exist.
    out[#out + 1] = { text = "  ", bg = "AcpCardBg", segments = {} }
    for _, line in ipairs(body_lines) do
      out[#out + 1] = {
        text = "  " .. line.text,
        segments = vim.tbl_map(function(seg)
          return { s = seg.s + 2, e = seg.e >= 0 and seg.e + 2 or seg.e, group = seg.group, conceal = seg.conceal }
        end, line.segments or {}),
        bg = "AcpCardBg",
      }
    end
    for _, loc in ipairs(block.locations or {}) do
      local rel = one_line(loc.path or "")
      if ctx.cwd and vim.startswith(rel, ctx.cwd .. "/") then
        rel = rel:sub(#ctx.cwd + 2)
      end
      out[#out + 1] = {
        text = string.format("  %s%s", rel, loc.line and (":" .. loc.line) or ""),
        segments = { { s = 2, e = -1, group = "AcpLink" } },
        location = loc,
        bg = "AcpCardBg",
      }
    end
    out[#out + 1] = { text = "  ", bg = "AcpCardBg", segments = {} }
  elseif block.detail and block.detail ~= "" then
    -- Collapsed: one muted preview line, as before.
    local first = block.detail:match("([^\r\n]*)") or ""
    if first ~= "" then
      local maxw = math.max(10, ctx.width - 8)
      if vim.api.nvim_strwidth(first) > maxw then
        first = M.truncate_width(first, maxw - vim.api.nvim_strwidth(ic.more)) .. ic.more
      end
      out[#out + 1] = {
        text = "    " .. first,
        segments = { { s = 4, e = -1, group = "AcpMuted" } },
      }
    end
  end

  out[#out + 1] = { text = "", segments = nil }
  return out
end

local function render_plan(block, ctx)
  local ic = ctx.icons
  local out = {
    { text = ic.plan .. " " .. "Plan", segments = { { s = 0, e = -1, group = "AcpPlan" } } },
  }
  for _, entry in ipairs(block.entries or {}) do
    local mark, hl
    if entry.status == "completed" then
      mark, hl = ic.tool_ok, "AcpPlanDone"
    elseif entry.status == "in_progress" then
      mark, hl = ic.tool_run, "AcpPlan"
    else
      mark, hl = ic.tool_pending, "AcpPlanPending"
    end
    out[#out + 1] = {
      text = "  " .. mark .. " " .. one_line(entry.content or ""),
      segments = { { s = 2, e = 2 + #mark, group = hl } },
    }
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

local function render_notice(block, ctx)
  local hl = "AcpNotice"
  if block.severity == "warning" then
    hl = "AcpNoticeWarn"
  elseif block.severity == "error" then
    hl = "AcpNoticeError"
  end
  local text = string.format(
    "%s %s%s",
    ctx.icons.notice,
    block.title and (one_line(block.title) .. ": ") or "",
    one_line(block.text or "")
  )
  return { { text = text, segments = { { s = 0, e = -1, group = hl } } }, { text = "", segments = nil } }
end

local function render_compaction(block, ctx)
  local label
  if block.status == "in_progress" then
    label = "Context compacted" .. " …"
  elseif block.status == "failed" then
    label = "Context compacted" .. " (" .. "failed" .. ")"
  elseif block.status == "cancelled" then
    label = "Context compacted" .. " (" .. "cancelled" .. ")"
  else
    label = "Context compacted"
  end
  local out = {
    { text = "── " .. label .. " ──", segments = { { s = 0, e = -1, group = "AcpSeparator" } } },
  }
  if block.expanded and block.text and block.text ~= "" then
    block._md_compaction = block._md_compaction or {}
    for _, line in ipairs(M.indent_lines(M.render_text(block.text, "AcpMuted", ctx.width, block._md_compaction), "  ")) do
      out[#out + 1] = line
    end
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

local function render_error(block, ctx)
  block._md_error = block._md_error or {}
  local lines = M.render_text(block.text or "", "AcpToolError", ctx.width, block._md_error)
  local out = M.indent_lines(lines, "  ", ctx.icons.tool_fail .. " ")
  for _, line in ipairs(out) do
    line.segments = { { s = 0, e = -1, group = "AcpToolError" } }
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

---Render the divider drawn between conversation turns.
---
---The rule spans the transcript width and carries a centred marker: either a
---plain dot, or the turn number. Kept out of `render_block` because a turn is a
---property of the transcript, not of one block — the number depends on how many
---turns precede it.
---@param ctx {width: integer, icons: table}
---@param opts {form: string, turn: integer}
---@return AcpRenderedLine[]
function M.render_separator(ctx, opts)
  local width = math.max(1, ctx.width or 1)
  local ic = ctx.icons or {}
  local label
  if opts.form == "turn" and ic.history then
    label = string.format(" %s Turn %d ", ic.history, opts.turn or 1)
  else
    label = " ● "
  end
  local label_w = vim.api.nvim_strwidth(label)
  local rule_w = width - label_w
  if rule_w < 2 then
    -- Too narrow for a rule on both sides: the marker alone still separates.
    return { { text = label, segments = { { s = 0, e = -1, group = "AcpMuted" } } } }
  end
  local left = math.floor(rule_w / 2)
  local right = rule_w - left
  local left_text = string.rep("─", left)
  local text = left_text .. label .. string.rep("─", right)
  local label_s = #left_text
  return {
    {
      text = text,
      segments = {
        { s = 0, e = label_s, group = "AcpSeparator" },
        { s = label_s, e = label_s + #label, group = "AcpMuted" },
        { s = label_s + #label, e = -1, group = "AcpSeparator" },
      },
    },
  }
end

---Render a single block.
---@param block AcpBlock
---@param ctx {icons: table, width: integer, cwd: string|nil, show_thoughts: boolean}
---@return AcpRenderedLine[]
function M.render_block(block, ctx)
  -- Streaming text is buffered in chunks; join it so reads through
  -- `block.text` see the complete message.
  session_state.block_text(block)
  -- Markdown caches are width-dependent (icon and truncation decisions differ
  -- per width) and must be dropped when the panel is resized.
  if block._md_width ~= ctx.width then
    block._md_width = ctx.width
    block._md_user = nil
    block._md_agent = nil
    block._md_thought = nil
    block._md_detail = nil
    block._md_compaction = nil
    block._md_error = nil
    block._md_system = nil
  end
  local kind = block.kind
  if kind == "user" then
    return render_user(block, ctx)
  elseif kind == "agent" then
    return render_assistant(block, ctx)
  elseif kind == "thought" then
    -- `show_thoughts` is the legacy switch (fully visible); the newer
    -- `thoughts` table controls the collapsed/expanded default and whether a
    -- header is drawn at all.
    local thoughts = ctx.thoughts or {}
    local show_header = thoughts.show_collapsed_header ~= false
    if ctx.show_thoughts then
      -- Legacy switch: show the content without touching the block's own
      -- toggle state.
      local previous = block.expanded
      block.expanded = true
      local out = render_thought(block, ctx)
      block.expanded = previous
      return out
    end
    if not show_header and block.expanded ~= true then
      return {}
    end
    return render_thought(block, ctx)
  elseif kind == "tool" then
    return render_tool(block, ctx)
  elseif kind == "plan" then
    return render_plan(block, ctx)
  elseif kind == "notice" then
    return render_notice(block, ctx)
  elseif kind == "compaction" then
    return render_compaction(block, ctx)
  elseif kind == "error" then
    return render_error(block, ctx)
  elseif kind == "system" then
    -- System notices may span several lines; render them as such.
    block._md_system = block._md_system or {}
    local lines = M.render_text(block.text or "", "AcpMuted", ctx.width, block._md_system)
    local out = {}
    for _, line in ipairs(lines) do
      out[#out + 1] = {
        text = line.text,
        segments = { { s = 0, e = -1, group = "AcpMuted" } },
      }
    end
    out[#out + 1] = { text = "", segments = nil }
    return out
  end
  return {}
end

return M
