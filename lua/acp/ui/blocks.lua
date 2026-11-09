-- Turning session blocks into display lines.

local M = {}

---@class AcpRenderedLine
---@field text string
---@field segments {s: integer, e: integer, group: string}[]|nil
---@field bg string|nil highlight group painted behind the whole line
---@field location table|nil jump target when the line is a file location

local Icons = require("acp.ui.icons")
local session_state = require("acp.session.state")

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
---@param state {in_fence: boolean, fence_lang: string|nil}
---@return AcpRenderedLine
local function render_line(raw, base_hl, state)
  local line = raw:gsub("\r$", "")
  local fence = line:match("^```(%S*)")
  if fence then
    state.in_fence = not state.in_fence
    state.fence_lang = state.in_fence and fence or nil
    local label = state.in_fence and (state.fence_lang ~= "" and state.fence_lang or "code") or ""
    return {
      text = state.in_fence and ("╭─ " .. label) or "╰─",
      segments = { { s = 0, e = -1, group = "AcpCodeFence" } },
    }
  end
  if state.in_fence then
    return {
      text = "│ " .. line,
      segments = { { s = 0, e = 1, group = "AcpCodeFence" } },
    }
  end
  local segments = { { s = 0, e = -1, group = base_hl } }
  local heading = line:match("^(#+)%s+(.*)")
  if heading then
    line = heading
    segments[1].group = "AcpHeading"
  elseif line:match("^>%s?") then
    line = line:gsub("^>%s?", "")
    segments[1].group = "AcpQuote"
  elseif line:match("^[%-%*]%s+") or line:match("^%d+[%.%)]%s+") then
    line = line:gsub("^([%-%*])%s+", "• "):gsub("^(%d+[%.%)])%s+", "%1 ")
  end
  -- inline code
  local pos = 1
  while true do
    local s, e = line:find("`[^`]+`", pos)
    if not s then
      break
    end
    segments[#segments + 1] = { s = s - 1, e = e, group = "AcpInlineCode" }
    pos = e + 1
  end
  return { text = line, segments = segments }
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
---@param cache {text: string, lines: AcpRenderedLine[], in_fence: boolean, fence_lang: string|nil, done: integer, final: integer}|nil
---@return AcpRenderedLine[]
function M.render_text(text, base_hl, width, cache)
  local lines
  local pos = 1
  local mark = { in_fence = false, fence_lang = nil }

  local resume = cache ~= nil
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
    pos = cache.done + 1
  else
    lines = {}
  end

  local search = pos
  while true do
    local nl = text:find("\n", search, true)
    if not nl then
      break
    end
    lines[#lines + 1] = render_line(text:sub(search, nl - 1), base_hl, mark)
    search = nl + 1
  end

  if cache then
    -- Snapshot the state *before* the trailing fragment, which is rendered
    -- again from scratch once more text arrives.
    cache.text = text
    cache.lines = lines
    cache.in_fence = mark.in_fence
    cache.fence_lang = mark.fence_lang
    cache.done = search - 1
    cache.final = #lines
  end

  local tail = text:sub(search)
  if tail ~= "" then
    lines[#lines + 1] = render_line(tail, base_hl, mark)
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
      }
    end
    out[#out + 1] = {
      text = head .. line.text,
      segments = segs,
      -- Background is line-wide, so it survives indentation unchanged.
      bg = line.bg,
      location = line.location,
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
  local header = ic.user .. " " .. "You"
  if #chips > 0 then
    header = header .. "  " .. table.concat(chips, " ")
  end
  local out = {
    { text = header, segments = { { s = 0, e = -1, group = "AcpUser" } } },
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
  local body = M.render_text(block.text or "", "AcpAssistant", ctx.width, block._md_agent)
  local out = M.indent_lines(body, string.rep(" ", #head), head)
  -- The header glyph belongs to the assistant highlight on the first line.
  if #out > 0 then
    out[1].segments =
      vim.list_extend({ { s = 0, e = #prefix + #ic.assistant, group = "AcpAssistant" } }, out[1].segments)
  else
    out[1] = { text = prefix .. ic.assistant, segments = { { s = 0, e = -1, group = "AcpAssistant" } } }
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

local function render_thought(block, ctx)
  block._md_thought = block._md_thought or {}
  local lines = M.render_text(block.text or "", "AcpThought", ctx.width, block._md_thought)
  local out = M.indent_lines(lines, "  ", (ctx.icons.thought .. " "))
  for _, line in ipairs(out) do
    line.segments = { { s = 0, e = -1, group = "AcpThought" } }
  end
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

local function render_tool(block, ctx)
  local ic = ctx.icons
  local glyph, glyph_hl = tool_icon(block, ic)
  local caret = block.expanded and ic.chevron_down or ic.chevron_right
  local title = one_line(block.title ~= nil and block.title ~= "" and block.title or (block.name or "tool"))
  local status = tool_status_label(block.status)
  local label = string.format("%s %s %s", caret, glyph, title)
  local caret_end = #caret
  local glyph_start = caret_end + 1
  local glyph_end = glyph_start + #glyph
  local title_start = glyph_end + 1
  local segments = {
    { s = 0, e = caret_end, group = "AcpSeparator" },
    { s = glyph_start, e = glyph_end, group = glyph_hl },
    { s = title_start, e = -1, group = "AcpToolTitle" },
  }
  local meta = {}
  if block.child and block.child.title then
    meta[#meta + 1] = "subagent" .. ": " .. one_line(block.child.title)
  end
  if status ~= "" then
    meta[#meta + 1] = status
  end
  local suffix = #meta > 0 and ("  " .. table.concat(meta, " · ")) or ""
  if suffix ~= "" then
    segments[#segments + 1] = { s = string.len(label), e = -1, group = glyph_hl }
  end
  local out = {
    {
      text = label .. suffix,
      segments = segments,
    },
  }

  if block.expanded then
    if block.detail and block.detail ~= "" then
      block._md_detail = block._md_detail or {}
      local lines = M.indent_lines(M.render_text(block.detail, "AcpMuted", ctx.width, block._md_detail), "    ")
      for _, line in ipairs(lines) do
        out[#out + 1] = line
      end
    end
    if block.locations and #block.locations > 0 then
      for _, loc in ipairs(block.locations) do
        local rel = one_line(loc.path or "")
        if ctx.cwd and vim.startswith(rel, ctx.cwd .. "/") then
          rel = rel:sub(#ctx.cwd + 2)
        end
        local text = string.format("    %s%s", rel, loc.line and (":" .. loc.line) or "")
        out[#out + 1] = {
          text = text,
          segments = { { s = 4, e = -1, group = "AcpLink" } },
          location = loc,
        }
      end
    end
    if block.status == "failed" and block.raw_output then
      local dump = type(block.raw_output) == "string" and block.raw_output or vim.inspect(block.raw_output)
      -- raw_output is not streamed; render it without a cache to keep the
      -- cache table keyed by block kind simple.
      for _, line in ipairs(M.indent_lines(M.render_text(dump, "AcpToolError", ctx.width), "    ")) do
        out[#out + 1] = line
      end
    end
  elseif block.detail and block.detail ~= "" then
    -- Extract the first line without splitting the whole (possibly huge)
    -- detail string into a table on every render tick.
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
    if not ctx.show_thoughts then
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
