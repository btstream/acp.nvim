-- Plan, notice, compaction and error blocks.
local text_layout = require("acp.ui.text")

local M = {}

local one_line = text_layout.one_line
local render_text = text_layout.render_text
local indent_lines = text_layout.indent_lines

function M.render_plan(block, ctx)
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

function M.render_notice(block, ctx)
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

function M.render_compaction(block, ctx)
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
    for _, line in ipairs(indent_lines(render_text(block.text, "AcpMuted", ctx.width, block._md_compaction), "  ")) do
      out[#out + 1] = line
    end
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

function M.render_error(block, ctx)
  block._md_error = block._md_error or {}
  local lines = render_text(block.text or "", "AcpToolError", ctx.width, block._md_error)
  local out = indent_lines(lines, "  ", ctx.icons.tool_fail .. " ")
  for _, line in ipairs(out) do
    line.segments = { { s = 0, e = -1, group = "AcpToolError" } }
    line.decorations = nil
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

return M
