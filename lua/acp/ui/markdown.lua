-- Inline Markdown parsing for a single line of agent output.
--
-- Why hand-rolled instead of treesitter `markdown_inline`: the inline grammar is
-- small, and measuring showed ~0.26 ms per line with a parser versus ~0.0035 ms
-- with a straight scan. The transcript re-renders on every stream tick, so the
-- cheap path wins by a wide margin.
--
-- Markup characters are *kept* in the text and hidden with `conceal`. Deleting
-- them would shift every byte offset after them, which the incremental render
-- cache and the extmark coordinates both depend on.
local M = {}

---@class AcpInlineSegment
---@field s integer start byte (0-based)
---@field e integer end byte (exclusive)
---@field group string
---@field conceal boolean|nil hide this range instead of styling it

---Byte length needed to skip a UTF-8 codepoint starting at `i`.
---@param s string
---@param i integer 1-based byte index
---@return integer
local function char_width(s, i)
  local byte = s:byte(i)
  if not byte then
    return 1
  end
  if byte >= 0xF0 then
    return 4
  elseif byte >= 0xE0 then
    return 3
  elseif byte >= 0xC0 then
    return 2
  end
  return 1
end

---Whether `i` is a valid byte index into `s`.
---@param s string
---@param i integer
---@return boolean
local function at(s, i)
  return i >= 1 and i <= #s
end

---Whether the character before `i` counts as a word boundary.
---
---Stops `snake_case` and `2*3*4` from turning into emphasis.
---@param s string
---@param i integer
---@return boolean
local function boundary_before(s, i)
  if i <= 1 then
    return true
  end
  local ch = s:sub(i - 1, i - 1)
  return not ch:match("[%w%u]")
end

---Whether the character at `i` (after a closing delimiter) counts as boundary.
---@param s string
---@param i integer
---@return boolean
local function boundary_after(s, i)
  if i > #s then
    return true
  end
  local ch = s:sub(i, i)
  return not ch:match("[%w%u]")
end

---Find a closing delimiter on the same line, ignoring escaped ones.
---@param s string
---@param delim string
---@param from integer 1-based index to start searching
---@return integer|nil position of the delimiter
local function find_close(s, delim, from)
  local i = from
  while true do
    local p = s:find(delim, i, true)
    if not p then
      return nil
    end
    -- Skip an escaped delimiter: `\` immediately before it.
    local escaped = p > 1 and s:sub(p - 1, p - 1) == "\\"
    if not escaped then
      return p
    end
    i = p + #delim
  end
end

---Parse a link `[text](url)` starting at `i`.
---@param s string
---@param i integer index of `[`
---@return AcpInlineSegment[]|nil segments for the whole construct
---@return integer|nil index of the closing `)` of the url
local function parse_link(s, i)
  local text_end = s:find("]", i + 1, true)
  if not text_end then
    return nil
  end
  if s:sub(text_end + 1, text_end + 1) ~= "(" then
    return nil
  end
  local url_end = s:find(")", text_end + 2, true)
  if not url_end then
    return nil
  end
  local label = s:sub(i + 1, text_end - 1)
  if label == "" then
    return nil
  end
  return {
    -- `[` and `]` are hidden; the label keeps its own range.
    { s = i - 1, e = i, conceal = true },
    { s = i, e = text_end - 1, group = "AcpMdLink" },
    { s = text_end - 1, e = text_end, conceal = true },
    -- `(url)` is hidden entirely.
    { s = text_end, e = url_end, conceal = true },
  },
    url_end
end

local EMPHASIS = {
  { delim = "**", group = "AcpBold", min = 1 },
  { delim = "__", group = "AcpBold", min = 1 },
  { delim = "~~", group = "AcpStrike", min = 1 },
  { delim = "*", group = "AcpItalic", min = 1 },
  { delim = "_", group = "AcpItalic", min = 1 },
}

---Parse one line of inline Markdown.
---
---Returns the segments in source order. Ranges use byte offsets into `line`, so
---the caller can keep the text untouched and conceal only the delimiters.
---@param line string
---@param base_hl string
---@return AcpInlineSegment[]
function M.parse_inline(line, base_hl)
  local segments = { { s = 0, e = #line, group = base_hl } }
  if line == "" then
    return segments
  end

  local extra = {}
  local i = 1
  while i <= #line do
    local byte = line:sub(i, i)

    -- Inline code has the highest priority: nothing inside it is parsed.
    if byte == "`" then
      local close = find_close(line, "`", i + 1)
      if close and close > i + 1 then
        extra[#extra + 1] = { s = i - 1, e = i, conceal = true }
        extra[#extra + 1] = { s = i, e = close - 1, group = "AcpMdCode" }
        extra[#extra + 1] = { s = close - 1, e = close, conceal = true }
        i = close + 1
      else
        i = i + 1
      end

    -- Links.
    elseif byte == "[" then
      local link, after = parse_link(line, i)
      if link then
        for _, seg in ipairs(link) do
          extra[#extra + 1] = seg
        end
        i = after + 1
      else
        i = i + 1
      end
    else
      -- Emphasis: try the longest delimiters first so `**` beats `*`.
      local matched = false
      if boundary_before(line, i) then
        for _, spec in ipairs(EMPHASIS) do
          local delim = spec.delim
          if line:sub(i, i + #delim - 1) == delim then
            local inner_start = i + #delim
            local close = find_close(line, delim, inner_start)
            if
              close
              and close > inner_start
              and boundary_after(line, close + #delim)
              and not line:sub(inner_start, inner_start):match("%s")
            then
              extra[#extra + 1] = { s = i - 1, e = inner_start - 1, conceal = true }
              extra[#extra + 1] = { s = inner_start - 1, e = close - 1, group = spec.group }
              extra[#extra + 1] = { s = close - 1, e = close + #delim - 1, conceal = true }
              i = close + #delim
              matched = true
              break
            end
          end
        end
      end
      if not matched then
        -- Advance one whole codepoint so multi-byte text is skipped correctly.
        i = i + char_width(line, i)
      end
    end
  end

  -- Emit in source order so overlapping ranges resolve predictably: later
  -- segments (inline code, links, emphasis) are appended after the base range.
  for _, seg in ipairs(extra) do
    segments[#segments + 1] = seg
  end
  return segments
end

---Whether any segment of the list should be concealed.
---@param segments AcpInlineSegment[]
---@return boolean
function M.has_conceal(segments)
  for _, seg in ipairs(segments) do
    if seg.conceal then
      return true
    end
  end
  return false
end

return M
