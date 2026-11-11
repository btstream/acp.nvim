-- User, assistant and thought blocks.
local text_layout = require("acp.ui.text")
local decoration = require("acp.ui.decoration")
local context = require("acp.context")

local M = {}

local one_line = text_layout.one_line
local render_text = text_layout.render_text
local indent_lines = text_layout.indent_lines

-- Markdown body lines are indented by this many cells under the message header.
local BODY_INDENT = 2

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

function M.render_user(block, ctx)
  local ic = ctx.icons
  local text, placed = context.display_text(block.text, block.attachments)
  local chips = {}
  if block.attachments then
    for _, att in ipairs(block.attachments) do
      if not placed[att] then
        chips[#chips + 1] = "[" .. one_line(att.label or att.path or "?") .. "]"
      end
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
  local body = indent_lines(render_text(text, "AcpUser", ctx.width, block._md_user), "  ")
  for _, line in ipairs(body) do
    out[#out + 1] = line
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

function M.render_assistant(block, ctx)
  local ic = ctx.icons
  local prefix = block.child and (ic.child .. " ") or ""
  local head = prefix .. ic.assistant .. " "
  block._md_agent = block._md_agent or {}
  -- Body lines are indented by two cells, so a table has to fit in what remains.
  -- One extra cell is left spare so a full-width table does not sit against the
  -- window edge.
  local body_width = math.max(20, ctx.width - BODY_INDENT - 1)
  local body = render_text(block.text or "", "AcpAssistant", body_width, block._md_agent)

  -- A table cannot share a line with the header glyph: the icon would shift only
  -- the first row and break the columns. In that case the glyph gets its own
  -- line and the table starts below it.
  local starts_with_table = body[1] and body[1].table
  local out = {}
  if starts_with_table then
    out[1] = { text = prefix .. ic.assistant, segments = { { s = 0, e = -1, group = "AcpAssistantIcon" } } }
    for _, line in ipairs(indent_lines(body, string.rep(" ", BODY_INDENT))) do
      out[#out + 1] = line
    end
  else
    out = indent_lines(body, string.rep(" ", BODY_INDENT), head)
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

function M.render_thought(block, ctx)
  local ic = ctx.icons
  local thoughts = ctx.thoughts or {}
  local streaming = block.status == "streaming"
  -- A block that was never toggled follows the configured default; an explicit
  -- toggle always wins, so a user's choice is never overridden by a re-render.
  -- Live reasoning is visible while it streams even if completed thoughts stay
  -- collapsed.
  local expanded
  if block.expanded ~= nil then
    expanded = block.expanded == true
  elseif streaming and thoughts.expand_while_streaming ~= false then
    expanded = true
  else
    expanded = thoughts.default_expanded == true
  end
  local label = streaming and "Thinking" or "Thought"
  local caret = expanded and ic.chevron_down or ic.chevron_right
  -- The header is always drawn when thoughts are enabled: without it there is
  -- nothing for the user to expand.
  --
  -- Only the icon and the label are highlighted; the disclosure caret keeps its
  -- own colour, so the header does not read as a solid block of search colour.
  local icon_start = #caret + 1
  local header = {
    text = caret .. " " .. ic.thought .. " " .. label,
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
  local body = render_text(block.text or "", nil, ctx.width - 2, block._md_thought)
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
      source = line.source,
      decorations = decoration.shift(line.decorations, 2),
    }
  end
  out[#out + 1] = { text = "  ", segments = nil, bg = "AcpCardBg" }
  out[#out + 1] = { text = "", segments = nil }
  return out
end

M.BODY_INDENT = BODY_INDENT

return M
