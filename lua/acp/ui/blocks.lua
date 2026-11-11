-- Turning session blocks into display lines.
--
-- Text layout lives in `acp.ui.text`; block-specific components live under
-- `acp.ui.blocks.*`. This module keeps the public entry points (`icon_set`,
-- `render_block`, `render_separator` and the historical text forwarders).

local M = {}

---@class AcpRenderedLine
---@field text string
---@field segments {s: integer, e: integer, group: string}[]|nil
---@field bg string|nil highlight group painted behind the whole line
---@field location table|nil jump target when the line is a file location

local Icons = require("acp.ui.icons")
local session_state = require("acp.session.state")
local text_layout = require("acp.ui.text")
local messages = require("acp.ui.blocks.messages")
local tool = require("acp.ui.blocks.tool")
local notices = require("acp.ui.blocks.notices")

---Resolve the icon set used for rendering.
---@param use_icons boolean
---@return table<string,string>
function M.icon_set(use_icons)
  return Icons.get(use_icons)
end

-- Text layout forwarders: keep the historical `acp.ui.blocks` entry points
-- working for callers and tests.
M.one_line = text_layout.one_line
M.truncate_width = text_layout.truncate_width
M.pad_to = text_layout.pad_to
M.render_text = text_layout.render_text
M.indent_lines = text_layout.indent_lines

local render_user = messages.render_user
local render_assistant = messages.render_assistant
local render_thought = messages.render_thought
local render_tool = tool.render_tool
local render_plan = notices.render_plan
local render_notice = notices.render_notice
local render_compaction = notices.render_compaction
local render_error = notices.render_error

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
local function render_block(block, ctx)
  -- Streaming text is buffered in chunks; join it so reads through
  -- `block.text` see the complete message.
  session_state.block_text(block)
  for _, key in ipairs({
    "_md_user",
    "_md_agent",
    "_md_thought",
    "_md_detail",
    "_md_compaction",
    "_md_error",
    "_md_system",
  }) do
    if block[key] then
      block[key].append_base = block._append_base
    end
  end
  -- Markdown caches are width-dependent (icon and truncation decisions differ
  -- per width) and must be dropped when the panel is resized.
  if block._md_width ~= ctx.width or block._md_lazy ~= ctx.lazy_syntax then
    block._md_width = ctx.width
    block._md_lazy = ctx.lazy_syntax
    block._md_user = nil
    block._md_agent = nil
    block._md_thought = nil
    block._md_detail = nil
    block._md_compaction = nil
    block._md_error = nil
    block._md_system = nil
  end
  local cache_key = ({
    user = "_md_user",
    agent = "_md_agent",
    thought = "_md_thought",
    tool = "_md_detail",
    compaction = "_md_compaction",
    error = "_md_error",
    system = "_md_system",
  })[block.kind]
  if cache_key then
    block[cache_key] = block[cache_key] or {}
    block[cache_key].lazy_syntax = ctx.lazy_syntax
    block[cache_key].checkpoint = ctx.checkpoint
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
    -- Live reasoning always keeps its header so "Thinking" stays visible.
    if not show_header and block.expanded ~= true and block.status ~= "streaming" then
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
    local lines = text_layout.render_text(block.text or "", "AcpMuted", ctx.width, block._md_system)
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

function M.render_block(block, ctx)
  local original
  if ctx.checkpoint then
    -- A cancelled coroutine must not leave published Markdown cache arrays or
    -- temporary expansion state half-mutated. Publish only a completed render.
    session_state.block_text(block)
    original = block
    block = vim.tbl_extend("force", {}, block)
    for key, value in pairs(block) do
      if type(key) == "string" and key:match("^_md_") and type(value) == "table" then
        block[key] = vim.tbl_extend("force", {}, value)
        if value.lines then
          block[key].lines = vim.list_slice(value.lines)
        end
      end
    end
  end
  local lines = render_block(block, ctx)
  if original then
    original._diff_cache = block._diff_cache
    for key in pairs(original) do
      if type(key) == "string" and key:match("^_md_") then
        original[key] = nil
      end
    end
    for key, value in pairs(block) do
      if type(key) == "string" and key:match("^_md_") then
        if type(value) == "table" then
          value.checkpoint = nil
        end
        original[key] = value
      end
    end
  end
  if block.truncated and #lines > 0 then
    for _, line in ipairs(lines) do
      if (line.text or ""):find("Truncated by local memory limit", 1, true) then
        return lines
      end
    end
    -- The underlying Markdown lines may be cached; never append to that array.
    lines = vim.list_slice(lines)
    lines[#lines + 1] =
      { text = "[Truncated by local memory limit]", segments = { { s = 0, e = -1, group = "AcpNoticeWarn" } } }
  end
  return lines
end

return M
